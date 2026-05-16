#!/usr/bin/env bash
# test_wizard_llm_profile.sh — Non-interactive wizard LLM profile assertions.
# Tests _apply_blackwell_cu130 (the non-interactive twin of _wizard_llm_profile)
# under various AGMIND_LLM_PROFILE / VLLM_MAX_MODEL_LEN / LLM_ON_PEER combos.
#
# Exit: 0 = all PASS, 1 = any FAIL, 77 = SKIP (required libs missing).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

for f in "${REPO_ROOT}/lib/common.sh" "${REPO_ROOT}/lib/i18n.sh" "${REPO_ROOT}/lib/wizard.sh"; do
    if [[ ! -f "$f" ]]; then
        echo "SKIP: required lib missing: $f"
        exit 77
    fi
done

echo "## test_wizard_llm_profile.sh"

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

# Helper: run _apply_blackwell_cu130 in a subshell with the given env, capture
# exported variable values. Returns KEY=VALUE pairs on stdout.
_run_profile() {
    # Arguments are VAR=VALUE pairs to set before calling _apply_blackwell_cu130.
    # Prints exported vars VLLM_IMAGE VLLM_MODEL VLLM_EXTRA_ARGS VLLM_MAX_MODEL_LEN
    # VLLM_GPU_MEM_UTIL VLLM_ALLOW_LONG_MAX_MODEL_LEN AGMIND_LLM_PROFILE to stdout.
    (
        # Stub wt_* functions so wizard.sh can be sourced without whiptail
        wt_menu()    { echo "${5:-1}"; }   # return first tag (option 1)
        wt_input()   { echo "${3:-}"; }    # return default
        wt_yesno()   { return 1; }         # default no
        wt_msg()     { true; }
        wt_checklist() { true; }
        wt_parse()   { true; }
        wt_info()    { true; }
        wt_gauge()   { true; }
        export -f wt_menu wt_input wt_yesno wt_msg wt_checklist wt_parse wt_info wt_gauge

        # Stub docker to avoid real calls (image inspect / manifest inspect)
        docker() {
            # image inspect: always fail (image not local) so manifest path tried
            # manifest inspect: always succeed (simulate reachable AEON image)
            case "${1:-} ${2:-}" in
                "image inspect") return 1 ;;
                "manifest inspect") return 0 ;;
                *) return 0 ;;
            esac
        }
        export -f docker

        # Suppress colors
        RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
        export RED GREEN YELLOW CYAN BOLD NC

        # Set caller-provided env
        for _kv in "$@"; do
            export "${_kv?}"
        done

        # Fixed test env
        export NON_INTERACTIVE=true
        export DETECTED_DGX_SPARK=true
        export DETECTED_GPU_COMPUTE="12.1"
        export LLM_PROVIDER=vllm
        export EMBED_PROVIDER=vllm
        export INSTALLER_DIR="${REPO_ROOT}"

        # shellcheck source=../../lib/common.sh
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null
        # shellcheck source=../../lib/i18n.sh
        source "${REPO_ROOT}/lib/i18n.sh" 2>/dev/null
        # Load versions.env so VLLM_AEON_IMAGE is available
        set +u
        source "${REPO_ROOT}/templates/versions.env" 2>/dev/null || true
        set -u
        # shellcheck source=../../lib/wizard.sh
        source "${REPO_ROOT}/lib/wizard.sh" 2>/dev/null

        # Run the non-interactive twin
        _init_wizard_defaults
        _apply_blackwell_cu130

        # Print results
        echo "VLLM_IMAGE=${VLLM_IMAGE:-}"
        echo "VLLM_MODEL=${VLLM_MODEL:-}"
        echo "VLLM_EXTRA_ARGS=${VLLM_EXTRA_ARGS:-}"
        echo "VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-}"
        echo "VLLM_GPU_MEM_UTIL=${VLLM_GPU_MEM_UTIL:-}"
        echo "VLLM_ALLOW_LONG_MAX_MODEL_LEN=${VLLM_ALLOW_LONG_MAX_MODEL_LEN:-}"
        echo "AGMIND_LLM_PROFILE=${AGMIND_LLM_PROFILE:-}"
    )
}

