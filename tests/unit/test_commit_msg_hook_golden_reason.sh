#!/usr/bin/env bash
# tests/unit/test_commit_msg_hook_golden_reason.sh
# Phase 13 D-15 / TEST-07 acceptance: commit-msg hook behavior contract.
#
# Verifies tests/golden/_commit_msg_guard.sh enforces a
# `golden-accept-reason: <text>` trailer (≥10 graphic chars) when staged diff
# touches tests/golden/expected/**.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to $REPO_ROOT" >&2; exit 1; }

GUARD="tests/golden/_commit_msg_guard.sh"
[[ -x "$GUARD" ]] || { echo "FAIL: $GUARD missing or not executable"; exit 1; }

fail=0

_test() {
    local name="$1" staged="$2" msg="$3" expected_rc="$4"
    local msgfile
    msgfile="$(mktemp)"
    printf '%s\n' "$msg" > "$msgfile"
    local rc=0
    GOLDEN_GUARD_STAGED_PATHS="$staged" bash "$GUARD" "$msgfile" >/dev/null 2>&1 || rc=$?
    rm -f "$msgfile"
    if [[ "$rc" == "$expected_rc" ]]; then
        echo "  ok: $name (rc=$rc)"
    else
        echo "  FAIL: $name expected rc=$expected_rc, got $rc"
        fail=1
    fi
}

echo "== Case 1: no expected/ touch + no trailer → pass =="
_test "lib/* edit no trailer" "lib/common.sh" "fix: typo in log_error" 0

echo "== Case 2: expected/ touch + no trailer → fail =="
_test "expected touch no trailer" "tests/golden/expected/minimal_lan/.env.rendered" "feat: snapshot drift" 1

echo "== Case 3: expected/ touch + valid trailer (long) → pass =="
_test "expected touch valid trailer" "tests/golden/expected/minimal_lan/.env.rendered" "$(printf 'feat: snapshot drift\n\ngolden-accept-reason: postgres bump 17.2 to 17.3 verified')" 0

echo "== Case 4: expected/ touch + short trailer (3 chars 'ok!') → fail =="
_test "trailer 3 chars" "tests/golden/expected/x" "$(printf 'feat\n\ngolden-accept-reason: ok!')" 1

echo "== Case 5: expected/ touch + empty trailer → fail =="
_test "empty trailer" "tests/golden/expected/x" "$(printf 'feat\n\ngolden-accept-reason: ')" 1

echo "== Case 6: expected/ touch + whitespace-only trailer → fail =="
_test "whitespace trailer" "tests/golden/expected/x" "$(printf 'feat\n\ngolden-accept-reason:    ')" 1

echo "== Case 7: expected/ touch + exactly-10-chars trailer → pass (boundary) =="
# exactly 10 chars boundary — proves regex `[[:graph:]].{9,}` matches ≥10 (1 + 9)
_test "trailer exactly 10" "tests/golden/expected/x" "$(printf 'feat\n\ngolden-accept-reason: 1234567890')" 0

echo "== Case 8: missing msg file → fail (rc=2) =="
rc=0
bash "$GUARD" /nonexistent/path >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
    echo "  ok: missing msg file rejected (rc=2)"
else
    echo "  FAIL: expected rc=2, got $rc"
    fail=1
fi

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: all 8 cases of commit-msg hook contract verified"
    exit 0
else
    echo "FAIL: at least one case failed"
    exit 1
fi
