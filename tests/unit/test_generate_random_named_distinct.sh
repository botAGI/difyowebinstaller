#!/usr/bin/env bash
# tests/unit/test_generate_random_named_distinct.sh
# TEST-04 acceptance: generate_random_named idempotence (A==A) + distinctness (A!=B)
# + length + production guard / no-seed CSPRNG behavior.
# shellcheck disable=SC1091
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail=0
_assert() {
    if [[ "$1" == "$2" ]]; then
        echo "  ok: $3"
    else
        echo "  FAIL: $3 (expected '$2', got '$1')"
        fail=1
    fi
}
_assert_ne() {
    if [[ "$1" != "$2" ]]; then
        echo "  ok: $3"
    else
        echo "  FAIL: $3 (expected != '$2', got equal)"
        fail=1
    fi
}

echo "== Test 1: idempotence A==A across subshells (same slug + seed) =="
A1="$(AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; generate_random_named SLUG_X 32')"
A2="$(AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; generate_random_named SLUG_X 32')"
_assert "$A1" "$A2" "A1==A2 (idempotent under same slug+seed)"
_assert "${#A1}" "32" "output length == 32 (got ${#A1})"

echo "== Test 2: distinctness A!=B (different slug under same seed) =="
B="$(AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; generate_random_named SLUG_Y 32')"
_assert_ne "$A1" "$B" "A != B (distinct slugs produce distinct output)"

echo "== Test 3: length parameter respected =="
L16="$(AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; generate_random_named SLUG_Z 16')"
_assert "${#L16}" "16" "length=16 output is 16 chars"

echo "== Test 4: no-seed CSPRNG fallback produces non-deterministic =="
# Explicit env -u so this test still works when invoked under outer
# AGMIND_TEST_SEED (e.g., from run_all.sh opt-in collateral run).
C1="$(env -u AGMIND_TEST_SEED -u AGMIND_ALLOW_TEST_SEED bash -c 'source lib/common.sh; generate_random_named SLUG_NS 32')"
C2="$(env -u AGMIND_TEST_SEED -u AGMIND_ALLOW_TEST_SEED bash -c 'source lib/common.sh; generate_random_named SLUG_NS 32')"
_assert_ne "$C1" "$C2" "C1 != C2 (CSPRNG path is non-deterministic under no seed)"
_assert "${#C1}" "32" "no-seed output length still 32"

echo "== Test 5: invalid slug rejected =="
rc=0
AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; generate_random_named "" 32' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  ok: empty slug rejected (rc=$rc)"
else
    echo "  FAIL: empty slug accepted"
    fail=1
fi

rc=0
AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; generate_random_named "1bad" 32' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  ok: slug starting with digit rejected (rc=$rc)"
else
    echo "  FAIL: digit-leading slug accepted"
    fail=1
fi

echo "== Test 6: invalid length rejected =="
rc=0
AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; generate_random_named GOOD_SLUG 0' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  ok: length 0 rejected (rc=$rc)"
else
    echo "  FAIL: length 0 accepted"
    fail=1
fi

echo "== Test 7: _now_utc fixed under seed =="
NOW="$(AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; _now_utc')"
_assert "$NOW" "2026-01-01T00:00:00Z" "_now_utc returns fixed value under seed"

echo "== Test 8: _host_name fixed under seed =="
HN="$(AGMIND_TEST_SEED='foo:13:v1' AGMIND_ALLOW_TEST_SEED=true bash -c 'source lib/common.sh; _host_name')"
_assert "$HN" "agmind-golden-host" "_host_name returns fixed value under seed"

echo ""
if [[ "$fail" -eq 0 ]]; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
