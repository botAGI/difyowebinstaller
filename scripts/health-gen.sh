#!/usr/bin/env bash
# health-gen.sh — Generate health.json for nginx /health endpoint
# Runs via cron every minute. Calls agmind status --json for data.
set -euo pipefail

AGMIND_DIR="${AGMIND_DIR:-/opt/agmind}"
HEALTH_DIR="${AGMIND_DIR}/docker/nginx"
HEALTH_JSON="${HEALTH_DIR}/health.json"

# Ensure target directory exists
mkdir -p "$HEALTH_DIR"

# Atomic write: tmp file + mv prevents nginx from serving partial JSON
TMPFILE=$(mktemp "${HEALTH_DIR}/.health.json.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

# Delegate to agmind status --json for schema consistency
if "${AGMIND_DIR}/scripts/agmind.sh" status --json > "$TMPFILE" 2>/dev/null; then
    mv "$TMPFILE" "$HEALTH_JSON"
    chmod 644 "$HEALTH_JSON"
else
    # Fallback: write degraded status rather than leaving stale file
    cat > "$TMPFILE" <<ENDJSON
{
  "status": "unhealthy",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "services": {"total": 0, "running": 0, "details": {}},
  "gpu": {"type": "unknown"},
  "error": "health-gen failed to collect status"
}
ENDJSON
    mv "$TMPFILE" "$HEALTH_JSON"
    chmod 644 "$HEALTH_JSON"
fi
