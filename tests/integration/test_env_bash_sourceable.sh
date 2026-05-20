#!/usr/bin/env bash
# test_env_bash_sourceable.sh — Matrix .env generation + bash-source validity.
# Guards: generated .env is bash-sourceable under set -u across representative
# (DEPLOY_PROFILE × AGMIND_LLM_PROFILE × VLLM_MAX_MODEL_LEN) cells, with all
# required secrets non-empty. Closes bugs 4, 5, 11 class.
#
# Exit: 0 = all PASS, 1 = any FAIL, 77 = SKIP (required libs missing).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

for f in "${REPO_ROOT}/lib/common.sh" "${REPO_ROOT}/lib/i18n.sh" \
          "${REPO_ROOT}/lib/wizard.sh" "${REPO_ROOT}/lib/config.sh"; do
    if [[ ! -f "$f" ]]; then
        echo "SKIP: required lib missing: $f"
        exit 77
    fi
done

echo "## test_env_bash_sourceable.sh"

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

# _run_cell DEPLOY_PROFILE AGMIND_LLM_PROFILE VLLM_MAX_MODEL_LEN CELL_LABEL
# Emits KEY=VALUE lines on stdout for the generated env vars + PASS/FAIL deltas.
_run_cell() {
    local dp="$1" llm="$2" ctx="$3" label="$4"
    (
        # ── Stub wt_* so wizard.sh/config.sh can be sourced without whiptail ──
        wt_menu()      { echo "${5:-1}"; }
        wt_input()     { echo "${3:-}"; }
        wt_yesno()     { return 1; }
        wt_msg()       { true; }
        wt_checklist() { true; }
        wt_parse()     { true; }
        wt_info()      { true; }
        wt_gauge()     { true; }
        export -f wt_menu wt_input wt_yesno wt_msg wt_checklist wt_parse wt_info wt_gauge

        # ── Stub docker to avoid real registry calls ──
        docker() {
            case "${1:-} ${2:-}" in
                "image inspect")    return 1 ;;
                "manifest inspect") return 0 ;;
                *)                  return 0 ;;
            esac
        }
        export -f docker

        # ── Suppress colors ──
        RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
        export RED GREEN YELLOW CYAN BOLD NC

        # ── Stub log_* ──
        log_info()    { true; }
        log_warn()    { true; }
        log_error()   { true; }
        log_success() { true; }
        log_success_with_url() { true; }
        export -f log_info log_warn log_error log_success log_success_with_url

        # ── Per-cell tempdir ──
        PER_TMP="$(mktemp -d -p "${TMPDIR_ROOT}")"
        mkdir -p "${PER_TMP}/docker"

        # ── Fixed test env ──
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

        # ── Cell-specific vars ──
        export DEPLOY_PROFILE="${dp}"
        export AGMIND_LLM_PROFILE="${llm}"
        if [[ -n "${ctx}" ]]; then
            export VLLM_MAX_MODEL_LEN="${ctx}"
        fi

        # ── Source libs ──
        # shellcheck source=../../lib/common.sh
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null
        # shellcheck source=../../lib/i18n.sh
        source "${REPO_ROOT}/lib/i18n.sh" 2>/dev/null
        set +u
        source "${REPO_ROOT}/templates/versions.env" 2>/dev/null || true
        set -u
        # shellcheck source=../../lib/wizard.sh
        source "${REPO_ROOT}/lib/wizard.sh" 2>/dev/null
        # shellcheck source=../../lib/config.sh
        source "${REPO_ROOT}/lib/config.sh" 2>/dev/null

        # ── Stub cluster_mode_save (avoids /var/lib/agmind/state writes) ──
        cluster_mode_save() { :; }
        export -f cluster_mode_save

        # ── Run the config generation sequence ──
        _init_wizard_defaults
        _apply_blackwell_cu130
        _generate_secrets
        _generate_env_file "${dp}" "${REPO_ROOT}/templates"
        _append_provider_vars

        # ── A1: .env file exists ──
        local a1_rc=0
        [[ -f "${PER_TMP}/docker/.env" ]] || a1_rc=1
        echo "A1_EXISTS=${a1_rc}"

        # ── A2: syntactic check (bash -n) ──
        local a2_rc=0
        bash -n "${PER_TMP}/docker/.env" 2>/dev/null || a2_rc=1
        echo "A2_BASH_N=${a2_rc}"

        # ── A3: semantic check (set -u source in fresh subshell) ──
        local a3_rc=0
        # shellcheck disable=SC1090
        ( set -u; source "${PER_TMP}/docker/.env" ) 2>/dev/null || a3_rc=$?
        # any non-zero = fail for our purposes
        [[ "${a3_rc}" -eq 0 ]] || a3_rc=1
        echo "A3_SOURCE_SET_U=${a3_rc}"

        # ── A4: secrets non-empty (4 of 4) ──
        local a4_count=0
        a4_count="$(
            # shellcheck disable=SC1090
            (
                source "${PER_TMP}/docker/.env" 2>/dev/null
                printf '%s\n' "${REDIS_PASSWORD:-}" "${DB_PASSWORD:-}" \
                              "${SANDBOX_API_KEY:-}" "${PLUGIN_DAEMON_KEY:-}"
            ) | grep -c '^.\+$' || true
        )"
        echo "A4_SECRETS_COUNT=${a4_count}"

        # ── A5: VLLM_MODEL matches profile expectation ──
        local env_vllm_model=""
        env_vllm_model="$(
            # shellcheck disable=SC1090
            ( source "${PER_TMP}/docker/.env" 2>/dev/null; echo "${VLLM_MODEL:-}" )
        )"
        echo "A5_VLLM_MODEL=${env_vllm_model}"

        # ── A6: VLLM_EXTRA_ARGS from .env ──
        local env_extra_args=""
        env_extra_args="$(
            # shellcheck disable=SC1090
            ( source "${PER_TMP}/docker/.env" 2>/dev/null; echo "${VLLM_EXTRA_ARGS:-}" )
        )"
        echo "A6_VLLM_EXTRA_ARGS=${env_extra_args}"

        # ── A7/A8: JSON-typed args moved out of VLLM_EXTRA_ARGS into
        # dedicated env vars on 2026-05-18. Consumed by
        # templates/vllm-config/entrypoint.sh. See CLAUDE.md §8 entry
        # "vLLM CLI: --speculative-config is JSON, not path".
        local env_spec_cfg=""
        env_spec_cfg="$(
            # shellcheck disable=SC1090
            ( source "${PER_TMP}/docker/.env" 2>/dev/null; echo "${VLLM_SPECULATIVE_CONFIG:-}" )
        )"
        echo "A7_VLLM_SPECULATIVE_CONFIG=${env_spec_cfg}"

        local env_rope_cfg=""
        env_rope_cfg="$(
            # shellcheck disable=SC1090
            ( source "${PER_TMP}/docker/.env" 2>/dev/null; echo "${VLLM_ROPE_SCALING_CONFIG:-}" )
        )"
        echo "A8_VLLM_ROPE_SCALING_CONFIG=${env_rope_cfg}"

    ) 2>/dev/null
}

