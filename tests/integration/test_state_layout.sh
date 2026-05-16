#!/usr/bin/env bash
# tests/integration/test_state_layout.sh — STATE-01 integration coverage.
#
# Asserts the post-install state-store layout — what install.sh::phase_config produces:
#   - /var/lib/agmind/state/ at 0700 root:root
#   - .locks/ subdir at 0700
#   - schema_version file at 0644
#   - secrets.env at 0600 with `# schema=N` marker
#   - schema_version >= 1 after migration 001 applies
#   - Idempotent state_init_dir
#   - Backup tarball created with 0600 by migrations_apply
#
# Hermetic: STATE_DIR + INSTALL_DIR + MIGRATIONS_DIR + BACKUP_BASE = mktemp.
# Does NOT call install.sh — that's manual UAT (see VALIDATION.md). This validates the
# code paths phase_config invokes (state_init_dir + migrations_apply --yes).
#
# Exit: 0 = pass, 1 = fail, 77 = SKIP (deps missing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_state_layout"

for f in lib/common.sh lib/state.sh lib/migrations.sh lib/migrations/001-initial.sh; do
    if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
        echo "  SKIP: ${f} missing" >&2
        exit 77
    fi
done

STATE_DIR="$(mktemp -d)"
INSTALL_DIR="$(mktemp -d)"
BACKUP_BASE="$(mktemp -d)"
export STATE_DIR INSTALL_DIR BACKUP_BASE
export MIGRATIONS_DIR="${REPO_ROOT}/lib/migrations"
# CI mode — unset STATE_DIR_OWNER so state_init_dir does NOT attempt chown
unset STATE_DIR_OWNER
# shellcheck disable=SC2064  # we want $STATE_DIR/$INSTALL_DIR/$BACKUP_BASE expanded NOW, not at trap time
trap "rm -rf '$STATE_DIR' '$INSTALL_DIR' '$BACKUP_BASE'" EXIT

# Synthetic INSTALL_DIR/docker/.env so migration 001 has something to read
mkdir -p "${INSTALL_DIR}/docker"
cat > "${INSTALL_DIR}/docker/.env" <<'ENV'
DB_PASSWORD=test-db-pw
REDIS_PASSWORD=test-redis-pw
SECRET_KEY=test-secret-key
ENV
chmod 600 "${INSTALL_DIR}/docker/.env"

# common.sh forces `set -euo pipefail` as a side-effect of source — that would
# kill the test on the first deliberate non-zero rc assertion. Relax after source.
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/state.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/migrations.sh"
set +e
set -u
set -o pipefail

pass=0; fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# 1. state_init_dir succeeds in CI mode
state_init_dir
init_rc=$?
[[ "$init_rc" -eq 0 ]] && _ok "state_init_dir CI mode exit 0" || _fail "init rc=${init_rc}"

# 2. STATE_DIR mode 0700
mode_state="$(stat -c '%a' "$STATE_DIR")"
[[ "$mode_state" == "700" ]] && _ok "STATE_DIR mode 0700" || _fail "STATE_DIR mode ${mode_state}"

# 3. .locks/ subdir exists
[[ -d "${STATE_DIR}/.locks" ]] && _ok ".locks/ created" || _fail ".locks/ missing"

# 4. .locks/ mode 0700
mode_locks="$(stat -c '%a' "${STATE_DIR}/.locks")"
[[ "$mode_locks" == "700" ]] && _ok ".locks/ mode 0700" || _fail ".locks/ mode ${mode_locks}"

# 5. schema_version file created
[[ -f "${STATE_DIR}/schema_version" ]] && _ok "schema_version exists" || _fail "schema_version missing"

# 6. schema_version mode 0644
mode_sv="$(stat -c '%a' "${STATE_DIR}/schema_version")"
[[ "$mode_sv" == "644" ]] && _ok "schema_version mode 0644" || _fail "schema_version mode ${mode_sv}"

# 7. secrets.env created
[[ -f "${STATE_DIR}/secrets.env" ]] && _ok "secrets.env exists" || _fail "secrets.env missing"

# 8. secrets.env mode 0600
mode_se="$(stat -c '%a' "${STATE_DIR}/secrets.env")"
[[ "$mode_se" == "600" ]] && _ok "secrets.env mode 0600" || _fail "secrets.env mode ${mode_se}"

# 9. schema marker on line 1
marker="$(head -1 "${STATE_DIR}/secrets.env")"
[[ "$marker" == "# schema=0" ]] && _ok "schema marker on line 1 (${marker})" || _fail "marker: '${marker}'"

# 10. Idempotent state_init_dir — re-run keeps mode
state_init_dir
mode_state2="$(stat -c '%a' "$STATE_DIR")"
[[ "$mode_state2" == "700" ]] && _ok "idempotent: STATE_DIR mode 0700 unchanged" || _fail "drift to ${mode_state2}"

# 11. Idempotent: marker unchanged after re-init
marker2="$(head -1 "${STATE_DIR}/secrets.env")"
[[ "$marker2" == "$marker" ]] && _ok "idempotent: marker unchanged" || _fail "marker drift"

# 12. migrations_apply --yes succeeds (schema bumps to 1)
migrations_apply --yes >/dev/null 2>&1
ma_rc=$?
[[ "$ma_rc" -eq 0 ]] && _ok "migrations_apply --yes exit 0" || _fail "migrations_apply rc=${ma_rc}"

# 13. schema_version bumped to 1
sv_after="$(state_schema_version)"
[[ "$sv_after" == "1" ]] && _ok "schema_version=1 after migration" || _fail "schema=${sv_after}"

# 14. secrets.env mode preserved after upserts
mode_se_post="$(stat -c '%a' "${STATE_DIR}/secrets.env")"
[[ "$mode_se_post" == "600" ]] && _ok "secrets.env mode 0600 preserved after migration" || _fail "mode drift to ${mode_se_post}"

# 15. BACKUP_BASE dir exists (install -d -m 0700 inside _migrations_disk_ok)
[[ -d "$BACKUP_BASE" ]] && _ok "BACKUP_BASE exists" || _fail "BACKUP_BASE missing"

# 16. BACKUP_BASE mode 0700
mode_bb="$(stat -c '%a' "$BACKUP_BASE")"
[[ "$mode_bb" == "700" ]] && _ok "BACKUP_BASE mode 0700" || _fail "BACKUP_BASE mode ${mode_bb}"

# 17. Backup tarball created at state-pre-001-*.tar.gz
backup_tar="$(find "$BACKUP_BASE" -name 'state-pre-001-*.tar.gz' -type f 2>/dev/null | head -1)"
[[ -n "$backup_tar" ]] && _ok "backup tarball created" || _fail "no backup tarball found in $BACKUP_BASE"

# 18. Backup tarball mode 0600
if [[ -n "$backup_tar" ]]; then
    mode_bt="$(stat -c '%a' "$backup_tar")"
    [[ "$mode_bt" == "600" ]] && _ok "backup tarball mode 0600" || _fail "backup tarball mode ${mode_bt}"
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ "$fail" -eq 0 ]]
