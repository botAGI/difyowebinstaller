#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_generate_random_length.sh
# Regression test for GEN-01 — generate_random must always produce exactly
# `length` characters of [a-zA-Z0-9].
#
# Spec: §3.1 GEN-01, §6.3 verification entry.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"

pass=0
fail=0

_assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  [FAIL] ${name}: expected '${expected}', got '${actual}'"
    fi
}

echo "## test_generate_random_length"
echo ""

# ----------------------------------------------------------------------------
# Test 1: exact length across 200 iterations × {1, 16, 32, 64, 128}
# (Spec asks 1000 — keeping 200 for CI speed; total = 1000 calls.)
# ----------------------------------------------------------------------------
echo "Test 1: exact-length guarantee (200 iter × 5 lengths)..."
LENGTHS=(1 16 32 64 128)
length_failures=0
for L in "${LENGTHS[@]}"; do
    for _ in $(seq 1 200); do
        out="$(generate_random "$L")"
        if [[ ${#out} -ne "$L" ]]; then
            length_failures=$((length_failures + 1))
            if [[ $length_failures -le 3 ]]; then
                echo "  [FAIL] length=${L}: got ${#out} chars: '${out}'"
            fi
        fi
    done
done
if [[ $length_failures -eq 0 ]]; then
    pass=$((pass + 1))
    echo "  [PASS] 1000/1000 calls produced exact length"
else
    fail=$((fail + 1))
    echo "  [FAIL] ${length_failures}/1000 calls had wrong length"
fi
echo ""

# ----------------------------------------------------------------------------
# Test 2: charset is [a-zA-Z0-9] only
# ----------------------------------------------------------------------------
echo "Test 2: charset = [a-zA-Z0-9]..."
charset_failures=0
for _ in $(seq 1 50); do
    out="$(generate_random 64)"
    if [[ ! "$out" =~ ^[a-zA-Z0-9]+$ ]]; then
        charset_failures=$((charset_failures + 1))
        [[ $charset_failures -le 3 ]] && echo "  [FAIL] non-alnum output: '${out}'"
    fi
done
if [[ $charset_failures -eq 0 ]]; then
    pass=$((pass + 1))
    echo "  [PASS] 50/50 outputs are alphanumeric only"
else
    fail=$((fail + 1))
fi
echo ""

# ----------------------------------------------------------------------------
# Test 3: distinct outputs across iterations (entropy sanity)
# ----------------------------------------------------------------------------
echo "Test 3: distinct outputs (entropy)..."
declare -A seen
distinct_failures=0
for _ in $(seq 1 100); do
    out="$(generate_random 32)"
    if [[ -n "${seen[$out]:-}" ]]; then
        distinct_failures=$((distinct_failures + 1))
    fi
    seen[$out]=1
done
if [[ $distinct_failures -eq 0 ]]; then
    pass=$((pass + 1))
    echo "  [PASS] 100/100 outputs unique"
else
    fail=$((fail + 1))
    echo "  [FAIL] ${distinct_failures}/100 duplicates"
fi
echo ""

# ----------------------------------------------------------------------------
# Test 4: invalid length rejected
# ----------------------------------------------------------------------------
echo "Test 4: invalid length returns non-zero..."
if generate_random 0 2>/dev/null; then
    fail=$((fail + 1))
    echo "  [FAIL] generate_random 0 should fail"
else
    pass=$((pass + 1))
    echo "  [PASS] generate_random 0 → non-zero exit"
fi
if generate_random abc 2>/dev/null; then
    fail=$((fail + 1))
    echo "  [FAIL] generate_random abc should fail"
else
    pass=$((pass + 1))
    echo "  [PASS] generate_random abc → non-zero exit"
fi
if generate_random -5 2>/dev/null; then
    fail=$((fail + 1))
    echo "  [FAIL] generate_random -5 should fail"
else
    pass=$((pass + 1))
    echo "  [PASS] generate_random -5 → non-zero exit"
fi
echo ""

# ----------------------------------------------------------------------------
# Test 5: default length = 32
# ----------------------------------------------------------------------------
echo "Test 5: default length is 32..."
out="$(generate_random)"
_assert_eq "default length" "32" "${#out}"
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
