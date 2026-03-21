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
    echo "  Open WebUI:   http://${domain}"
    echo "  Dify Console: http://${domain}:3000"
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
        local cm; cm="$(echo "$cv" | cut -d. -f2)"
        if [[ "${cm:-0}" -ge 20 ]] 2>/dev/null; then _check OK "Compose v${cv}"
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
    ram_gb="$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")"
    ram_used="$(free -g 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0")"
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
            [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}.env Completeness:${NC}"
            local mandatory_vars=(
                DOMAIN
                LLM_PROVIDER
                EMBED_PROVIDER
                DIFY_SECRET_KEY
                POSTGRES_PASSWORD
                REDIS_PASSWORD
                INIT_PASSWORD
                DEPLOY_PROFILE
            )
            local env_ok=0 env_missing=0
            for var in "${mandatory_vars[@]}"; do
                local val
                val="$(_read_env "$var" "")"
                if [[ -n "$val" ]]; then
                    env_ok=$((env_ok + 1))
                else
                    _check FAIL ".env: ${var}" "Не задан" "Проверьте ${ENV_FILE}"
                    env_missing=$((env_missing + 1))
                fi
            done
            if [[ $env_missing -eq 0 ]]; then
                _check OK ".env: все ${env_ok} обязательных переменных заданы"
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
  backup             Create backup (root)
  restore <path>     Restore from backup (root)
  update [options]     Update AGMind stack (root)
    --check              Show available updates without changing anything
    --component <name>   Update single component (e.g., dify-api, ollama, vllm)
    --version <tag>      Target version (use with --component)
    --rollback <name>    Rollback component to previous version
    --auto               Skip confirmation prompts
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
    backup)         shift; _require_root backup; exec "${SCRIPTS_DIR}/backup.sh" "$@" ;;
    restore)        shift; _require_root restore; exec "${SCRIPTS_DIR}/restore.sh" "$@" ;;
    update)         shift; _require_root update; exec "${SCRIPTS_DIR}/update.sh" "$@" ;;
    uninstall)      shift; _require_root uninstall; exec "${SCRIPTS_DIR}/uninstall.sh" "$@" ;;
    rotate-secrets) shift; _require_root rotate-secrets; exec "${SCRIPTS_DIR}/rotate_secrets.sh" "$@" ;;
    logs)           shift; exec docker compose -f "$COMPOSE_FILE" logs "$@" ;;
    help|--help|-h) cmd_help ;;
    *)              echo -e "${RED}Unknown command: ${1}${NC}" >&2; cmd_help; exit 1 ;;
esac