_get() {
    local key="$1" output="$2"
    echo "$output" | grep "^${key}=" | head -1 | cut -d'=' -f2-
}

# ============================================================================
# TC1: Default (no AGMIND_LLM_PROFILE) → Gemma 4 vars unchanged from today
# ============================================================================
echo ""
echo "--- TC1: default → Gemma 4 ---"
out=$(_run_profile 2>/dev/null)
_assert_eq "TC1: VLLM_IMAGE=gemma4-cu130" \
    "vllm/vllm-openai:gemma4-cu130" "$(_get VLLM_IMAGE "$out")"
_assert_eq "TC1: VLLM_MODEL=gemma-4-26B-A4B-it" \
    "google/gemma-4-26B-A4B-it" "$(_get VLLM_MODEL "$out")"
_assert_eq "TC1: VLLM_MAX_MODEL_LEN=65536" \
    "65536" "$(_get VLLM_MAX_MODEL_LEN "$out")"
_assert_contains "TC1: EXTRA_ARGS has kv-cache-dtype fp8" \
    "--kv-cache-dtype fp8" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_contains "TC1: EXTRA_ARGS has enforce-eager" \
    "--enforce-eager" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_not_contains "TC1: EXTRA_ARGS has no dflash" \
    "dflash" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_eq "TC1: AGMIND_LLM_PROFILE=gemma" \
    "gemma" "$(_get AGMIND_LLM_PROFILE "$out")"

# ============================================================================
# TC2: AGMIND_LLM_PROFILE=qwen36-fp8 → AEON image, Qwen FP8 model
# Note: FP8 model MUST NOT have --quantization arg (HF config.json declares fp8
# already; explicit override triggers pydantic ValidationError).
# Note: --speculative-config dropped pending file-mount restoration (BACKLOG).
# ============================================================================
echo ""
echo "--- TC2: qwen36-fp8 profile ---"
out=$(_run_profile "AGMIND_LLM_PROFILE=qwen36-fp8" 2>/dev/null)
_assert_eq "TC2: VLLM_IMAGE=AEON v1.2" \
    "ghcr.io/aeon-7/vllm-spark-omni-q36:v1.2" "$(_get VLLM_IMAGE "$out")"
_assert_eq "TC2: VLLM_MODEL=Qwen3.6-35B-A3B-FP8" \
    "Qwen/Qwen3.6-35B-A3B-FP8" "$(_get VLLM_MODEL "$out")"
_assert_eq "TC2: VLLM_MAX_MODEL_LEN=131072 (default for qwen36)" \
    "131072" "$(_get VLLM_MAX_MODEL_LEN "$out")"
_assert_not_contains "TC2: EXTRA_ARGS has NO --quantization (FP8 auto-detect)" \
    "--quantization" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_contains "TC2: EXTRA_ARGS contains --tool-call-parser qwen3_coder" \
    "--tool-call-parser qwen3_coder" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_contains "TC2: EXTRA_ARGS contains --reasoning-parser qwen3" \
    "--reasoning-parser qwen3" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_eq "TC2: AGMIND_LLM_PROFILE=qwen36-fp8" \
    "qwen36-fp8" "$(_get AGMIND_LLM_PROFILE "$out")"

# ============================================================================
# TC3: AGMIND_LLM_PROFILE=qwen36-fp8 + VLLM_MAX_MODEL_LEN=262144 → ctx override sticks
# ============================================================================
echo ""
echo "--- TC3: qwen36-fp8 + VLLM_MAX_MODEL_LEN=262144 ---"
out=$(_run_profile "AGMIND_LLM_PROFILE=qwen36-fp8" "VLLM_MAX_MODEL_LEN=262144" 2>/dev/null)
_assert_eq "TC3: VLLM_MAX_MODEL_LEN=262144 (override sticks)" \
    "262144" "$(_get VLLM_MAX_MODEL_LEN "$out")"
