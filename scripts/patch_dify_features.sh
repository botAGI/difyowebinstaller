#!/usr/bin/env bash
# patch_dify_features.sh — Unlock premium features for Dify API (self-hosted)
# Idempotent — checks marker before patching, safe to re-run
# Apply AFTER containers are running and healthy
#
# Usage: patch_dify_features.sh [CONTAINER] [INSTALL_DIR]

set -euo pipefail

CONTAINER="${1:-agmind-api}"
WORKER="${CONTAINER/api/worker}"
INSTALL_DIR="${2:-/opt/agmind}"
MARKER="# --- AGmind: unlock premium features"
TARGET_FILE="/app/api/services/feature_service.py"

# --- Helpers ---
_log() { echo "[${1}] ${2}"; }

# --- Pre-checks ---

# Container exists and running?
if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    _log "SKIP" "Container $CONTAINER not running"
    exit 0
fi

# Already patched?
if docker exec "$CONTAINER" grep -q "$MARKER" "$TARGET_FILE" 2>/dev/null; then
    _log "OK" "Already patched"
    exit 0
fi

# --- Backup to persistent directory ---
BACKUP_DIR="${INSTALL_DIR}/.patches/backups"
mkdir -p "$BACKUP_DIR"
docker cp "$CONTAINER":"$TARGET_FILE" \
    "$BACKUP_DIR/feature_service.py.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

# --- Detect Dify version for diagnostics ---
DIFY_VERSION=$(docker exec "$CONTAINER" python3 -c "
try:
    from configs import dify_config
    print(getattr(dify_config, 'CURRENT_VERSION', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")

# --- Build patch script ---
PATCH_SCRIPT=$(mktemp /tmp/_agmind_patch_XXXXXX.py)
cat > "$PATCH_SCRIPT" << 'PYEOF'
import re, sys

target = "/app/api/services/feature_service.py"

with open(target, "r") as f:
    content = f.read()

PATCH_BLOCK = """\
        # --- AGmind: unlock premium features for self-hosted ---
        features.webapp_copyright_enabled = True
        features.can_replace_logo = True
        features.model_load_balancing_enabled = True
        features.dataset_operator_enabled = True
        features.knowledge_pipeline.publish_enabled = True
        features.docs_processing = "priority"
        features.members.limit = 0
        features.apps.limit = 0
        features.documents_upload_quota.limit = 0
        features.annotation_quota_limit.limit = 0
        features.vector_space.limit = 0
        features.knowledge_rate_limit = 999
        # --- end AGmind patch ---"""

# Strategy 1: exact string match (Dify 1.13.x)
OLD_EXACT = (
    "        cls._fulfill_params_from_env(features)\n"
    "\n"
    "        if dify_config.BILLING_ENABLED and tenant_id:"
)
NEW_EXACT = (
    "        cls._fulfill_params_from_env(features)\n"
    "\n"
    + PATCH_BLOCK + "\n"
    "\n"
    "        if dify_config.BILLING_ENABLED and tenant_id:"
)

if OLD_EXACT in content:
    content = content.replace(OLD_EXACT, NEW_EXACT)
    with open(target, "w") as f:
        f.write(content)
    print("PATCHED")
    sys.exit(0)

# Strategy 2: regex fallback — find _fulfill_params_from_env and inject after
pattern = r"(cls\._fulfill_params_from_env\(features\)\s*\n)"
match = re.search(pattern, content)
if match:
    insert_pos = match.end()
    inject = "\n" + PATCH_BLOCK + "\n\n"
    content = content[:insert_pos] + inject + content[insert_pos:]
    with open(target, "w") as f:
        f.write(content)
    print("PATCHED_FALLBACK")
    sys.exit(0)

print("PATTERN_NOT_FOUND")
sys.exit(1)
PYEOF

# --- Apply patch inside container ---
docker cp "$PATCH_SCRIPT" "$CONTAINER":/tmp/_agmind_patch_features.py
# docker cp creates files as root:root 600 — container may run as non-root
docker exec -u 0 "$CONTAINER" chmod 644 /tmp/_agmind_patch_features.py 2>/dev/null || true
RESULT=$(docker exec "$CONTAINER" python3 /tmp/_agmind_patch_features.py 2>&1) || true

# Cleanup temp files
rm -f "$PATCH_SCRIPT"
docker exec "$CONTAINER" rm -f /tmp/_agmind_patch_features.py 2>/dev/null || true

case "$RESULT" in
    PATCHED|PATCHED_FALLBACK)
        # Restart api
        docker restart "$CONTAINER" >/dev/null 2>&1
        # Restart worker only if it exists
        if docker inspect "$WORKER" &>/dev/null; then
            docker restart "$WORKER" >/dev/null 2>&1
        fi
        _log "OK" "Dify premium features unlocked ($RESULT)"
        ;;
    *)
        _log "WARN" "Patch failed: $RESULT (Dify version: $DIFY_VERSION)"
        _log "WARN" "Update patch pattern for this Dify version"
        exit 0  # don't block install/update
        ;;
esac
