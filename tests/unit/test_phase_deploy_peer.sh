#!/usr/bin/env bash
# Unit test for install.sh::phase_deploy_peer — mocked curl/ssh, no live peer.
# MAJOR 6 FIX (revision): was only live UAT (VALIDATION T2.7); now automated coverage.
#
# Scenarios:
#   1. AGMIND_MODE=single  → early return 0 (no network calls)
#   2. AGMIND_MODE=master + PEER_IP empty → fail gracefully (return != 0)
#
# Dependencies: tests/mocks/curl, tests/mocks/ssh (created in Plan 02-01 Task 3)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MOCKS_DIR="${REPO_ROOT}/tests/mocks"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# PATH-prepend mocks so curl/ssh/scp/docker/systemctl resolve to stubs
export PATH="${MOCKS_DIR}:${PATH}"
chmod +x "${MOCKS_DIR}"/* 2>/dev/null || true

# State isolation — no real /var/lib/agmind writes
export AGMIND_CLUSTER_STATE_DIR="${WORK_DIR}/state"
export AGMIND_CLUSTER_STATE_FILE="${AGMIND_CLUSTER_STATE_DIR}/cluster.json"
mkdir -p "${AGMIND_CLUSTER_STATE_DIR}"

# Suppress color output to keep test output readable
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Source helper libs that phase_deploy_peer depends on (in dependency order)
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/cluster_mode.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/ssh_trust.sh" 2>/dev/null || true

# Extract phase_deploy_peer and its helpers from install.sh via awk.
# install.sh has side-effects at top level, so we extract function definitions only.
for fn in phase_deploy_peer _render_worker_env _deploy_image_to_peer _wait_peer_vllm_ready; do
    block="$(awk -v f="${fn}" '
        $0 ~ "^"f"\\(\\)" { found=1 }
        found { print }
        found && /^}$/ { exit }
    ' "${REPO_ROOT}/install.sh")"
    if [[ -z "$block" ]]; then
        echo "SKIP: function '${fn}' not yet defined in install.sh (Plan 02-04 Task 1 not applied?)"
        exit 77  # rc=77 = SKIP in run_all.sh
    fi
    # shellcheck disable=SC1090
    eval "${block}"
done

echo "=== test_phase_deploy_peer.sh ==="

# --- Scenario 1: MODE=single → early return 0 without network calls ---
(
    set +eu  # disable errexit + nounset — allow testing return codes
    export AGMIND_MODE=single
    PEER_IP=""
    export PEER_IP
    export MOCK_CURL_EXIT=0
    export MOCK_SSH_EXIT=0
    phase_deploy_peer >/dev/null 2>&1
    echo "EXIT=$?"
) > "${WORK_DIR}/s1.out" 2>&1
if grep -q 'EXIT=0' "${WORK_DIR}/s1.out"; then
    pass "single mode early return 0"
else
    fail "single mode should return 0 — got: $(cat "${WORK_DIR}/s1.out")"
fi

# --- Scenario 2: MODE=master + PEER_IP empty → fail gracefully (return != 0) ---
(
    set +eu  # disable errexit + nounset — we want to capture non-zero exit code
    export AGMIND_MODE=master
    PEER_IP=""
    export PEER_IP
    # cluster.json with empty peer_ip to prevent jq fallback success
    mkdir -p "${AGMIND_CLUSTER_STATE_DIR}"
    echo '{"mode":"master","peer_ip":""}' > "${AGMIND_CLUSTER_STATE_FILE}"
    phase_deploy_peer >/dev/null 2>&1
    echo "EXIT=$?"
) > "${WORK_DIR}/s2.out" 2>&1
if grep -qE 'EXIT=[1-9]' "${WORK_DIR}/s2.out"; then
    pass "master mode without PEER_IP fails gracefully"
else
    fail "master mode without PEER_IP should fail — got: $(cat "${WORK_DIR}/s2.out")"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