_assert_eq "TC3: VLLM_MODEL=Qwen3.6-35B-A3B-FP8" \
    "Qwen/Qwen3.6-35B-A3B-FP8" "$(_get VLLM_MODEL "$out")"

# ============================================================================
# TC4: AGMIND_LLM_PROFILE=qwen36-heretic → heretic model, no tool-call-parser,
#       has reasoning-parser + --quantization compressed-tensors (NVFP4 format).
# ============================================================================
echo ""
echo "--- TC4: qwen36-heretic profile ---"
out=$(_run_profile "AGMIND_LLM_PROFILE=qwen36-heretic" 2>/dev/null)
_assert_eq "TC4: VLLM_MODEL=heretic-NVFP4" \
    "AEON-7/Qwen3.6-35B-A3B-heretic-NVFP4" "$(_get VLLM_MODEL "$out")"
_assert_not_contains "TC4: EXTRA_ARGS NO --tool-call-parser" \
    "--tool-call-parser" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_not_contains "TC4: EXTRA_ARGS NO --enable-auto-tool-choice" \
    "--enable-auto-tool-choice" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_contains "TC4: EXTRA_ARGS has --reasoning-parser qwen3" \
    "--reasoning-parser qwen3" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_contains "TC4: EXTRA_ARGS has --quantization compressed-tensors (NVFP4)" \
    "--quantization compressed-tensors" "$(_get VLLM_EXTRA_ARGS "$out")"
_assert_eq "TC4: AGMIND_LLM_PROFILE=qwen36-heretic" \
    "qwen36-heretic" "$(_get AGMIND_LLM_PROFILE "$out")"

# ============================================================================
# TC5: qwen36-fp8 + LLM_ON_PEER=true → VLLM_GPU_MEM_UTIL=0.75
# ============================================================================
echo ""
echo "--- TC5: qwen36-fp8 + LLM_ON_PEER=true → GPU_MEM_UTIL=0.75 ---"
out=$(_run_profile "AGMIND_LLM_PROFILE=qwen36-fp8" "LLM_ON_PEER=true" 2>/dev/null)
_assert_eq "TC5: VLLM_GPU_MEM_UTIL=0.75 (peer dedicated GPU)" \
    "0.75" "$(_get VLLM_GPU_MEM_UTIL "$out")"

# ============================================================================
# TC6: default (Gemma) + LLM_ON_PEER=false → VLLM_GPU_MEM_UTIL unset/empty
# ============================================================================
echo ""
echo "--- TC6: gemma + LLM_ON_PEER=false → GPU_MEM_UTIL empty ---"
out=$(_run_profile "AGMIND_LLM_PROFILE=gemma" "LLM_ON_PEER=false" 2>/dev/null)
_assert_eq "TC6: VLLM_GPU_MEM_UTIL not set for Gemma" \
    "" "$(_get VLLM_GPU_MEM_UTIL "$out")"

# ============================================================================
# TC7: i18n smoke — AGMIND_LANG=ru → wizard prompts come out Russian (t() works)
# ============================================================================
echo ""
echo "--- TC7: AGMIND_LANG=ru smoke ---"
ru_title=$(env -i AGMIND_LANG=ru HOME="${HOME}" bash --noprofile --norc -c "
    source ${REPO_ROOT}/lib/i18n.sh
    t wizard.llm_profile.title
" 2>/dev/null)
_assert_eq "TC7: Russian LLM profile title" "Профиль LLM (DGX Spark)" "$ru_title"

en_title=$(env -i AGMIND_LANG=en HOME="${HOME}" bash --noprofile --norc -c "
    source ${REPO_ROOT}/lib/i18n.sh
    t wizard.llm_profile.title
" 2>/dev/null)
_assert_eq "TC7: English LLM profile title" "LLM Profile (DGX Spark)" "$en_title"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
