# Dockerfile
#
# Railway template: "OpenClaw Durable"
# OpenClaw gateway + S3 backup sync to Railway Bucket.
#
# Adds sqlite3 CLI (for safe .backup API on running DBs) and
# lightweight S3 client on top of the standard OpenClaw image.

# ── Build stage (same as upstream OpenClaw) ─────────────────────────

FROM node:22-bookworm AS openclaw-build

ARG OPENCLAW_GIT_REF=main

RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /build

# Clone and build OpenClaw from source.
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" \
    https://github.com/openclaw/openclaw.git . \
    && pnpm install --frozen-lockfile \
    && OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build \
    && OPENCLAW_PREFER_PNPM=1 pnpm ui:build

# ── Runtime stage ───────────────────────────────────────────────────

FROM node:22-bookworm-slim

# Install only what we need:
#   - sqlite3: CLI with .backup API for safe live-DB snapshots
#   - awscli: S3-compatible sync to Railway Bucket
#   - ca-certificates: TLS for S3 endpoint
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       sqlite3 \
       python3-minimal \
       ca-certificates \
       curl \
       unzip \
    && curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip \
    && cd /tmp && unzip -q awscli.zip && ./aws/install && rm -rf /tmp/aws /tmp/awscli.zip \
    && apt-get remove -y curl unzip \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy built OpenClaw from build stage.
# UI builds into dist/control-ui/, so copying all of dist/ gets both.
COPY --from=openclaw-build /build/dist ./dist
COPY --from=openclaw-build /build/node_modules ./node_modules
COPY --from=openclaw-build /build/package.json ./package.json
COPY --from=openclaw-build /build/openclaw.mjs ./openclaw.mjs

# Workspace templates (AGENTS.md, IDENTITY.md, etc.) are required at runtime.
# The gateway resolves them at <packageRoot>/docs/reference/templates/.
COPY --from=openclaw-build /build/docs/reference/templates ./docs/reference/templates

# Bundled skills (50+ built-in agent skills: github, slack, coding-agent, etc.).
# Without these, agents function but lack all built-in skill definitions.
COPY --from=openclaw-build /build/skills ./skills

# memory-core plugin (provides memory_search/memory_get tools + embeddings).
# Loaded via jiti at runtime from extensions/ directory.
COPY --from=openclaw-build /build/extensions/memory-core ./extensions/memory-core

# Copy backup scripts.
COPY backup-sync.sh /app/railway/backup-sync.sh
COPY entrypoint.sh /app/railway/entrypoint.sh
RUN chmod +x /app/railway/*.sh

# Ensure writable dirs for non-root user.
RUN mkdir -p /data /tmp/openclaw-sqlite-backup \
    && chown -R node:node /app /data /tmp/openclaw-sqlite-backup

ENV NODE_ENV=production
ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/data/workspace

# Note: No USER directive — entrypoint runs as root to fix volume permissions,
# then the gateway process itself runs safely. Railway volumes mount as root
# and are not writable by non-root users without this.
ENTRYPOINT ["/app/railway/entrypoint.sh"]