_get() {
    local key="$1" output="$2"
    echo "$output" | grep "^${key}=" | head -1 | cut -d'=' -f2-
}

# ============================================================================
# Matrix: 6 cells
# Format: deploy_profile | llm_profile | vllm_max_model_len | expected_model | label
# ============================================================================

# Cell 1: lan + gemma + 65536 — baseline
echo ""
echo "--- Cell 1: (lan, gemma, 65536) ---"
out=$(_run_cell "lan" "gemma" "65536" "cell1" 2>/dev/null)
_assert_eq "cell1_lan_gemma_65536: A1 .env exists"             "0" "$(_get A1_EXISTS       "$out")"
_assert_eq "cell1_lan_gemma_65536: A2 bash-n valid"            "0" "$(_get A2_BASH_N        "$out")"
_assert_eq "cell1_lan_gemma_65536: A3 sourceable under set -u" "0" "$(_get A3_SOURCE_SET_U  "$out")"
_assert_eq "cell1_lan_gemma_65536: A4 4 secrets non-empty"     "4" "$(_get A4_SECRETS_COUNT "$out")"
_assert_eq "cell1_lan_gemma_65536: A5 VLLM_MODEL=gemma-4" \
    "google/gemma-4-26B-A4B-it" "$(_get A5_VLLM_MODEL "$out")"
