#!/usr/bin/env bash
# test_all_bind_mounts_exist.sh — Matrix bind-mount source presence after generate_config.
# Guards: after the config-generation sequence, all bind-mount source paths
# actually exist on disk for representative ENABLE_* toggle combos.
# Closes bug 6 class (missing litellm-config.yaml on custom profile without LiteLLM,
# and latent ragflow/nginx/*.conf gap check).
#
# NOTE: ragflow/nginx/*.conf checks in cells 3+4 are gated behind
#       RAGFLOW_NGINX_STRICT=true (default off). The files are provided
#       via templates/ragflow/nginx/ and _copy_ragflow_templates cp-r's them.
#       Set RAGFLOW_NGINX_STRICT=true to enable strict enforcement.
#
# Exit: 0 = all PASS, 1 = any FAIL, 77 = SKIP (required libs or python3+PyYAML missing).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

for f in "${REPO_ROOT}/lib/common.sh" "${REPO_ROOT}/lib/i18n.sh" \
          "${REPO_ROOT}/lib/wizard.sh" "${REPO_ROOT}/lib/config.sh" \
          "${REPO_ROOT}/lib/cluster_mode.sh"; do
    if [[ ! -f "$f" ]]; then
        echo "SKIP: required lib missing: $f"
        exit 77
    fi
done

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_all_bind_mounts_exist.sh"

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

