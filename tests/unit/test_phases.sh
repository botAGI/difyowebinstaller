#!/usr/bin/env bash
# tests/unit/test_phases.sh — Unit coverage for lib/phases.sh phase engine.
# Covers: count, parity, iteration_order, name_to_idx, resume_from,
#         skip_optional, dry_run, nonzero_aborts, graceful_no_abort, jsonl_emit
# Uses set -uo pipefail (NO -e) to capture non-zero return codes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCKS_DIR="${REPO_ROOT}/tests/mocks"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="${MOCKS_DIR}:${PATH}"
export INSTALL_DIR="$WORK"
export TIMEOUT_START=300

# Suppress colors in output
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$(( FAIL + 1 )); }

echo "## test_phases"

# ============================================================================
# SETUP — load phases.sh after defining the stubs it depends on
# ============================================================================

# Stub run_phase: writes .install_phase then calls the phase function
run_phase() {
    local num="$1" total="$2" name="$3" func="$4"
    echo "$num" > "${INSTALL_DIR}/.install_phase"
    "$func"
}

# Stub run_phase_with_timeout: same as run_phase (ignores timeout in tests)
run_phase_with_timeout() {
    # shellcheck disable=SC2034  # total/name/secs unused in stub — real fn uses them
    local num="$1" total="$2" name="$3" func="$4" secs="$5"
    echo "$num" > "${INSTALL_DIR}/.install_phase"
    "$func"
}

# Stub cluster_mode_read: returns "master" by default (so peer phase runs)
cluster_mode_read() { echo "master"; }

# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true

# shellcheck source=../../lib/phases.sh
source "${REPO_ROOT}/lib/phases.sh"

# ============================================================================
# STUB PHASE FUNCTIONS
# ============================================================================
# CALLLOG is set per-case to a temp file; stubs append their name there.
# Override individual stubs per-case to inject failure.
CALLLOG="${WORK}/calllog.default"

_mk_stubs() {
    phase_diagnostics()     { echo "Diagnostics"   >> "$CALLLOG"; }
    phase_wizard()          { echo "Wizard"        >> "$CALLLOG"; }
    phase_docker()          { echo "Docker"        >> "$CALLLOG"; }
    phase_config()          { echo "Configuration" >> "$CALLLOG"; }
    phase_pull()            { echo "Pull"          >> "$CALLLOG"; }
    phase_start()           { echo "Start"         >> "$CALLLOG"; }
    peer_deploy()           { echo "Deploy Peer"   >> "$CALLLOG"; }
    phase_health()          { echo "Health"        >> "$CALLLOG"; }
    phase_models_graceful() { echo "Models"        >> "$CALLLOG"; }
    phase_backups()         { echo "Backups"       >> "$CALLLOG"; }
    phase_complete()        { echo "Complete"      >> "$CALLLOG"; }
}

# ============================================================================
# CASE 1: count
# ============================================================================
echo ""
echo "--- count ---"
got="$(phases_count)"
[[ "$got" == "11" ]] && pass "count: phases_count == 11" \
    || fail "count: expected 11, got '$got'"

# ============================================================================
# CASE 2: parity — verify all 11 records match the expected parity table
# ============================================================================
echo ""
echo "--- parity ---"

# name/fn spot-checks for all 11
_check_parity() {
    local idx="$1" exp_name="$2" exp_fn="$3" exp_timeout="$4" exp_flags="$5"
    local got_name got_fn got_timeout got_flags
    got_name="$(phases_get "$idx" name)"
    got_fn="$(phases_get "$idx" fn)"
    got_timeout="$(phases_get "$idx" timeout)"
    got_flags="$(phases_get "$idx" flags)"
    if [[ "$got_name" == "$exp_name" && "$got_fn" == "$exp_fn" && \
          "$got_timeout" == "$exp_timeout" && "$got_flags" == "$exp_flags" ]]; then
        pass "parity[${idx}]: ${exp_name} / ${exp_fn} / t=${exp_timeout} / flags='${exp_flags}'"
    else
        fail "parity[${idx}]: expected '${exp_name}/${exp_fn}/${exp_timeout}/${exp_flags}'" \
             "got '${got_name}/${got_fn}/${got_timeout}/${got_flags}'"
    fi
}

