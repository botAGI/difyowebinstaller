#!/usr/bin/env bash
# test_wizard_full_flow.sh — Matrix run_wizard end-to-end profile coherence (16 cells).
# Guards the run_wizard output for all (DEPLOY_PROFILE x AGMIND_LLM_PROFILE) combos
# in NON_INTERACTIVE mode. Verifies:
#   C1. run_wizard exits 0
#   C2. VLLM_MODEL consistent with profile selection path
#   C3. VLLM_IMAGE non-empty and consistent with model
#   C4. VLLM_EXTRA_ARGS present for vllm provider
#   C5. _wizard_llm_model does NOT override VLLM_MODEL set by _apply_blackwell_cu130
#       (REGRESSION GUARD bug-2 / commit 328c669: for custom+qwen36 cells)
#
# Behavior summary discovered via live run (locked here as regression contract):
#   - core/rag/full profiles: _wizard_llm_provider SKIPPED (_SKIP_GRANULAR=true),
#     _apply_blackwell_cu130 NOT called → NI fallback = Gemma 4 always.
#     AGMIND_LLM_PROFILE retained in env but does not affect model in NI named profiles.
#   - custom profile: _wizard_llm_provider runs → _apply_blackwell_cu130 called →
#     AGMIND_LLM_PROFILE env drives model selection correctly.
#   - REGRESSION GUARD (C5): for custom+qwen36, after _apply_blackwell_cu130 sets
#     VLLM_MODEL, _wizard_llm_model must NOT overwrite it (bug-2 guard from 328c669).
#     Verified: VLLM_MODEL remains Qwen/Qwen3.6 / heretic after run_wizard.
#
# Exit: 0 = all PASS, 1 = any FAIL, 77 = SKIP (required libs missing).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

for f in "${REPO_ROOT}/lib/common.sh" "${REPO_ROOT}/lib/i18n.sh" \
          "${REPO_ROOT}/lib/wizard.sh" "${REPO_ROOT}/lib/cluster_mode.sh"; do
    if [[ ! -f "$f" ]]; then
        echo "SKIP: required lib missing: $f"
        exit 77
    fi
done

echo "## test_wizard_full_flow.sh"

PASS=0; FAIL=0

_assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: ${label}"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        actual:   $(printf '%q' "$actual")"
        FAIL=$(( FAIL + 1 ))
    fi
}

_assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: ${label}"
        echo "        expected to contain: $(printf '%q' "$needle")"
        echo "        actual: $(printf '%q' "$haystack")"
        FAIL=$(( FAIL + 1 ))
    fi
}

_assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: ${label}"
        echo "        expected NOT to contain: $(printf '%q' "$needle")"
        echo "        actual: $(printf '%q' "$haystack")"
        FAIL=$(( FAIL + 1 ))
    fi
}

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

# _run_wizard_cell DEPLOY_PROFILE AGMIND_LLM_PROFILE
# Runs run_wizard in a subshell and emits KEY=VALUE lines for assertion.
_run_wizard_cell() {
    local dp="$1" llm="$2"
    (
        # ── Stubs ──
        wt_menu()      { echo "${5:-1}"; }
        wt_input()     { echo "${3:-}"; }
        wt_yesno()     { return 1; }
        wt_msg()       { true; }
        wt_checklist() { true; }
        wt_parse()     { true; }
        wt_info()      { true; }
        wt_gauge()     { true; }
        export -f wt_menu wt_input wt_yesno wt_msg wt_checklist wt_parse wt_info wt_gauge

        docker() {
            case "${1:-} ${2:-}" in
                "image inspect")    return 1 ;;
                "manifest inspect") return 0 ;;
                *)                  return 0 ;;
            esac
        }
        export -f docker

        log_info()    { true; }
        log_warn()    { true; }
        log_error()   { true; }
        log_success() { true; }
        log_success_with_url() { true; }
        export -f log_info log_warn log_error log_success log_success_with_url

        RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
        export RED GREEN YELLOW CYAN BOLD NC

        PER_TMP="$(mktemp -d -p "${TMPDIR_ROOT}")"
        mkdir -p "${PER_TMP}/docker"

        export INSTALL_DIR="${PER_TMP}"
        export AGMIND_CLUSTER_STATE_DIR="${PER_TMP}/cluster"
        export NON_INTERACTIVE=true
        export DETECTED_DGX_SPARK=true
        export DETECTED_GPU_COMPUTE="12.1"
        export LLM_PROVIDER=vllm
        export EMBED_PROVIDER=vllm
        export HF_TOKEN=stub_hf
        export INSTALLER_DIR="${REPO_ROOT}"
        export AGMIND_LANG=en
        export VECTOR_STORE=weaviate
        export AGMIND_MODE_OVERRIDE=single

        export DEPLOY_PROFILE="${dp}"
        export AGMIND_LLM_PROFILE="${llm}"

        # ── Source libs ──
        # shellcheck source=../../lib/common.sh
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null
        # shellcheck source=../../lib/i18n.sh
        source "${REPO_ROOT}/lib/i18n.sh" 2>/dev/null
        set +u
        source "${REPO_ROOT}/templates/versions.env" 2>/dev/null || true
        set -u
        # shellcheck source=../../lib/cluster_mode.sh
        source "${REPO_ROOT}/lib/cluster_mode.sh" 2>/dev/null
        cluster_mode_save()   { :; }
        cluster_mode_read()   { echo "single"; }
        cluster_mode_select() { echo "single"; }
        export -f cluster_mode_save cluster_mode_read cluster_mode_select
        # shellcheck source=../../lib/wizard.sh
        source "${REPO_ROOT}/lib/wizard.sh" 2>/dev/null

        # ── Run wizard ──
        local rc=0
        run_wizard 2>/dev/null || rc=$?

        echo "RC=${rc}"
        echo "VLLM_MODEL=${VLLM_MODEL:-}"
        echo "VLLM_IMAGE=${VLLM_IMAGE:-}"
        echo "VLLM_EXTRA_ARGS=${VLLM_EXTRA_ARGS:-}"
        echo "AGMIND_LLM_PROFILE=${AGMIND_LLM_PROFILE:-}"
    ) 2>/dev/null
}

