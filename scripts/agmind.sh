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
    if [[ "$(uname)" == "Darwin" ]]; then ipconfig getifaddr en0 2>/dev/null || echo "localhost"
    else hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"; fi
}

# ============================================================================
# STATUS
# ============================================================================

_status_dashboard() {
    echo -e "\n${BOLD}${CYAN}=========================================${NC}"
    echo -e "${BOLD}${CYAN}  AGMind Status${NC}"
    echo -e "${BOLD}${CYAN}=========================================${NC}\n"

    echo -e "${BOLD}Services:${NC}"
    check_all || true
    echo ""

    echo -e "${BOLD}GPU:${NC}"
    check_gpu_status

    local llm_prov; llm_prov="$(_read_env LLM_PROVIDER "ollama")"
    if [[ "$llm_prov" == "ollama" ]]; then
        echo -e "${BOLD}Models:${NC}"
        check_ollama_models || true
    fi

    echo -e "${BOLD}Endpoints:${NC}"
    local domain; domain="$(_read_env DOMAIN "")"
    [[ -z "$domain" ]] && domain="$(_get_ip)"
    echo "  Dify App:     http://${domain}"
    echo "  Dify Console: http://agmind-dify.local"
    [[ "$(_read_env ENABLE_OPENWEBUI "false")" == "true" ]] && echo "  Open WebUI:   http://agmind-chat.local"
    [[ "$(_read_env ENABLE_LITELLM "true")" == "true" ]] && echo "  LiteLLM UI:   http://${domain}:4001/ui/"
    if [[ "$(_read_env ADMIN_UI_OPEN "false")" == "true" ]]; then
        local ip; ip="$(_get_ip)"
        echo "  Portainer:    https://${ip}:9443"
        echo "  Grafana:      http://${ip}:3001"
    fi
    echo ""

    echo -e "${BOLD}Backup:${NC}"
    check_backup_status

    echo -e "${BOLD}Credentials:${NC}"
    echo "  ${AGMIND_DIR}/credentials.txt"
    echo ""
}

_status_json() {
    local services_arr; read -ra services_arr <<< "$(get_service_list)"
    local total=${#services_arr[@]} running=0 details="" sep=""

    for svc in "${services_arr[@]}"; do
        local st; st="$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")"
        local state="stopped"
        if echo "$st" | grep -qi "up\|healthy"; then state="running"; running=$((running+1)); fi
        details="${details}${sep}\"${svc}\":\"${state}\""; sep=","
    done

    local overall="unhealthy"
    [[ $running -gt 0 ]] && overall="degraded"
    [[ $running -eq $total ]] && overall="healthy"

    local gpu_type="none" gpu_util="N/A"
    if command -v nvidia-smi &>/dev/null; then
        gpu_type="nvidia"
        gpu_util="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null | head -1 | xargs || echo "N/A")"
    elif command -v rocm-smi &>/dev/null; then
        gpu_type="amd"
    fi

    local domain; domain="$(_read_env DOMAIN "")"; [[ -z "$domain" ]] && domain="$(_get_ip)"

    cat <<ENDJSON
{
  "status": "${overall}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "services": {"total": ${total}, "running": ${running}, "details": {${details}}},
  "gpu": {"type": "${gpu_type}", "utilization": "${gpu_util}"},
  "endpoints": {"webui": "http://${domain}", "dify": "http://${domain}:3000"}
}
ENDJSON
}

cmd_status() {
    if [[ "${1:-}" == "--json" ]]; then _status_json; else _status_dashboard; fi
}

# ============================================================================
# DOCTOR
# ============================================================================

