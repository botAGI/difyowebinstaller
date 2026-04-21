#!/usr/bin/env bash
# Unit test for lib/cluster_mode.sh — cluster_mode_select + cluster_mode_read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MOCKS_DIR="${REPO_ROOT}/tests/mocks"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

export PATH="${MOCKS_DIR}:${PATH}"
export AGMIND_CLUSTER_STATE_DIR="${TEST_TMPDIR}/state"
export AGMIND_CLUSTER_STATE_FILE="${AGMIND_CLUSTER_STATE_DIR}/cluster.json"
mkdir -p "$AGMIND_CLUSTER_STATE_DIR"

chmod +x "${MOCKS_DIR}"/* 2>/dev/null || true

# Suppress colors in test output
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
# shellcheck source=../../lib/tui.sh
source "${REPO_ROOT}/lib/tui.sh"
# shellcheck source=../../lib/cluster_mode.sh
source "${REPO_ROOT}/lib/cluster_mode.sh"

reset_state() {
    rm -f "$AGMIND_CLUSTER_STATE_FILE"
    unset AGMIND_MODE_OVERRIDE 2>/dev/null || true
}

echo "=== test_cluster_mode_select.sh ==="

# Scenario 1: AGMIND_MODE_OVERRIDE=master takes priority over persisted state
reset_state
cluster_mode_save "single" "" "" "192.168.100.0/24" "configured" >/dev/null 2>&1
got="$(AGMIND_MODE_OVERRIDE=master cluster_mode_read)"
[[ "$got" == "master" ]] && pass "ENV override priority: master over persisted single" \
    || fail "ENV override: expected master got '$got'"

# Scenario 2: AGMIND_MODE_OVERRIDE=invalid exits 1
# Run in a child bash process because cluster_mode_read calls exit 1 (not return),
# which would abort the current shell if called inline.
reset_state
if bash -c "
    source '${REPO_ROOT}/lib/common.sh' 2>/dev/null
    source '${REPO_ROOT}/lib/cluster_mode.sh'
    AGMIND_MODE_OVERRIDE=invalid cluster_mode_read
" 2>/dev/null; then
    fail "invalid override should exit 1"
else
    pass "invalid override exits 1"
fi

# Scenario 3: persisted state read (no env, cluster.json exists with mode=worker)
reset_state
cluster_mode_save "worker" "spark-xyz" "192.168.100.5" "192.168.100.0/24" "running" >/dev/null 2>&1
got="$(cluster_mode_read)"
[[ "$got" == "worker" ]] && pass "persisted state: worker" \
    || fail "persisted: expected worker got '$got'"

# Scenario 4: no state, no env, peer detected → TUI (mocked) returns master
reset_state
got="$(MOCK_WT_CHOICE=master cluster_mode_select 'spark-69a2' '192.168.100.2')"
[[ "$got" == "master" ]] && pass "TUI with peer -> master" \
    || fail "TUI with peer: expected master got '$got'"

# Scenario 5: no state, no env, no peer → TUI cancel (empty MOCK_WT_CHOICE) → default single
reset_state
got="$(MOCK_WT_CHOICE="" cluster_mode_select '' '')"
[[ "$got" == "single" ]] && pass "TUI no-peer cancel -> default single" \
    || fail "TUI no-peer: expected single got '$got'"

# Scenario 5b (MAJOR 5 FIX — ROADMAP SC#1 regression): peer detected + cancel -> STILL single
reset_state
got="$(MOCK_WT_CHOICE="" cluster_mode_select 'spark-69a2' '192.168.100.2')"
[[ "$got" == "single" ]] && pass "TUI peer-detected cancel -> single (SC#1 lock enforced)" \
    || fail "SC#1 lock broken: peer detected but cancel gave '$got' (expected single)"

# Scenario 6: TUI user selects worker
reset_state
got="$(MOCK_WT_CHOICE=worker cluster_mode_select 'spark-69a2' '192.168.100.2')"
[[ "$got" == "worker" ]] && pass "TUI user selects worker" \
    || fail "TUI worker: got '$got'"

# Scenario 7: round-trip select -> save -> read
reset_state
got="$(MOCK_WT_CHOICE=master cluster_mode_select 'spark-69a2' '192.168.100.2')"
cluster_mode_save "$got" "spark-69a2" "192.168.100.2" "192.168.100.0/24" "configured" >/dev/null 2>&1
got_reread="$(cluster_mode_read)"
[[ "$got_reread" == "master" ]] && pass "round-trip select->save->read: master" \
    || fail "round-trip: got '$got_reread'"

# Scenario 8: persisted state overrides TUI — re-install idempotent (PEER-04)
reset_state
cluster_mode_save "worker" "" "" "192.168.100.0/24" "configured" >/dev/null 2>&1
got="$(MOCK_WT_CHOICE=single cluster_mode_select 'spark-xxx' '192.168.100.3')"
[[ "$got" == "worker" ]] && pass "persisted state overrides TUI (idempotent re-install)" \
    || fail "idempotency: got '$got' (TUI should not override persisted state)"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
