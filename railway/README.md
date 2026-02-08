# OpenClaw Durable — Railway Template

Deploy OpenClaw on Railway with persistent state backed by a Railway Bucket (S3-compatible storage).

## Quick Start

1. Deploy the template on Railway.
2. Set the **root directory** to `railway/` in service settings.
3. Attach a **Volume** mounted at `/data`.
4. Attach a **Bucket** for automatic backup sync.
5. Set required variables (see below).
6. Enable **Public Networking** on port `8080`.
7. Open `https://<your-railway-domain>/` for the Control UI.

## Variables

### Required

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | API key from [console.anthropic.com](https://console.anthropic.com). Powers the default AI model (Claude). |
| `OPENCLAW_GATEWAY_TOKEN` | Secret token for gateway auth. Generate a random string (64+ chars). Required for non-loopback binding. |

### Optional — Embedding Providers

At least one is needed for memory search (vector search over past conversations):

| Variable | Description |
|----------|-------------|
| `OPENAI_API_KEY` | [platform.openai.com](https://platform.openai.com) — enables embeddings + OpenAI models. |
| `GEMINI_API_KEY` | [aistudio.google.com](https://aistudio.google.com) — alternative embeddings + Gemini models. |
| `VOYAGE_API_KEY` | [voyageai.com](https://dash.voyageai.com) — alternative embedding provider. |

### Optional — Channels

| Variable | Description |
|----------|-------------|
| `TELEGRAM_BOT_TOKEN` | Token from @BotFather. |
| `DISCORD_BOT_TOKEN` | Token from Discord Developer Portal. Requires Message Content Intent. |
| `SLACK_BOT_TOKEN` | Bot token (`xoxb-...`) from a Slack app. |

### Optional — Backup

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_ENABLED` | `true` | Enable/disable backup sync. |
| `BACKUP_INTERVAL_SEC` | `300` | Seconds between backup cycles. |
| `BACKUP_S3_PREFIX` | `openclaw-state` | Key prefix inside the bucket. |

## How Backup Works

The entrypoint runs a backup sync loop alongside the gateway:

1. **On startup** — if the volume is empty (no `openclaw.json`), state is restored from the bucket.
2. **Every 5 minutes** — all state files are synced to the bucket. SQLite databases use the `sqlite3 .backup` API for safe live snapshots.
3. **On shutdown** — a final backup runs before the container exits.

### What Gets Backed Up

All files under `OPENCLAW_STATE_DIR` (`/data/.openclaw`):

- `openclaw.json` — configuration
- `agents/` — session transcripts, metadata
- `workspace/` — AGENTS.md, MEMORY.md, memory files
- `credentials/` — OAuth tokens, channel credentials
- `memory/*.sqlite` — embedding databases (requires an embedding API key)
- `cron/`, `devices/`, `update-check.json`

Excluded: `*.lock`, `*.tmp`, `media/` (ephemeral), live SQLite WAL/SHM files.

### Bucket Layout

```
<BACKUP_S3_PREFIX>/
  backup-marker.json        # Timestamp of last backup
  files/                    # All state files (mirrors OPENCLAW_STATE_DIR)
    openclaw.json
    agents/main/sessions/...
    workspace/...
    credentials/...
  sqlite/                   # Safe SQLite copies
    main.sqlite
```

## Backup and Restore via S3 CLI

Railway Buckets are S3-compatible. You can use the standard AWS CLI to download and upload files.

### Prerequisites

Install the AWS CLI if you don't have it:

```bash
# macOS
brew install awscli

# or via pip
pip install awscli
```

### Credentials

Find your S3-compatible credentials in the Railway dashboard under the Bucket service. You need:

| Field | Example |
|-------|---------|
| **Endpoint URL** | `https://t3.storageapi.dev` |
| **Region** | `auto` |
| **Bucket Name** | `my-bucket-name` |
| **Access Key ID** | `tid_...` |
| **Secret Access Key** | `tsec_...` |

Export them for all commands below:

```bash
export AWS_ACCESS_KEY_ID="tid_..."
export AWS_SECRET_ACCESS_KEY="tsec_..."
export BUCKET="my-bucket-name"
export ENDPOINT="https://t3.storageapi.dev"
```

### List All Files in the Bucket

```bash
aws s3 ls s3://$BUCKET/ \
  --endpoint-url $ENDPOINT \
  --region auto \
  --recursive
```

### Download Bucket to Local Machine

Sync the entire bucket to a local directory:

```bash
aws s3 sync \
  s3://$BUCKET/ \
  /tmp/railway-bucket/ \
  --endpoint-url $ENDPOINT \
  --region auto
```

To download only a specific prefix (e.g., `data/.openclaw/`):

```bash
aws s3 sync \
  s3://$BUCKET/data/.openclaw/ \
  /tmp/railway-bucket/data/.openclaw/ \
  --endpoint-url $ENDPOINT \
  --region auto
```

Run the same command again to pull only changed files (incremental sync).

### Upload a Local Folder to the Bucket

Upload a specific folder while preserving its path structure:

```bash
aws s3 sync \
  /tmp/railway-bucket/data/.openclaw_v2/ \
  s3://$BUCKET/data/.openclaw_v2/ \
  --endpoint-url $ENDPOINT \
  --region auto
```

To upload from a local OpenClaw state directory (e.g., `~/.openclaw/`), excluding transient files:

```bash
aws s3 sync \
  ~/.openclaw/ \
  s3://$BUCKET/data/.openclaw/files/ \
  --exclude "*.lock" --exclude "*.tmp" \
  --exclude "media/*" \
  --exclude "*.sqlite-wal" --exclude "*.sqlite-shm" \
  --endpoint-url $ENDPOINT \
  --region auto
```

### Restore from a Local Backup

1. Upload state files to the bucket (see above).
2. Change `OPENCLAW_STATE_DIR` to a new empty path (e.g., `/data/.openclaw-v2`) in Railway variables, then redeploy. The entrypoint sees no existing config and restores everything from the bucket.
3. Verify via the Control UI that your config, conversations, and workspace are intact.

### Update Bot Config via Backup

1. Download the current backup.
2. Edit the files locally (e.g., modify `files/openclaw.json`).
3. Upload the modified files back:

```bash
aws s3 sync \
  /tmp/railway-bucket/data/.openclaw/files/ \
  s3://$BUCKET/data/.openclaw/files/ \
  --endpoint-url $ENDPOINT \
  --region auto
```

4. Trigger a restore by changing `OPENCLAW_STATE_DIR` to a new path and redeploying.

> **Note:** The backup loop runs every 5 minutes and syncs local state to the bucket with `--delete`. If you upload files while the instance is running, the next backup cycle will overwrite them. Stop or redeploy the instance before uploading to the bucket.

### Migrate Between Instances

1. Download the backup from the source bucket.
2. Upload it to the destination bucket (can be a different bucket with different credentials).
3. If the destination already has state, change `OPENCLAW_STATE_DIR` to trigger a fresh restore.

## Architecture

```
entrypoint.sh
  ├── inject_railway_config()   # Disable device auth for Railway proxy
  ├── backup-sync.sh restore    # Restore from bucket (if volume empty)
  ├── openclaw gateway          # Main process (foreground)
  └── backup-sync.sh loop       # Backup sync (background, every 5 min)
```

The entrypoint manages three concerns:
- **Config injection**: Sets `dangerouslyDisableDeviceAuth: true` because Railway's reverse proxy (100.64.0.0/10) makes all connections appear non-local.
- **Restore**: Downloads state from bucket on first boot or after a volume wipe.
- **Backup loop**: Syncs state to bucket on a schedule and on shutdown.