cmd_doctor() {
    local errors=0 warnings=0 checks=() output_json=false
    [[ "${1:-}" == "--json" ]] && output_json=true

    _check() {
        local sev="$1" label="$2" msg="${3:-}" fix="${4:-}"
        if [[ "$output_json" == "true" ]]; then
            local m; m="$(echo "$msg" | sed 's/"/\\"/g')"
            local f; f="$(echo "$fix" | sed 's/"/\\"/g')"
            checks+=("{\"severity\":\"${sev}\",\"label\":\"${label}\",\"message\":\"${m}\",\"fix\":\"${f}\"}")
        else
            case "$sev" in
                OK)   echo -e "  ${GREEN}[OK]${NC}   ${label}" ;;
                WARN) echo -e "  ${YELLOW}[WARN]${NC} ${label} — ${msg}"; [[ -n "$fix" ]] && echo -e "         ${CYAN}-> ${fix}${NC}" ;;
                FAIL) echo -e "  ${RED}[FAIL]${NC} ${label} — ${msg}"; [[ -n "$fix" ]] && echo -e "         ${CYAN}-> ${fix}${NC}" ;;
                SKIP) echo -e "  ${CYAN}[SKIP]${NC} ${label} — ${msg}" ;;
            esac
        fi
        case "$sev" in WARN) warnings=$((warnings+1));; FAIL) errors=$((errors+1));; esac
    }

    # Docker
    [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}Docker + Compose:${NC}"
    if ! command -v docker &>/dev/null; then
        _check FAIL "Docker" "not installed" "curl -fsSL https://get.docker.com | sh"
    else
        local dv; dv="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")"
        local dm="${dv%%.*}"
        if [[ "$dm" -ge 24 ]] 2>/dev/null; then _check OK "Docker v${dv}"
        elif [[ "$dm" -ge 20 ]] 2>/dev/null; then _check WARN "Docker v${dv}" "24.0+ recommended"
        else _check FAIL "Docker v${dv}" "24.0+ required"; fi
    fi
    if docker compose version &>/dev/null; then
        local cv; cv="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
        local cmaj; cmaj="$(echo "$cv" | cut -d. -f1)"
        local cmin; cmin="$(echo "$cv" | cut -d. -f2)"
        if [[ "${cmaj:-0}" -ge 3 ]] 2>/dev/null; then _check OK "Compose v${cv}"
        elif [[ "${cmaj:-0}" -eq 2 && "${cmin:-0}" -ge 20 ]] 2>/dev/null; then _check OK "Compose v${cv}"
        else _check WARN "Compose v${cv}" "2.20+ recommended"; fi
    elif command -v docker &>/dev/null; then
        _check FAIL "Docker Compose" "not installed"
    fi

    # DNS
    [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}DNS + Network:${NC}"
    if host registry.ollama.ai &>/dev/null 2>&1 || nslookup registry.ollama.ai &>/dev/null 2>&1; then
        _check OK "DNS (registry.ollama.ai)"
    else _check WARN "DNS" "Cannot resolve registry.ollama.ai"; fi
    if curl -sf --max-time 5 https://registry-1.docker.io/v2/ &>/dev/null; then _check OK "Docker Hub"
    else _check WARN "Docker Hub" "Unreachable"; fi

    # GPU
    [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}GPU:${NC}"
    local lp ep; lp="$(_read_env LLM_PROVIDER "unknown")"; ep="$(_read_env EMBED_PROVIDER "unknown")"
    if [[ "$lp" == "external" && "$ep" == "external" ]]; then _check SKIP "GPU" "External provider"
    elif command -v nvidia-smi &>/dev/null; then
        _check OK "NVIDIA GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
        if docker info 2>/dev/null | grep -qi "nvidia"; then _check OK "NVIDIA Container Toolkit"
        else _check WARN "NVIDIA Container Toolkit" "Docker nvidia runtime not configured"; fi
    elif command -v rocm-smi &>/dev/null; then _check OK "AMD GPU (ROCm)"
    else _check WARN "GPU" "nvidia-smi not found"; fi

    # Resources
    [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}Resources:${NC}"
    local free_gb disk_total disk_used disk_pct
    free_gb="$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo "0")"
    disk_total="$(df -BG / 2>/dev/null | tail -1 | awk '{print $2}' | tr -d 'G' || echo "0")"
    disk_used="$(df -BG / 2>/dev/null | tail -1 | awk '{print $3}' | tr -d 'G' || echo "0")"
    disk_pct="$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || echo "0")"
    if [[ "${free_gb:-0}" -ge 20 ]] 2>/dev/null; then _check OK "Disk: ${free_gb}GB free (${disk_pct}% used of ${disk_total}GB)"
    elif [[ "${free_gb:-0}" -ge 10 ]] 2>/dev/null; then _check WARN "Disk: ${free_gb}GB free (${disk_pct}% used)" "20GB+ recommended" "docker system prune"
    else _check FAIL "Disk: ${free_gb}GB free (${disk_pct}% used)" "Мало места" "docker system prune -af"; fi

    local ram_gb ram_total ram_used ram_pct
    ram_gb="$(LANG=C free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")"
    ram_used="$(LANG=C free -g 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0")"
    if [[ "${ram_gb:-0}" -gt 0 ]] 2>/dev/null; then
        ram_pct=$(( (ram_used * 100) / ram_gb ))
    else
        ram_pct=0
    fi
    if [[ "${ram_gb:-0}" -ge 8 ]] 2>/dev/null; then _check OK "RAM: ${ram_gb}GB total (${ram_pct}% used)"
    elif [[ "${ram_gb:-0}" -ge 4 ]] 2>/dev/null; then _check WARN "RAM: ${ram_gb}GB (${ram_pct}% used)" "8GB+ recommended"
    else _check FAIL "RAM: ${ram_gb}GB (${ram_pct}% used)" "Минимум 4GB"; fi

    for port in 80 443; do
        local pp; pp="$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 || true)"
        if [[ -z "$pp" ]]; then _check OK "Port ${port} (free)"
        elif echo "$pp" | grep -q "agmind\|nginx\|docker"; then _check OK "Port ${port} (AGMind)"
        else _check FAIL "Port ${port}" "In use by another process"; fi
    done

    # Docker disk usage summary
    local docker_disk
    docker_disk="$(docker system df --format 'table {{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2>/dev/null || true)"
    if [[ -n "$docker_disk" ]]; then
        [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}Docker Disk:${NC}"
        while IFS= read -r line; do
            [[ "$output_json" != "true" ]] && echo "  $line"
        done <<< "$docker_disk"
    fi

    # Container Health
    if [[ -f "${AGMIND_DIR}/.agmind_installed" ]]; then
        [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}Container Health:${NC}"

        # Unhealthy containers
        local unhealthy
        unhealthy="$(docker ps --filter "name=agmind-" --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null || true)"
        if [[ -n "$unhealthy" ]]; then
            while IFS= read -r c; do
                _check FAIL "Unhealthy: ${c}" "Контейнер нездоров" "docker logs --tail 20 ${c}"
            done <<< "$unhealthy"
        else
            _check OK "Нет unhealthy контейнеров"
        fi

        # Exited containers
        local exited
        exited="$(docker ps -a --filter "name=agmind-" --filter "status=exited" --format '{{.Names}}' 2>/dev/null || true)"
        if [[ -n "$exited" ]]; then
            while IFS= read -r c; do
                # Skip init-containers (expected to exit)
                [[ "$c" == *"lock-cleaner"* ]] && continue
                _check WARN "Exited: ${c}" "Контейнер остановлен" "docker start ${c}"
            done <<< "$exited"
        fi

        # High restart count (>3)
        local restarts
        restarts="$(docker ps --filter "name=agmind-" --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)"
        if [[ -n "$restarts" ]]; then
            while IFS=$'\t' read -r cname cstatus; do
                local rcount
                rcount="$(docker inspect --format '{{.RestartCount}}' "$cname" 2>/dev/null || echo "0")"
                if [[ "${rcount:-0}" -gt 3 ]] 2>/dev/null; then
                    _check WARN "Restarts: ${cname}" "${rcount} перезапусков" "docker logs --tail 30 ${cname}"
                fi
            done <<< "$restarts"
        fi

        # LiteLLM
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'agmind-litellm'; then
            if docker exec agmind-litellm curl -sf --max-time 5 http://localhost:4000/health >/dev/null 2>&1; then
                _check OK "LiteLLM Gateway" "healthy (port 4000)"
            else
                _check WARN "LiteLLM Gateway" "Container running but health check failed" "docker compose restart agmind-litellm"
            fi
        fi
    fi

    # HTTP Endpoints
    if [[ -f "${AGMIND_DIR}/.agmind_installed" ]]; then
        [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}HTTP Endpoints:${NC}"
        verify_services >/dev/null 2>&1 || true
        if [[ ${#VERIFY_RESULTS[@]} -gt 0 ]]; then
            for entry in "${VERIFY_RESULTS[@]}"; do
                IFS='|' read -r name url status <<< "$entry"
                if [[ "$status" == "OK" ]]; then
                    _check OK "${name} (${url})"
                else
                    local hint=""
                    case "$name" in
                        vLLM)           hint="agmind logs vllm" ;;
                        Ollama)         hint="agmind logs ollama" ;;
                        TEI)            hint="agmind logs tei" ;;
                        "Dify Console") hint="agmind logs api" ;;
                        "Open WebUI")   hint="agmind logs open-webui" ;;
                        Weaviate)       hint="agmind logs weaviate" ;;
                        Qdrant)         hint="agmind logs qdrant" ;;
                        *)              hint="Проверьте логи сервиса" ;;
                    esac
                    _check FAIL "${name} (${url})" "Сервис не отвечает" "$hint"
                fi
            done
        fi

        # .env Completeness
        if [[ -f "$ENV_FILE" ]]; then
            if [[ ! -r "$ENV_FILE" ]]; then
                [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}.env Completeness:${NC}"
                _check SKIP ".env" "Нет прав чтения" "Запустите: sudo agmind doctor"
            else
                [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}.env Completeness:${NC}"
                # Required vars — must always be set
                local required_vars=(LLM_PROVIDER EMBED_PROVIDER SECRET_KEY DB_PASSWORD REDIS_PASSWORD INIT_PASSWORD)
                # Optional vars — WARN if missing (normal on some profiles)
                local optional_vars=(DOMAIN DEPLOY_PROFILE)
                local env_ok=0 env_missing=0
                for var in "${required_vars[@]}"; do
                    local val
                    val="$(_read_env "$var" "")"
                    if [[ -n "$val" ]]; then
                        env_ok=$((env_ok + 1))
                    else
                        _check FAIL ".env: ${var}" "Не задан" "Проверьте ${ENV_FILE}"
                        env_missing=$((env_missing + 1))
                    fi
                done
                for var in "${optional_vars[@]}"; do
                    local val
                    val="$(_read_env "$var" "")"
                    if [[ -n "$val" ]]; then
                        env_ok=$((env_ok + 1))
                    else
                        _check WARN ".env: ${var}" "Не задан (опционально для LAN)"
                    fi
                done
                if [[ $env_missing -eq 0 ]]; then
                    _check OK ".env: все ${env_ok} обязательных переменных заданы"
                fi
            fi
        fi
    fi

    # Post-install
    if [[ -f "${AGMIND_DIR}/.agmind_installed" ]]; then
        [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}Post-Install:${NC}"
        [[ -f "$ENV_FILE" ]] && _check OK ".env exists" || _check FAIL ".env" "Not found"
        local rest; rest="$(docker ps --filter "name=agmind-" --filter "status=restarting" --format '{{.Names}}' 2>/dev/null || true)"
        [[ -z "$rest" ]] && _check OK "No restart loops" || _check FAIL "Restart loop" "$rest"
    fi

    # Output
    if [[ "$output_json" == "true" ]]; then
        local cj; cj="$(printf '%s,' "${checks[@]}" | sed 's/,$//')"
        local ov="ok"; [[ $warnings -gt 0 ]] && ov="warnings"; [[ $errors -gt 0 ]] && ov="failures"
        echo "{\"status\":\"${ov}\",\"errors\":${errors},\"warnings\":${warnings},\"checks\":[${cj}]}"
    else
        echo ""
        if [[ $errors -gt 0 ]]; then echo -e "${RED}${errors} error(s), ${warnings} warning(s)${NC}"
        elif [[ $warnings -gt 0 ]]; then echo -e "${YELLOW}${warnings} warning(s)${NC}"
        else echo -e "${GREEN}All checks passed${NC}"; fi
    fi

    if [[ $errors -gt 0 ]]; then return 2; elif [[ $warnings -gt 0 ]]; then return 1; else return 0; fi
}

