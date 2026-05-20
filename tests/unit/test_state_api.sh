#!/usr/bin/env bash
# tests/unit/test_state_api.sh — STATE-02 + STATE-03 unit coverage.
#
# Asserts:
#   1. lib/state.sh is sourceable under set -uo pipefail
#   2. state_init_dir creates STATE_DIR + .locks/ + bootstrap files with correct modes
#   3. state_set / state_get round-trip non-secret values byte-exact
#   4. state_get on absent key returns 1
#   5. state_set_secret / state_get_secret round-trip $-special secrets byte-exact
#   6. state_set_secret rejects empty value (return 1, existing value untouched)
#   7. state_set_secret upsert preserves other keys + `# schema=N` marker
#   8. state_schema_version defaults to 0, state_schema_version_set N persists, file mode 0644
#   8b. Concurrent state_schema_version_set under flock: 4 parallel writers → final ∈ {11,12,13,14}
#   9. Concurrent state_set under flock: 5 parallel writers → final value is one of the 5
#  10. log_info / log_error in lib/state.sh never emits secret value (regression vs R7)
#
# Hermetic: STATE_DIR = $(mktemp -d); no real /var/lib/ touches.
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_state_api"

STATE_DIR="$(mktemp -d)"
export STATE_DIR
trap 'rm -rf "$STATE_DIR"' EXIT

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/state.sh"

pass=0; fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# 1. state_init_dir
state_init_dir
[[ -d "$STATE_DIR" ]]                && _ok "STATE_DIR exists"               || _fail "STATE_DIR missing"
[[ -d "$STATE_DIR/.locks" ]]         && _ok ".locks/ created"                || _fail ".locks/ missing"
mode_state="$(stat -c '%a' "$STATE_DIR")"
[[ "$mode_state" == "700" ]]         && _ok "STATE_DIR mode 0700"            || _fail "STATE_DIR mode ${mode_state}"
[[ -f "$STATE_DIR/schema_version" ]] && _ok "schema_version bootstrapped"    || _fail "schema_version missing"
[[ -f "$STATE_DIR/secrets.env" ]]    && _ok "secrets.env bootstrapped"       || _fail "secrets.env missing"
mode_se="$(stat -c '%a' "$STATE_DIR/secrets.env")"
[[ "$mode_se" == "600" ]]            && _ok "secrets.env mode 0600"          || _fail "secrets.env mode ${mode_se}"
marker="$(head -1 "$STATE_DIR/secrets.env")"
[[ "$marker" == "# schema=0" ]]      && _ok "schema marker bootstrapped"     || _fail "marker: ${marker}"

# 2. round-trip non-secret
state_set last_action "upgrade-check"
got="$(state_get last_action)"
[[ "$got" == "upgrade-check" ]] && _ok "round-trip state_set/state_get" || _fail "round-trip drift: ${got}"

# 3. state_get on absent key returns 1
state_get nonexistent_key 2>/dev/null && _fail "absent key returned 0" || _ok "absent key returns 1"

# 4. byte-exact $-special secret round-trip
tricky='postgresPw$with$special#chars and "quotes" 123'
state_set_secret DB_PASSWORD "$tricky"
got="$(state_get_secret DB_PASSWORD)"
[[ "$got" == "$tricky" ]] && _ok "secret \$-safe byte-exact" || _fail "secret drift: |${got}|"

# 5. empty-value rejection
state_set_secret DB_PASSWORD "" 2>/dev/null && _fail "empty value accepted" || _ok "empty value rejected"
got="$(state_get_secret DB_PASSWORD)"
[[ "$got" == "$tricky" ]] && _ok "empty rejection left existing value intact" || _fail "value corrupted by empty attempt: |${got}|"

# 6. upsert preserves other keys + marker
state_set_secret REDIS_PASSWORD "redis-pw-xyz"
state_set_secret DB_PASSWORD "new-db-pw"
marker_after="$(head -1 "$STATE_DIR/secrets.env")"
[[ "$marker_after" == "# schema=0" ]] && _ok "marker preserved after upserts" || _fail "marker drifted: ${marker_after}"
[[ "$(state_get_secret REDIS_PASSWORD)" == "redis-pw-xyz" ]] && _ok "REDIS_PASSWORD preserved" || _fail "REDIS lost"
[[ "$(state_get_secret DB_PASSWORD)" == "new-db-pw" ]]       && _ok "DB_PASSWORD upserted"     || _fail "DB upsert failed"

# 7. schema_version round-trip
[[ "$(state_schema_version)" == "0" ]] && _ok "default schema=0" || _fail "default schema not 0"
state_schema_version_set 1
[[ "$(state_schema_version)" == "1" ]] && _ok "schema_version_set persists" || _fail "schema_version_set drift"
mode_sv="$(stat -c '%a' "$STATE_DIR/schema_version")"
[[ "$mode_sv" == "644" ]] && _ok "schema_version mode 0644" || _fail "schema_version mode ${mode_sv}"

# 7b. concurrent state_schema_version_set under flock — 4 writers, final is exactly one input
state_schema_version_set 0  # baseline
(
    state_schema_version_set 11 &
    state_schema_version_set 12 &
    state_schema_version_set 13 &
    state_schema_version_set 14 &
    wait
) 2>/dev/null
final_sv="$(state_schema_version)"
case "$final_sv" in
    11|12|13|14) _ok "schema_version flock contention: final=${final_sv} (one of writers)" ;;
    *)           _fail "schema_version flock contention: corrupt/unexpected final='${final_sv}'" ;;
esac
# Reset for downstream assertions
state_schema_version_set 1

# 8. invalid name rejection
state_set_secret "bad-name!" "v" 2>/dev/null && _fail "invalid name accepted" || _ok "invalid name rejected"
state_set_secret "" "v" 2>/dev/null && _fail "empty name accepted" || _ok "empty name rejected"

# 9. concurrent state_set — 5 parallel writers, final value is one of the 5
pids=()
for i in 1 2 3 4 5; do
    ( state_set concurrent_key "writer-$i" ) &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
final="$(state_get concurrent_key)"
case "$final" in
    writer-1|writer-2|writer-3|writer-4|writer-5)
        _ok "flock contention: final value is valid writer (${final})"
        ;;
    *)
        _fail "flock contention: final value corrupted: |${final}|"
        ;;
esac

# 10. No secret value logged — grep stderr of a state_set_secret call
stderr_capture="$(mktemp)"
state_set_secret SECRET_FOR_LOG_TEST "ultra-secret-canary-12345" 2>"$stderr_capture"
if grep -q 'ultra-secret-canary-12345' "$stderr_capture"; then
    _fail "secret value leaked to stderr"
else
    _ok "no secret value in log output"
fi
rm -f "$stderr_capture"

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ "$fail" -eq 0 ]]
