#!/usr/bin/env bash
# agmind — AGMind day-2 operations CLI
# Usage: agmind <command> [options]
# Symlinked to /usr/local/bin/agmind during install.
set -euo pipefail

# --- Directory resolution ---
AGMIND_DIR="${AGMIND_DIR:-$(cd "$(dirname "$(realpath "$0")")/.." && pwd)}"
INSTALL_DIR="$AGMIND_DIR"
export INSTALL_DIR
SCRIPTS_DIR="${AGMIND_DIR}/scripts"
COMPOSE_DIR="${AGMIND_DIR}/docker"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
ENV_FILE="${COMPOSE_DIR}/.env"

# --- Source shared libs ---
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/health.sh" 2>/dev/null || {
    echo "ERROR: AGMind not installed at ${AGMIND_DIR}" >&2
    echo "Set AGMIND_DIR if installed elsewhere" >&2
    exit 1
}
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/detect.sh" 2>/dev/null || true

# Colors from health.sh (which sources common.sh patterns)
RED="${RED:-\033[0;31m}"; GREEN="${GREEN:-\033[0;32m}"; YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"; BOLD="${BOLD:-\033[1m}"; NC="${NC:-\033[0m}"

# --- Helpers ---
_require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}Root required. Run: sudo agmind ${1:-}${NC}" >&2; exit 1
    fi
}

_read_env() {
    local key="$1" default="${2:-}"
    [[ -f "$ENV_FILE" ]] && grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "$default"
}

_set_env_var() {
    local key="$1" value="$2"
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}.env file not found: ${ENV_FILE}${NC}" >&2
        return 1
    fi
    if LC_ALL=C grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        LC_ALL=C sed -i "s/^${key}=.*/${key}=${value}/" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

_get_ip() {
    if [[ "$(uname)" == "Darwin" ]]; then
        ipconfig getifaddr en0 2>/dev/null || echo "localhost"
        return
    fi
    # Prefer shared helper from detect.sh (same logic as mDNS publish).
    if declare -F _mdns_get_primary_ip >/dev/null 2>&1; then
        local ip
        ip="$(_mdns_get_primary_ip)"
        [[ -n "$ip" ]] && { echo "$ip"; return; }
    fi
    # Legacy fallback (only if helper missing AND no primary IP found).
    hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
}

# ============================================================================
# STATUS
# ============================================================================

cmd_status() {
    # Thin wrapper. Logic lives in lib/status.sh::status_run (Phase 2).
    # Runtime copy: scripts/status.sh (created by _copy_runtime_files from lib/status.sh).
    # Fallback to repo lib/status.sh for dev mode. lib/doctor.sh is sourced first
    # because lib/status.sh reuses _check / _doctor_peer for the peer-node row.
    # shellcheck source=/dev/null
    source "${SCRIPTS_DIR}/doctor.sh" 2>/dev/null || source "${AGMIND_DIR}/lib/doctor.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${SCRIPTS_DIR}/status.sh" 2>/dev/null \
        || source "${AGMIND_DIR}/lib/status.sh" 2>/dev/null \
        || { echo -e "${RED}status module missing — reinstall AGmind${NC}" >&2; return 1; }
    status_run "$@"
}

# ============================================================================
# DOCTOR
# ============================================================================

cmd_doctor() {
    # Thin wrapper. Logic lives in lib/doctor.sh::doctor_run.
    # Runtime copy: scripts/doctor.sh (created by _copy_runtime_files from lib/doctor.sh).
    # Fallback to repo lib/doctor.sh for dev mode.
    # shellcheck source=/dev/null
    source "${SCRIPTS_DIR}/doctor.sh" 2>/dev/null \
        || source "${AGMIND_DIR}/lib/doctor.sh" 2>/dev/null \
        || { echo -e "${RED}doctor module missing — reinstall AGmind${NC}" >&2; return 1; }
    doctor_run "$@"
}

# ============================================================================
# OPEN
# ============================================================================

cmd_open() {
    # Thin wrapper: source status.sh lazily (provides _status_service_url).
    # Headless (SSH / no display / non-TTY) → print URL; desktop → launch opener + echo URL.
    # shellcheck source=/dev/null
    source "${SCRIPTS_DIR}/status.sh" 2>/dev/null \
        || source "${AGMIND_DIR}/lib/status.sh" 2>/dev/null \
        || { echo -e "${RED}status module missing — reinstall AGmind${NC}" >&2; return 2; }

    # No-arg / --list → print all openable services
    if [[ -z "${1:-}" || "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
        echo "Openable services:"
        local _s _u _label
        for _s in api open-webui grafana portainer ragflow minio litellm notebook; do
            _u="$(_status_service_url "$_s")"
            [[ "$_u" == "—" ]] && continue
            case "$_s" in
                api)       _label="dify" ;;
                open-webui) _label="chat" ;;
                *)         _label="$_s" ;;
            esac
            printf '  %-14s %s\n' "$_label" "$_u"
        done
        return 0
    fi

    # Synonym resolve → canonical name for _status_service_url
    local arg="$1" svc
    case "$arg" in
        dify|agmind-dify)                             svc="api" ;;
        chat|webui|openwebui|open-webui|agmind-chat)  svc="open-webui" ;;
        storage|minio|agmind-storage)                 svc="minio" ;;
        notebook|open-notebook|agmind-notebook)       svc="notebook" ;;
        agmind-*)                                     svc="${arg#agmind-}" ;;
        *)                                            svc="$arg" ;;
    esac

    local url; url="$(_status_service_url "$svc")"
    if [[ "$url" == "—" ]]; then
        echo "Unknown or internal-only service: '${arg}'" >&2
        echo "Available: dify chat grafana portainer ragflow minio litellm notebook" >&2
        return 1
    fi

    # Deployment-state warning (non-fatal — URL is valid once the service is up)
    local st; st="$(_status_docker_state "$svc" 2>/dev/null || echo "unknown")"
    case "$st" in
        disabled|not-installed|exited)
            echo "note: ${svc} is ${st} — start it with 'sudo bash install.sh'" >&2 ;;
    esac

    # Headless detection (D-03): any condition → headless
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]] \
        || [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]] \
        || [[ ! -t 1 ]]; then
        printf '%s\n' "$url"
        return 0
    fi

    # Desktop: try an opener (background, suppress noise), then always echo URL (pipeable)
    if grep -qi microsoft /proc/version 2>/dev/null && command -v wslview >/dev/null 2>&1; then
        wslview "$url" 2>/dev/null &
    elif [[ "$(uname)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
        open "$url" 2>/dev/null &
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" 2>/dev/null &
    fi
    printf '%s\n' "$url"
}

# ============================================================================
# ENDPOINTS
# ============================================================================

cmd_endpoints() {
    # Thin wrapper: source status.sh lazily (provides _status_service_url + _status_docker_state).
    # Prints SERVICE | URL | STATE table; --json for machine-readable output.
    # Exit 0 always (display command).
    # shellcheck source=/dev/null
    source "${SCRIPTS_DIR}/status.sh" 2>/dev/null \
        || source "${AGMIND_DIR}/lib/status.sh" 2>/dev/null \
        || { echo -e "${RED}status module missing — reinstall AGmind${NC}" >&2; return 0; }

    local json_mode=0
    [[ "${1:-}" == "--json" ]] && json_mode=1

    # Not installed → graceful message (D-05)
    if ! _status_installed 2>/dev/null; then
        if [[ "$json_mode" -eq 1 ]]; then
            printf '{"installed":false,"endpoints":[]}\n'
        else
            echo "AGmind not installed — run: sudo bash install.sh" >&2
        fi
        return 0
    fi

    # Build rows: label<TAB>url<TAB>state for each public service
    local _s _u _st _label
    local -a _rows=()
    for _s in api open-webui grafana portainer ragflow minio litellm notebook; do
        _u="$(_status_service_url "$_s")"
        [[ "$_u" == "—" ]] && continue
        _st="$(_status_docker_state "$_s" 2>/dev/null || echo "not-installed")"
        case "$_s" in
            api)       _label="dify" ;;
            open-webui) _label="chat" ;;
            *)         _label="$_s" ;;
        esac
        _rows+=("${_label}"$'\t'"${_u}"$'\t'"${_st}")
    done

    if [[ "$json_mode" -eq 1 ]]; then
        # Use python3 for safe JSON (same pattern as _status_render_json)
        printf '%s\n' "${_rows[@]}" | python3 -c '
