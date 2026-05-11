#!/usr/bin/env bash
# Unit test for lib/peer.sh::peer_deploy — mocked curl/ssh/scp, no live peer.
# Updated Plan 06-01 Task 3: re-pointed from install.sh awk-extraction to lib/peer.sh source.
# Original: MAJOR 6 FIX (revision): was only live UAT (VALIDATION T2.7); now automated.
#
# Scenarios:
#   1. AGMIND_MODE=single  → early return 0 (no scp/ssh/curl calls)
#   2. AGMIND_MODE=master + PEER_IP empty → fail gracefully (return != 0)
#   3. AGMIND_MODE=master + PEER_IP valid + all mocks OK → return 0, scp called
#
# Dependencies: tests/mocks/curl, tests/mocks/ssh, tests/mocks/scp, tests/mocks/docker
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

# Source peer module and its dependencies (in dependency order).
# lib/peer.sh is the unit under test — no awk-extraction from install.sh needed.
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/cluster_mode.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/ssh_trust.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/peer.sh"

echo "=== test peer_deploy (lib/peer.sh) ==="

# --- Scenario 1: MODE=single → early return 0 without network calls ---
# Assert: no scp calls recorded (calllog empty), exit 0.
(
    set +eu  # disable errexit + nounset — allow testing return codes
    export AGMIND_MODE=single
    PEER_IP=""
    export PEER_IP
    export MOCK_CURL_EXIT=0
    export MOCK_SSH_EXIT=0
    export MOCK_SCP_CALLLOG="${WORK_DIR}/s1_scp.log"
    : > "${WORK_DIR}/s1_scp.log"
    peer_deploy >/dev/null 2>&1
    echo "EXIT=$?"
) > "${WORK_DIR}/s1.out" 2>&1
if grep -q 'EXIT=0' "${WORK_DIR}/s1.out"; then
    pass "single mode early return 0"
else
    fail "single mode should return 0 — got: $(cat "${WORK_DIR}/s1.out")"
fi
if [[ ! -s "${WORK_DIR}/s1_scp.log" ]]; then
    pass "single mode: no scp calls (no side effects)"
else
    fail "single mode should make no scp calls — got: $(cat "${WORK_DIR}/s1_scp.log")"
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
    peer_deploy >/dev/null 2>&1
    echo "EXIT=$?"
) > "${WORK_DIR}/s2.out" 2>&1
if grep -qE 'EXIT=[1-9]' "${WORK_DIR}/s2.out"; then
    pass "master mode without PEER_IP fails gracefully"
else
    fail "master mode without PEER_IP should fail — got: $(cat "${WORK_DIR}/s2.out")"
fi

# --- Scenario 3: MODE=master + valid PEER_IP + all mocks OK → return 0, scp called ---
# Strategy: use MOCK_SSH_STDOUT='' (no current running image) so idempotent branch is
# skipped, then all mocks succeed (exit 0) → peer_deploy returns 0 and scp IS called.
# gpu-metrics.sh absent → _deploy_peer_gpu_metrics returns 1 (non-fatal warn, continues).
# worker template absent → _deploy_peer_systemd returns 1 (non-fatal warn, continues).
# The key assertions: exit 0 + scp log non-empty (scp was called for worker compose/.env).
mkdir -p "${WORK_DIR}/docker"
# Provide a minimal worker compose template so scp step doesn't fail on cp
echo "# mock worker compose" > "${WORK_DIR}/templates/docker-compose.worker.yml" 2>/dev/null \
    || { mkdir -p "${WORK_DIR}/templates"; echo "# mock worker compose" > "${WORK_DIR}/templates/docker-compose.worker.yml"; }
(
    set +eu  # disable errexit + nounset — capture return code
    export AGMIND_MODE=master
    export PEER_IP=192.168.100.2
    export PEER_USER=agmind2
    export MOCK_SSH_EXIT=0
    export MOCK_SSH_STDOUT=''          # no current image → idempotent branch NOT taken
    export MOCK_CURL_EXIT=0            # _wait_peer_vllm_ready succeeds immediately
    export MOCK_SCP_EXIT=0
    export MOCK_SCP_CALLLOG="${WORK_DIR}/s3_scp.log"
    export MOCK_DOCKER_FIXTURE=healthy
    : > "${MOCK_SCP_CALLLOG}"
    mkdir -p "${WORK_DIR}/state"
    echo '{"mode":"master","peer_ip":"192.168.100.2","status":"deploying"}' > "${AGMIND_CLUSTER_STATE_FILE}"
    # Point peer.sh to our temp dirs for file paths
    export INSTALL_DIR="${WORK_DIR}"
    export INSTALLER_DIR="${WORK_DIR}"
    export TEMPLATE_DIR="${WORK_DIR}/templates"
    peer_deploy >/dev/null 2>&1
    echo "EXIT=$?"
) > "${WORK_DIR}/s3.out" 2>&1
if grep -q 'EXIT=0' "${WORK_DIR}/s3.out"; then
    pass "master mode happy path returns 0"
else
    fail "master mode happy path should return 0 — got: $(cat "${WORK_DIR}/s3.out")"
fi
if [[ -s "${WORK_DIR}/s3_scp.log" ]]; then
    pass "master mode happy path: scp was called (worker files transferred)"
else
    fail "master mode happy path: scp was NOT called — expected worker file transfer; log: $(cat "${WORK_DIR}/s3.out")"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
