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

# --- Scenario 4: MODE=master + valid PEER_IP + all mocks OK → firewall rule applied ---
# Asserts: the ssh calllog contains port 8000 firewall command strings (iptables/ufw).
# _apply_peer_vllm_firewall sends the entire remote script as one ssh argument — the
# calllog captures it, so grep for the iptables -C idempotency guard and --dport 8000.
(
    set +eu
    export AGMIND_MODE=master
    export PEER_IP=192.168.100.2
    export PEER_USER=agmind2
    export MOCK_SSH_EXIT=0
    export MOCK_SSH_STDOUT=''
    export MOCK_CURL_EXIT=0
    export MOCK_SCP_EXIT=0
    export MOCK_SCP_CALLLOG="${WORK_DIR}/s4_scp.log"
    export MOCK_SSH_CALLLOG="${WORK_DIR}/s4_ssh.log"
    export MOCK_DOCKER_FIXTURE=healthy
    : > "${MOCK_SCP_CALLLOG}"
    : > "${MOCK_SSH_CALLLOG}"
    mkdir -p "${WORK_DIR}/state"
    echo '{"mode":"master","peer_ip":"192.168.100.2","status":"deploying"}' > "${AGMIND_CLUSTER_STATE_FILE}"
    export INSTALL_DIR="${WORK_DIR}"
    export INSTALLER_DIR="${WORK_DIR}"
    export TEMPLATE_DIR="${WORK_DIR}/templates"
    mkdir -p "${WORK_DIR}/templates"
    echo "# mock worker compose" > "${WORK_DIR}/templates/docker-compose.worker.yml"
    peer_deploy >/dev/null 2>&1
    echo "EXIT=$?"
) > "${WORK_DIR}/s4.out" 2>&1
if grep -q 'EXIT=0' "${WORK_DIR}/s4.out"; then
    pass "firewall scenario: peer_deploy returns 0"
else
    fail "firewall scenario: peer_deploy should return 0 — got: $(cat "${WORK_DIR}/s4.out")"
fi
# Assert firewall-related command (port 8000) appears in the ssh call log
if [[ -f "${WORK_DIR}/s4_ssh.log" ]] && grep -q '8000' "${WORK_DIR}/s4_ssh.log"; then
    pass "firewall rule: ssh calllog contains port 8000 restriction command"
else
    fail "firewall rule: expected '8000' in ssh calllog — got: $(cat "${WORK_DIR}/s4_ssh.log" 2>/dev/null || echo '<missing>')"
fi
# Assert idempotency guard: iptables -C check-before-add is shipped in the remote script
if [[ -f "${WORK_DIR}/s4_ssh.log" ]] && grep -qE 'iptables -C|ufw status' "${WORK_DIR}/s4_ssh.log"; then
    pass "firewall idempotency: ssh calllog contains check-before-add guard (iptables -C or ufw status)"
else
    fail "firewall idempotency: expected 'iptables -C' or 'ufw status' in ssh calllog — got: $(cat "${WORK_DIR}/s4_ssh.log" 2>/dev/null || echo '<missing>')"
fi

# --- Scenario 5: MODE=single → no firewall call (peer_deploy exits early) ---
# Assert: the ssh calllog is empty (no ssh call at all — mode=single exits before any ssh).
(
    set +eu
    export AGMIND_MODE=single
    export PEER_IP=""
    export MOCK_SSH_EXIT=0
    export MOCK_SSH_CALLLOG="${WORK_DIR}/s5_ssh.log"
    : > "${WORK_DIR}/s5_ssh.log"
    peer_deploy >/dev/null 2>&1
    echo "EXIT=$?"
) > "${WORK_DIR}/s5.out" 2>&1
if grep -q 'EXIT=0' "${WORK_DIR}/s5.out"; then
    pass "single mode no firewall: returns 0"
else
    fail "single mode no firewall: should return 0"
fi
if [[ ! -s "${WORK_DIR}/s5_ssh.log" ]]; then
    pass "single mode no firewall: no ssh calls made (calllog empty)"
else
    fail "single mode no firewall: expected empty ssh calllog — got: $(cat "${WORK_DIR}/s5_ssh.log")"
fi

# --- Scenario 6: firewall ssh failure is non-fatal (peer_deploy still returns 0) ---
# Strategy: set MOCK_SSH_EXIT=1 for ALL ssh calls but peer_deploy should succeed because
# _apply_peer_vllm_firewall wraps failure with || log_warn (non-fatal).
# We cannot selectively fail only the firewall ssh call with the current mock, so we verify
# the design instead: check that _apply_peer_vllm_firewall is defined with a non-fatal wrap.
# This is a structural (static) assertion — the || log_warn guard is in the source.
if grep -q 'log_warn.*non-fatal\|non-fatal.*log_warn' /dev/stdin <<< "$(grep -A2 'firewall rule not applied' "${REPO_ROOT}/lib/peer.sh" 2>/dev/null || true)"; then
    pass "firewall non-fatal: lib/peer.sh has non-fatal log_warn wrap"
else
    # Direct grep on the file
    if grep -q 'peer.*firewall rule not applied.*non-fatal\|non-fatal.*defence-in-depth' "${REPO_ROOT}/lib/peer.sh" 2>/dev/null; then
        pass "firewall non-fatal: lib/peer.sh has non-fatal log_warn wrap"
    else
        fail "firewall non-fatal: expected non-fatal log_warn in _apply_peer_vllm_firewall — check lib/peer.sh"
    fi
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