import json, sys, subprocess, datetime, re
eps = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    svc, url, state = parts[0], parts[1], parts[2]
    port = ""
    m = re.search(r":(\d+)(?:/|$)", url.split("//", 1)[-1])
    if m:
        port = m.group(1)
    eps.append({"service": svc, "url": url, "port": port, "state": state})
host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
print(json.dumps({
    "generated_at": datetime.datetime.utcnow().isoformat() + "Z",
    "hostname": host,
    "installed": True,
    "endpoints": eps
}))
'
        return 0
    fi

    # Human table
    printf '%-14s  %-44s  %s\n' "SERVICE" "URL" "STATE"
    local _r _svc _url _st2 _col
    for _r in "${_rows[@]}"; do
        IFS=$'\t' read -r _svc _url _st2 <<< "$_r"
        _col="$(_status_state_color "$_st2" 2>/dev/null || true)"
        printf '%-14s  %-44s  %b%s%b\n' "$_svc" "$_url" "${_col}" "$_st2" "${NC}"
    done
    return 0
}

# ============================================================================
# CREDS SHOW  (thin wrapper — logic in lib/creds.sh::creds_show)
# ============================================================================

cmd_creds_show() {
    # Lazy-source creds.sh (runtime copy in scripts/; dev fallback to lib/).
    # shellcheck source=/dev/null
    source "${SCRIPTS_DIR}/creds.sh" 2>/dev/null \
        || source "${AGMIND_DIR}/lib/creds.sh" 2>/dev/null \
        || { echo -e "${RED}creds module missing — reinstall AGmind${NC}" >&2; return 2; }
    creds_show "$@"
}

# ============================================================================
# SECURITY AUDIT
# ============================================================================

cmd_security() {
    # `agmind security audit [--json]` — read-only scanner. Logic in lib/security.sh::security_audit.
    # Runtime copy: scripts/security.sh (from _copy_runtime_files). Dev fallback: lib/security.sh.
    # lib/doctor.sh sourced first because security_audit reuses doctor_check_security_exposure.
    # shellcheck source=/dev/null
    source "${SCRIPTS_DIR}/doctor.sh" 2>/dev/null || source "${AGMIND_DIR}/lib/doctor.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${SCRIPTS_DIR}/security.sh" 2>/dev/null \
        || source "${AGMIND_DIR}/lib/security.sh" 2>/dev/null \
        || { echo -e "${RED}security module missing — reinstall AGmind${NC}" >&2; return 1; }
    # subcommand: only `audit` for now
    local sub="${1:-audit}"
    case "$sub" in
        audit) shift 2>/dev/null || true; security_audit "$@" ;;
        *)     echo "Usage: agmind security audit [--json]" >&2; return 1 ;;
    esac
}

# ============================================================================
# STOP / START / RESTART
# ============================================================================

cmd_stop() {
    _require_root stop
    cd "$COMPOSE_DIR"
    echo -e "${YELLOW}Stopping AGMind...${NC}"
    COMPOSE_PROFILES=monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei \
        docker compose stop
    echo -e "${GREEN}Stopped${NC}"
}

cmd_start() {
    _require_root start
    cd "$COMPOSE_DIR"
    echo -e "${YELLOW}Starting AGMind...${NC}"
    # Read profiles from .env to start only configured services
    docker compose up -d
    echo -e "${GREEN}Started${NC}"
}

cmd_restart() {
    _require_root restart
    cd "$COMPOSE_DIR"
    echo -e "${YELLOW}Restarting AGMind...${NC}"
    COMPOSE_PROFILES=monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei \
        docker compose restart
    echo -e "${GREEN}Restarted${NC}"
}