_check_parity 0  "Diagnostics"   "phase_diagnostics"      "0"    "preflight"
_check_parity 1  "Wizard"        "phase_wizard"           "0"    ""
_check_parity 2  "Docker"        "phase_docker"           "0"    ""
_check_parity 3  "Configuration" "phase_config"           "0"    ""
_check_parity 4  "Pull"          "phase_pull"             "0"    ""
_check_parity 5  "Start"         "phase_start"            "300"  ""
_check_parity 6  "Deploy Peer"   "peer_deploy"            "1800" "optional,master-only"
_check_parity 7  "Health"        "phase_health"           "0"    ""
_check_parity 8  "Models"        "phase_models_graceful"  "0"    "graceful"
_check_parity 9  "Backups"       "phase_backups"          "0"    ""
_check_parity 10 "Complete"      "phase_complete"         "0"    ""

# ============================================================================
# CASE 3: iteration_order — phases_run_all 0 calls all 11 in order
# ============================================================================
echo ""
echo "--- iteration_order ---"
_mk_stubs
CALLLOG="$(mktemp)"
# Run in subshell so any unexpected exit doesn't kill the test runner.
# cluster_mode_read is stubbed to "master" at top level — inherited by subshell.
(
    set +eu
    phases_run_all 0 >/dev/null 2>&1
)
EXPECTED_ORDER="$(printf 'Diagnostics\nWizard\nDocker\nConfiguration\nPull\nStart\nDeploy Peer\nHealth\nModels\nBackups\nComplete\n')"
ACTUAL_ORDER="$(cat "$CALLLOG")"
if [[ "$EXPECTED_ORDER" == "$ACTUAL_ORDER" ]]; then
    pass "iteration_order: all 11 phases called in correct order"
else
    fail "iteration_order: expected order differs"
    echo "    expected: $(echo "$EXPECTED_ORDER" | tr '\n' ',')" >&2
    echo "    actual:   $(echo "$ACTUAL_ORDER"   | tr '\n' ',')" >&2
fi
rm -f "$CALLLOG"

# ============================================================================
# CASE 4: name_to_idx — by name and by 1-based number
# ============================================================================
echo ""
echo "--- name_to_idx ---"

got="$(phases_name_to_idx Health)"
[[ "$got" == "7" ]] && pass "name_to_idx: 'Health' -> 7" \
    || fail "name_to_idx: 'Health' expected 7, got '$got'"

got="$(phases_name_to_idx "Deploy Peer")"
[[ "$got" == "6" ]] && pass "name_to_idx: 'Deploy Peer' -> 6" \
    || fail "name_to_idx: 'Deploy Peer' expected 6, got '$got'"

got="$(phases_name_to_idx 8)"
[[ "$got" == "7" ]] && pass "name_to_idx: 1-based 8 -> 7" \
    || fail "name_to_idx: 1-based 8 expected 7, got '$got'"

got="$(phases_name_to_idx 1)"
[[ "$got" == "0" ]] && pass "name_to_idx: 1-based 1 -> 0" \
    || fail "name_to_idx: 1-based 1 expected 0, got '$got'"

got="$(phases_name_to_idx 11)"
[[ "$got" == "10" ]] && pass "name_to_idx: 1-based 11 -> 10" \
    || fail "name_to_idx: 1-based 11 expected 10, got '$got'"

# Out-of-range numeric
OOR_OUT="$(
    set +eu
    phases_name_to_idx 99 2>/dev/null
    echo "EXIT=$?"
)"
if echo "$OOR_OUT" | grep -q 'EXIT=[1-9]'; then
    pass "name_to_idx: out-of-range 99 returns non-zero"
else
    fail "name_to_idx: out-of-range 99 should return non-zero, got: $OOR_OUT"
fi

# Unknown name
UNK_OUT="$(
    set +eu
    phases_name_to_idx "NoSuchPhase" 2>/dev/null
    echo "EXIT=$?"
)"
if echo "$UNK_OUT" | grep -q 'EXIT=[1-9]'; then
    pass "name_to_idx: unknown name returns non-zero"
else
    fail "name_to_idx: unknown name should return non-zero, got: $UNK_OUT"
fi

# ============================================================================
# CASE 5: resume_from — phases_run_all 6 starts at Deploy Peer (idx 6)
# ============================================================================
echo ""
echo "--- resume_from ---"
_mk_stubs
CALLLOG="$(mktemp)"
(
    set +eu
    phases_run_all 6 >/dev/null 2>&1
)
FIRST_CALLED="$(head -1 "$CALLLOG" 2>/dev/null || echo "")"
LINE_COUNT="$(grep -c . "$CALLLOG" 2>/dev/null || echo 0)"

[[ "$FIRST_CALLED" == "Deploy Peer" ]] && \
    pass "resume_from: first phase called is 'Deploy Peer'" || \
    fail "resume_from: expected first='Deploy Peer', got='$FIRST_CALLED'"

