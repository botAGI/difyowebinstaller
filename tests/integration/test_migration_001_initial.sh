#!/usr/bin/env bash
# tests/integration/test_migration_001_initial.sh — STATE-05 integration coverage.
#
# Asserts migration 001-initial.sh on synthetic v3.1.x legacy layout:
#   1. 3 .preserved files copied byte-exact -> state_get_secret returns same bytes
#   2. Known secrets from docker/.env copied byte-exact (incl. $/#/quotes/spaces)
#   3. legacy .preserved files NOT REMOVED (rollback safety)
#   4. legacy docker/.env NOT MODIFIED
#   5. schema_version=1 after apply
#   6. # schema=N marker stays on line 1 (state_set_secret upsert behavior)
#   7. secrets.env mode 0600
#   8. Idempotent re-apply -> no schema drift, no extra backup
#
# Hermetic: STATE_DIR + INSTALL_DIR + MIGRATIONS_DIR + BACKUP_BASE = mktemp.
# Exit: 0 = all pass, 1 = any fail, 77 = SKIP (deps missing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_migration_001_initial"

# Skip if dependencies absent
for f in lib/common.sh lib/state.sh lib/migrations.sh lib/migrations/001-initial.sh; do
    if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
        echo "  SKIP: ${f} missing" >&2
        exit 77
    fi
done

STATE_DIR="$(mktemp -d)"
INSTALL_DIR="$(mktemp -d)"
MIGRATIONS_DIR="${REPO_ROOT}/lib/migrations"
BACKUP_BASE="$(mktemp -d)"
export STATE_DIR INSTALL_DIR MIGRATIONS_DIR BACKUP_BASE
trap 'rm -rf "$STATE_DIR" "$INSTALL_DIR" "$BACKUP_BASE"' EXIT

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/state.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/migrations.sh"

state_init_dir