# Compare pinned versions in versions.env (template) vs currently-running
# container images. Read-only — никаких изменений на стек. Полезно ДО запуска
# `agmind update` или `bash install.sh` чтобы увидеть какие сервисы получат
# bump. Не предлагает варианты автоматического update — это делает agmind update.
cmd_upgrade_diff() {
    # Source of truth для current pinned versions: /opt/agmind/docker/.env
    # (записан _copy_versions при install). Альтернатива:
    # /opt/agmind/templates/versions.env (template snapshot). docker/.env
    # содержит реальный state применённый к compose (после _copy_versions
    # appends VERSION lines в конец файла).
    local versions_file="${INSTALL_DIR:-/opt/agmind}/docker/.env"
    if [[ ! -f "$versions_file" ]]; then
        echo -e "${RED}.env not found: ${versions_file}${NC}" >&2
        echo "Run install.sh first or check INSTALL_DIR." >&2
        exit 1
    fi
    # Map version key → container name(s). Только сервисы с docker compose image-tag,
    # SOPS/MC binary исключены (они контролируются install.sh hooks).
    local -A KEY_TO_CONTAINER=(
        [DIFY_VERSION]="agmind-api"
        [OPENWEBUI_VERSION]="agmind-openwebui"
        [POSTGRES_VERSION]="agmind-db"
        [REDIS_VERSION]="agmind-redis"
        [WEAVIATE_VERSION]="agmind-weaviate"
        [QDRANT_VERSION]="agmind-qdrant"
        [SANDBOX_VERSION]="agmind-sandbox"
        [SQUID_VERSION]="agmind-ssrf-proxy"
        [NGINX_VERSION]="agmind-nginx"
        [MINIO_VERSION]="agmind-minio"
        [PLUGIN_DAEMON_VERSION]="agmind-plugin-daemon"
        [LITELLM_VERSION]="agmind-litellm"
        [SEARXNG_VERSION]="agmind-searxng"
        [SURREALDB_VERSION]="agmind-surrealdb"
        [OPEN_NOTEBOOK_VERSION]="agmind-notebook"
        [DBGPT_VERSION]="agmind-dbgpt"
        [CRAWL4AI_VERSION]="agmind-crawl4ai"
        [AUTHELIA_VERSION]="agmind-authelia"
        [GRAFANA_VERSION]="agmind-grafana"
        [PORTAINER_VERSION]="agmind-portainer"
        [NODE_EXPORTER_VERSION]="agmind-node-exporter"
        [CADVISOR_VERSION]="agmind-cadvisor"
        [REDIS_EXPORTER_VERSION]="agmind-redis-exporter"
        [POSTGRES_EXPORTER_VERSION]="agmind-postgres-exporter"
        [NGINX_EXPORTER_VERSION]="agmind-nginx-exporter"
        [PROMETHEUS_VERSION]="agmind-prometheus"
        [ALERTMANAGER_VERSION]="agmind-alertmanager"
        [LOKI_VERSION]="agmind-loki"
        [ALLOY_VERSION]="agmind-alloy"
    )
    echo -e "${BOLD}AGMind version diff — pinned (versions.env) vs live (container)${NC}"
    echo ""
    printf "%-28s %-30s %-30s %s\n" "VARIABLE" "PINNED" "LIVE" "STATUS"
    printf "%-28s %-30s %-30s %s\n" "--------" "------" "----" "------"
    local key cname pinned live status
    local out_of_sync=0
    local not_deployed=0
    local rows=""
    for key in "${!KEY_TO_CONTAINER[@]}"; do
        cname="${KEY_TO_CONTAINER[$key]}"
        pinned="$(grep "^${key}=" "$versions_file" 2>/dev/null | head -1 | cut -d'=' -f2-)"
        if [[ -z "$pinned" ]]; then continue; fi
        live="$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null | awk -F: '{print $NF}' || true)"
        if [[ -z "$live" ]]; then
            status="${YELLOW}NOT DEPLOYED${NC}"
            not_deployed=$((not_deployed+1))
        elif [[ "$live" == "$pinned" ]] || [[ "$pinned" == *"$live"* ]] || [[ "$live" == *"$pinned"* ]]; then
            status="${GREEN}OK${NC}"
        else
            status="${YELLOW}DRIFT${NC}"
            out_of_sync=$((out_of_sync+1))
        fi
        rows+="$(printf '%-28s %-30s %-30s %b' "$key" "$pinned" "${live:--}" "$status")"$'\n'
    done
    printf '%s' "$rows" | sort
    echo ""
    if [[ $out_of_sync -gt 0 ]]; then
        echo -e "${YELLOW}${out_of_sync} services drift from pinned versions.${NC}"
        echo "To apply: edit /opt/agmind/docker/.env (or rerun install.sh) + per-service docker compose up -d"
    else
        echo -e "${GREEN}All deployed services match pinned versions${NC} (not deployed: ${not_deployed})"
    fi
}

# ============================================================================
# PLUGIN DAEMON ONLINE / OFFLINE TOGGLE
# Default install: ONLINE (MARKETPLACE_ENABLED=true) — большинство юзеров
# ставят плагины из marketplace.dify.ai (включая witmeng/ragflow-api для RAGFlow).
# Выключить при критичном supply-chain risk: agmind plugins offline.
# Uses `docker restart` (NOT recreate) to preserve plugin daemon state per
# CLAUDE.md §8 force-recreate trap (avoids stale Redis/Celery cleanup risk).
# ============================================================================

cmd_plugins() {
    local sub="${1:-status}"
    case "$sub" in
        online|on|enable)
            _require_root "plugins online"
            echo -e "${YELLOW}Enabling Dify marketplace (MARKETPLACE_ENABLED=true)...${NC}"
            _set_env_var MARKETPLACE_ENABLED true
            docker restart agmind-api agmind-plugin-daemon >/dev/null
            echo -e "${GREEN}Plugin daemon ONLINE — marketplace.dify.ai accessible${NC}"
            echo -e "${YELLOW}Reminder: marketplace plugins run as root in plugin_daemon — install only trusted${NC}"
            ;;
        offline|off|disable)
            _require_root "plugins offline"
            echo -e "${YELLOW}Disabling Dify marketplace (MARKETPLACE_ENABLED=false)...${NC}"
            _set_env_var MARKETPLACE_ENABLED false
            docker restart agmind-api agmind-plugin-daemon >/dev/null
            echo -e "${GREEN}Plugin daemon OFFLINE — local .difypkg upload still works${NC}"
            ;;
        status|"")
            # .env is mode 600 root:root — _read_env silently falls back to default
            # without sudo. Use sudo -n explicitly so status is honest with NOPASSWD,
            # falls back to default with clear UX otherwise.
            local current
            if [[ -r "$ENV_FILE" ]]; then
                current="$(_read_env MARKETPLACE_ENABLED "true")"
            else
                current="$(sudo -n grep '^MARKETPLACE_ENABLED=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo 'unknown')"
                [[ -z "$current" ]] && current="unknown"
            fi
            local mode_label color
            case "$current" in
                true)    mode_label="ONLINE (marketplace.dify.ai accessible)"; color="$YELLOW" ;;
                false)   mode_label="OFFLINE (только локальные .difypkg)"; color="$YELLOW" ;;
                unknown) mode_label="UNKNOWN (run with sudo to read .env)";       color="$RED" ;;
                *)       mode_label="UNEXPECTED ($current)";                       color="$RED" ;;
            esac
            echo -e "Plugin daemon: ${color}${mode_label}${NC}"
            echo "  MARKETPLACE_ENABLED=${current}"
            local pd_status; pd_status="$(docker ps --filter 'name=agmind-plugin-daemon' --format '{{.Status}}' 2>/dev/null | head -1)"
            echo "  Container:           ${pd_status:-not running}"
            ;;
        *)
            echo -e "${RED}Unknown plugins subcommand: ${sub}${NC}" >&2
            echo "Usage: agmind plugins [online|offline|status]" >&2
            exit 1
            ;;
    esac
}

# ============================================================================
# GPU MANAGEMENT
# ============================================================================