[[ "$LINE_COUNT" == "5" ]] && \
    pass "resume_from: 5 phases called (Deploy Peer...Complete)" || \
    fail "resume_from: expected 5 phases called, got $LINE_COUNT"

if ! grep -q "Diagnostics" "$CALLLOG" 2>/dev/null; then
    pass "resume_from: Diagnostics NOT called (correctly skipped)"
else
    fail "resume_from: Diagnostics should have been skipped"
fi
rm -f "$CALLLOG"

# ============================================================================
# CASE 6: skip_optional — Deploy Peer (optional,master-only) is skipped
# ============================================================================
echo ""
echo "--- skip_optional ---"
_mk_stubs
CALLLOG="$(mktemp)"
(
    set +eu
    phases_run_all 0 --skip-optional >/dev/null 2>&1
)
LINE_COUNT="$(grep -c . "$CALLLOG" 2>/dev/null || echo 0)"

if ! grep -q "Deploy Peer" "$CALLLOG" 2>/dev/null; then
    pass "skip_optional: 'Deploy Peer' not called"
else
    fail "skip_optional: 'Deploy Peer' should have been skipped"
fi

grep -q "Diagnostics" "$CALLLOG" 2>/dev/null && \
    pass "skip_optional: Diagnostics still called" || \
    fail "skip_optional: Diagnostics should still run"

grep -q "Complete" "$CALLLOG" 2>/dev/null && \
    pass "skip_optional: Complete still called" || \
    fail "skip_optional: Complete should still run"

[[ "$LINE_COUNT" == "10" ]] && \
    pass "skip_optional: 10 phases called (11 minus 1 optional)" || \
    fail "skip_optional: expected 10 phases called, got $LINE_COUNT"

rm -f "$CALLLOG"

# ============================================================================
# CASE 7: dry_run — only preflight phases run; exit 0; summary printed
# ============================================================================
echo ""
echo "--- dry_run ---"
_mk_stubs
CALLLOG="$(mktemp)"
DR_OUT="${WORK}/dr.out"

# phases_run_all --dry-run calls exit 0, so must run in a subshell.
# Capture the subshell's exit code at the PARENT level (exit 0 prevents echo
# inside the subshell from running).
DR_RC=0
(
    set +eu
    phases_run_all 0 --dry-run >/dev/null 2>&1
) > "$DR_OUT" 2>&1 || DR_RC=$?

if [[ $DR_RC -eq 0 ]]; then
    pass "dry_run: exit code is 0"
else
    fail "dry_run: expected exit 0, got rc=$DR_RC"
fi

# Only Diagnostics (preflight) should appear in calllog
DR_LINE_COUNT="$(grep -c . "$CALLLOG" 2>/dev/null || echo 0)"
[[ "$DR_LINE_COUNT" == "1" ]] && \
    pass "dry_run: only 1 phase called (Diagnostics/preflight)" || \
    fail "dry_run: expected 1 phase called, got $DR_LINE_COUNT"

grep -q "Diagnostics" "$CALLLOG" 2>/dev/null && \
    pass "dry_run: Diagnostics (preflight) was called" || \
    fail "dry_run: Diagnostics should have been called"

rm -f "$CALLLOG" "$DR_OUT"

# ============================================================================
# CASE 8: nonzero_aborts — non-graceful phase returning 1 aborts the loop
# ============================================================================
echo ""
echo "--- nonzero_aborts ---"
_mk_stubs
# Override Docker to fail
phase_docker() { echo "Docker" >> "$CALLLOG"; return 1; }
CALLLOG="$(mktemp)"
NA_OUT="${WORK}/na.out"

(
    set +eu
    phases_run_all 0 >/dev/null 2>&1
    echo "EXIT=$?"
) > "$NA_OUT" 2>&1

if grep -q "EXIT=[1-9]" "$NA_OUT"; then
    pass "nonzero_aborts: phases_run_all returned non-zero when Docker failed"
else
    fail "nonzero_aborts: expected non-zero exit, got: $(cat "$NA_OUT")"
fi

# Configuration (after Docker) must NOT have been called
if ! grep -q "Configuration" "$CALLLOG" 2>/dev/null; then
    pass "nonzero_aborts: Configuration not called (loop aborted at Docker)"
else
    fail "nonzero_aborts: Configuration should not have been called after Docker failed"
fi

rm -f "$CALLLOG" "$NA_OUT"

