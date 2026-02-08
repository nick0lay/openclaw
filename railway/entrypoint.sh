#!/usr/bin/env bash
# railway-entrypoint.sh
#
# Entrypoint for the Railway template container.
# Orchestrates: restore from bucket → start gateway → backup loop → graceful shutdown.
#
# This script replaces the default CMD and manages three processes:
#   1. Restore from S3 (blocking, runs first)
#   2. OpenClaw gateway (main process)
#   3. Backup sync loop (background process)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup-sync.sh"
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"

GATEWAY_PID=""
BACKUP_PID=""

cleanup() {
  echo "[entrypoint] Shutting down..."

  # Stop the gateway gracefully.
  if [ -n "$GATEWAY_PID" ] && kill -0 "$GATEWAY_PID" 2>/dev/null; then
    echo "[entrypoint] Stopping gateway (PID $GATEWAY_PID)..."
    kill -TERM "$GATEWAY_PID" 2>/dev/null || true
    wait "$GATEWAY_PID" 2>/dev/null || true
  fi

  # The backup loop's SIGTERM trap runs a final backup before exiting.
  if [ -n "$BACKUP_PID" ] && kill -0 "$BACKUP_PID" 2>/dev/null; then
    echo "[entrypoint] Stopping backup sync (PID $BACKUP_PID)..."
    kill -TERM "$BACKUP_PID" 2>/dev/null || true
    wait "$BACKUP_PID" 2>/dev/null || true
  fi

  echo "[entrypoint] Shutdown complete."
  exit 0
}

trap cleanup TERM INT

# ── Step 0: Ensure volume directories exist ─────────────────────────

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
mkdir -p "$STATE_DIR" /tmp/openclaw-sqlite-backup

# ── Step 1: Restore from bucket (if volume is empty) ───────────────
#
# Restore runs BEFORE config injection so that a fresh state dir
# (e.g., switching OPENCLAW_STATE_DIR to trigger a restore) is not
# blocked by inject_railway_config creating openclaw.json first.

if [ "$BACKUP_ENABLED" = "true" ] && [ -f "$BACKUP_SCRIPT" ]; then
  echo "[entrypoint] Running restore check..."
  bash "$BACKUP_SCRIPT" restore || echo "[entrypoint] Restore skipped or failed (non-fatal)."
fi

# ── Step 2: Inject Railway-specific gateway config ─────────────────
#
# Railway's reverse proxy forwards requests from internal IPs (100.64.0.0/10)
# with X-Forwarded-For headers. The gateway sees these as untrusted proxy
# connections and requires device pairing for the Control UI.
#
# We disable device auth for the Control UI (token/password auth still applies).

CONFIG_FILE="${STATE_DIR}/openclaw.json"

inject_railway_config() {
  if [ -f "$CONFIG_FILE" ]; then
    echo "[entrypoint] Merging Railway config into existing ${CONFIG_FILE}..."
    # Use node to merge JSON safely (preserves user settings).
    node -e "
      const fs = require('fs');
      const cfg = JSON.parse(fs.readFileSync('${CONFIG_FILE}', 'utf8'));
      if (!cfg.gateway) cfg.gateway = {};
      if (!cfg.gateway.controlUi) cfg.gateway.controlUi = {};
      cfg.gateway.controlUi.dangerouslyDisableDeviceAuth = true;
      // Re-enable plugins if previously disabled by an older entrypoint.
      if (cfg.plugins) {
        if (cfg.plugins.enabled === false) delete cfg.plugins.enabled;
        if (cfg.plugins.slots && cfg.plugins.slots.memory === 'none') {
          delete cfg.plugins.slots.memory;
          if (Object.keys(cfg.plugins.slots).length === 0) delete cfg.plugins.slots;
        }
        if (Object.keys(cfg.plugins).length === 0) delete cfg.plugins;
      }
      fs.writeFileSync('${CONFIG_FILE}', JSON.stringify(cfg, null, 2) + '\n');
    "
  else
    echo "[entrypoint] Creating Railway config at ${CONFIG_FILE}..."
    cat > "$CONFIG_FILE" <<'CFGEOF'
{
  "gateway": {
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
CFGEOF
  fi
}

inject_railway_config

# ── Step 3: Start OpenClaw gateway ─────────────────────────────────

echo "[entrypoint] Starting OpenClaw gateway..."

node openclaw.mjs gateway --allow-unconfigured --bind lan --port "${PORT:-18789}" &
GATEWAY_PID=$!

echo "[entrypoint] Gateway started (PID $GATEWAY_PID)."

# ── Step 4: Start backup loop (background) ─────────────────────────

if [ "$BACKUP_ENABLED" = "true" ] && [ -f "$BACKUP_SCRIPT" ]; then
  echo "[entrypoint] Starting backup sync loop..."
  bash "$BACKUP_SCRIPT" loop &
  BACKUP_PID=$!
  echo "[entrypoint] Backup sync started (PID $BACKUP_PID)."
else
  echo "[entrypoint] Backup sync disabled or script not found."
fi

# ── Wait for gateway to exit ────────────────────────────────────────

# If the gateway crashes, we exit too (Railway will restart the container).
wait "$GATEWAY_PID"
EXIT_CODE=$?

echo "[entrypoint] Gateway exited with code $EXIT_CODE."

# Run final backup if gateway exited cleanly.
if [ "$BACKUP_ENABLED" = "true" ] && [ -n "$BACKUP_PID" ]; then
  kill -TERM "$BACKUP_PID" 2>/dev/null || true
  wait "$BACKUP_PID" 2>/dev/null || true
fi

exit $EXIT_CODE