_gpu_status() {
    # Check nvidia-smi availability
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "${RED}nvidia-smi not found. NVIDIA GPU required for gpu status.${NC}" >&2
        return 1
    fi

    echo -e "\n${BOLD}${CYAN}=========================================${NC}"
    echo -e "${BOLD}${CYAN}  GPU Status${NC}"
    echo -e "${BOLD}${CYAN}=========================================${NC}\n"

    # Per-GPU info table
    echo -e "${BOLD}GPUs:${NC}"
    local gpu_idx=0
    while IFS=',' read -r name mem_total mem_used mem_free util_gpu; do
        name="$(echo "$name" | xargs)"
        mem_total="$(echo "$mem_total" | xargs)"
        mem_used="$(echo "$mem_used" | xargs)"
        mem_free="$(echo "$mem_free" | xargs)"
        util_gpu="$(echo "$util_gpu" | xargs)"
        # Unified memory fallback: nvidia-smi returns [N/A] on DGX Spark
        local unified_label=""
        if [[ "$mem_total" == *"N/A"* || -z "$mem_total" ]]; then
            local meminfo_total meminfo_avail
            meminfo_total=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
            meminfo_avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
            mem_total="$meminfo_total"
            mem_used="$((meminfo_total - meminfo_avail))"
            mem_free="$meminfo_avail"
            unified_label=" (unified)"
        fi
        printf "  GPU %d: %-30s | VRAM: %s / %s MiB%s (free: %s MiB) | Util: %s\n" \
            "$gpu_idx" "$name" "$mem_used" "$mem_total" "$unified_label" "$mem_free" "$util_gpu"
        gpu_idx=$((gpu_idx + 1))
    done < <(nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null)

    if [[ $gpu_idx -eq 0 ]]; then
        echo "  No NVIDIA GPUs detected"
        return 1
    fi
    echo ""

    # Container-GPU assignment from .env
    echo -e "${BOLD}Container Assignments:${NC}"
    local vllm_dev tei_dev
    vllm_dev="$(_read_env VLLM_CUDA_DEVICE "0")"
    tei_dev="$(_read_env TEI_CUDA_DEVICE "0")"
    local llm_prov embed_prov
    llm_prov="$(_read_env LLM_PROVIDER "unknown")"
    embed_prov="$(_read_env EMBED_PROVIDER "unknown")"

    if [[ "$llm_prov" == "vllm" ]]; then
        echo -e "  vLLM           -> GPU ${BOLD}${vllm_dev}${NC}  (VLLM_CUDA_DEVICE=${vllm_dev})"
    else
        echo -e "  vLLM           -> ${YELLOW}not active (LLM_PROVIDER=${llm_prov})${NC}"
    fi
    if [[ "$embed_prov" == "tei" ]]; then
        echo -e "  TEI            -> GPU ${BOLD}${tei_dev}${NC}  (TEI_CUDA_DEVICE=${tei_dev})"
    else
        echo -e "  TEI            -> ${YELLOW}not active (EMBED_PROVIDER=${embed_prov})${NC}"
    fi
    echo ""

    # GPU processes with container name mapping
    echo -e "${BOLD}GPU Processes:${NC}"

    # Build PID -> container map via docker top
    declare -A pid_container_map
    local compose_file="${INSTALL_DIR:-/opt/agmind}/docker/docker-compose.yml"
    while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        while read -r cpid; do
            [[ -z "$cpid" ]] && continue
            pid_container_map["$cpid"]="$cname"
        done < <(docker top "$cname" -o pid 2>/dev/null | tail -n +2 | xargs -n1)
    done < <(docker compose -f "$compose_file" ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}}' 2>/dev/null | sed 's|^/||')

    # Read model names from .env for annotation
    local vllm_model tei_model
    vllm_model="$(_read_env VLLM_MODEL "")"
    tei_model="$(_read_env EMBEDDING_MODEL "")"

    local proc_output
    proc_output="$(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
        --format=csv,noheader,nounits 2>/dev/null || true)"
    if [[ -z "$proc_output" ]]; then
        echo "  No GPU compute processes running"
    else
        while IFS=',' read -r _uuid pid pname pmem; do
            pid="$(echo "$pid" | xargs)"
            pname="$(echo "$pname" | xargs)"
            pmem="$(echo "$pmem" | xargs)"
            local container="${pid_container_map[$pid]:-}"
            if [[ -n "$container" ]]; then
                # Determine model name based on container
                local model_info=""
                if [[ "$container" == *vllm* && -n "$vllm_model" ]]; then
                    model_info=" ($vllm_model)"
                elif [[ "$container" == *tei* && -n "$tei_model" ]]; then
                    model_info=" ($tei_model)"
                fi
                printf "  %-30s | %s MiB\n" "${container}${model_info}" "$pmem"
            else
                printf "  PID %-8s | %-20s | %s MiB  (non-agmind)\n" "$pid" "$pname" "$pmem"
            fi
        done <<< "$proc_output"
    fi
    echo ""
}

_gpu_auto_assign() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "${RED}nvidia-smi not found. Cannot auto-assign GPUs.${NC}" >&2
        return 1
    fi

    local gpu_count
    gpu_count="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"

    if [[ "$gpu_count" -eq 0 ]]; then
        echo -e "${RED}No NVIDIA GPUs detected.${NC}" >&2
        return 1
    fi

    if [[ "$gpu_count" -eq 1 ]]; then
        echo -e "${YELLOW}Single GPU detected, all services on GPU 0${NC}"
        _set_env_var "VLLM_CUDA_DEVICE" "0"
        _set_env_var "TEI_CUDA_DEVICE" "0"
        echo -e "${GREEN}Set VLLM_CUDA_DEVICE=0, TEI_CUDA_DEVICE=0${NC}"
        echo -e "${YELLOW}Restart required: sudo agmind restart${NC}"
        return 0
    fi

    # Multi-GPU: vLLM gets GPU with most free VRAM, TEI gets GPU with least free VRAM
    local biggest_gpu=0 biggest_free=0
    local smallest_gpu=0 smallest_free=999999
    local idx=0
    while IFS=',' read -r name mem_free; do
        mem_free="$(echo "$mem_free" | xargs)"
        if [[ "$mem_free" -gt "$biggest_free" ]]; then
            biggest_free="$mem_free"
            biggest_gpu="$idx"
        fi
        if [[ "$mem_free" -lt "$smallest_free" ]]; then
            smallest_free="$mem_free"
            smallest_gpu="$idx"
        fi
        idx=$((idx + 1))
    done < <(nvidia-smi --query-gpu=name,memory.free --format=csv,noheader,nounits 2>/dev/null)

    # If same GPU selected for both (e.g., all GPUs equal), spread across 0 and 1
    if [[ "$biggest_gpu" -eq "$smallest_gpu" && "$gpu_count" -ge 2 ]]; then
        biggest_gpu=0
        smallest_gpu=1
    fi

    _set_env_var "VLLM_CUDA_DEVICE" "$biggest_gpu"
    _set_env_var "TEI_CUDA_DEVICE" "$smallest_gpu"

    echo -e "${GREEN}Auto-assigned:${NC}"
    echo -e "  vLLM -> GPU ${biggest_gpu} (${biggest_free} MiB free)"
    echo -e "  TEI  -> GPU ${smallest_gpu} (${smallest_free} MiB free)"
    echo -e "${YELLOW}Restart required: sudo agmind restart${NC}"
}

