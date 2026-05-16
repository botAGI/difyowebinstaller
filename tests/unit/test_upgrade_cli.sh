#!/usr/bin/env bash
# tests/unit/test_upgrade_cli.sh — STATE-06/07/08 unit coverage.
#
# Asserts upgrade_run / upgrade_check / upgrade_apply / upgrade_rollback contract:
#   1. No args → --check default → exit 0 on empty migrations dir
#   2. Unknown action → exit 2
#   3. -h / --help → exit 0, prints usage
#   4. With pending migration → upgrade_check exit 1
#   5. upgrade_apply --yes → schema bumps, exit 0
#   6. After apply with no pending → upgrade_check exit 0
#   7. Schema marker mismatch (manual corruption) → upgrade_check exit 2
#   8. upgrade_rollback without target → exit 2
#   9. upgrade_rollback 0 --yes → schema=0 restored from tarball
#         (precondition guard via `compgen -G` — warning #4 fix)
#  10. upgrade_rollback when no tarball → exit 2
#  11. Concurrent upgrade_apply: second invocation under flock → exit 2
#         (touch-file sync marker — warning #2 fix, no `sleep 0.5` flakes)
#  12. upgrade_apply on no pending → exit 0
#
# Hermetic: STATE_DIR + MIGRATIONS_DIR + BACKUP_BASE all mktemp.
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_upgrade_cli"

STATE_DIR="$(mktemp -d)"
MIGRATIONS_DIR="$(mktemp -d)"
BACKUP_BASE="$(mktemp -d)"
export STATE_DIR MIGRATIONS_DIR BACKUP_BASE
trap 'rm -rf "$STATE_DIR" "$MIGRATIONS_DIR" "$BACKUP_BASE"' EXIT

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/state.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/migrations.sh"

state_init_dir

pass=0; fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# 1. Default action is --check, exits 0 with no pending
upgrade_run >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && _ok "default --check exit 0 on empty" || _fail "default --check rc=${rc}"

# 2. Unknown action exits 2
upgrade_run --bogus >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] && _ok "unknown action exit 2" || _fail "unknown action rc=${rc}"

# 3. -h prints usage, exit 0
out="$(upgrade_run -h 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && [[ "$out" == *"Usage:"* ]] && _ok "-h exit 0 + usage" || _fail "-h rc=${rc} out=${out:0:60}"

# 4. Add 1 pending migration → upgrade_check exits 1
cat > "${MIGRATIONS_DIR}/001-test.sh" <<'EOF'
migration_1_up() { state_set_secret TEST_KEY "test-001" || return 1; return 0; }
EOF
upgrade_check >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 1 ]] && _ok "pending → exit 1" || _fail "pending rc=${rc}"

# 5. upgrade_apply --yes → schema bumps to 1, exit 0
upgrade_apply --yes >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && _ok "apply --yes exit 0" || _fail "apply rc=${rc}"
[[ "$(state_schema_version)" == "1" ]] && _ok "schema bumped to 1" || _fail "schema=$(state_schema_version)"

# 6. After apply, check exits 0
upgrade_check >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && _ok "post-apply check exit 0" || _fail "post-apply check rc=${rc}"

# 7. Schema marker corruption → exit 2
# Manually corrupt line 1 of secrets.env to # schema=99
tmp_se="$(mktemp)"
{ echo '# schema=99'; tail -n +2 "${STATE_DIR}/secrets.env"; } > "$tmp_se"
mv "$tmp_se" "${STATE_DIR}/secrets.env"
upgrade_check >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] && _ok "marker mismatch → exit 2" || _fail "marker mismatch rc=${rc}"
# Restore marker
tmp_se="$(mktemp)"
{ echo '# schema=1'; tail -n +2 "${STATE_DIR}/secrets.env"; } > "$tmp_se"
mv "$tmp_se" "${STATE_DIR}/secrets.env"

# 8. upgrade_rollback without target → exit 2
upgrade_rollback >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] && _ok "rollback without target exit 2" || _fail "rollback no-target rc=${rc}"

# 9. upgrade_rollback 0 --yes → restores from state-pre-001-*.tar.gz that apply created.
# PRECONDITION GUARD (warning #4 fix): assertion #5 (upgrade_apply --yes) MUST have
# produced ${BACKUP_BASE}/state-pre-001-*.tar.gz via _migrations_backup. If #5 failed
# for any reason, this assertion would misleadingly fail with "no backup" — the real
# fix is in #5. The compgen -G guard below makes the cascade obvious.
if compgen -G "${BACKUP_BASE}/state-pre-001-*.tar.gz" >/dev/null; then
    _ok "precondition: backup tarball from #5 present"
else
    _fail "precondition: no state-pre-001-*.tar.gz in ${BACKUP_BASE} — assertion #5 failed upstream"
fi
upgrade_rollback 0 --yes >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && _ok "rollback 0 --yes exit 0" || _fail "rollback rc=${rc}"
[[ "$(state_schema_version)" == "0" ]] && _ok "schema restored to 0" || _fail "schema after rollback=$(state_schema_version)"

# 10. Rollback target=5 (no tarball) → exit 2
upgrade_rollback 5 --yes >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] && _ok "rollback no-tarball exit 2" || _fail "rollback no-tarball rc=${rc}"

# 11. Concurrent --apply: hold upgrade.lock in background, second invocation = exit 2.
# WARNING #2 FIX: `sleep 0.5` to wait for background lock-acquire was FLAKY under CI
# load — the foreground upgrade_apply may run before the background flock actually
# grabs the FD. Touch-file sync marker mechanism: background subshell signals via
# ${STATE_DIR}/.lock_acquired AFTER flock returns, foreground polls until it sees
# the file (5s max, 100ms poll = 50 iterations).
install -d -m 0700 "${STATE_DIR}/.locks" 2>/dev/null
lockfile="${STATE_DIR}/.locks/upgrade.lock"
sync_marker="${STATE_DIR}/.lock_acquired"
rm -f "$sync_marker"
(
    flock -x 9
    touch "$sync_marker"
    sleep 5
    rm -f "$sync_marker"
) 9>"$lockfile" &
holder_pid=$!
# Wait for background to actually hold the lock (5s timeout)
for _ in $(seq 1 50); do
    [[ -f "$sync_marker" ]] && break
    sleep 0.1
done
if [[ ! -f "$sync_marker" ]]; then
    _fail "concurrent apply: background lock holder did not acquire within 5s — flaky env, test inconclusive"
    kill "$holder_pid" 2>/dev/null
    wait "$holder_pid" 2>/dev/null
else
    upgrade_apply --yes >/dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 2 ]] && _ok "concurrent apply blocked (exit 2)" || _fail "concurrent apply rc=${rc} (expected 2 due to flock)"
    kill "$holder_pid" 2>/dev/null
    wait "$holder_pid" 2>/dev/null
fi

# 12. apply with no pending → exit 0
# After rollback target=0, schema=0 but migration file still exists → apply re-runs,
# then second apply finds nothing pending → exit 0.
upgrade_apply --yes >/dev/null 2>&1 || true
upgrade_apply --yes >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && _ok "apply on no-pending exit 0" || _fail "no-pending apply rc=${rc}"

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ "$fail" -eq 0 ]]