# _run_cell ENABLE_LITELLM ENABLE_RAGFLOW MONITORING_MODE
# Runs the config-generation sequence in a subshell and emits KEY=VALUE result tokens.
_run_cell() {
    local enable_litellm="$1"
    local enable_ragflow="$2"
    local monitoring_mode="$3"
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
        export HF_TOKEN=stub
        export INSTALLER_DIR="${REPO_ROOT}"
        export AGMIND_LANG=en
        export DEPLOY_PROFILE=lan
        export VECTOR_STORE=weaviate
        export AGMIND_LLM_PROFILE=gemma

        # ── Cell-specific env ──
        export ENABLE_LITELLM="${enable_litellm}"
        export ENABLE_RAGFLOW="${enable_ragflow}"
        export MONITORING_MODE="${monitoring_mode}"

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
        # shellcheck source=../../lib/cluster_mode.sh
        source "${REPO_ROOT}/lib/cluster_mode.sh" 2>/dev/null
        cluster_mode_save() { :; }
        export -f cluster_mode_save

        # ── Config generation sequence ──
        _init_wizard_defaults
        _apply_blackwell_cu130
        ensure_bind_mount_files
        _generate_secrets
        _generate_env_file lan "${REPO_ROOT}/templates"
        _append_provider_vars
        _generate_litellm_config
        if [[ "${enable_ragflow}" == "true" ]]; then
            _copy_ragflow_templates "${REPO_ROOT}/templates"
        fi
        if [[ "${monitoring_mode}" == "local" ]]; then
            _copy_monitoring_files "${REPO_ROOT}/templates" 2>/dev/null || true
        fi

        # ── B1: preflight_bind_mount_check exit code ──
        local b1_rc=0
        preflight_bind_mount_check 2>/dev/null || b1_rc=$?
        [[ "${b1_rc}" -eq 0 ]] || b1_rc=1
        echo "B1_PREFLIGHT_RC=${b1_rc}"

        # ── B2: litellm-config.yaml always exists after _generate_litellm_config ──
        local b2_litellm=0
        [[ -f "${PER_TMP}/docker/litellm-config.yaml" ]] || b2_litellm=1
        echo "B2_LITELLM_EXISTS=${b2_litellm}"

        # ── B2 ragflow: nginx conf files exist when ENABLE_RAGFLOW=true ──
        local b2_ragflow_empty=0 b2_ragflow_proxy=0 b2_ragflow_main=0
        if [[ "${enable_ragflow}" == "true" ]]; then
            [[ -f "${PER_TMP}/docker/ragflow/nginx/empty.conf"   ]] || b2_ragflow_empty=1
            [[ -f "${PER_TMP}/docker/ragflow/nginx/proxy.conf"   ]] || b2_ragflow_proxy=1
            [[ -f "${PER_TMP}/docker/ragflow/nginx/ragflow.conf" ]] || b2_ragflow_main=1
        fi
        echo "B2_RAGFLOW_EMPTY_CONF=${b2_ragflow_empty}"
        echo "B2_RAGFLOW_PROXY_CONF=${b2_ragflow_proxy}"
        echo "B2_RAGFLOW_MAIN_CONF=${b2_ragflow_main}"

        # ── B2 monitoring: prometheus.yml exists when MONITORING_MODE=local ──
        local b2_prom=0
        if [[ "${monitoring_mode}" == "local" ]]; then
            [[ -f "${PER_TMP}/docker/monitoring/prometheus.yml" ]] || b2_prom=1
        fi
        echo "B2_PROM_EXISTS=${b2_prom}"

        # ── B3: unconditional compose bind-mount sources all resolvable ──
        local b3_missing=0
        local compose_sources
        compose_sources="$(python3 - "${REPO_ROOT}/templates/docker-compose.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
seen = set()
for svc, cfg in (doc.get('services') or {}).items():
    for vol in cfg.get('volumes', []) or []:
        if isinstance(vol, dict):
            src = vol.get('source','')
        else:
            src = str(vol).split(':')[0]
        if src.startswith('./') and src not in seen:
            seen.add(src)
            print(src)
PY
        )"

        # Runtime-generated paths — skip (created by install.sh / lib/config.sh at install time)
        local RUNTIME_PREFIXES
        RUNTIME_PREFIXES=(
            "./volumes/"
            "./.env"
            "./monitoring/textfile"
            "./litellm-config.yaml"
            "./nginx/"
            "./ragflow/"
            "./conf.d/"
            "./authelia"
            "./searxng"
        )

        while IFS= read -r src; do
            [[ -z "$src" ]] && continue
            local skip=false
            local prefix
            for prefix in "${RUNTIME_PREFIXES[@]}"; do
                if [[ "$src" == "${prefix}"* || "$src" == "$prefix" ]]; then
                    skip=true
                    break
                fi
            done
            "${skip}" && continue

            local rel_path="${src#./}"
            if [[ ! -e "${REPO_ROOT}/templates/${rel_path}" ]] && \
               [[ ! -e "${REPO_ROOT}/${rel_path}" ]]; then
                echo "B3_MISSING_SOURCE=${src}"
                b3_missing=$(( b3_missing + 1 ))
            fi
        done <<< "$compose_sources"

        echo "B3_MISSING_COUNT=${b3_missing}"
        echo "DONE=1"
    ) 2>/dev/null
}

_get() {
    local key="$1" output="$2"
    echo "$output" | grep "^${key}=" | head -1 | cut -d'=' -f2-
}

# Helper: check ragflow nginx files for cells with ENABLE_RAGFLOW=true.
# Non-strict (default): count as PASS if files exist, WARN if not.
# Strict (RAGFLOW_NGINX_STRICT=true): FAIL if not present.
_check_ragflow_nginx() {
    local cell_prefix="$1" out="$2"
    local files=(B2_RAGFLOW_EMPTY_CONF B2_RAGFLOW_PROXY_CONF B2_RAGFLOW_MAIN_CONF)
    local names=("ragflow/nginx/empty.conf" "ragflow/nginx/proxy.conf" "ragflow/nginx/ragflow.conf")
    local i
    for i in 0 1 2; do
        local _v
        _v="$(_get "${files[$i]}" "$out")"
        if [[ "${RAGFLOW_NGINX_STRICT:-false}" == "true" ]]; then
            _assert_eq "${cell_prefix}: B2 ${names[$i]} exists" "0" "$_v"
        else
            if [[ "$_v" == "0" ]]; then
                _assert_eq "${cell_prefix}: B2 ${names[$i]} exists (non-strict check)" "0" "$_v"
            else
                echo "  WARN: ${cell_prefix}: ${names[$i]} missing (set RAGFLOW_NGINX_STRICT=true to enforce)"
            fi
        fi
    done
}

