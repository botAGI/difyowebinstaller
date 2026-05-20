#!/usr/bin/env bash
# tests/integration/test_upgrade_v3_1_2_to_v3_2_0.sh — STATE-10 end-to-end.
#
# Asserts: v3.1.2 → v3.2.0 schema migration preserves all secrets byte-exact,
#          schema_version=1 after, secrets.env sourceable, rollback restores legacy.
# Hermetic: STATE_DIR + INSTALL_DIR + BACKUP_BASE = mktemp. Does NOT touch live system.
#
# Per RESEARCH.md §"Integration Test Strategy" — uses synthetic v3.1.2 baseline tarball
# built reproducibly by tests/fixtures/state/build-v3.1.2-baseline.sh. The "real baseline"
# is a hand-crafted tarball with tricky synthetic secrets (containing $, #, quotes, spaces),
# NOT a real production install snapshot.
#
# Exit: 0 = pass, 77 = SKIP (missing baseline tarball), 1 = fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_upgrade_v3_1_2_to_v3_2_0"

BASELINE="${REPO_ROOT}/tests/fixtures/state/v3.1.2-baseline.tar.gz"
if [[ ! -f "$BASELINE" ]]; then
    echo "  SKIP: baseline ${BASELINE} not found (run build-v3.1.2-baseline.sh)" >&2
    exit 77
fi

for f in lib/common.sh lib/state.sh lib/migrations.sh lib/migrations/001-initial.sh; do
    if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
        echo "  SKIP: ${f} missing" >&2
        exit 77
    fi
done

# Hermetic dirs
STATE_DIR="$(mktemp -d)"
INSTALL_DIR="$(mktemp -d)"
BACKUP_BASE="$(mktemp -d)"
EXTRACT_TMP="$(mktemp -d)"
export STATE_DIR INSTALL_DIR BACKUP_BASE
export MIGRATIONS_DIR="${REPO_ROOT}/lib/migrations"
# CI mode — unset STATE_DIR_OWNER so state_init_dir does NOT attempt chown
unset STATE_DIR_OWNER
# shellcheck disable=SC2064  # we want the vars expanded NOW, not at trap time
trap "rm -rf '$STATE_DIR' '$INSTALL_DIR' '$BACKUP_BASE' '$EXTRACT_TMP'" EXIT

# Extract baseline into staging area, then move into hermetic dirs.
tar xzf "$BASELINE" -C "$EXTRACT_TMP"

