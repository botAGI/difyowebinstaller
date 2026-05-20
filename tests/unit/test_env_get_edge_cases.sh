#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_env_get_edge_cases.sh
# ENV-04: edge cases для _env_get / _env_get_raw из lib/common.sh.
# Покрывает 9 случаев — 7 ENV-04 минимум (quoted, multiline, comment-in-value,
# $-escape, empty, no-trailing-newline, trailing-comment) + 2 бонусных
# (key-not-found, file-unreadable) + 10-я ассертация side-effect freedom.
#
# Hermetic: все fixtures через mktemp -d + trap cleanup. Никаких хост-paths.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

_assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass=$((pass + 1))
        echo "  [PASS] ${name}"
    else
        fail=$((fail + 1))
        echo "  [FAIL] ${name}"
        echo "         expected: $(printf '%q' "$expected")"
        echo "         actual:   $(printf '%q' "$actual")"
    fi
}

_assert_exit() {
    local name="$1" expected_rc="$2"; shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq "$expected_rc" ]]; then
        pass=$((pass + 1))
        echo "  [PASS] ${name} (exit=$rc)"
    else
        fail=$((fail + 1))
        echo "  [FAIL] ${name}: expected exit=$expected_rc, got exit=$rc"
    fi
}

echo "## test_env_get_edge_cases"
echo ""

# ----------------------------------------------------------------------------
# Case 1: Quoted value with spaces
# ----------------------------------------------------------------------------
echo "Case 1: KEY=\"value with spaces\""
f1="${TMPDIR}/case1.env"
printf 'KEY="value with spaces"\n' > "$f1"
_assert_eq "case1 _env_get strips quotes" "value with spaces" "$(_env_get KEY "$f1")"
_assert_eq "case1 _env_get_raw keeps quotes" '"value with spaces"' "$(_env_get_raw KEY "$f1")"
echo ""

# ----------------------------------------------------------------------------
# Case 2: Multiline value
# ----------------------------------------------------------------------------
echo "Case 2: KEY=\"line1\\nline2\" (multiline)"
f2="${TMPDIR}/case2.env"
printf 'KEY="line1\nline2"\n' > "$f2"
_assert_eq "case2 _env_get joins multiline" $'line1\nline2' "$(_env_get KEY "$f2")"
_assert_eq "case2 _env_get_raw first line only" '"line1' "$(_env_get_raw KEY "$f2")"
echo ""

# ----------------------------------------------------------------------------
# Case 3: Comment-in-value (no space before #)
# ----------------------------------------------------------------------------
echo "Case 3: KEY=value#notcomment"
f3="${TMPDIR}/case3.env"
printf 'KEY=value#notcomment\n' > "$f3"
_assert_eq "case3 _env_get keeps #notcomment" "value#notcomment" "$(_env_get KEY "$f3")"
_assert_eq "case3 _env_get_raw keeps #notcomment" "value#notcomment" "$(_env_get_raw KEY "$f3")"
echo ""

# ----------------------------------------------------------------------------
# Case 4: $-expansion (THE secret-safety proof)
# ----------------------------------------------------------------------------
echo "Case 4: KEY=foo\$bar (proves _env_get_raw mandatory for secrets)"
f4="${TMPDIR}/case4.env"
printf 'KEY=foo$bar\n' > "$f4"
_assert_eq "case4 _env_get eats \$bar (UNSAFE for secrets)" "foo" "$(_env_get KEY "$f4")"
_assert_eq "case4 _env_get_raw preserves \$bar (SAFE for secrets)" 'foo$bar' "$(_env_get_raw KEY "$f4")"
echo ""

# ----------------------------------------------------------------------------
# Case 5: Empty value
# ----------------------------------------------------------------------------
echo "Case 5: KEY= (empty)"
f5="${TMPDIR}/case5.env"
printf 'KEY=\n' > "$f5"
_assert_eq "case5 _env_get empty" "" "$(_env_get KEY "$f5")"
_assert_eq "case5 _env_get_raw empty" "" "$(_env_get_raw KEY "$f5")"
_assert_exit "case5 _env_get exit=0 on key=empty" 0 _env_get KEY "$f5"
_assert_exit "case5 _env_get_raw exit=0 on key=empty" 0 _env_get_raw KEY "$f5"
echo ""

# ----------------------------------------------------------------------------
# Case 6: No trailing newline on last line
# ----------------------------------------------------------------------------
echo "Case 6: KEY=novendnl (no final LF)"
f6="${TMPDIR}/case6.env"
printf 'KEY=novendnl' > "$f6"
_assert_eq "case6 _env_get reads w/o trailing LF" "novendnl" "$(_env_get KEY "$f6")"
_assert_eq "case6 _env_get_raw reads w/o trailing LF" "novendnl" "$(_env_get_raw KEY "$f6")"
echo ""

# ----------------------------------------------------------------------------
# Case 7: Trailing # comment after whitespace
# ----------------------------------------------------------------------------
echo "Case 7: KEY=value  # trailing"
f7="${TMPDIR}/case7.env"
printf 'KEY=value  # trailing\n' > "$f7"
_assert_eq "case7 _env_get strips trailing comment" "value" "$(_env_get KEY "$f7")"
_assert_eq "case7 _env_get_raw keeps trailing comment" "value  # trailing" "$(_env_get_raw KEY "$f7")"
echo ""

# ----------------------------------------------------------------------------
# Case 8 (bonus): Key not found — distinguishable exit codes
# ----------------------------------------------------------------------------
echo "Case 8 (bonus): KEY missing in file with OTHER=value"
f8="${TMPDIR}/case8.env"
printf 'OTHER=value\n' > "$f8"
_assert_eq "case8 _env_get empty stdout for missing key" "" "$(_env_get KEY "$f8")"
_assert_exit "case8 _env_get exit=0 (no distinction missing vs empty)" 0 _env_get KEY "$f8"
_assert_exit "case8 _env_get_raw exit=1 (distinguishes missing key)" 1 _env_get_raw KEY "$f8"
echo ""

# ----------------------------------------------------------------------------
# Case 9 (bonus): File unreadable / missing
# ----------------------------------------------------------------------------
echo "Case 9 (bonus): file missing"
f9="${TMPDIR}/nonexistent.env"
_assert_exit "case9 _env_get exit=1 on missing file" 1 _env_get KEY "$f9"
_assert_exit "case9 _env_get_raw exit=1 on missing file" 1 _env_get_raw KEY "$f9"
echo ""

# ----------------------------------------------------------------------------
# Case 10 (side-effect freedom): _env_get must NOT leak env vars to caller
# Critical: subshell discipline. Without it _env_get(KEY) sets $KEY globally.
# ----------------------------------------------------------------------------
echo "Case 10: side-effect freedom (_env_get must not pollute caller env)"
f10="${TMPDIR}/case10.env"
printf 'LEAK_TEST_VAR=leaked\n' > "$f10"
unset LEAK_TEST_VAR
_env_get LEAK_TEST_VAR "$f10" >/dev/null
if [[ -z "${LEAK_TEST_VAR+x}" ]]; then
    pass=$((pass + 1))
    echo "  [PASS] _env_get LEAK_TEST_VAR did NOT pollute caller env"
else
    fail=$((fail + 1))
    echo "  [FAIL] _env_get leaked LEAK_TEST_VAR=${LEAK_TEST_VAR} to caller (subshell discipline broken)"
fi
echo ""

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