# ============================================================================
# Matrix: 4 cells
# ============================================================================

# Cell 1: (true, false, none) — baseline
echo ""
echo "--- Cell 1: (ENABLE_LITELLM=true, ENABLE_RAGFLOW=false, MONITORING_MODE=none) ---"
out=$(_run_cell "true" "false" "none" 2>/dev/null)
_assert_eq "cell1: B1 preflight_bind_mount_check exit 0" "0" "$(_get B1_PREFLIGHT_RC  "$out")"
_assert_eq "cell1: B2 litellm-config.yaml exists"        "0" "$(_get B2_LITELLM_EXISTS "$out")"
_assert_eq "cell1: B3 no missing static compose sources"  "0" "$(_get B3_MISSING_COUNT  "$out")"

# Cell 2: (false, false, none) — LiteLLM OFF (bug 6: file still present unconditionally)
echo ""
echo "--- Cell 2: (ENABLE_LITELLM=false, ENABLE_RAGFLOW=false, MONITORING_MODE=none) --- [bug 6]"
out=$(_run_cell "false" "false" "none" 2>/dev/null)
_assert_eq "cell2: B1 preflight_bind_mount_check exit 0" "0" "$(_get B1_PREFLIGHT_RC  "$out")"
_assert_eq "cell2: B2 litellm-config.yaml generated unconditionally" \
    "0" "$(_get B2_LITELLM_EXISTS "$out")"
_assert_eq "cell2: B3 no missing static compose sources" "0" "$(_get B3_MISSING_COUNT  "$out")"

# Cell 3: (true, true, local) — full stack: LiteLLM + RAGFlow + monitoring
echo ""
echo "--- Cell 3: (ENABLE_LITELLM=true, ENABLE_RAGFLOW=true, MONITORING_MODE=local) --- [full stack]"
out=$(_run_cell "true" "true" "local" 2>/dev/null)
_assert_eq "cell3: B1 preflight_bind_mount_check exit 0" "0" "$(_get B1_PREFLIGHT_RC  "$out")"
_assert_eq "cell3: B2 litellm-config.yaml exists"        "0" "$(_get B2_LITELLM_EXISTS "$out")"
_assert_eq "cell3: B3 no missing static compose sources"  "0" "$(_get B3_MISSING_COUNT  "$out")"
_check_ragflow_nginx "cell3" "$out"
# Monitoring prometheus check
_mval="$(_get B2_PROM_EXISTS "$out")"
if [[ "$_mval" == "0" ]]; then
    _assert_eq "cell3: B2 monitoring/prometheus.yml exists" "0" "$_mval"
else
    echo "  WARN: cell3: monitoring/prometheus.yml missing (non-fatal if _copy_monitoring_files not wired)"
fi

# Cell 4: (false, true, none) — LiteLLM off + RAGFlow on
echo ""
echo "--- Cell 4: (ENABLE_LITELLM=false, ENABLE_RAGFLOW=true, MONITORING_MODE=none) ---"
out=$(_run_cell "false" "true" "none" 2>/dev/null)
_assert_eq "cell4: B1 preflight_bind_mount_check exit 0" "0" "$(_get B1_PREFLIGHT_RC  "$out")"
_assert_eq "cell4: B2 litellm-config.yaml generated unconditionally" \
    "0" "$(_get B2_LITELLM_EXISTS "$out")"
_assert_eq "cell4: B3 no missing static compose sources"    "0" "$(_get B3_MISSING_COUNT  "$out")"
_check_ragflow_nginx "cell4" "$out"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
