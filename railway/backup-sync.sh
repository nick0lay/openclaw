#!/usr/bin/env bash
# railway-backup-sync.sh
#
# Syncs OpenClaw state between a Railway Volume and a Railway Bucket (S3).
# Runs inside the Railway template container alongside the gateway.
#
# Modes:
#   restore  — Download from bucket → local volume (run before gateway starts)
#   backup   — Upload local volume → bucket (run periodically or on shutdown)
#   loop     — Run backup every BACKUP_INTERVAL_SEC (default 300s / 5 min)
#
# Required env vars (auto-injected by Railway when a Bucket is attached):
#   BUCKET              — S3 bucket name
#   ACCESS_KEY_ID       — S3 access key
#   SECRET_ACCESS_KEY   — S3 secret key
#   ENDPOINT            — S3 endpoint URL (e.g. https://storage.railway.app)
#   REGION              — S3 region (typically "auto")
#
# Optional env vars:
#   OPENCLAW_STATE_DIR      — local state dir (default: /data/.openclaw)
#   BACKUP_INTERVAL_SEC     — seconds between backups in loop mode (default: 300)
#   BACKUP_S3_PREFIX        — prefix inside bucket (default: "openclaw-state")
#   BACKUP_ENABLED          — set to "false" to disable (default: "true")

set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
INTERVAL="${BACKUP_INTERVAL_SEC:-300}"
S3_PREFIX="${BACKUP_S3_PREFIX:-openclaw-state}"
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
SQLITE_BACKUP_DIR="/tmp/openclaw-sqlite-backup"

S3_DEST="s3://${BUCKET}/${S3_PREFIX}"

# ── Pre-flight checks ───────────────────────────────────────────────

check_env() {
  local missing=()
  for var in BUCKET ACCESS_KEY_ID SECRET_ACCESS_KEY ENDPOINT REGION; do
    if [ -z "${!var:-}" ]; then
      missing+=("$var")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[backup-sync] Missing env vars: ${missing[*]}"
    echo "[backup-sync] Attach a Railway Bucket to enable backup sync."
    return 1
  fi
}

# Configure aws CLI for Railway's S3-compatible endpoint.
configure_aws() {
  export AWS_ACCESS_KEY_ID="$ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION="$REGION"
  # Railway uses virtual-hosted-style URLs by default.
  # --endpoint-url is passed per-command.
}

aws_s3() {
  aws s3 "$@" --endpoint-url "$ENDPOINT" --no-progress 2>&1
}

# ── SQLite safe backup ──────────────────────────────────────────────

