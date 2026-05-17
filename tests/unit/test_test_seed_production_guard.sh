#!/usr/bin/env bash
# tests/unit/test_test_seed_production_guard.sh
# T-13-01-RNG-PROD-LEAK mitigation acceptance: AGMIND_TEST_SEED set without
# AGMIND_ALLOW_TEST_SEED=true MUST refuse to source lib/common.sh.
# shellcheck disable=SC1091
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail=0

echo "== Test 1: refused without AGMIND_ALLOW_TEST_SEED=true =="
# env -u AGMIND_ALLOW_TEST_SEED so this test still works when invoked under
# outer opt-in (e.g., from run_all.sh opt-in collateral run).
out="$(env -u AGMIND_ALLOW_TEST_SEED AGMIND_TEST_SEED='x' bash -c 'source lib/common.sh; echo SHOULD_NOT_REACH' 2>&1)" || true
if echo "$out" | grep -q 'AGMIND_TEST_SEED is set'; then
    echo "  ok: refuse message printed"
else
    echo "  FAIL: refuse message missing. Output was:"
    echo "$out"
    fail=1
fi
if echo "$out" | grep -q SHOULD_NOT_REACH; then
    echo "  FAIL: source proceeded past guard"
    fail=1
else
    echo "  ok: source aborted before SHOULD_NOT_REACH"
fi

echo "== Test 2: allowed when AGMIND_ALLOW_TEST_SEED=true =="
out="$(AGMIND_TEST_SEED='x' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; echo ALLOWED' 2>&1)" || true
if echo "$out" | grep -q ALLOWED; then
    echo "  ok: source proceeded under opt-in"
else
    echo "  FAIL: opt-in path blocked. Output:"
    echo "$out"
    fail=1
fi

echo "== Test 3: unset AGMIND_TEST_SEED → no refuse (production normal) =="
out="$(env -u AGMIND_TEST_SEED -u AGMIND_ALLOW_TEST_SEED bash -c 'source lib/common.sh; echo NORMAL' 2>&1)" || true
if echo "$out" | grep -q NORMAL; then
    echo "  ok: unset seed → normal source"
else
    echo "  FAIL: unset seed blocked source. Output:"
    echo "$out"
    fail=1
fi

echo ""
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