_assert_contains "cell1_lan_gemma_65536: A6 EXTRA_ARGS has kv-cache-dtype fp8" \
    "kv-cache-dtype fp8" "$(_get A6_VLLM_EXTRA_ARGS "$out")"

# Cell 2: custom + gemma + 65536 — env.<profile>.template fallback path (bug 5)
echo ""
echo "--- Cell 2: (custom, gemma, 65536) --- [fallback template path]"
out=$(_run_cell "custom" "gemma" "65536" "cell2" 2>/dev/null)
_assert_eq "cell2_custom_gemma_65536: A1 .env exists (fallback to lan template)" "0" "$(_get A1_EXISTS       "$out")"
_assert_eq "cell2_custom_gemma_65536: A2 bash-n valid"                           "0" "$(_get A2_BASH_N        "$out")"
_assert_eq "cell2_custom_gemma_65536: A3 sourceable under set -u"                "0" "$(_get A3_SOURCE_SET_U  "$out")"
_assert_eq "cell2_custom_gemma_65536: A4 4 secrets non-empty"                    "4" "$(_get A4_SECRETS_COUNT "$out")"
_assert_eq "cell2_custom_gemma_65536: A5 VLLM_MODEL=gemma-4" \
    "google/gemma-4-26B-A4B-it" "$(_get A5_VLLM_MODEL "$out")"
_assert_contains "cell2_custom_gemma_65536: A6 EXTRA_ARGS has kv-cache-dtype fp8" \
    "kv-cache-dtype fp8" "$(_get A6_VLLM_EXTRA_ARGS "$out")"

# Cell 3: rag + qwen36-fp8 + 131072 — DFlash JSON in VLLM_EXTRA_ARGS (bug 4)
echo ""
echo "--- Cell 3: (rag, qwen36-fp8, 131072) --- [DFlash JSON args]"
out=$(_run_cell "rag" "qwen36-fp8" "131072" "cell3" 2>/dev/null)
_assert_eq "cell3_rag_qwen36fp8_131072: A1 .env exists"             "0" "$(_get A1_EXISTS       "$out")"
_assert_eq "cell3_rag_qwen36fp8_131072: A2 bash-n valid"            "0" "$(_get A2_BASH_N        "$out")"
_assert_eq "cell3_rag_qwen36fp8_131072: A3 sourceable under set -u" "0" "$(_get A3_SOURCE_SET_U  "$out")"
_assert_eq "cell3_rag_qwen36fp8_131072: A4 4 secrets non-empty"     "4" "$(_get A4_SECRETS_COUNT "$out")"
_assert_eq "cell3_rag_qwen36fp8_131072: A5 VLLM_MODEL=Qwen3.6-35B-A3B-FP8" \
    "Qwen/Qwen3.6-35B-A3B-FP8" "$(_get A5_VLLM_MODEL "$out")"
_assert_contains "cell3_rag_qwen36fp8_131072: A7 VLLM_SPECULATIVE_CONFIG contains dflash" \
    "dflash" "$(_get A7_VLLM_SPECULATIVE_CONFIG "$out")"

# Cell 4: full + qwen36-fp8 + 262144 — 256K context
echo ""
echo "--- Cell 4: (full, qwen36-fp8, 262144) --- [256K context]"
out=$(_run_cell "full" "qwen36-fp8" "262144" "cell4" 2>/dev/null)
_assert_eq "cell4_full_qwen36fp8_262144: A1 .env exists"             "0" "$(_get A1_EXISTS       "$out")"
_assert_eq "cell4_full_qwen36fp8_262144: A2 bash-n valid"            "0" "$(_get A2_BASH_N        "$out")"
_assert_eq "cell4_full_qwen36fp8_262144: A3 sourceable under set -u" "0" "$(_get A3_SOURCE_SET_U  "$out")"
_assert_eq "cell4_full_qwen36fp8_262144: A4 4 secrets non-empty"     "4" "$(_get A4_SECRETS_COUNT "$out")"
_assert_eq "cell4_full_qwen36fp8_262144: A5 VLLM_MODEL=Qwen3.6-35B-A3B-FP8" \
    "Qwen/Qwen3.6-35B-A3B-FP8" "$(_get A5_VLLM_MODEL "$out")"
