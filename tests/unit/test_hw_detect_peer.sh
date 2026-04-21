#!/usr/bin/env bash
# Unit test for lib/detect.sh::hw_detect_peer + _ensure_lldpd + _peer_ping_fallback.
# Uses PATH-prepend mocks for lldpcli, fping, systemctl, apt-get, hostname.
# Does NOT require root, Docker, or network access.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MOCKS_DIR="${REPO_ROOT}/tests/mocks"
FIXTURES_DIR="${REPO_ROOT}/tests/fixtures"

export MOCK_FIXTURE_DIR="${FIXTURES_DIR}"
export PATH="${MOCKS_DIR}:${PATH}"

# Make mocks executable (idempotent)
chmod +x "${MOCKS_DIR}"/* 2>/dev/null || true

# Suppress color codes for clean CI output
RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0
FAIL=0
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }

# run_scenario name lldp_scenario apt_ok fping_alive mock_hostname expect_host expect_ip
run_scenario() {
    local name="$1" scenario="$2" apt_ok="${3:-1}" fping_alive="${4:-}" \
          mock_hostname="${5:-mock-host}" expect_host="${6:-}" expect_ip="${7:-}"
    local out
    out="$(
        MOCK_LLDP_SCENARIO="$scenario" \
        MOCK_APT_OK="$apt_ok" \
        MOCK_FPING_ALIVE="$fping_alive" \
        MOCK_HOSTNAME="$mock_hostname" \
        DETECTED_NETWORK="true" \
        bash -c "
            set +e
            source '${REPO_ROOT}/lib/common.sh' 2>/dev/null || true
            source '${REPO_ROOT}/lib/detect.sh'
            _ensure_lldpd >/dev/null 2>&1
            hw_detect_peer >/dev/null 2>&1
            echo \"H=\${PEER_HOSTNAME:-}\"
            echo \"IP=\${PEER_IP:-}\"
            echo \"U=\${PEER_USER:-}\"
            exit 0
        " 2>/dev/null
    )"
    local got_host got_ip got_user
    got_host="$(echo "$out" | awk -F= '/^H=/{print substr($0,3)}')"
    got_ip="$(echo "$out" | awk -F= '/^IP=/{print substr($0,4)}')"
    got_user="$(echo "$out" | awk -F= '/^U=/{print substr($0,3)}')"

    if [[ "$got_host" == "$expect_host" && "$got_ip" == "$expect_ip" && "$got_user" == "agmind2" ]]; then
        pass "${name} => H='${got_host}' IP='${got_ip}' U='${got_user}'"
    else
        fail "${name} => expected H='${expect_host}' IP='${expect_ip}' U='agmind2'" \
             "got H='${got_host}' IP='${got_ip}' U='${got_user}'"
    fi
}

echo "=== test_hw_detect_peer.sh ==="
echo ""

# Scenario 1: LLDP happy path — finds spark-69a2 at 192.168.100.2
run_scenario "LLDP happy path" \
    "peer" 1 "" "mock-host" "spark-69a2" "192.168.100.2"

# Scenario 2: LLDP self-only (our hostname = spark-3eac, self-filtered) + fping finds .2
run_scenario "LLDP self-only + fping finds peer" \
    "self_only" 1 "192.168.100.2" "spark-3eac" "" "192.168.100.2"

# Scenario 3: LLDP empty + fping finds .2
run_scenario "LLDP empty + fping finds peer" \
    "empty" 1 "192.168.100.2" "mock-host" "" "192.168.100.2"

# Scenario 4: LLDP empty + fping empty => single mode, no peer
run_scenario "No peer at all (single mode)" \
    "empty" 1 "" "mock-host" "" ""

# Scenario 5: LLDP unavailable (empty) + apt fails + fping finds peer
run_scenario "LLDP unavailable, fping finds peer" \
    "empty" 0 "192.168.100.5" "mock-host" "" "192.168.100.5"

# Scenario 6: LLDP self-only + fping empty => no peer
run_scenario "LLDP self-only + fping empty" \
    "self_only" 1 "" "spark-3eac" "" ""

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
