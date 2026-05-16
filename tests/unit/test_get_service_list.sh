#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_get_service_list.sh
# Regression for HEALTH-02A — MinIO must appear in get_service_list when
# either ENABLE_MINIO=true, ENABLE_RAGFLOW=true, or VECTOR_STORE=milvus.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/health.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/docker"

pass=0; fail=0

_write_env() {
    : > "${TMP}/docker/.env"
    for kv in "$@"; do echo "$kv" >> "${TMP}/docker/.env"; done
}

_run_get() {
    INSTALL_DIR="$TMP" get_service_list
}

_assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ " ${haystack} " == *" ${needle} "* ]]; then
        pass=$((pass + 1))
        echo "  [PASS] ${label}: '${needle}' in list"
    else
        fail=$((fail + 1))
        echo "  [FAIL] ${label}: '${needle}' NOT in list"
        echo "         actual: ${haystack}"
    fi
}

_assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ " ${haystack} " == *" ${needle} "* ]]; then
        fail=$((fail + 1))
        echo "  [FAIL] ${label}: '${needle}' UNEXPECTEDLY in list"
        echo "         actual: ${haystack}"
    else
        pass=$((pass + 1))
        echo "  [PASS] ${label}: '${needle}' correctly absent"
    fi
}

echo "## test_get_service_list"
echo ""

# ----------------------------------------------------------------------------
# TC1: ENABLE_MINIO=true → minio in list
# ----------------------------------------------------------------------------
echo "--- TC1: explicit ENABLE_MINIO=true ---"
_write_env "ENABLE_MINIO=true"
out="$(_run_get)"
_assert_contains "TC1" "minio" "$out"

# ----------------------------------------------------------------------------
# TC2: ENABLE_RAGFLOW=true, ENABLE_MINIO=false → minio implied
# ----------------------------------------------------------------------------
echo ""
echo "--- TC2: ENABLE_RAGFLOW=true implies minio ---"
_write_env "ENABLE_RAGFLOW=true" "ENABLE_MINIO=false"
out="$(_run_get)"
_assert_contains "TC2" "minio" "$out"
_assert_contains "TC2 ragflow chain" "ragflow" "$out"

# ----------------------------------------------------------------------------
# TC3: VECTOR_STORE=milvus → minio + milvus + milvus-etcd
# ----------------------------------------------------------------------------
echo ""
echo "--- TC3: VECTOR_STORE=milvus → minio + milvus + milvus-etcd ---"
_write_env "VECTOR_STORE=milvus"
out="$(_run_get)"
_assert_contains "TC3 minio" "minio" "$out"
_assert_contains "TC3 milvus" "milvus" "$out"
_assert_contains "TC3 milvus-etcd" "milvus-etcd" "$out"

# ----------------------------------------------------------------------------
# TC4: all-false → no minio (default state, no implicit pulls)
# ----------------------------------------------------------------------------
echo ""
echo "--- TC4: all-false → no minio ---"
_write_env "ENABLE_MINIO=false" "ENABLE_RAGFLOW=false" "VECTOR_STORE=weaviate"
out="$(_run_get)"
_assert_not_contains "TC4" "minio" "$out"
_assert_contains "TC4 weaviate default" "weaviate" "$out"

# ----------------------------------------------------------------------------
# TC5: ENABLE_MINIO=true + VECTOR_STORE=milvus → minio listed once
# ----------------------------------------------------------------------------
echo ""
echo "--- TC5: minio listed once even when multiple triggers active ---"
_write_env "ENABLE_MINIO=true" "VECTOR_STORE=milvus"
out="$(_run_get)"
minio_count=$(echo "$out" | tr ' ' '\n' | grep -c '^minio$' || true)
if [[ "$minio_count" -eq 1 ]]; then
    pass=$((pass + 1))
    echo "  [PASS] TC5: minio appears exactly once"
else
    fail=$((fail + 1))
    echo "  [FAIL] TC5: minio appeared ${minio_count} times (expected 1)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