_assert_contains "cell4_full_qwen36fp8_262144: A7 VLLM_SPECULATIVE_CONFIG contains dflash" \
    "dflash" "$(_get A7_VLLM_SPECULATIVE_CONFIG "$out")"

# Cell 5: custom + qwen36-fp8 + 1010000 — 1M YaRN: DFlash JSON + rope-scaling (bugs 4+11)
echo ""
echo "--- Cell 5: (custom, qwen36-fp8, 1010000) --- [1M YaRN context]"
out=$(_run_cell "custom" "qwen36-fp8" "1010000" "cell5" 2>/dev/null)
_assert_eq "cell5_custom_qwen36fp8_1010000: A1 .env exists"             "0" "$(_get A1_EXISTS       "$out")"
_assert_eq "cell5_custom_qwen36fp8_1010000: A2 bash-n valid"            "0" "$(_get A2_BASH_N        "$out")"
_assert_eq "cell5_custom_qwen36fp8_1010000: A3 sourceable under set -u" "0" "$(_get A3_SOURCE_SET_U  "$out")"
_assert_eq "cell5_custom_qwen36fp8_1010000: A4 4 secrets non-empty"     "4" "$(_get A4_SECRETS_COUNT "$out")"
_assert_eq "cell5_custom_qwen36fp8_1010000: A5 VLLM_MODEL=Qwen3.6-35B-A3B-FP8" \
    "Qwen/Qwen3.6-35B-A3B-FP8" "$(_get A5_VLLM_MODEL "$out")"
_assert_contains "cell5_custom_qwen36fp8_1010000: A7 VLLM_SPECULATIVE_CONFIG contains dflash" \
    "dflash" "$(_get A7_VLLM_SPECULATIVE_CONFIG "$out")"
_assert_contains "cell5_custom_qwen36fp8_1010000: A8 VLLM_ROPE_SCALING_CONFIG contains yarn rope_type" \
    "yarn" "$(_get A8_VLLM_ROPE_SCALING_CONFIG "$out")"
_assert_contains "cell5_custom_qwen36fp8_1010000: A8 VLLM_ROPE_SCALING_CONFIG contains original_max_position_embeddings" \
    "original_max_position_embeddings" "$(_get A8_VLLM_ROPE_SCALING_CONFIG "$out")"

# Cell 6: rag + qwen36-heretic + 131072 — heretic profile
echo ""
echo "--- Cell 6: (rag, qwen36-heretic, 131072) --- [heretic profile]"
out=$(_run_cell "rag" "qwen36-heretic" "131072" "cell6" 2>/dev/null)
_assert_eq "cell6_rag_qwen36heretic_131072: A1 .env exists"             "0" "$(_get A1_EXISTS       "$out")"
_assert_eq "cell6_rag_qwen36heretic_131072: A2 bash-n valid"            "0" "$(_get A2_BASH_N        "$out")"
_assert_eq "cell6_rag_qwen36heretic_131072: A3 sourceable under set -u" "0" "$(_get A3_SOURCE_SET_U  "$out")"
_assert_eq "cell6_rag_qwen36heretic_131072: A4 4 secrets non-empty"     "4" "$(_get A4_SECRETS_COUNT "$out")"
_assert_eq "cell6_rag_qwen36heretic_131072: A5 VLLM_MODEL=heretic-NVFP4" \
    "AEON-7/Qwen3.6-35B-A3B-heretic-NVFP4" "$(_get A5_VLLM_MODEL "$out")"
_assert_contains "cell6_rag_qwen36heretic_131072: A7 VLLM_SPECULATIVE_CONFIG contains dflash" \
    "dflash" "$(_get A7_VLLM_SPECULATIVE_CONFIG "$out")"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