# ============================================================================
# CASE 9: graceful_no_abort — graceful phase (Models) returning 1 continues
# ============================================================================
echo ""
echo "--- graceful_no_abort ---"
_mk_stubs
# Override Models to fail
phase_models_graceful() { echo "Models" >> "$CALLLOG"; return 1; }
CALLLOG="$(mktemp)"
GR_OUT="${WORK}/gr.out"

(
    set +eu
    phases_run_all 0 >/dev/null 2>&1
    echo "EXIT=$?"
) > "$GR_OUT" 2>&1

if grep -q "EXIT=0" "$GR_OUT"; then
    pass "graceful_no_abort: phases_run_all returned 0 despite Models failure"
else
    fail "graceful_no_abort: expected EXIT=0, got: $(cat "$GR_OUT")"
fi

grep -q "Backups" "$CALLLOG" 2>/dev/null && \
    pass "graceful_no_abort: Backups called after graceful Models failure" || \
    fail "graceful_no_abort: Backups should have been called"

grep -q "Complete" "$CALLLOG" 2>/dev/null && \
    pass "graceful_no_abort: Complete called after graceful Models failure" || \
    fail "graceful_no_abort: Complete should have been called"

rm -f "$CALLLOG" "$GR_OUT"

# ============================================================================
# CASE 10: jsonl_emit — .install-phases.jsonl produced, valid JSON, 11 lines
# ============================================================================
echo ""
echo "--- jsonl_emit ---"
_mk_stubs
CALLLOG="$(mktemp)"

# Fresh run (start_idx=0) truncates jsonl
: > "${INSTALL_DIR}/.install-phases.jsonl"
(
    set +eu
    phases_run_all 0 >/dev/null 2>&1
)

JSONL="${INSTALL_DIR}/.install-phases.jsonl"

if [[ -s "$JSONL" ]]; then
    pass "jsonl_emit: .install-phases.jsonl exists and is non-empty"
else
    fail "jsonl_emit: .install-phases.jsonl missing or empty"
fi

JSONL_LINES="$(grep -c . "$JSONL" 2>/dev/null || echo 0)"
[[ "$JSONL_LINES" == "11" ]] && \
    pass "jsonl_emit: 11 lines in jsonl (one per phase)" || \
    fail "jsonl_emit: expected 11 lines, got $JSONL_LINES"

# Validate every line parses as JSON
if python3 -c '
import sys, json
lines = open(sys.argv[1]).readlines()
for i, line in enumerate(lines):
    try:
        obj = json.loads(line)
        required = {"n","name","status","started","ended","duration_s"}
        missing = required - set(obj.keys())
        if missing:
            print(f"Line {i}: missing fields {missing}", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"Line {i}: parse error: {e}", file=sys.stderr)
        sys.exit(1)
' "$JSONL" 2>/dev/null; then
    pass "jsonl_emit: all lines are valid JSON with required fields"
else
    fail "jsonl_emit: some lines failed JSON validation"
fi

# Verify Deploy Peer appears in jsonl
if python3 -c '
import sys, json
names = [json.loads(l)["name"] for l in open(sys.argv[1])]
assert "Deploy Peer" in names, f"Deploy Peer not in {names}"
' "$JSONL" 2>/dev/null; then
    pass "jsonl_emit: 'Deploy Peer' present in jsonl"
else
    fail "jsonl_emit: 'Deploy Peer' not found in jsonl"
fi

# Truncation: second fresh run (start_idx=0) should still produce 11 lines
(
    set +eu
    phases_run_all 0 >/dev/null 2>&1
)
JSONL_LINES2="$(grep -c . "$JSONL" 2>/dev/null || echo 0)"
[[ "$JSONL_LINES2" == "11" ]] && \
    pass "jsonl_emit: second fresh run truncates — still 11 lines (not 22)" || \
    fail "jsonl_emit: expected 11 lines after second run, got $JSONL_LINES2"

# Resume append: fresh run (11 lines) + resume from idx 6 (5 more) = 16 lines
: > "$JSONL"
(
    set +eu
    phases_run_all 0 >/dev/null 2>&1
)
(
    set +eu
    phases_run_all 6 >/dev/null 2>&1
)
JSONL_LINES3="$(grep -c . "$JSONL" 2>/dev/null || echo 0)"
[[ "$JSONL_LINES3" == "16" ]] && \
    pass "jsonl_emit: resume append — 11 + 5 = 16 lines" || \
    fail "jsonl_emit: expected 16 lines after resume append, got $JSONL_LINES3"

rm -f "$CALLLOG"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
