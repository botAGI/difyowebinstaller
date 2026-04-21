#!/usr/bin/env bash
# Unit test for lib/cluster_mode.sh::cluster_mode_save atomic write.
# Verifies: tmp file creation, atomic mv, JSON validity, status update preservation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

export AGMIND_CLUSTER_STATE_DIR="${TEST_TMPDIR}/state"
export AGMIND_CLUSTER_STATE_FILE="${AGMIND_CLUSTER_STATE_DIR}/cluster.json"

# Suppress colors in test output
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
# shellcheck source=../../lib/cluster_mode.sh
source "${REPO_ROOT}/lib/cluster_mode.sh"

echo "=== test_cluster_json_persist.sh ==="

# Scenario 1: save creates valid JSON with all 6 expected fields
rm -rf "$AGMIND_CLUSTER_STATE_DIR"
cluster_mode_save "master" "spark-69a2" "192.168.100.2" "192.168.100.0/24" "configured" >/dev/null 2>&1
if [[ -f "$AGMIND_CLUSTER_STATE_FILE" ]]; then
    if jq -e . "$AGMIND_CLUSTER_STATE_FILE" >/dev/null 2>&1; then
        mode=$(jq -r .mode "$AGMIND_CLUSTER_STATE_FILE")
        peer_h=$(jq -r .peer_hostname "$AGMIND_CLUSTER_STATE_FILE")
        peer_i=$(jq -r .peer_ip "$AGMIND_CLUSTER_STATE_FILE")
        subnet=$(jq -r .subnet "$AGMIND_CLUSTER_STATE_FILE")
        status=$(jq -r .status "$AGMIND_CLUSTER_STATE_FILE")
        ts=$(jq -r .updated_at "$AGMIND_CLUSTER_STATE_FILE")
        if [[ "$mode" == "master" && "$peer_h" == "spark-69a2" && "$peer_i" == "192.168.100.2" \
            && "$subnet" == "192.168.100.0/24" && "$status" == "configured" \
            && "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
            pass "save creates valid JSON with 6 expected fields"
        else
            fail "save fields mismatch: mode=$mode peer_h=$peer_h peer_i=$peer_i subnet=$subnet status=$status ts=$ts"
        fi
    else
        fail "save produced invalid JSON"
    fi
else
    fail "save did not create file"
fi

# Scenario 2: save invalid mode returns non-zero + no file created
rm -rf "$AGMIND_CLUSTER_STATE_DIR"
if cluster_mode_save "zzz" "" "" "" "configured" 2>/dev/null; then
    fail "invalid mode should return non-zero"
else
    pass "invalid mode -> return 1"
fi
if [[ ! -f "$AGMIND_CLUSTER_STATE_FILE" ]]; then
    pass "invalid mode -> no file created"
else
    fail "invalid mode should not create file"
fi

# Scenario 3: no temp files left after successful save (atomic write)
rm -rf "$AGMIND_CLUSTER_STATE_DIR"
cluster_mode_save "single" "" "" "192.168.100.0/24" "configured" >/dev/null 2>&1
leftover_tmp=$(find "$AGMIND_CLUSTER_STATE_DIR" -name 'cluster.json.tmp.*' 2>/dev/null | wc -l)
[[ "$leftover_tmp" == "0" ]] && pass "no .tmp.* leftover after atomic save" \
    || fail "leftover .tmp files found: $leftover_tmp"

# Scenario 4: cluster_status_update preserves mode + peer fields
rm -rf "$AGMIND_CLUSTER_STATE_DIR"
cluster_mode_save "master" "spark-69a2" "192.168.100.2" "192.168.100.0/24" "configured" >/dev/null 2>&1
cluster_status_update "running" >/dev/null 2>&1
new_status=$(jq -r .status "$AGMIND_CLUSTER_STATE_FILE")
new_mode=$(jq -r .mode "$AGMIND_CLUSTER_STATE_FILE")
new_peer=$(jq -r .peer_hostname "$AGMIND_CLUSTER_STATE_FILE")
if [[ "$new_status" == "running" && "$new_mode" == "master" && "$new_peer" == "spark-69a2" ]]; then
    pass "status_update preserves mode+peer fields"
else
    fail "status_update broke fields: status=$new_status mode=$new_mode peer=$new_peer"
fi

# Scenario 5: second save overwrites first (overwrite semantics)
rm -rf "$AGMIND_CLUSTER_STATE_DIR"
cluster_mode_save "master" "spark-a" "192.168.100.2" "192.168.100.0/24" "configured" >/dev/null 2>&1
cluster_mode_save "single" "" "" "192.168.100.0/24" "configured" >/dev/null 2>&1
final_mode=$(jq -r .mode "$AGMIND_CLUSTER_STATE_FILE")
final_peer=$(jq -r .peer_hostname "$AGMIND_CLUSTER_STATE_FILE")
[[ "$final_mode" == "single" && "$final_peer" == "" ]] && pass "second save overwrites first" \
    || fail "overwrite: mode=$final_mode peer=$final_peer"

# Scenario 6: special chars in hostname (dashes, dots) are preserved verbatim
rm -rf "$AGMIND_CLUSTER_STATE_DIR"
cluster_mode_save "master" "spark-69a2-test.local" "192.168.100.2" "192.168.100.0/24" "configured" >/dev/null 2>&1
got_h=$(jq -r .peer_hostname "$AGMIND_CLUSTER_STATE_FILE")
[[ "$got_h" == "spark-69a2-test.local" ]] && pass "special chars (dots/dashes) in hostname preserved" \
    || fail "hostname special chars: got '$got_h'"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