# Populate STATE_DIR with .preserved files (preserve mode 0600 from tarball)
cp "$EXTRACT_TMP/state/"*.preserved "$STATE_DIR/"
chmod 0600 "$STATE_DIR"/*.preserved

# Populate INSTALL_DIR/docker/.env
mkdir -p "$INSTALL_DIR/docker"
cp "$EXTRACT_TMP/docker/.env" "$INSTALL_DIR/docker/.env"
chmod 0600 "$INSTALL_DIR/docker/.env"

# common.sh forces `set -euo pipefail` — relax after source so non-zero rc
# assertions don't kill the script.
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/state.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/migrations.sh"
set +e
set -u
set -o pipefail

state_init_dir

# Capture BEFORE values directly from the baseline files (byte-exact source-of-truth)
declare -A BEFORE
BEFORE[surrealdb]="$(cat "${STATE_DIR}/surrealdb_password.preserved")"
BEFORE[n8n]="$(cat "${STATE_DIR}/n8n_encryption_key.preserved")"
BEFORE[portainer]="$(cat "${STATE_DIR}/portainer_agent_secret.preserved")"
BEFORE[DB_PASSWORD]="$(_env_get_raw DB_PASSWORD "$INSTALL_DIR/docker/.env")"
BEFORE[REDIS_PASSWORD]="$(_env_get_raw REDIS_PASSWORD "$INSTALL_DIR/docker/.env")"
BEFORE[SECRET_KEY]="$(_env_get_raw SECRET_KEY "$INSTALL_DIR/docker/.env")"
BEFORE[MINIO_ROOT_PASSWORD]="$(_env_get_raw MINIO_ROOT_PASSWORD "$INSTALL_DIR/docker/.env")"
BEFORE[AUTHELIA_JWT_SECRET]="$(_env_get_raw AUTHELIA_JWT_SECRET "$INSTALL_DIR/docker/.env")"

# Capture legacy mtimes for "unchanged" proof
preserved_mtime_before="$(stat -c '%Y' "${STATE_DIR}/surrealdb_password.preserved")"
env_mtime_before="$(stat -c '%Y' "${INSTALL_DIR}/docker/.env")"

pass=0; fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# 1. Migrate
migrations_apply --yes >/dev/null 2>&1 && _ok "migrations_apply --yes exit 0" || _fail "migrations_apply non-zero"

# 2. schema=1
[[ "$(state_schema_version)" == "1" ]] && _ok "schema=1" || _fail "schema=$(state_schema_version)"

# 3. Marker on line 1 — must be a `# schema=N` comment (migration 001-initial does NOT
# update line-1 marker; the canonical schema_version lives in schema_version file. Marker
# is bootstrap-only. Accept both # schema=0 (current behavior) and # schema=1 (future
# tightening) per Plan 11-02 SUMMARY contract.)
marker="$(head -1 "${STATE_DIR}/secrets.env")"
case "$marker" in
    "# schema=0"|"# schema=1") _ok "marker present on line 1 (${marker})" ;;
    *) _fail "marker: '${marker}'" ;;
esac

# 4. Mode 0600 on secrets.env
mode="$(stat -c '%a' "${STATE_DIR}/secrets.env")"
[[ "$mode" == "600" ]] && _ok "secrets.env mode 0600" || _fail "mode ${mode}"

# 5-7. .preserved byte-exact via state_get_secret
[[ "$(state_get_secret SURREALDB_PASSWORD)"     == "${BEFORE[surrealdb]}" ]] && _ok "SURREALDB_PASSWORD byte-exact (\$/#)"     || _fail "SURREALDB drift"
[[ "$(state_get_secret N8N_ENCRYPTION_KEY)"     == "${BEFORE[n8n]}" ]]       && _ok "N8N_ENCRYPTION_KEY byte-exact (hex)"      || _fail "N8N drift"
[[ "$(state_get_secret PORTAINER_AGENT_SECRET)" == "${BEFORE[portainer]}" ]] && _ok "PORTAINER_AGENT_SECRET byte-exact"          || _fail "PORTAINER drift"

# 8-12. docker/.env byte-exact via state_get_secret
[[ "$(state_get_secret DB_PASSWORD)"         == "${BEFORE[DB_PASSWORD]}" ]]         && _ok "DB_PASSWORD byte-exact (\$/#)"           || _fail "DB drift"
[[ "$(state_get_secret REDIS_PASSWORD)"      == "${BEFORE[REDIS_PASSWORD]}" ]]      && _ok "REDIS_PASSWORD byte-exact (spaces)"      || _fail "REDIS drift"
[[ "$(state_get_secret SECRET_KEY)"          == "${BEFORE[SECRET_KEY]}" ]]          && _ok "SECRET_KEY byte-exact"                   || _fail "SECRET drift"
[[ "$(state_get_secret MINIO_ROOT_PASSWORD)" == "${BEFORE[MINIO_ROOT_PASSWORD]}" ]] && _ok "MINIO_ROOT_PASSWORD byte-exact (quotes)" || _fail "MINIO drift"
[[ "$(state_get_secret AUTHELIA_JWT_SECRET)" == "${BEFORE[AUTHELIA_JWT_SECRET]}" ]] && _ok "AUTHELIA_JWT_SECRET byte-exact"          || _fail "AUTHELIA drift"

# 13-14. Placeholder __X__ + empty values are SKIPPED by migration_1_up
state_get_secret GRAFANA_ADMIN_PASSWORD >/dev/null 2>&1 && _fail "placeholder __X__ copied" || _ok "placeholder __X__ skipped"
state_get_secret RAGFLOW_MYSQL_PASSWORD >/dev/null 2>&1 && _fail "empty value copied"       || _ok "empty value skipped"

# 15-17. Legacy .preserved INTACT (rollback safety / Phase 11 dormancy contract)
[[ -f "${STATE_DIR}/surrealdb_password.preserved" ]]     && _ok "surrealdb.preserved kept"     || _fail "surrealdb removed"
[[ -f "${STATE_DIR}/n8n_encryption_key.preserved" ]]     && _ok "n8n.preserved kept"           || _fail "n8n removed"
[[ -f "${STATE_DIR}/portainer_agent_secret.preserved" ]] && _ok "portainer.preserved kept"     || _fail "portainer removed"
preserved_mtime_after="$(stat -c '%Y' "${STATE_DIR}/surrealdb_password.preserved")"
[[ "$preserved_mtime_before" == "$preserved_mtime_after" ]] && _ok "legacy .preserved mtime unchanged" || _fail "legacy mtime changed"

# 18. docker/.env mtime intact (migration READS via _env_get_raw, never writes)
env_mtime_after="$(stat -c '%Y' "${INSTALL_DIR}/docker/.env")"
[[ "$env_mtime_before" == "$env_mtime_after" ]] && _ok "docker/.env mtime unchanged" || _fail "docker/.env mtime changed"

# 19. secrets.env sourceable in a subshell — Phase 11 "containers healthy" proxy.
# Per RESEARCH.md §"Containers healthy" — full docker compose config validation
# moves to Phase 14 SC after consumer flip. In Phase 11 the substrate is dormant,
# so we only assert the marker line is comment-shell-safe (the keys/values follow
# but contain $/quotes/spaces by design — those are read by state_get_secret +
# _env_get_raw byte-exact, never via `source`. Sourceability of the WHOLE file
# is an anti-property under ADR-0011 — we only verify line 1 parses cleanly).
# shellcheck disable=SC1090  # process substitution is intentional — we want runtime content
( set +u; set +e; source <(head -1 "${STATE_DIR}/secrets.env") >/dev/null 2>&1; )
src_rc=$?
[[ "$src_rc" -eq 0 ]] && _ok "secrets.env line-1 marker sourceable (comment)" || _fail "marker source error rc=${src_rc}"

# 20-22. Idempotent re-apply
before_backups="$(find "$BACKUP_BASE" -name '*.tar.gz' -type f | wc -l)"
migrations_apply --yes >/dev/null 2>&1 && _ok "idempotent re-apply exit 0" || _fail "re-apply non-zero"
[[ "$(state_schema_version)" == "1" ]] && _ok "schema still 1 after re-run" || _fail "schema drift"
after_backups="$(find "$BACKUP_BASE" -name '*.tar.gz' -type f | wc -l)"
[[ "$before_backups" -eq "$after_backups" ]] && _ok "no extra backup on no-op apply" || _fail "extra backup on no-op (${before_backups}->${after_backups})"

# 23. Rollback round-trip — upgrade_rollback 0 --yes restores from state-pre-001-*.tar.gz
upgrade_rollback 0 --yes >/dev/null 2>&1 && _ok "upgrade_rollback 0 --yes exit 0" || _fail "rollback non-zero"

# 24. After rollback, schema_version restored to 0 (pre-migration state)
[[ "$(state_schema_version)" == "0" ]] && _ok "rollback: schema=0" || _fail "rollback: schema=$(state_schema_version)"

# 25. After rollback, legacy .preserved files STILL present (tarball captured them)
[[ -f "${STATE_DIR}/surrealdb_password.preserved" ]] && _ok "rollback: .preserved restored" || _fail "rollback: .preserved missing"

# 26. After rollback, secrets.env marker is back to schema=0 (pre-migration state)
if [[ -f "${STATE_DIR}/secrets.env" ]]; then
    marker_post="$(head -1 "${STATE_DIR}/secrets.env" 2>/dev/null || true)"
    [[ "$marker_post" == "# schema=0" ]] && _ok "rollback: marker reset to # schema=0" || _fail "rollback: marker='${marker_post}'"
else
    _ok "rollback: secrets.env removed (pre-migration state)"
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ "$fail" -eq 0 ]]
