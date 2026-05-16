#!/usr/bin/env bash
# tests/unit/test_migrations_runner.sh — STATE-04 unit coverage.
#
# Asserts:
#   1. migrations_list on empty dir = no output
#   2. migrations_list sorts 001/002/010 numerically (NOT lexicographically — 010 last)
#   3. migrations_pending filters by state_schema_version (only NNN > current)
#   4. Bad migration (bash -n fails) -> migrations_apply returns 1, schema_version unchanged
#   5. Good migration applied -> schema_version bumps, backup tarball appears in BACKUP_BASE
#   6. migration without migration_NNN_up function -> bails out
#   7. Idempotence: second migrations_apply with no pending = exit 0, no new backup
#
# Hermetic: STATE_DIR + MIGRATIONS_DIR + BACKUP_BASE all $(mktemp -d).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_migrations_runner"

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

# 1. Empty migrations dir
[[ -z "$(migrations_list)" ]] && _ok "empty migrations_list" || _fail "empty list returned content"

# 2. Numeric sort (010 must come after 002, NOT after 001 lexically)
cat > "${MIGRATIONS_DIR}/001-alpha.sh" <<'EOF'
migration_1_up() { return 0; }
EOF
cat > "${MIGRATIONS_DIR}/002-beta.sh"  <<'EOF'
migration_2_up() { return 0; }
EOF
cat > "${MIGRATIONS_DIR}/010-gamma.sh" <<'EOF'
migration_10_up() { return 0; }
EOF
listing="$(migrations_list)"
expected=$'001-alpha.sh\n002-beta.sh\n010-gamma.sh'
[[ "$listing" == "$expected" ]] && _ok "numeric sort 001/002/010" || _fail "sort drift: ${listing}"

# 3. pending — at schema=0, all 3 pending; at schema=2, only 010 pending
state_schema_version_set 0
pend="$(migrations_pending | tr '\n' ' ')"
[[ "$pend" == "001-alpha.sh 002-beta.sh 010-gamma.sh " ]] && _ok "pending at schema=0" || _fail "pending drift: '${pend}'"
state_schema_version_set 2
pend="$(migrations_pending | tr '\n' ' ')"
[[ "$pend" == "010-gamma.sh " ]] && _ok "pending filtered at schema=2" || _fail "pending drift at 2: '${pend}'"
state_schema_version_set 0

# 4. Bad migration (syntax error) — runner refuses, schema unchanged
echo 'this is not bash {{ broken' > "${MIGRATIONS_DIR}/001-alpha.sh"
migrations_apply --yes 2>/dev/null && _fail "bad syntax accepted" || _ok "bad syntax rejected"
[[ "$(state_schema_version)" == "0" ]] && _ok "schema unchanged after bad migration" || _fail "schema bumped on bad migration"

# 5. Good migration — schema bumps, backup tarball appears
cat > "${MIGRATIONS_DIR}/001-alpha.sh" <<'EOF'
migration_1_up() { state_set_secret TEST_KEY "test-value-from-001" || return 1; return 0; }
EOF
# Wipe the lateral 002/010 so only 001 runs (target the focused assertion)
rm "${MIGRATIONS_DIR}/002-beta.sh" "${MIGRATIONS_DIR}/010-gamma.sh"
migrations_apply --yes >/dev/null 2>&1 && _ok "good migration succeeded" || _fail "good migration failed"
[[ "$(state_schema_version)" == "1" ]] && _ok "schema bumped to 1" || _fail "schema=$(state_schema_version)"
backup_count="$(find "$BACKUP_BASE" -name 'state-pre-001-*.tar.gz' -type f | wc -l)"
[[ "$backup_count" -ge 1 ]] && _ok "backup tarball created" || _fail "no backup tarball (count=${backup_count})"

# 6. Missing migration_NNN_up function — bails
state_schema_version_set 1
cat > "${MIGRATIONS_DIR}/002-no-up-fn.sh" <<'EOF'
# Intentionally missing migration_2_up function
EOF
migrations_apply --yes 2>/dev/null && _fail "missing up fn accepted" || _ok "missing up fn rejected"
[[ "$(state_schema_version)" == "1" ]] && _ok "schema unchanged after missing-fn" || _fail "schema bumped"

# 7. Idempotence — re-apply with no pending
rm "${MIGRATIONS_DIR}/002-no-up-fn.sh"
before_count="$(find "$BACKUP_BASE" -name '*.tar.gz' -type f | wc -l)"
migrations_apply --yes >/dev/null 2>&1 && _ok "idempotent re-apply exit 0" || _fail "idempotent re-apply failed"
after_count="$(find "$BACKUP_BASE" -name '*.tar.gz' -type f | wc -l)"
[[ "$before_count" -eq "$after_count" ]] && _ok "no new backup on no-op apply" || _fail "extra backup on no-op (${before_count}->${after_count})"

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ "$fail" -eq 0 ]]