_gpu_assign() {
    _require_root "gpu assign"

    local service="${1:-}"
    local gpu_id="${2:-}"

    # --auto mode
    if [[ "$service" == "--auto" ]]; then
        _gpu_auto_assign
        return $?
    fi

    # Validate service name
    local env_var=""
    case "$service" in
        vllm)        env_var="VLLM_CUDA_DEVICE" ;;
        tei)         env_var="TEI_CUDA_DEVICE" ;;
        *)
            echo -e "${RED}Unknown service: ${service}${NC}" >&2
            echo "Valid services: vllm, tei" >&2
            return 1
            ;;
    esac

    # Validate gpu_id is a number
    if [[ -z "$gpu_id" ]]; then
        echo -e "${RED}Usage: agmind gpu assign <service> <gpu_id>${NC}" >&2
        echo "       agmind gpu assign --auto" >&2
        return 1
    fi
    if ! [[ "$gpu_id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid GPU ID: ${gpu_id} (must be a number)${NC}" >&2
        return 1
    fi

    # Validate GPU exists
    if command -v nvidia-smi &>/dev/null; then
        local gpu_count
        gpu_count="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)"
        if [[ "$gpu_id" -ge "$gpu_count" ]]; then
            echo -e "${RED}GPU ${gpu_id} does not exist. Found ${gpu_count} GPU(s) (0-$((gpu_count - 1))).${NC}" >&2
            return 1
        fi
    fi

    # Update .env
    _set_env_var "$env_var" "$gpu_id"

    echo -e "${GREEN}Set ${env_var}=${gpu_id} in ${ENV_FILE}${NC}"
    echo -e "${YELLOW}Restart required: sudo agmind restart${NC}"
}

cmd_gpu() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true
    case "$subcmd" in
        status)  _gpu_status ;;
        assign)  _gpu_assign "$@" ;;
        *)       echo -e "${RED}Unknown gpu subcommand: ${subcmd}${NC}" >&2
                 echo "Usage: agmind gpu {status|assign}" >&2
                 return 1 ;;
    esac
}

# ============================================================================
# MODEL — list loaded models across inference containers
# ============================================================================

cmd_model() {
    local subcmd="${1:-list}"
    case "$subcmd" in
        list) _model_list ;;
        *)    echo "Usage: agmind model list" >&2; exit 1 ;;
    esac
}

_model_list() {
    echo -e "${BOLD}Loaded Models:${NC}"
    echo ""

    # LLM models (vLLM)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'agmind-vllm$'; then
        echo -e "  ${CYAN}vLLM (LLM):${NC}"
        docker exec agmind-vllm curl -sf http://localhost:8000/v1/models 2>/dev/null \
            | python3 -c "import sys,json; [print(f'    {m[\"id\"]}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null \
            || echo "    (loading or unavailable)"
    fi

    # Ollama models
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'agmind-ollama'; then
        echo -e "  ${CYAN}Ollama:${NC}"
        docker exec agmind-ollama ollama list 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
    fi

    # Embedding models (vLLM)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'agmind-vllm-embed'; then
        echo -e "  ${CYAN}vLLM (Embed):${NC}"
        docker exec agmind-vllm-embed curl -sf http://localhost:8000/v1/models 2>/dev/null \
            | python3 -c "import sys,json; [print(f'    {m[\"id\"]}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null \
            || echo "    (loading or unavailable)"
    fi

    # Reranker models (vLLM)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'agmind-vllm-rerank'; then
        echo -e "  ${CYAN}vLLM (Rerank):${NC}"
        docker exec agmind-vllm-rerank curl -sf http://localhost:8000/v1/models 2>/dev/null \
            | python3 -c "import sys,json; [print(f'    {m[\"id\"]}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null \
            || echo "    (loading or unavailable)"
    fi
}

# ============================================================================
# INIT-DIFY — manual Dify admin initialization
# ============================================================================

cmd_init_dify() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}.env not found: ${ENV_FILE}${NC}" >&2
        exit 1
    fi

    # Prevent parallel init-dify runs (flock)
    local lock_file="/var/lock/agmind-init-dify.lock"
    if [[ "$(uname)" != "Darwin" ]]; then
        exec 8>"$lock_file"
        if ! flock -n 8; then
            echo -e "${RED}Another init-dify is already running${NC}" >&2
            exit 1
        fi
    fi

    if [[ -f "${AGMIND_DIR}/.dify_initialized" ]]; then
        echo -e "${GREEN}Dify already initialized${NC}"
        echo "  To re-initialize, remove ${AGMIND_DIR}/.dify_initialized and retry."
        return 0
    fi

    local init_password
    init_password="$(grep '^INIT_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)"
    if [[ -z "$init_password" ]]; then
        echo -e "${RED}INIT_PASSWORD not found in .env${NC}" >&2
        return 1
    fi

    local admin_password
    admin_password="$(echo "$init_password" | base64 -d 2>/dev/null || echo "$init_password")"

    # Check API health
    echo "Checking Dify API health..."
    if ! docker exec agmind-api curl -sf http://localhost:5001/health >/dev/null 2>&1; then
        echo -e "${RED}Dify API is not healthy. Wait for it to start or check logs:${NC}"
        echo "  agmind logs api"
        return 1
    fi

    echo "Initializing Dify admin..."
    local resp
    resp="$(docker exec \
        -e "INIT_PWD=${init_password}" \
        -e "ADMIN_PWD=${admin_password}" \
        agmind-api sh -c '
            curl -sf -c /tmp/dify_cookies \
                -H "Content-Type: application/json" \
                -d "{\"password\":\"$INIT_PWD\"}" \
                http://localhost:5001/console/api/init >/dev/null 2>&1
            curl -sf -b /tmp/dify_cookies \
                -H "Content-Type: application/json" \
                -d "{\"email\":\"admin@agmind.ai\",\"name\":\"AGMind Admin\",\"password\":\"$ADMIN_PWD\"}" \
                http://localhost:5001/console/api/setup 2>/dev/null
            rm -f /tmp/dify_cookies
        ' 2>&1)" || true

    if echo "$resp" | grep -qi '"result"\|"id"\|"token"\|success'; then
        echo -e "${GREEN}Dify admin initialized successfully${NC}"
        touch "${AGMIND_DIR}/.dify_initialized"
    elif echo "$resp" | grep -qi "already\|initialized\|repeat"; then
        echo -e "${GREEN}Dify already initialized${NC}"
        touch "${AGMIND_DIR}/.dify_initialized"
    else
        echo -e "${RED}Dify init failed:${NC} $(echo "$resp" | head -c 300)"
        echo ""
        echo "Troubleshooting:"
        echo "  1) Check API logs: agmind logs api"
        echo "  2) Verify API health: docker exec agmind-api curl -sf http://localhost:5001/health"
        echo "  3) Try manual init: open http://<host>:3000/install"
        echo "     Init password: grep INIT_PASSWORD ${ENV_FILE} | cut -d= -f2-"
        return 1
    fi
}

# ============================================================================
# LOADTEST — k6 scenarios runner (Phase 40)
# ============================================================================

