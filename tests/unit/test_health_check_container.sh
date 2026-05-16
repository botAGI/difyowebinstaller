#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_health_check_container.sh
# Regression test for HEALTH-01 — check_container must distinguish healthy
# from unhealthy/exited/starting/etc via docker inspect.
#
# Mocks `docker` on PATH with a controllable stub so the test runs offline
# and exercises each state without spinning real containers.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Mock docker via PATH override.
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_DIR"' EXIT
cat > "${MOCK_DIR}/docker" <<'MOCK'
#!/usr/bin/env bash
# Mock docker for HEALTH-01 tests. Reads desired state from MOCK_DOCKER_STATE env.
case "$1" in
    inspect)
        printf '%s' "${MOCK_DOCKER_STATE:-not-found}"
        exit 0
        ;;
    ps|compose|version|info)
        # Return empty for ps/compose/version — check_container doesn't use them
        # in the new path; preserved for callers that still might invoke.
        exit 0
        ;;
esac
exit 0
MOCK
chmod +x "${MOCK_DIR}/docker"
export PATH="${MOCK_DIR}:${PATH}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"  # for log_*, color codes
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/health.sh"
# Sourced files set -euo pipefail; we need to test return codes manually.
set +e

pass=0
fail=0
_run_state() {
    local label="$1" state="$2" expect_rc="$3"
    MOCK_DOCKER_STATE="$state" check_container "redis" >/dev/null 2>&1
    local actual_rc=$?
    if [[ "$actual_rc" -eq "$expect_rc" ]]; then
        pass=$((pass + 1))
        echo "  [PASS] ${label}: state=${state} rc=${actual_rc}"
    else
        fail=$((fail + 1))
        echo "  [FAIL] ${label}: state=${state} expected rc=${expect_rc} got rc=${actual_rc}"
    fi
}

echo "## test_health_check_container"
echo ""
echo "--- HEALTH-01 regression: state → expected rc ---"
_run_state "healthy = OK"           "healthy"    0
_run_state "running (no healthcheck) = OK" "running"    0
_run_state "unhealthy = FAIL (HEALTH-01)"  "unhealthy"  1
_run_state "exited = FAIL"          "exited"     1
_run_state "starting = IN-PROGRESS" "starting"   1
_run_state "created = IN-PROGRESS"  "created"    1
_run_state "restarting = IN-PROGRESS" "restarting" 1
_run_state "dead = FAIL"            "dead"       1
_run_state "paused = FAIL"          "paused"     1
_run_state "not-found = FAIL"       "not-found"  1

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