_get() {
    local key="$1" output="$2"
    echo "$output" | grep "^${key}=" | head -1 | cut -d'=' -f2-
}

# ============================================================================
# Matrix: 4×4 = 16 cells
#
# Behavioral contract (verified against live SUT, locked as regression baseline):
#
# Named profiles (core/rag/full):
#   _wizard_llm_provider SKIPPED (_SKIP_GRANULAR=true) → _apply_blackwell_cu130
#   NOT called → NI fallback Gemma 4 regardless of AGMIND_LLM_PROFILE.
#   VLLM_IMAGE = vllm/vllm-openai:gemma4-cu130 for all named+any llm_profile.
#
# Custom profile:
#   _wizard_llm_provider runs → _apply_blackwell_cu130 called →
#   AGMIND_LLM_PROFILE drives model selection:
#     gemma     → google/gemma-4-26B-A4B-it  + gemma4-cu130
#     qwen36-fp8  → Qwen/Qwen3.6-35B-A3B-FP8 + ghcr.io/aeon-7/vllm-spark-omni-q36:v1.2
#     qwen36-heretic → AEON-7/Qwen3.6-35B-A3B-heretic-NVFP4 + same AEON image
#     other       → NI: falls back to Gemma (no override known to wizard)
# ============================================================================

# ── Named profiles (3×4 = 12 cells) ────────────────────────────────────────

for dp in core rag full; do
    for llm in gemma qwen36-fp8 qwen36-heretic other; do
        echo ""
        echo "--- Cell: (${dp}, ${llm}) --- [named profile → Gemma fallback in NI]"
        out=$(_run_wizard_cell "${dp}" "${llm}" 2>/dev/null)
        cell_label="${dp}_${llm}"

        # C1: exit 0
        _assert_eq "${cell_label}: C1 run_wizard exit 0" "0" "$(_get RC "$out")"

        # C2: named profiles always produce Gemma in NI (SKIP_GRANULAR path)
        _assert_eq "${cell_label}: C2 VLLM_MODEL=gemma (NI named-profile fallback)" \
            "google/gemma-4-26B-A4B-it" "$(_get VLLM_MODEL "$out")"

        # C3: VLLM_IMAGE is gemma4-cu130 for named profiles
        _assert_contains "${cell_label}: C3 VLLM_IMAGE contains gemma4-cu130" \
            "gemma4-cu130" "$(_get VLLM_IMAGE "$out")"

        # C4: VLLM_EXTRA_ARGS non-empty for vllm
        _assert_contains "${cell_label}: C4 VLLM_EXTRA_ARGS non-empty" \
            "--" "$(_get VLLM_EXTRA_ARGS "$out")"
    done
done

# ── Custom profile (1×4 = 4 cells) ─────────────────────────────────────────
echo ""
echo "======== Custom profile cells ========"

