#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_resolve_active_services.sh
#
# Plan 14-02 / RESOLVER-04 contract — ≥10 assertions covering the matrix:
#   profile combos (VECTOR_STORE = weaviate / qdrant / milvus)
#   provider overrides (LLM_PROVIDER, EMBED_PROVIDER, RERANKER_PROVIDER)
#   peer-on/off (LLM_ON_PEER=true removes local vllm)
#   monitoring toggle (MONITORING_MODE local vs none)
#   ENABLE_* flags (RERANKER, RAGFLOW)
#   cache behaviour (hit, mtime invalidation)
#   backward-compat alias (get_service_list ≡ resolve_active_services)
#   graceful degradation (missing env file)
#
# Hermetic — uses mktemp -d for INSTALL_DIR; never reads /opt/agmind.
# rc=77 SKIP if Plan 14-01 deliverables (lib/health.sh resolver, service-map
# cache vars) are missing.
#
# Exit: 0 = all pass, 1 = ≥1 fail.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Plan 14-01 prerequisite check — rc=77 SKIP convention
if [[ ! -f "${REPO_ROOT}/lib/health.sh" ]] \
   || [[ ! -f "${REPO_ROOT}/lib/service-map.sh" ]] \
   || ! grep -q "^resolve_active_services()" "${REPO_ROOT}/lib/health.sh" 2>/dev/null \
   || ! grep -q "_AGMIND_SVC_CACHE_KEY" "${REPO_ROOT}/lib/service-map.sh" 2>/dev/null; then
    echo "SKIP: Plan 14-01 deliverables missing (resolve_active_services / _AGMIND_SVC_CACHE_*)"
    exit 77
fi

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/service-map.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/health.sh"
set +e

# ----------------------------------------------------------------------------
# Test fixtures + helpers
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/docker"

export INSTALL_DIR="$TMP"

FAILED=0
PASS_COUNT=0
FAIL_COUNT=0