cmd_loadtest() {
    local sub="${1:-help}"
    shift || true

    local results_dir="${AGMIND_DIR}/docker/volumes/loadtest"
    mkdir -p "$results_dir" 2>/dev/null || true

    case "$sub" in
        list|ls)
            echo -e "${BOLD}Available scenarios:${NC}"
            for f in "${SCRIPTS_DIR}/loadtest"/*.js; do
                [[ -e "$f" ]] || continue
                local name
                name="$(basename "$f" .js)"
                local desc
                desc="$(head -2 "$f" | tail -1 | sed 's|^// ||')"
                printf "  %-20s %s\n" "$name" "$desc"
            done
            ;;
        last)
            echo -e "${BOLD}Recent results:${NC}"
            ls -lt "$results_dir"/*.json 2>/dev/null | head -5 | awk '{print "  "$9" ("$5" bytes, "$6" "$7" "$8")"}'
            ;;
        chat|embed|kb|dify-chat)
            local scenario="chat-baseline"
            case "$sub" in
                chat)      scenario="chat-baseline" ;;
                embed)     scenario="embed-burst" ;;
                kb)        scenario="kb-indexing" ;;
                dify-chat) scenario="dify-chat" ;;
            esac
            local scenario_file="${SCRIPTS_DIR}/loadtest/${scenario}.js"
            if [[ ! -f "$scenario_file" ]]; then
                echo -e "${RED}Scenario not found: ${scenario_file}${NC}" >&2
                exit 1
            fi
            local ts; ts="$(date +%Y%m%d-%H%M%S)"
            local result_file="${results_dir}/${scenario}-${ts}.json"
            echo -e "${BOLD}Running: ${scenario}${NC}"
            echo -e "Result will be saved to: ${result_file}"
            # Pass through remaining args (e.g. --duration 30s --vus 2).
            # k6 returns non-zero on threshold breach — don't let `set -e` kill us
            # before we move the summary file.
            local rc=0
            # Pass through user-provided DIFY_* / VLLM_* / MODEL env so k6 scripts see them
            local env_args=()
            for v in DIFY_URL DIFY_APP_TOKEN DIFY_TOKEN DATASET_ID VLLM_URL EMBED_URL MODEL EMBED_MODEL; do
                if [[ -n "${!v:-}" ]]; then env_args+=(-e "${v}=${!v}"); fi
            done
            docker compose -f "$COMPOSE_FILE" --profile loadtest run --rm \
                ${env_args[@]+"${env_args[@]}"} \
                k6 run "$@" "/scripts/${scenario}.js" || rc=$?
            if [[ -f "${results_dir}/summary.json" ]]; then
                mv "${results_dir}/summary.json" "$result_file"
                echo -e "${GREEN}Result saved: ${result_file}${NC}"
            else
                echo -e "${YELLOW}No summary.json produced (rc=${rc})${NC}"
            fi
            return "$rc"
            ;;
        help|--help|-h|*)
            cat <<'LTHELP'
Usage: agmind loadtest <subcommand> [k6 options]

Subcommands:
  list             List available scenarios
  chat             Run chat-baseline.js (direct vLLM chat completions)
  embed            Run embed-burst.js (sustained embed load)
  kb               Run kb-indexing.js (Dify KB upload; requires DIFY_TOKEN env)
  last             Show 5 most recent result files

Common k6 options (after subcommand):
  --duration 30s   Override stage duration (smoke test)
  --vus 2          Override peak virtual users
  --iterations 10  Run N total iterations instead of stages

Examples:
  agmind loadtest list
  agmind loadtest chat --duration 30s --vus 2     # 30s smoke test
  agmind loadtest embed                            # full ramp
  DIFY_TOKEN=<jwt> DATASET_ID=<uuid> agmind loadtest kb
LTHELP
            ;;
    esac
}

# ============================================================================
# HELP
# ============================================================================

cmd_ragflow() {
    local sub="${1:-status}"; shift || true
    # Detect by container, not .env (chmod 600 — non-root user читает default=false).
    if ! docker ps --filter 'name=agmind-ragflow$' --format '{{.Names}}' 2>/dev/null | grep -q '^agmind-ragflow$'; then
        echo -e "${YELLOW}RAGFlow disabled (контейнер agmind-ragflow не запущен).${NC}"
        echo "Enable: re-run install.sh and select ragflow в чек-листе optional services."
        [[ "$sub" == "status" || "$sub" == "version" ]] && exit 0 || exit 1
    fi

    case "$sub" in
        status)
            docker ps --filter 'name=agmind-ragflow' --format 'table {{.Names}}\t{{.Status}}' || true
            ;;
        logs)
            local svc="${1:-ragflow}"; shift || true
            local cname="agmind-${svc}"
            [[ "$svc" == "ragflow" ]] && cname="agmind-ragflow"
            [[ "$svc" == "mysql" || "$svc" == "ragflow_mysql" ]] && cname="agmind-ragflow-mysql"
            [[ "$svc" == "es" || "$svc" == "ragflow_es01" ]] && cname="agmind-ragflow-es"
            exec docker logs -f --tail 100 "$cname" "$@"
            ;;
        version)
            docker exec agmind-ragflow curl -fsS http://localhost:9380/v1/system/version 2>/dev/null \
                || { echo "ragflow API not reachable" >&2; exit 1; }
            echo ""
            ;;
        query)
            local q="${1:-}"
            [[ -z "$q" ]] && { echo "Usage: agmind ragflow query <text>" >&2; exit 1; }
            local key dset
            key="$(grep '^RAGFLOW_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2-)"
            dset="$(grep '^RAGFLOW_DATASET_ID=' "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2-)"
            if [[ -z "$key" || -z "$dset" ]]; then
                echo "RAGFLOW_API_KEY и RAGFLOW_DATASET_ID должны быть в ${ENV_FILE}." >&2
                echo "Создай через RAGFlow UI → Profile → API → API Keys, прописать в .env." >&2
                exit 1
            fi
            docker exec agmind-ragflow curl -fsS \
                -H "Authorization: Bearer ${key}" \
                -H "Content-Type: application/json" \
                -X POST "http://localhost:9380/api/v1/dify/retrieval" \
                -d "{\"knowledge_id\":\"${dset}\",\"query\":\"${q}\",\"retrieval_setting\":{\"top_k\":5,\"score_threshold\":0.3}}"
            echo ""
            ;;
        keys)
            # Diagnostic: show whether key+dataset prописаны (без значений секретов).
            local key dset
            key="$(grep '^RAGFLOW_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2-)"
            dset="$(grep '^RAGFLOW_DATASET_ID=' "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2-)"
            echo "RAGFLOW_API_KEY:    $([[ -n "$key" ]] && echo SET || echo UNSET)"
            echo "RAGFLOW_DATASET_ID: $([[ -n "$dset" ]] && echo SET || echo UNSET)"
            ;;
        restart)
            _require_root "ragflow restart"
            cd "$(dirname "$COMPOSE_FILE")"
            docker compose restart ragflow ragflow_mysql ragflow_es01
            ;;
        backup)
            _require_root "ragflow backup"
            exec "${SCRIPTS_DIR}/backup.sh" --component ragflow "$@"
            ;;
        es-health)
            local pw
            pw="$(grep '^RAGFLOW_ES_PASSWORD=' "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2-)"
            [[ -z "$pw" ]] && { echo "RAGFLOW_ES_PASSWORD missing" >&2; exit 1; }
            docker exec agmind-ragflow-es curl -fsS -u "elastic:${pw}" \
                "http://localhost:9200/_cluster/health?pretty" 2>/dev/null \
                || { echo "ES not reachable" >&2; exit 1; }
            ;;
        *)
            cat >&2 <<EOF
Usage: agmind ragflow <subcommand>
  status              Show 3 ragflow containers status
  logs [svc]          Tail logs (svc: ragflow|mysql|es; default ragflow)
  version             Print RAGFlow API version
  query <text>        Test retrieval against RAGFLOW_DATASET_ID
  keys                Check RAGFLOW_API_KEY/DATASET_ID env присутствие
  restart             Restart ragflow + mysql + es (root)
  backup              Backup ragflow stack only (root)
  es-health           ES cluster health (raw JSON)
EOF
            exit 1
            ;;
    esac
}

cmd_plugin_daemon() {
    local sub="${1:-status}"
    case "$sub" in
        status)
            local state
            state="$(docker inspect -f '{{.State.Status}} ({{.State.Health.Status}})' agmind-plugin-daemon 2>/dev/null || echo 'absent')"
            echo "agmind-plugin-daemon: $state"
            ;;
        stop)
            _require_root "plugin-daemon stop"
            cd "$(dirname "$COMPOSE_FILE")"
            echo -e "${YELLOW}Stopping plugin_daemon...${NC}"
            docker compose stop plugin_daemon
            echo -e "${YELLOW}Внимание: Dify плагины (LLM-провайдеры, RAGFlow коннектор и др.) больше не работают.${NC}"
            ;;
        start)
            _require_root "plugin-daemon start"
            cd "$(dirname "$COMPOSE_FILE")"
            docker compose start plugin_daemon
            echo -e "${GREEN}plugin_daemon запущен${NC}"
            ;;
        restart)
            _require_root "plugin-daemon restart"
            cd "$(dirname "$COMPOSE_FILE")"
            docker compose restart plugin_daemon
            ;;
        logs)
            docker logs --tail 100 -f agmind-plugin-daemon
            ;;
        *)
            cat >&2 <<EOF
Usage: agmind plugin-daemon <subcommand>
  status    State + health (default)
  stop      Остановить daemon (Dify плагины перестанут работать)
  start     Запустить daemon
  restart   Restart
  logs      Tail logs
EOF
            exit 1
            ;;
    esac
}

cmd_help() {
    cat <<'HELP'
Usage: agmind <command> [options]

Commands:
  status [--json] [--watch [N]] [--service <name>]   Show stack overview table
    (no args)           4-col table: SERVICE | STATE | URL | NOTES, grouped, colored
    --json              Machine-readable JSON (services array + overall + gpu + endpoints)
    --watch [N]         Live refresh every N seconds (default 2; no flicker; Ctrl-C to exit)
    --service <name>    Details for one service (model/RestartCount/GPU mem/logs); exit 0=healthy 1=not
  doctor [--peer] [--json] [--fix [--dry-run]] [--bundle]   Run system diagnostics
    --peer              Only the peer-node section
    --json              Machine-readable JSON output
    --fix               Auto-fix idempotent issues (vm.max_map_count, mDNS, driver pin) — requires root, non-interactive
    --fix --dry-run     Show what --fix would do, change nothing
    --bundle            Create a sanitized support-bundle-<ts>.tar.gz (no secrets) for remote debug
  health [--peer] [--json]   Alias for doctor (deprecated)
  logs [-f] [svc]    Show container logs
  stop               Stop all containers
  start              Start containers
  restart            Restart all containers
  gpu [subcommand]   GPU management
    status             Show GPUs, VRAM, utilization, assignments
    assign <svc> <id>  Assign GPU to service (vllm, tei)
    assign --auto      Auto-distribute across GPUs
  model list         Show loaded models (vLLM, Ollama, embed, rerank)
  loadtest [sub]     Run k6 performance scenarios (Phase 40)
    list               List available scenarios
    chat|embed|kb      Run scenario; pass --duration/--vus after name
    last               Show 5 most recent result JSON files
  docling bench <pdf>  Benchmark docling-serve on a real PDF (Phase 42)
                       Iterates ?=3 times, reports cold/warm/per-page timing
  ragflow <sub>      RAGFlow stack management (BACKLOG #999.7)
    status               3 ragflow containers status
    logs [svc]           Tail logs (ragflow|mysql|es)
    version              RAGFlow API version
    query <text>         Test retrieval against RAGFLOW_DATASET_ID
    keys                 Check RAGFLOW_API_KEY/DATASET_ID env
    restart              Restart 3 ragflow containers (root)
    backup               Backup ragflow stack (root)
    es-health            ES cluster health
  mdns-status [--json]  Diagnose mDNS publishing (exits 1 on any issue)
  init-dify          Initialize Dify admin (if auto-init failed)
  backup <sub>       Backup operations (root)
    create [--include-models]   Create a backup (default; can include vLLM model cache)
    list                        List backups (DATE / SIZE / STATUS)
    verify [latest|<dir>] [--json]   Check backup integrity; exit 0=valid, 1=corrupt/incomplete
  restore [latest|<dir>] [--auto-confirm] [--dry-run] [--service <name>]   Restore from backup (root)
    --dry-run          Print the restore plan, change nothing (runs verify too)
    --service <name>   Restore only one group: dify | rag | ragflow | openwebui | ollama | config
  config <sub>           Config validation and update preview (no root; static)
    validate [--json]      Check installed .env (placeholders, required keys), versions<->manifest sync,
                           compose schema validity, no :latest/mutating tags
    diff [--release]       Preview version changes 'agmind update' would make (no root; no changes made)
                           Note: 'agmind upgrade --diff' shows pinned-in-.env vs actually-running-container
                           drift (a different axis from 'config diff' which shows current-pinned vs target-release)
  update [options]       Update AGMind stack (root)
    --check                Check for new bundle release (GitHub Releases)
    --dry-run              Preview what update would do (no root; no changes made) — same as 'config diff'
    --component <name>     Emergency: update single component (shows warning)
    --version <tag>        Target version (use with --component)
    --force                Skip emergency mode confirmation
    --rollback             Rollback to previous bundle version
    --rollback <name>      Rollback single component (legacy)
    --auto                 Skip all confirmation prompts
    --scripts-only         Update scripts/configs only (skip docker pull)
    --release              Pull from legacy 'release' branch (default = 'main' since 2026-04)
  upgrade [--diff]   Compare pinned versions.env vs live containers (read-only)
  plugins <sub>      Dify plugin daemon marketplace toggle (root for online/offline)
    online               Enable marketplace.dify.ai (default — рекомендуется)
    offline              Disable marketplace (только локальные .difypkg)
    status               Show current marketplace state (no root)
  plugin-daemon <sub>  Управление контейнером plugin_daemon
    status               Состояние и health (по умолчанию)
    stop|start|restart   Управление daemon (root)
    logs                 Tail логи
  open [<svc>|--list]   Open a service URL in the browser (headless/SSH → prints the URL, one line, pipeable)
                        Services: dify chat grafana portainer ragflow minio litellm notebook
                        Bare or --list: print all openable services and their URLs
  endpoints [--json]    List all public service URLs (SERVICE | URL | STATE); --json = machine-readable; always exit 0
  security audit [--json]   Scan exposed ports / privileged containers / docker.sock consumers / weak secrets / bad file perms (report-only)
  creds show [--show] [--json]   Show stack credentials (root-only; masked unless --show)
  creds rotate [args]   Rotate passwords and keys — wraps rotate_secrets.sh (root)
  uninstall          Remove AGMind (root)
  rotate-secrets     Rotate passwords and keys (root)
  help               Show this help

Environment:
  AGMIND_DIR    Override install directory (default: /opt/agmind)
HELP
}

# ============================================================================
# DISPATCH
# ============================================================================

case "${1:-help}" in
    status)         shift; cmd_status "$@" ;;
    doctor)         shift; cmd_doctor "$@" ;;
    health)         shift; cmd_doctor "$@" ;;   # deprecated alias: agmind health [--peer] [--json]
    stop)           cmd_stop ;;
    start)          cmd_start ;;
    restart)        cmd_restart ;;
    init-dify)      cmd_init_dify ;;
    backup)
        shift
        _require_root backup
        _bk_sub="${1:-create}"
        case "$_bk_sub" in
            create|"")
                [[ "$_bk_sub" == "create" ]] && shift || true
                exec "${SCRIPTS_DIR}/backup.sh" "$@"
                ;;
            list|ls)
                # shellcheck source=/dev/null
                source "${AGMIND_DIR}/lib/restore.sh" || { echo -e "${RED}lib/restore.sh not found${NC}" >&2; exit 1; }
                restore_list
                ;;
            verify)  # agmind backup verify [latest|<dir>] [--json]
                shift
                # shellcheck source=/dev/null
                source "${AGMIND_DIR}/lib/restore.sh" || { echo -e "${RED}lib/restore.sh not found${NC}" >&2; exit 1; }
                _bk_dir="$(_resolve_backup_dir "${1:-latest}")" || exit 1
                if [[ "${2:-}" == "--json" ]]; then
                    restore_verify "$_bk_dir" --json
                else
                    restore_verify "$_bk_dir"
                fi
                ;;
            *)
                echo -e "${RED}Unknown backup subcommand: ${_bk_sub}${NC}" >&2
                echo "Usage: agmind backup [create [--include-models] | list | verify [latest|<dir>] [--json]]" >&2
                exit 1
                ;;
        esac
        ;;
    restore)        shift; _require_root restore; exec "${SCRIPTS_DIR}/restore.sh" "$@" ;;
    update)
        shift
        # --dry-run is read-only — skip root check (D-06: agmind.sh side of two-bypass topology)
        if [[ " $* " != *" --dry-run "* ]]; then
            _require_root update
        fi
        exec "${SCRIPTS_DIR}/update.sh" "$@"
        ;;
    upgrade)        shift
                    case "${1:-}" in
                        --diff|diff|""|--help|-h) cmd_upgrade_diff ;;
                        *) echo "Usage: agmind upgrade [--diff]" >&2
                           echo "  --diff   Show pinned vs live drift (read-only, default)" >&2
                           echo "Apply: rerun install.sh OR edit /opt/agmind/docker/.env + docker compose up -d" >&2
                           exit 1 ;;
                    esac ;;
    config)
        shift
        case "${1:-}" in
            validate)
                shift
                # Static read-only check — no root required
                # shellcheck source=/dev/null
                source "${AGMIND_DIR}/lib/config.sh" 2>/dev/null \
                    || { echo -e "${RED}lib/config.sh not found${NC}" >&2; exit 2; }
                config_validate "$@"
                ;;
            diff)
                shift
                # Update preview — no root (read-only); update.sh --dry-run handles its own bypass
                exec "${SCRIPTS_DIR}/update.sh" --dry-run "$@"
                ;;
            ""|--help|-h|help)
                echo "Usage: agmind config <validate|diff> [options]"
                echo "  validate [--json]      Check installed .env / versions<->manifest / compose schema (no root; static)"
                echo "  diff [--release]       Preview what 'agmind update' would change (no root; no changes made)"
                ;;
            *)
                echo "Unknown 'config' subcommand: $1" >&2
                echo "Usage: agmind config <validate|diff>" >&2
                exit 1
                ;;
        esac
        ;;
    uninstall)      shift; _require_root uninstall; exec "${SCRIPTS_DIR}/uninstall.sh" "$@" ;;
    rotate-secrets) shift; _require_root rotate-secrets; exec "${SCRIPTS_DIR}/rotate_secrets.sh" "$@" ;;
    logs)           shift; exec docker compose -f "$COMPOSE_FILE" logs "$@" ;;
    gpu)            shift; cmd_gpu "$@" ;;
    model)          shift; cmd_model "$@" ;;
    loadtest)       shift; cmd_loadtest "$@" ;;
    mdns-status)    shift; exec "${SCRIPTS_DIR}/mdns-status.sh" "$@" ;;
    plugins)        shift; cmd_plugins "$@" ;;
    docling)        shift
                    case "${1:-}" in
                        bench) shift; exec "${SCRIPTS_DIR}/docling-bench.sh" "$@" ;;
                        *)     echo "Usage: agmind docling bench <pdf>" >&2; exit 1 ;;
                    esac ;;
    dify)           shift
                    case "${1:-}" in
                        import-workflow) shift; exec "${SCRIPTS_DIR}/import-dify-workflow.sh" "$@" ;;
                        *)               echo "Usage: agmind dify import-workflow <dsl.yaml>" >&2; exit 1 ;;
                    esac ;;
    ragflow)        shift; cmd_ragflow "$@" ;;
    security)       shift; cmd_security "$@" ;;
    plugin-daemon)  shift; cmd_plugin_daemon "$@" ;;
    open)           shift; cmd_open "$@" ;;
    endpoints)      shift; cmd_endpoints "$@" ;;
    creds)
        shift
        case "${1:-show}" in
            show)
                shift
                cmd_creds_show "$@"
                ;;
            rotate)
                shift
                _require_root "creds rotate"
                exec "${SCRIPTS_DIR}/rotate_secrets.sh" "$@"
                ;;
            ""|--help|-h)
                echo "Usage: agmind creds {show [--show] [--json] | rotate [args]}" >&2
                exit 1
                ;;
            *)
                echo -e "${RED}Unknown creds subcommand: ${1}${NC}" >&2
                echo "Usage: agmind creds {show|rotate}" >&2
                exit 1
                ;;
        esac
        ;;
    help|--help|-h) cmd_help ;;
    *)              echo -e "${RED}Unknown command: ${1}${NC}" >&2; cmd_help; exit 1 ;;
esac