# Custom + gemma
echo ""
echo "--- Cell: (custom, gemma) ---"
out=$(_run_wizard_cell "custom" "gemma" 2>/dev/null)
_assert_eq "custom_gemma: C1 run_wizard exit 0" "0" "$(_get RC "$out")"
_assert_eq "custom_gemma: C2 VLLM_MODEL=gemma-4-26B-A4B-it" \
    "google/gemma-4-26B-A4B-it" "$(_get VLLM_MODEL "$out")"
_assert_contains "custom_gemma: C3 VLLM_IMAGE contains gemma4-cu130" \
    "gemma4-cu130" "$(_get VLLM_IMAGE "$out")"
_assert_contains "custom_gemma: C4 VLLM_EXTRA_ARGS has kv-cache-dtype fp8" \
    "--kv-cache-dtype fp8" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_not_contains "custom_gemma: C4 VLLM_EXTRA_ARGS no dflash" \
    "dflash" "$(_get VLLM_EXTRA_ARGS "$out")"

# Custom + qwen36-fp8 — REGRESSION GUARD for bug-2 (commit 328c669)
echo ""
echo "--- Cell: (custom, qwen36-fp8) --- [REGRESSION GUARD bug-2]"
out=$(_run_wizard_cell "custom" "qwen36-fp8" 2>/dev/null)
_assert_eq "custom_qwen36fp8: C1 run_wizard exit 0" "0" "$(_get RC "$out")"
# C2: _apply_blackwell_cu130 sets Qwen3.6 FP8 model before _wizard_llm_model runs.
# C5 REGRESSION GUARD: _wizard_llm_model must NOT override back to Gemma.
_assert_eq "REGRESSION GUARD bug-2: custom_qwen36fp8 VLLM_MODEL not overridden by _wizard_llm_model" \
    "Qwen/Qwen3.6-35B-A3B-FP8" "$(_get VLLM_MODEL "$out")"
_assert_eq "custom_qwen36fp8: C3 VLLM_IMAGE=AEON v1.2" \
    "ghcr.io/aeon-7/vllm-spark-omni-q36:v1.2" "$(_get VLLM_IMAGE "$out")"
_assert_contains "custom_qwen36fp8: C4 VLLM_EXTRA_ARGS contains dflash" \
    "dflash" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_contains "custom_qwen36fp8: C4 VLLM_EXTRA_ARGS contains qwen3_coder" \
    "qwen3_coder" "$(_get VLLM_EXTRA_ARGS "$out")"

# Custom + qwen36-heretic — REGRESSION GUARD for bug-2
echo ""
echo "--- Cell: (custom, qwen36-heretic) --- [REGRESSION GUARD bug-2]"
out=$(_run_wizard_cell "custom" "qwen36-heretic" 2>/dev/null)
_assert_eq "custom_qwen36heretic: C1 run_wizard exit 0" "0" "$(_get RC "$out")"
# C5 REGRESSION GUARD: heretic model set by _apply_blackwell_cu130 must survive _wizard_llm_model.
_assert_eq "REGRESSION GUARD bug-2: custom_qwen36heretic VLLM_MODEL not overridden" \
    "AEON-7/Qwen3.6-35B-A3B-heretic-NVFP4" "$(_get VLLM_MODEL "$out")"
_assert_eq "custom_qwen36heretic: C3 VLLM_IMAGE=AEON v1.2" \
    "ghcr.io/aeon-7/vllm-spark-omni-q36:v1.2" "$(_get VLLM_IMAGE "$out")"
_assert_contains "custom_qwen36heretic: C4 VLLM_EXTRA_ARGS contains dflash" \
    "dflash" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_not_contains "custom_qwen36heretic: C4 VLLM_EXTRA_ARGS no qwen3_coder (heretic lacks tool-calling)" \
    "qwen3_coder" "$(_get VLLM_EXTRA_ARGS "$out")"

# Custom + other — wizard falls back to Gemma when profile unknown
echo ""
echo "--- Cell: (custom, other) ---"
out=$(_run_wizard_cell "custom" "other" 2>/dev/null)
_assert_eq "custom_other: C1 run_wizard exit 0" "0" "$(_get RC "$out")"
# C2: "other" profile → _apply_blackwell_cu130 falls through to gemma|* case
_assert_eq "custom_other: C2 VLLM_MODEL=gemma (fallback for unknown profile)" \
    "google/gemma-4-26B-A4B-it" "$(_get VLLM_MODEL "$out")"
_assert_contains "custom_other: C3 VLLM_IMAGE non-empty" \
    "vllm" "$(_get VLLM_IMAGE "$out")"
_assert_not_contains "custom_other: C2 VLLM_MODEL has no Qwen3.6 (not overriding to qwen36)" \
    "Qwen3.6" "$(_get VLLM_MODEL "$out")"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