# Build synthetic v3.1.x legacy state — exactly matches what lib/config.sh writes.
# Tricky values include $/#/spaces/quotes to prove _env_get_raw byte-exactness.
printf 'surreal-pw-with-$dollar-and-#hash' > "${STATE_DIR}/surrealdb_password.preserved"
printf 'n8n-key-abc123' > "${STATE_DIR}/n8n_encryption_key.preserved"
printf 'portainer-shared-secret-x' > "${STATE_DIR}/portainer_agent_secret.preserved"
chmod 600 "${STATE_DIR}"/*.preserved

mkdir -p "${INSTALL_DIR}/docker"
cat > "${INSTALL_DIR}/docker/.env" <<'ENV'
DB_PASSWORD=postgresPw$with$special#chars
REDIS_PASSWORD=redisPw 123
SECRET_KEY=dify-secret-64-char-string-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MINIO_ROOT_PASSWORD=minio "quoted" pw
SANDBOX_API_KEY=dify-sandbox-test
PLUGIN_DAEMON_KEY=plugin-daemon-key-aaa
GRAFANA_ADMIN_PASSWORD=__GRAFANA_ADMIN_PASSWORD__
RAGFLOW_MYSQL_PASSWORD=
ENV
chmod 600 "${INSTALL_DIR}/docker/.env"

# Capture BEFORE values
declare -A BEFORE
BEFORE[surrealdb]="$(cat "${STATE_DIR}/surrealdb_password.preserved")"
BEFORE[n8n]="$(cat "${STATE_DIR}/n8n_encryption_key.preserved")"
BEFORE[portainer]="$(cat "${STATE_DIR}/portainer_agent_secret.preserved")"
BEFORE[DB_PASSWORD]="$(_env_get_raw DB_PASSWORD "${INSTALL_DIR}/docker/.env")"
BEFORE[REDIS_PASSWORD]="$(_env_get_raw REDIS_PASSWORD "${INSTALL_DIR}/docker/.env")"
BEFORE[SECRET_KEY]="$(_env_get_raw SECRET_KEY "${INSTALL_DIR}/docker/.env")"
BEFORE[MINIO_ROOT_PASSWORD]="$(_env_get_raw MINIO_ROOT_PASSWORD "${INSTALL_DIR}/docker/.env")"

# Capture legacy file mtimes for "not modified" proof
preserved_mtime_before="$(stat -c '%Y' "${STATE_DIR}/surrealdb_password.preserved")"
env_mtime_before="$(stat -c '%Y' "${INSTALL_DIR}/docker/.env")"

pass=0; fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# 1. Apply
migrations_apply --yes >/dev/null 2>&1 && _ok "migrations_apply returned 0" || _fail "migrations_apply non-zero"

# 2. schema=1
[[ "$(state_schema_version)" == "1" ]] && _ok "schema=1" || _fail "schema=$(state_schema_version)"

# 3. Marker on line 1
marker="$(head -1 "${STATE_DIR}/secrets.env")"
[[ "$marker" == "# schema=0" || "$marker" == "# schema=1" ]] && _ok "marker present on line 1 (${marker})" || _fail "marker: ${marker}"

# 4. Mode 0600 preserved
mode="$(stat -c '%a' "${STATE_DIR}/secrets.env")"
[[ "$mode" == "600" ]] && _ok "secrets.env mode 0600" || _fail "mode ${mode}"

# 5. Byte-exact .preserved copies
[[ "$(state_get_secret SURREALDB_PASSWORD)"      == "${BEFORE[surrealdb]}" ]]  && _ok "SURREALDB_PASSWORD byte-exact"      || _fail "SURREALDB drift"
[[ "$(state_get_secret N8N_ENCRYPTION_KEY)"      == "${BEFORE[n8n]}" ]]        && _ok "N8N_ENCRYPTION_KEY byte-exact"      || _fail "N8N drift"
[[ "$(state_get_secret PORTAINER_AGENT_SECRET)"  == "${BEFORE[portainer]}" ]]  && _ok "PORTAINER_AGENT_SECRET byte-exact"  || _fail "PORTAINER drift"

# 6. Byte-exact docker/.env copies
[[ "$(state_get_secret DB_PASSWORD)"         == "${BEFORE[DB_PASSWORD]}" ]]         && _ok "DB_PASSWORD byte-exact (\$/#)"  || _fail "DB drift"
[[ "$(state_get_secret REDIS_PASSWORD)"      == "${BEFORE[REDIS_PASSWORD]}" ]]      && _ok "REDIS_PASSWORD byte-exact"       || _fail "REDIS drift"
[[ "$(state_get_secret SECRET_KEY)"          == "${BEFORE[SECRET_KEY]}" ]]          && _ok "SECRET_KEY byte-exact"           || _fail "SECRET drift"
[[ "$(state_get_secret MINIO_ROOT_PASSWORD)" == "${BEFORE[MINIO_ROOT_PASSWORD]}" ]] && _ok "MINIO_ROOT_PASSWORD byte-exact (quoted)" || _fail "MINIO drift"

# 7. Placeholder __X__ skipped, empty value skipped
state_get_secret GRAFANA_ADMIN_PASSWORD >/dev/null 2>&1 && _fail "placeholder __X__ copied" || _ok "placeholder __X__ skipped"
state_get_secret RAGFLOW_MYSQL_PASSWORD >/dev/null 2>&1 && _fail "empty value copied"      || _ok "empty value skipped"

# 8. Legacy .preserved files INTACT (rollback safety)
[[ -f "${STATE_DIR}/surrealdb_password.preserved" ]]       && _ok "surrealdb_password.preserved kept"       || _fail "surrealdb removed"
[[ -f "${STATE_DIR}/n8n_encryption_key.preserved" ]]       && _ok "n8n_encryption_key.preserved kept"       || _fail "n8n removed"
[[ -f "${STATE_DIR}/portainer_agent_secret.preserved" ]]   && _ok "portainer_agent_secret.preserved kept"   || _fail "portainer removed"
preserved_mtime_after="$(stat -c '%Y' "${STATE_DIR}/surrealdb_password.preserved")"
[[ "$preserved_mtime_before" == "$preserved_mtime_after" ]] && _ok "legacy .preserved mtime unchanged" || _fail "legacy mtime changed"

# 9. Legacy docker/.env NOT modified
env_mtime_after="$(stat -c '%Y' "${INSTALL_DIR}/docker/.env")"
[[ "$env_mtime_before" == "$env_mtime_after" ]] && _ok "docker/.env mtime unchanged" || _fail "docker/.env mtime changed"

# 10. Backup tarball created
backup_count="$(find "$BACKUP_BASE" -name 'state-pre-001-*.tar.gz' -type f | wc -l)"
[[ "$backup_count" -ge 1 ]] && _ok "backup tarball created" || _fail "no backup (${backup_count})"

# 11. Idempotent re-apply
before_backups="$(find "$BACKUP_BASE" -name '*.tar.gz' -type f | wc -l)"
migrations_apply --yes >/dev/null 2>&1 && _ok "idempotent re-apply exit 0" || _fail "re-apply non-zero"
[[ "$(state_schema_version)" == "1" ]] && _ok "schema still 1 after re-run" || _fail "schema drift"
after_backups="$(find "$BACKUP_BASE" -name '*.tar.gz' -type f | wc -l)"
[[ "$before_backups" -eq "$after_backups" ]] && _ok "no extra backup on no-op apply" || _fail "extra backup on no-op"

# 12. secrets.env layout sanity: marker on line 1, ≥7 KEY=VALUE entries follow
#     (3 .preserved + 4 valid .env keys: DB_PASSWORD, REDIS_PASSWORD, SECRET_KEY,
#      MINIO_ROOT_PASSWORD, SANDBOX_API_KEY, PLUGIN_DAEMON_KEY = 6 entries;
#      __X__ placeholder GRAFANA + empty RAGFLOW_MYSQL_PASSWORD skipped).
#     NB: we explicitly do NOT `source` secrets.env — values contain $/quotes/spaces
#     by design. Reading is via state_get_secret -> _env_get_raw (byte-exact awk).
#     The whole point of ADR-0011 is replacing source-based readers; sourceability
#     is an anti-property here.
kv_count="$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "${STATE_DIR}/secrets.env" || true)"
[[ "$kv_count" -ge 7 ]] && _ok "secrets.env has ${kv_count} KEY=VALUE entries (>=7 expected)" \
                        || _fail "secrets.env entry count: ${kv_count} (expected >=7)"

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ "$fail" -eq 0 ]]
