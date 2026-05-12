#!/usr/bin/env bash
# test_named_profiles.sh — RED (Wave-0) tests for Phase 9 named meta-profile expansion.
#
# Covers:
#   SC1: Wizard offers named profiles and writes DEPLOY_PROFILE + implied ENABLE_* vars.
#   SC4: build_compose_profiles backward-compat — no DEPLOY_PROFILE / DEPLOY_PROFILE=custom /
#        DEPLOY_PROFILE=lan → output IDENTICAL to pre-Phase-9 (no regression).
#
# These tests FAIL initially (RED) because:
#   • NAMED_PROFILE_EXPANSION does not exist in lib/service-map.sh yet (09-02 adds it).
#   • build_compose_profiles named-expansion block does not exist yet (09-02 extends it).
#   • _wizard_profile() does not set implied ENABLE_* vars yet (09-03 changes it).
#
# Template: tests/unit/test_build_compose_profiles.sh (same subshell + _assert_contains pattern).
# Exit: 0 = all PASS, non-zero = ≥1 FAIL, 77 = SKIP.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SERVICE_MAP_SH="${REPO_ROOT}/lib/service-map.sh"
COMPOSE_SH="${REPO_ROOT}/lib/compose.sh"
WIZARD_SH="${REPO_ROOT}/lib/wizard.sh"

if [[ ! -f "$SERVICE_MAP_SH" ]]; then
    echo "SKIP: ${SERVICE_MAP_SH} not found"
    exit 77
fi
if [[ ! -f "$COMPOSE_SH" ]]; then
    echo "SKIP: ${COMPOSE_SH} not found"
    exit 77
fi

echo "## test_named_profiles"

fail=0
pass=0

# ── Helpers ───────────────────────────────────────────────────────────────────

_assert_contains() {
    local label="$1" expected_token="$2" actual_csv="$3"
    if [[ ",${actual_csv}," == *",${expected_token},"* ]]; then
        echo "  PASS: ${label} (contains '${expected_token}')"
        pass=$((pass+1))
    else
        echo "  FAIL: ${label}"
        echo "        expected token: ${expected_token}"
        echo "        actual csv:     ${actual_csv}"
        fail=$((fail+1))
    fi
}

_assert_not_contains() {
    local label="$1" forbidden_token="$2" actual_csv="$3"
    if [[ ",${actual_csv}," != *",${forbidden_token},"* ]]; then
        echo "  PASS: ${label} (does NOT contain '${forbidden_token}')"
        pass=$((pass+1))
    else
        echo "  FAIL: ${label}"
        echo "        forbidden token: ${forbidden_token}"
        echo "        actual csv:      ${actual_csv}"
        fail=$((fail+1))
    fi
}

_assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: ${label}"
        pass=$((pass+1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        fail=$((fail+1))
    fi
}

_assert_nonempty() {
    local label="$1" val="$2"
    if [[ -n "$val" ]]; then
        echo "  PASS: ${label} (non-empty: '${val}')"
        pass=$((pass+1))
    else
        echo "  FAIL: ${label} (empty)"
        fail=$((fail+1))
    fi
}

# Runs build_compose_profiles in a clean subshell with given env setup.
# Returns the resulting COMPOSE_PROFILE_STRING.
_run_bcp() {
    local env_setup="$1"
    bash -c "
        set +e
        # Stub log_* (compose.sh expects them from common.sh)
        log_info()    { :; }
        log_warn()    { :; }
        log_error()   { :; }
        log_success() { :; }
        export -f log_info log_warn log_error log_success
        ${env_setup}
        # shellcheck disable=SC1090
        source '${SERVICE_MAP_SH}' 2>/dev/null
        # shellcheck disable=SC1090
        source '${COMPOSE_SH}' 2>/dev/null
        build_compose_profiles >/dev/null 2>&1
        echo \"\${COMPOSE_PROFILE_STRING}\"
    "
}

# ── Case 1: expansion_each_named_profile ──────────────────────────────────────
# NAMED_PROFILE_EXPANSION must be non-empty for each of the 8 named profiles.
# RED: NAMED_PROFILE_EXPANSION does not exist yet in lib/service-map.sh.
echo ""
echo "=== Case 1: expansion_each_named_profile ==="
(
    set +e
    # shellcheck disable=SC1090
    source "${SERVICE_MAP_SH}" 2>/dev/null

    # Check array exists (bash 4+: -v NAMED_PROFILE_EXPANSION tests if declared)
    if ! declare -p NAMED_PROFILE_EXPANSION >/dev/null 2>&1; then
        echo "  FAIL: NAMED_PROFILE_EXPANSION not declared in lib/service-map.sh"
        exit 1
    fi

    local_fail=0
    for name in core rag ragflow observability security agents full dev; do
        val="${NAMED_PROFILE_EXPANSION[${name}]:-}"
        if [[ -n "$val" ]]; then
            echo "  PASS: NAMED_PROFILE_EXPANSION[${name}] non-empty: '${val}'"
        else
            echo "  FAIL: NAMED_PROFILE_EXPANSION[${name}] is empty or missing"
            local_fail=$((local_fail+1))
        fi
    done

    # Spot-checks: rag contains weaviate and docling
    rag_val="${NAMED_PROFILE_EXPANSION[rag]:-}"
    [[ ",${rag_val}," == *",weaviate,"* ]] || { echo "  FAIL: rag missing weaviate"; local_fail=$((local_fail+1)); }
    [[ ",${rag_val}," == *",docling,"* ]]  || { echo "  FAIL: rag missing docling";  local_fail=$((local_fail+1)); }

    # observability contains monitoring and portainer
    obs_val="${NAMED_PROFILE_EXPANSION[observability]:-}"
    [[ ",${obs_val}," == *",monitoring,"* ]] || { echo "  FAIL: observability missing monitoring"; local_fail=$((local_fail+1)); }
    [[ ",${obs_val}," == *",portainer,"* ]]  || { echo "  FAIL: observability missing portainer"; local_fail=$((local_fail+1)); }

    # security contains authelia
    sec_val="${NAMED_PROFILE_EXPANSION[security]:-}"
    [[ ",${sec_val}," == *",authelia,"* ]] || { echo "  FAIL: security missing authelia"; local_fail=$((local_fail+1)); }

    # core contains vllm and litellm
    core_val="${NAMED_PROFILE_EXPANSION[core]:-}"
    [[ ",${core_val}," == *",vllm,"* ]]    || { echo "  FAIL: core missing vllm";    local_fail=$((local_fail+1)); }
    [[ ",${core_val}," == *",litellm,"* ]] || { echo "  FAIL: core missing litellm"; local_fail=$((local_fail+1)); }

    # XOR pairs — no named profile should contain BOTH members of a pair
    xor_fail=0
    for name in core rag ragflow observability security agents full dev; do
        v="${NAMED_PROFILE_EXPANSION[${name}]:-}"
        # weaviate XOR qdrant
        if [[ ",${v}," == *",weaviate,"* ]] && [[ ",${v}," == *",qdrant,"* ]]; then
            echo "  FAIL: ${name} contains BOTH weaviate and qdrant (XOR violation)"; xor_fail=$((xor_fail+1)); fi
        # tei XOR vllm-embed
        if [[ ",${v}," == *",tei,"* ]] && [[ ",${v}," == *",vllm-embed,"* ]]; then
            echo "  FAIL: ${name} contains BOTH tei and vllm-embed (XOR violation)"; xor_fail=$((xor_fail+1)); fi
        # reranker XOR vllm-rerank
        if [[ ",${v}," == *",reranker,"* ]] && [[ ",${v}," == *",vllm-rerank,"* ]]; then
            echo "  FAIL: ${name} contains BOTH reranker and vllm-rerank (XOR violation)"; xor_fail=$((xor_fail+1)); fi
        # vllm XOR ollama
        if [[ ",${v}," == *",vllm,"* ]] && [[ ",${v}," == *",ollama,"* ]]; then
            echo "  FAIL: ${name} contains BOTH vllm and ollama (XOR violation)"; xor_fail=$((xor_fail+1)); fi
    done
    [[ $xor_fail -eq 0 ]] && echo "  PASS: no XOR conflicts in any named profile"
    local_fail=$((local_fail + xor_fail))

    exit "$local_fail"
) && { echo "  [PASS] expansion_each_named_profile"; pass=$((pass+1)); } \
  || { echo "  [FAIL] expansion_each_named_profile"; fail=$((fail+1)); }

# ── Case 2: full_no_xor_conflict_no_milvus ────────────────────────────────────
# 'full' expansion: exactly one of each XOR pair; no milvus; no ollama.
# RED: NAMED_PROFILE_EXPANSION does not exist yet.
echo ""
echo "=== Case 2: full_no_xor_conflict_no_milvus ==="
(
    set +e
    # shellcheck disable=SC1090
    source "${SERVICE_MAP_SH}" 2>/dev/null
    if ! declare -p NAMED_PROFILE_EXPANSION >/dev/null 2>&1; then
        echo "  FAIL: NAMED_PROFILE_EXPANSION not declared"
        exit 1
    fi
    full_val="${NAMED_PROFILE_EXPANSION[full]:-}"
    if [[ -z "$full_val" ]]; then
        echo "  FAIL: NAMED_PROFILE_EXPANSION[full] is empty"
        exit 1
    fi
    local_fail=0
    # Exactly one of {weaviate, qdrant} — contains weaviate, NOT qdrant
    [[ ",${full_val}," == *",weaviate,"* ]] || { echo "  FAIL: full missing weaviate"; local_fail=$((local_fail+1)); }
    [[ ",${full_val}," != *",qdrant,"*   ]] || { echo "  FAIL: full contains qdrant (XOR: should use weaviate)"; local_fail=$((local_fail+1)); }
    # Exactly one of {tei, vllm-embed} — contains vllm-embed, NOT tei
    [[ ",${full_val}," == *",vllm-embed,"* ]] || { echo "  FAIL: full missing vllm-embed"; local_fail=$((local_fail+1)); }
    [[ ",${full_val}," != *",tei,"*        ]] || { echo "  FAIL: full contains tei (XOR: should use vllm-embed)"; local_fail=$((local_fail+1)); }
    # Exactly one of {reranker, vllm-rerank} — contains vllm-rerank, NOT reranker
    [[ ",${full_val}," == *",vllm-rerank,"* ]] || { echo "  FAIL: full missing vllm-rerank"; local_fail=$((local_fail+1)); }
    [[ ",${full_val}," != *",reranker,"*    ]] || { echo "  FAIL: full contains reranker (XOR: should use vllm-rerank)"; local_fail=$((local_fail+1)); }
    # No milvus (EXPERIMENTAL — excluded from full)
    [[ ",${full_val}," != *",milvus,"* ]] || { echo "  FAIL: full contains milvus (EXPERIMENTAL — must be excluded)"; local_fail=$((local_fail+1)); }
    # No ollama (hidden from wizard — default = vLLM)
    [[ ",${full_val}," != *",ollama,"* ]] || { echo "  FAIL: full contains ollama (hidden — must be excluded)"; local_fail=$((local_fail+1)); }
    [[ $local_fail -eq 0 ]] && echo "  PASS: full profile has no XOR conflicts, no milvus, no ollama"
    exit "$local_fail"
) && { echo "  [PASS] full_no_xor_conflict_no_milvus"; pass=$((pass+1)); } \
  || { echo "  [FAIL] full_no_xor_conflict_no_milvus"; fail=$((fail+1)); }

# ── Case 3: build_compose_profiles_named_rag ──────────────────────────────────
# DEPLOY_PROFILE=rag → result contains weaviate, docling, vllm, litellm, vllm-embed.
# RED: named-expansion block does not exist in build_compose_profiles yet.
echo ""
echo "=== Case 3: build_compose_profiles_named_rag ==="
result="$(_run_bcp 'DEPLOY_PROFILE=rag LLM_ON_PEER=false')"
_assert_contains "DEPLOY_PROFILE=rag → weaviate"    "weaviate"   "$result"
_assert_contains "DEPLOY_PROFILE=rag → docling"     "docling"    "$result"
_assert_contains "DEPLOY_PROFILE=rag → vllm"        "vllm"       "$result"
_assert_contains "DEPLOY_PROFILE=rag → litellm"     "litellm"    "$result"
_assert_contains "DEPLOY_PROFILE=rag → vllm-embed"  "vllm-embed" "$result"

# ── Case 4: build_compose_profiles_named_observability ────────────────────────
# DEPLOY_PROFILE=observability → monitoring, portainer; NOT weaviate/docling.
# RED: named-expansion block missing.
echo ""
echo "=== Case 4: build_compose_profiles_named_observability ==="
result="$(_run_bcp 'DEPLOY_PROFILE=observability')"
_assert_contains     "observability → monitoring"    "monitoring" "$result"
_assert_contains     "observability → portainer"     "portainer"  "$result"
_assert_not_contains "observability → no weaviate"   "weaviate"   "$result"
_assert_not_contains "observability → no docling"    "docling"    "$result"

# ── Case 5: build_compose_profiles_backcompat_no_deploy_profile (SC4) ─────────
# No DEPLOY_PROFILE + VECTOR_STORE=qdrant ENABLE_NOTEBOOK=true MONITORING_MODE=local
# → output IDENTICAL to pre-Phase-9 baseline.
# Baseline captured 2026-05-12 from current lib/compose.sh:
#   qdrant,monitoring,portainer,litellm,notebook
# GREEN both before and after Phase 9 (backcompat invariant — must not regress).
echo ""
echo "=== Case 5: build_compose_profiles_backcompat_no_deploy_profile (SC4) ==="
EXPECTED_BACKCOMPAT="qdrant,monitoring,portainer,litellm,notebook"
result="$(_run_bcp 'VECTOR_STORE=qdrant ENABLE_NOTEBOOK=true MONITORING_MODE=local')"
_assert_eq "SC4: no DEPLOY_PROFILE + fixed ENABLE_* set → same output as pre-Phase-9" \
    "$EXPECTED_BACKCOMPAT" "$result"
# Field-presence assertions (survive future additive changes)
_assert_contains     "SC4: qdrant present"       "qdrant"    "$result"
_assert_contains     "SC4: notebook present"     "notebook"  "$result"
_assert_contains     "SC4: monitoring present"   "monitoring" "$result"
_assert_contains     "SC4: litellm present"      "litellm"   "$result"
_assert_not_contains "SC4: no weaviate (qdrant mode)" "weaviate" "$result"
_assert_not_contains "SC4: no docling"           "docling"   "$result"
_assert_not_contains "SC4: no vllm"              "vllm"      "$result"

# ── Case 6: build_compose_profiles_backcompat_custom ──────────────────────────
# DEPLOY_PROFILE=custom → named block skipped; ENABLE_NOTEBOOK=true works via old path.
# GREEN both before and after Phase 9.
# NOTE: VECTOR_STORE defaults to weaviate even in custom mode (lib/compose.sh:23 uses
# ${VECTOR_STORE:-weaviate}). Weaviate appearing is expected pre-Phase-9 behavior.
# The test verifies that custom does NOT inject docling/vllm-embed from a named expansion.
echo ""
echo "=== Case 6: build_compose_profiles_backcompat_custom ==="
result="$(_run_bcp 'DEPLOY_PROFILE=custom ENABLE_NOTEBOOK=true')"
_assert_contains     "DEPLOY_PROFILE=custom: notebook via ENABLE_ path"          "notebook"  "$result"
_assert_not_contains "DEPLOY_PROFILE=custom: no docling (no ENABLE_DOCLING set)" "docling"   "$result"
_assert_not_contains "DEPLOY_PROFILE=custom: no vllm-embed (no EMBED_PROVIDER)"  "vllm-embed" "$result"
# weaviate IS present (default VECTOR_STORE) — verify named expansion did NOT add docling/vllm-embed
# i.e. the custom path just runs ENABLE_*-driven logic, not named-expansion logic

# ── Case 7: build_compose_profiles_backcompat_lan ─────────────────────────────
# DEPLOY_PROFILE=lan → treated as legacy/custom; named block skipped.
# ENABLE_DOCLING=true → docling via the ENABLE_* path (unchanged from pre-Phase-9).
# GREEN both before and after Phase 9.
echo ""
echo "=== Case 7: build_compose_profiles_backcompat_lan ==="
result="$(_run_bcp 'DEPLOY_PROFILE=lan ENABLE_DOCLING=true')"
_assert_contains "DEPLOY_PROFILE=lan ENABLE_DOCLING=true → docling via ENABLE_ path" "docling" "$result"

# ── Case 8: build_compose_profiles_env_override ───────────────────────────────
# DEPLOY_PROFILE=rag VECTOR_STORE=qdrant → qdrant (user override wins over rag's weaviate default).
# RED: named-expansion implied-defaults block uses := (env-override wins), but block missing.
echo ""
echo "=== Case 8: build_compose_profiles_env_override ==="
result="$(_run_bcp 'DEPLOY_PROFILE=rag VECTOR_STORE=qdrant LLM_ON_PEER=false')"
_assert_contains     "DEPLOY_PROFILE=rag VECTOR_STORE=qdrant: qdrant wins"   "qdrant"   "$result"
_assert_not_contains "DEPLOY_PROFILE=rag VECTOR_STORE=qdrant: no weaviate"  "weaviate"  "$result"

# ── Case 9: build_compose_profiles_llm_on_peer ────────────────────────────────
# DEPLOY_PROFILE=rag LLM_ON_PEER=true → no vllm (runs on peer), but weaviate/docling/vllm-embed/litellm.
# RED: named-expansion block missing.
echo ""
echo "=== Case 9: build_compose_profiles_llm_on_peer ==="
result="$(_run_bcp 'DEPLOY_PROFILE=rag LLM_ON_PEER=true PEER_IP=192.168.100.2')"
_assert_not_contains "DEPLOY_PROFILE=rag LLM_ON_PEER=true: no vllm locally" "vllm"      "$result"
_assert_contains     "DEPLOY_PROFILE=rag LLM_ON_PEER=true: weaviate present" "weaviate"  "$result"
_assert_contains     "DEPLOY_PROFILE=rag LLM_ON_PEER=true: docling present"  "docling"   "$result"
_assert_contains     "DEPLOY_PROFILE=rag LLM_ON_PEER=true: vllm-embed present" "vllm-embed" "$result"
_assert_contains     "DEPLOY_PROFILE=rag LLM_ON_PEER=true: litellm present" "litellm"   "$result"

# ── Case 10: wizard_profile_sets_env ──────────────────────────────────────────
# Simulate wizard: NON_INTERACTIVE=true DEPLOY_PROFILE=rag → _wizard_profile sets
# DEPLOY_PROFILE=rag AND implied ENABLE_DOCLING=true, VECTOR_STORE=weaviate,
# EMBED_PROVIDER=vllm-embed, ENABLE_LITELLM=true, LLM_PROVIDER=vllm.
# RED: _wizard_profile currently hard-codes "lan" and sets no implied vars (09-03 changes it).
echo ""
echo "=== Case 10: wizard_profile_sets_env ==="
(
    set +e
    export NON_INTERACTIVE=true
    export DEPLOY_PROFILE=rag
    # Stub tui/whiptail functions that wizard.sh may call
    wt_menu()    { echo "${2:-rag}"; }
    wt_yesno()   { return 1; }
    wt_info()    { :; }
    log_info()   { :; }
    log_warn()   { :; }
    log_error()  { :; }
    log_success(){ :; }
    export -f wt_menu wt_yesno wt_info log_info log_warn log_error log_success
    # Source lib modules wizard.sh depends on (silently)
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/common.sh"  2>/dev/null || true
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/detect.sh"  2>/dev/null || true
    # shellcheck disable=SC1090
    source "${SERVICE_MAP_SH}"           2>/dev/null || true
    # Source wizard (set +u to tolerate unset vars during source)
    set +u
    # shellcheck disable=SC1090
    source "${WIZARD_SH}" 2>/dev/null || true
    set -u

    _wizard_profile 2>/dev/null || true

    local_fail=0
    [[ "${DEPLOY_PROFILE:-}" == "rag" ]]          || { echo "  FAIL: DEPLOY_PROFILE='${DEPLOY_PROFILE:-}' want rag"; local_fail=$((local_fail+1)); }
    [[ "${ENABLE_DOCLING:-}" == "true" ]]          || { echo "  FAIL: ENABLE_DOCLING='${ENABLE_DOCLING:-}' want true"; local_fail=$((local_fail+1)); }
    [[ "${VECTOR_STORE:-}" == "weaviate" ]]        || { echo "  FAIL: VECTOR_STORE='${VECTOR_STORE:-}' want weaviate"; local_fail=$((local_fail+1)); }
    [[ "${EMBED_PROVIDER:-}" == "vllm-embed" ]]    || { echo "  FAIL: EMBED_PROVIDER='${EMBED_PROVIDER:-}' want vllm-embed"; local_fail=$((local_fail+1)); }
    [[ "${ENABLE_LITELLM:-}" == "true" ]]          || { echo "  FAIL: ENABLE_LITELLM='${ENABLE_LITELLM:-}' want true"; local_fail=$((local_fail+1)); }
    [[ "${LLM_PROVIDER:-}" == "vllm" ]]            || { echo "  FAIL: LLM_PROVIDER='${LLM_PROVIDER:-}' want vllm"; local_fail=$((local_fail+1)); }
    exit "$local_fail"
) && { echo "  [PASS] wizard_profile_sets_env"; pass=$((pass+1)); } \
  || { echo "  [FAIL] wizard_profile_sets_env (expected RED — _wizard_profile stub returns 'lan' + no implied vars)"; fail=$((fail+1)); }

# ── Case 11: wizard_profile_custom_keeps_custom ───────────────────────────────
# NON_INTERACTIVE=true DEPLOY_PROFILE=custom → _wizard_profile leaves DEPLOY_PROFILE=custom.
# RED: _wizard_profile currently overwrites with "lan" (09-03 changes it).
echo ""
echo "=== Case 11: wizard_profile_custom_keeps_custom ==="
(
    set +e
    export NON_INTERACTIVE=true
    export DEPLOY_PROFILE=custom
    wt_menu()    { echo "custom"; }
    wt_yesno()   { return 1; }
    wt_info()    { :; }
    log_info()   { :; }
    log_warn()   { :; }
    log_error()  { :; }
    log_success(){ :; }
    export -f wt_menu wt_yesno wt_info log_info log_warn log_error log_success
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/common.sh"  2>/dev/null || true
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/lib/detect.sh"  2>/dev/null || true
    # shellcheck disable=SC1090
    source "${SERVICE_MAP_SH}"           2>/dev/null || true
    set +u
    # shellcheck disable=SC1090
    source "${WIZARD_SH}" 2>/dev/null || true
    set -u

    _wizard_profile 2>/dev/null || true

    [[ "${DEPLOY_PROFILE:-}" == "custom" ]] || { echo "  FAIL: DEPLOY_PROFILE='${DEPLOY_PROFILE:-}' want custom (granular flow)"; exit 1; }
    echo "  PASS: DEPLOY_PROFILE=custom preserved by _wizard_profile"
    exit 0
) && { echo "  [PASS] wizard_profile_custom_keeps_custom"; pass=$((pass+1)); } \
  || { echo "  [FAIL] wizard_profile_custom_keeps_custom (expected RED — stub sets 'lan' not 'custom')"; fail=$((fail+1)); }

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