# setup_env KEY=VAL [KEY=VAL ...] — writes a fresh .env and resets the cache.
# Cache reset is critical: previous TC's cache key might still match new file
# if mtime resolution rounds to the same second.
#
# Last-key-wins semantics: if the same KEY appears twice in the args list
# (e.g. baseline says MONITORING_MODE=none and the TC says MONITORING_MODE=local),
# only the LAST occurrence is written. This dodges Pitfall 6 (legacy
# `grep|cut` reads in _resolve_active_services_uncached return concatenated
# values for duplicate keys — Plans 14-03..06 will migrate them to _env_get).
# By the time those bulk migrations land, this helper can keep both lines if
# the test wants to exercise duplicate-key semantics directly.
setup_env() {
    : > "${TMP}/docker/.env"
    declare -A _seen=()
    local -a _kv_ordered=()
    local kv key
    # Iterate in reverse, last-key-wins.
    for ((i = $#; i >= 1; i--)); do
        kv="${!i}"
        key="${kv%%=*}"
        if [[ -z "${_seen[$key]:-}" ]]; then
            _seen[$key]=1
            _kv_ordered=("$kv" "${_kv_ordered[@]}")
        fi
    done
    for kv in "${_kv_ordered[@]}"; do
        printf '%s\n' "$kv" >> "${TMP}/docker/.env"
    done
    # Reset cache between TCs (we test cache semantics in TC-11/12 explicitly).
    _AGMIND_SVC_CACHE_KEY=""
    _AGMIND_SVC_CACHE_VAL=""
}

_assert_contains() {
    local tc="$1" needle="$2" haystack="$3"
    if [[ " ${haystack} " == *" ${needle} "* ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  [PASS] ${tc}: contains '${needle}'"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED=1
        echo "  [FAIL] ${tc}: missing '${needle}'"
        echo "         got: ${haystack}"
    fi
}

_assert_not_contains() {
    local tc="$1" needle="$2" haystack="$3"
    if [[ " ${haystack} " == *" ${needle} "* ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED=1
        echo "  [FAIL] ${tc}: unexpectedly contains '${needle}'"
        echo "         got: ${haystack}"
    else
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  [PASS] ${tc}: correctly absent '${needle}'"
    fi
}

_assert_equal() {
    local tc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  [PASS] ${tc}: values equal"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED=1
        echo "  [FAIL] ${tc}: expected='${expected}' actual='${actual}'"
    fi
}

# Minimal-LAN baseline env knobs (used as the seed for most TCs).
_BASELINE_ENV=(
    VECTOR_STORE=weaviate
    LLM_PROVIDER=vllm
    EMBED_PROVIDER=tei
    LLM_ON_PEER=false
    ENABLE_RERANKER=false
    RERANKER_PROVIDER=tei
    MONITORING_MODE=none
    ETL_TYPE=dify
    ENABLE_LITELLM=false
    ENABLE_NOTEBOOK=false
    ENABLE_DBGPT=false
    ENABLE_OPENWEBUI=false
    ENABLE_RAGFLOW=false
    ENABLE_MINIO=false
    ENABLE_SEARXNG=false
    ENABLE_CRAWL4AI=false
    ENABLE_N8N=false
)

echo "## test_resolve_active_services (RESOLVER-04 contract)"
echo ""

# ----------------------------------------------------------------------------
# TC-01 — minimal LAN profile (weaviate + vllm + tei, all toggles off)
# ----------------------------------------------------------------------------
echo "--- TC-01: minimal LAN profile ---"
tc_01_minimal_lan() {
    setup_env "${_BASELINE_ENV[@]}"
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-01" "db" "$out"
    _assert_contains "TC-01" "weaviate" "$out"
    _assert_contains "TC-01" "vllm" "$out"
    _assert_contains "TC-01" "tei" "$out"
    _assert_not_contains "TC-01" "qdrant" "$out"
    _assert_not_contains "TC-01" "milvus" "$out"
    _assert_not_contains "TC-01" "ollama" "$out"
    _assert_not_contains "TC-01" "prometheus" "$out"
    _assert_not_contains "TC-01" "ragflow" "$out"
}
tc_01_minimal_lan
echo ""

# ----------------------------------------------------------------------------
# TC-02 — VECTOR_STORE=qdrant
# ----------------------------------------------------------------------------
echo "--- TC-02: VECTOR_STORE=qdrant ---"
tc_02_qdrant() {
    setup_env "${_BASELINE_ENV[@]}" VECTOR_STORE=qdrant
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-02" "qdrant" "$out"
    _assert_not_contains "TC-02" "weaviate" "$out"
    _assert_not_contains "TC-02" "milvus" "$out"
    _assert_not_contains "TC-02" "milvus-etcd" "$out"
}
tc_02_qdrant
echo ""

# ----------------------------------------------------------------------------
# TC-03 — VECTOR_STORE=milvus (pulls milvus-etcd + minio)
# ----------------------------------------------------------------------------
echo "--- TC-03: VECTOR_STORE=milvus ---"
tc_03_milvus() {
    setup_env "${_BASELINE_ENV[@]}" VECTOR_STORE=milvus
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-03" "milvus" "$out"
    _assert_contains "TC-03" "milvus-etcd" "$out"
    _assert_contains "TC-03 minio implied" "minio" "$out"
    _assert_not_contains "TC-03" "weaviate" "$out"
    _assert_not_contains "TC-03" "qdrant" "$out"
}
tc_03_milvus
echo ""

# ----------------------------------------------------------------------------
# TC-04 — LLM_PROVIDER=ollama → ollama added, no vllm
# ----------------------------------------------------------------------------
echo "--- TC-04: LLM_PROVIDER=ollama ---"
tc_04_ollama() {
    setup_env "${_BASELINE_ENV[@]}" LLM_PROVIDER=ollama
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-04" "ollama" "$out"
    _assert_contains "TC-04" "tei" "$out"
    _assert_not_contains "TC-04" "vllm" "$out"
}
tc_04_ollama
echo ""

# ----------------------------------------------------------------------------
# TC-05 — EMBED_PROVIDER=vllm-embed (replaces tei)
# ----------------------------------------------------------------------------
echo "--- TC-05: EMBED_PROVIDER=vllm-embed ---"
tc_05_vllm_embed() {
    setup_env "${_BASELINE_ENV[@]}" EMBED_PROVIDER=vllm-embed
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-05" "vllm-embed" "$out"
    _assert_not_contains "TC-05" "tei" "$out"
}
tc_05_vllm_embed
echo ""

# ----------------------------------------------------------------------------
# TC-06 — LLM_ON_PEER=true → vllm NOT in local list (peer hosts it)
# Matches memory project_llm_on_peer_refactor + lib/health.sh:90 guard.
# ----------------------------------------------------------------------------
echo "--- TC-06: LLM_ON_PEER=true removes local vllm ---"
tc_06_peer_on() {
    setup_env "${_BASELINE_ENV[@]}" LLM_PROVIDER=vllm LLM_ON_PEER=true
    local out; out="$(resolve_active_services)"
    _assert_not_contains "TC-06" "vllm" "$out"
    # vllm-embed still local (embed not on peer), tei still local
    _assert_contains "TC-06 (tei stays local)" "tei" "$out"
}
tc_06_peer_on
echo ""

# ----------------------------------------------------------------------------
# TC-07 — ENABLE_RERANKER=true + RERANKER_PROVIDER=tei → tei-rerank
# ----------------------------------------------------------------------------
echo "--- TC-07: ENABLE_RERANKER=true + RERANKER_PROVIDER=tei ---"
tc_07_reranker_tei() {
    setup_env "${_BASELINE_ENV[@]}" ENABLE_RERANKER=true RERANKER_PROVIDER=tei
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-07" "tei-rerank" "$out"
    _assert_not_contains "TC-07" "vllm-rerank" "$out"
}
tc_07_reranker_tei
echo ""

# ----------------------------------------------------------------------------
# TC-08 — ENABLE_RERANKER=true + RERANKER_PROVIDER=vllm-rerank
# ----------------------------------------------------------------------------
echo "--- TC-08: ENABLE_RERANKER=true + RERANKER_PROVIDER=vllm-rerank ---"
tc_08_reranker_vllm() {
    setup_env "${_BASELINE_ENV[@]}" ENABLE_RERANKER=true RERANKER_PROVIDER=vllm-rerank
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-08" "vllm-rerank" "$out"
    _assert_not_contains "TC-08" "tei-rerank" "$out"
}
tc_08_reranker_vllm
echo ""

# ----------------------------------------------------------------------------
# TC-09 — MONITORING_MODE=local pulls 8-svc monitoring stack
# ----------------------------------------------------------------------------
echo "--- TC-09: MONITORING_MODE=local ---"
tc_09_monitoring_local() {
    setup_env "${_BASELINE_ENV[@]}" MONITORING_MODE=local
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-09" "prometheus" "$out"
    _assert_contains "TC-09" "alertmanager" "$out"
    _assert_contains "TC-09" "grafana" "$out"
    _assert_contains "TC-09" "loki" "$out"
    _assert_contains "TC-09" "alloy" "$out"
}
tc_09_monitoring_local
echo ""

# ----------------------------------------------------------------------------
# TC-10 — ENABLE_RAGFLOW=true → ragflow trio + minio implied
# ----------------------------------------------------------------------------
echo "--- TC-10: ENABLE_RAGFLOW=true ---"
tc_10_ragflow() {
    setup_env "${_BASELINE_ENV[@]}" ENABLE_RAGFLOW=true
    local out; out="$(resolve_active_services)"
    _assert_contains "TC-10" "ragflow" "$out"
    _assert_contains "TC-10" "ragflow_mysql" "$out"
    _assert_contains "TC-10" "ragflow_es01" "$out"
    _assert_contains "TC-10 minio implied" "minio" "$out"
}
tc_10_ragflow
echo ""

# ----------------------------------------------------------------------------
# TC-11 — Cache hit (within single subshell) returns byte-identical bytes.
# Subshell caveat (Pitfall 4): cache vars set inside $() don't escape;
# we measure cache reuse strictly within one subshell scope.
# ----------------------------------------------------------------------------
echo "--- TC-11: cache hit in single subshell ---"
tc_11_cache_hit() {
    setup_env "${_BASELINE_ENV[@]}"
    local status
    status="$(
        resolve_active_services >/dev/null
        local first="${_AGMIND_SVC_CACHE_VAL:-}"
        local k1="${_AGMIND_SVC_CACHE_KEY:-}"
        [[ -z "$first" ]] && { echo NOPOP; exit; }
        resolve_active_services >/dev/null
        local second="${_AGMIND_SVC_CACHE_VAL:-}"
        local k2="${_AGMIND_SVC_CACHE_KEY:-}"
        if [[ "$first" == "$second" && "$k1" == "$k2" && -n "$k1" ]]; then
            echo CACHED
        else
            echo "DRIFT first=[$first] second=[$second] k1=[$k1] k2=[$k2]"
        fi
    )"
    _assert_equal "TC-11" "CACHED" "$status"
}
tc_11_cache_hit
echo ""

# ----------------------------------------------------------------------------
# TC-12 — mtime bump invalidates cache key.
# (Output may stay identical for content-equal env — we assert KEY change.)
# Bash subshell caveat: read cache key inside same subshell where we
# re-invoke resolve_active_services after touch.
# ----------------------------------------------------------------------------
echo "--- TC-12: mtime bump invalidates cache key ---"
tc_12_mtime_invalidation() {
    setup_env "${_BASELINE_ENV[@]}"
    local result
    result="$(
        resolve_active_services >/dev/null
        local k1="${_AGMIND_SVC_CACHE_KEY:-}"
        sleep 1
        touch -m "${TMP}/docker/.env"
        resolve_active_services >/dev/null
        local k2="${_AGMIND_SVC_CACHE_KEY:-}"
        if [[ -n "$k1" && -n "$k2" && "$k1" != "$k2" ]]; then
            echo INVALIDATED
        else
            echo "STALE k1=[$k1] k2=[$k2]"
        fi
    )"
    _assert_equal "TC-12" "INVALIDATED" "$result"
}
tc_12_mtime_invalidation
echo ""

# ----------------------------------------------------------------------------
# TC-13 — get_service_list alias returns byte-identical output (RESOLVER-03).
# Pitfall 5 contract — 65+ existing tests depend on this alias staying alive.
# ----------------------------------------------------------------------------
echo "--- TC-13: get_service_list alias parity ---"
tc_13_alias_parity() {
    setup_env "${_BASELINE_ENV[@]}"
    local via_canonical via_alias
    via_canonical="$(resolve_active_services)"
    # Reset cache so the alias path takes a fresh route, not the cached one.
    _AGMIND_SVC_CACHE_KEY=""
    _AGMIND_SVC_CACHE_VAL=""
    via_alias="$(get_service_list)"
    _assert_equal "TC-13" "$via_canonical" "$via_alias"
}
tc_13_alias_parity
echo ""

# ----------------------------------------------------------------------------
# TC-14 — Missing env file → resolver does not crash.
# lib/health.sh line 66 has `if [[ -f "$env_file" ]]` guard; uncached path
# falls back to baseline services + weaviate (no toggles).
# ----------------------------------------------------------------------------
echo "--- TC-14: missing env file graceful fallback ---"
tc_14_missing_env() {
    local saved_install_dir="$INSTALL_DIR"
    local ghost; ghost="$(mktemp -d)"
    rmdir "$ghost"   # path now doesn't exist
    export INSTALL_DIR="$ghost"
    _AGMIND_SVC_CACHE_KEY=""
    _AGMIND_SVC_CACHE_VAL=""
    local out
    out="$(resolve_active_services 2>/dev/null)"
    local rc=$?
    if [[ $rc -eq 0 && -n "$out" ]]; then
        _assert_contains "TC-14 fallback baseline" "db" "$out"
        _assert_contains "TC-14 fallback baseline" "weaviate" "$out"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED=1
        echo "  [FAIL] TC-14: resolver crashed or empty output (rc=$rc)"
    fi
    export INSTALL_DIR="$saved_install_dir"
}
tc_14_missing_env
echo ""

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
TC_COUNT=$(grep -c "^tc_[0-9]*_" "${BASH_SOURCE[0]}" | head -1)
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${PASS_COUNT} assertions passed, ${FAIL_COUNT} failed across ${TC_COUNT}+ test cases"
echo "RESOLVER-04 requires ≥10 assertions — this test file has ${PASS_COUNT} PASSING assertions"
echo "═══════════════════════════════════════════════════════════"

exit "$FAILED"