# ============================================================================
# STOP / START / RESTART
# ============================================================================

cmd_stop() {
    _require_root stop
    cd "$COMPOSE_DIR"
    echo -e "${YELLOW}Stopping AGMind...${NC}"
    COMPOSE_PROFILES=vps,monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei \
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
    COMPOSE_PROFILES=vps,monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei \
        docker compose restart
    echo -e "${GREEN}Restarted${NC}"
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
        printf "  GPU %d: %-30s | VRAM: %s / %s MiB (free: %s MiB) | Util: %s\n" \
            "$gpu_idx" "$name" "$mem_used" "$mem_total" "$mem_free" "$util_gpu"
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
        while IFS=',' read -r uuid pid pname pmem; do
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
# HELP
# ============================================================================

cmd_help() {
    cat <<'HELP'
Usage: agmind <command> [options]

Commands:
  status [--json]    Show stack status (services, GPU, models, endpoints)
  doctor [--json]    Run system diagnostics
  logs [-f] [svc]    Show container logs
  stop               Stop all containers
  start              Start containers
  restart            Restart all containers
  gpu [subcommand]   GPU management
    status             Show GPUs, VRAM, utilization, assignments
    assign <svc> <id>  Assign GPU to service (vllm, tei)
    assign --auto      Auto-distribute across GPUs
  model list         Show loaded models (vLLM, Ollama, embed, rerank)
  init-dify          Initialize Dify admin (if auto-init failed)
  backup             Create backup (root)
  restore <path>     Restore from backup (root)
  update [options]       Update AGMind stack (root)
    --check                Check for new bundle release (GitHub Releases)
    --component <name>     Emergency: update single component (shows warning)
    --version <tag>        Target version (use with --component)
    --force                Skip emergency mode confirmation
    --rollback             Rollback to previous bundle version
    --rollback <name>      Rollback single component (legacy)
    --auto                 Skip all confirmation prompts
    --scripts-only         Update scripts/configs only (skip docker pull)
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
    status)         shift; cmd_status "${1:-}" ;;
    doctor)         shift; cmd_doctor "${1:-}" ;;
    stop)           cmd_stop ;;
    start)          cmd_start ;;
    restart)        cmd_restart ;;
    init-dify)      cmd_init_dify ;;
    backup)         shift; _require_root backup; exec "${SCRIPTS_DIR}/backup.sh" "$@" ;;
    restore)        shift; _require_root restore; exec "${SCRIPTS_DIR}/restore.sh" "$@" ;;
    update)         shift; _require_root update; exec "${SCRIPTS_DIR}/update.sh" "$@" ;;
    uninstall)      shift; _require_root uninstall; exec "${SCRIPTS_DIR}/uninstall.sh" "$@" ;;
    rotate-secrets) shift; _require_root rotate-secrets; exec "${SCRIPTS_DIR}/rotate_secrets.sh" "$@" ;;
    logs)           shift; exec docker compose -f "$COMPOSE_FILE" logs "$@" ;;
    gpu)            shift; cmd_gpu "$@" ;;
    model)          shift; cmd_model "$@" ;;
    help|--help|-h) cmd_help ;;
    *)              echo -e "${RED}Unknown command: ${1}${NC}" >&2; cmd_help; exit 1 ;;
esac