# Uses sqlite3 .backup API to create a consistent copy of each open database.
# This is safe to run while the gateway has the DB open.
backup_sqlite_databases() {
  mkdir -p "$SQLITE_BACKUP_DIR"
  local count=0

  if [ ! -d "${STATE_DIR}/memory" ]; then
    return 0
  fi

  for db in "${STATE_DIR}"/memory/*.sqlite; do
    [ -f "$db" ] || continue
    local name
    name=$(basename "$db")
    local dest="${SQLITE_BACKUP_DIR}/${name}"

    # sqlite3 .backup uses the backup API — safe on a running database.
    # It acquires a shared lock, copies pages, and handles concurrent writes.
    if sqlite3 "$db" ".backup '${dest}'" 2>/dev/null; then
      count=$((count + 1))
    else
      echo "[backup-sync] Warning: failed to backup $name (may be locked, will retry next cycle)"
    fi
  done

  echo "[backup-sync] Backed up $count SQLite database(s)"
}

# ── Restore ─────────────────────────────────────────────────────────

# Downloads state from the bucket into the local volume.
# Only runs if the local state dir is empty or missing (fresh deploy / volume wipe).
do_restore() {
  if [ -f "${STATE_DIR}/openclaw.json" ]; then
    echo "[backup-sync] Local state exists (${STATE_DIR}/openclaw.json), skipping restore."
    return 0
  fi

  echo "[backup-sync] Local state dir is empty — restoring from bucket..."
  mkdir -p "$STATE_DIR"

  # Check if the bucket has any data for us.
  local file_count
  file_count=$(aws_s3 ls "${S3_DEST}/" 2>/dev/null | head -5 | wc -l | tr -d ' ' || echo "0")
  if [ "${file_count:-0}" -eq 0 ] 2>/dev/null; then
    echo "[backup-sync] Bucket is empty (${S3_DEST}/), nothing to restore. Fresh install."
    return 0
  fi

  # Restore all files except SQLite databases (they go to a separate prefix).
  aws_s3 sync "${S3_DEST}/files/" "$STATE_DIR" \
    --exclude "*.lock" \
    --exclude "*.tmp"
  echo "[backup-sync] Restored files from bucket."

  # Restore SQLite databases.
  if aws_s3 ls "${S3_DEST}/sqlite/" >/dev/null 2>&1; then
    mkdir -p "${STATE_DIR}/memory"
    aws_s3 sync "${S3_DEST}/sqlite/" "${STATE_DIR}/memory/" \
      --exclude "*.lock" \
      --exclude "*.tmp"
    echo "[backup-sync] Restored SQLite databases from bucket."
  fi

  echo "[backup-sync] Restore complete."
}

# ── Backup ──────────────────────────────────────────────────────────

# Uploads local state to the bucket.
do_backup() {
  echo "[backup-sync] Starting backup to ${S3_DEST}..."

  # 1. Safe-copy SQLite databases first.
  backup_sqlite_databases

  # 2. Sync all non-SQLite files to bucket.
  #    Excludes: lock files, temp files, media (ephemeral, 2-min TTL),
  #    and the live .sqlite files (we upload the safe copies instead).
  aws_s3 sync "$STATE_DIR" "${S3_DEST}/files/" \
    --exclude "*.lock" \
    --exclude "*.tmp" \
    --exclude "media/*" \
    --exclude "memory/*.sqlite" \
    --exclude "memory/*.sqlite-wal" \
    --exclude "memory/*.sqlite-shm" \
    --delete
  echo "[backup-sync] Synced files."

  # 3. Upload the safe SQLite copies.
  if [ -d "$SQLITE_BACKUP_DIR" ] && [ "$(ls -A "$SQLITE_BACKUP_DIR" 2>/dev/null)" ]; then
    aws_s3 sync "$SQLITE_BACKUP_DIR" "${S3_DEST}/sqlite/" \
      --delete
    echo "[backup-sync] Synced SQLite backups."
  fi

  # 4. Write a timestamp marker so we know when the last backup ran.
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"last_backup\":\"${ts}\",\"state_dir\":\"${STATE_DIR}\"}" > /tmp/backup-marker.json
  aws_s3 cp /tmp/backup-marker.json "${S3_DEST}/backup-marker.json"

  echo "[backup-sync] Backup complete at ${ts}."
}

# ── Loop mode ───────────────────────────────────────────────────────

# Runs backup on a schedule. Handles SIGTERM for a final backup before exit.
do_loop() {
  local running=true

  # Trap SIGTERM/SIGINT for graceful shutdown with final backup.
  trap 'echo "[backup-sync] Received shutdown signal, running final backup..."; do_backup; running=false' TERM INT

  echo "[backup-sync] Starting backup loop (interval: ${INTERVAL}s)"

  while $running; do
    sleep "$INTERVAL" &
    wait $! || true  # wait is interruptible by trap
    if $running; then
      do_backup || echo "[backup-sync] Backup failed, will retry next cycle."
    fi
  done

  echo "[backup-sync] Backup loop stopped."
}

# ── Main ────────────────────────────────────────────────────────────

main() {
  if [ "$BACKUP_ENABLED" = "false" ]; then
    echo "[backup-sync] Backup disabled (BACKUP_ENABLED=false). Exiting."
    exit 0
  fi

  if ! check_env; then
    echo "[backup-sync] S3 credentials not configured. Backup sync disabled."
    exit 0
  fi

  configure_aws

  local mode="${1:-loop}"
  case "$mode" in
    restore)
      do_restore
      ;;
    backup)
      do_backup
      ;;
    loop)
      do_loop
      ;;
    *)
      echo "Usage: $0 {restore|backup|loop}"
      exit 1
      ;;
  esac
}

main "$@"
