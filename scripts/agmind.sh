#!/usr/bin/env bash
# agmind — AGMind day-2 operations CLI
set -euo pipefail

# ---------------------------------------------------------------------------
# Directory resolution — derive AGMIND_DIR from script's own location,
# so this works whether run as symlink or direct path.
# ---------------------------------------------------------------------------
AGMIND_DIR="${AGMIND_DIR:-$(cd "$(dirname "$(realpath "$0")")/.." && pwd)}"
INSTALL_DIR="$AGMIND_DIR"
export INSTALL_DIR
SCRIPTS_DIR="${AGMIND_DIR}/scripts"
COMPOSE_DIR="${AGMIND_DIR}/docker"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
ENV_FILE="${COMPOSE_DIR}/.env"

# ---------------------------------------------------------------------------
# Source shared libs (installed copies under SCRIPTS_DIR).
# INSTALL_DIR must be exported BEFORE sourcing health.sh because health.sh
# evaluates COMPOSE_DIR at source time (line 7 of health.sh).
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/health.sh" 2>/dev/null || {
    echo "ERROR: AGMind not installed at ${AGMIND_DIR}" >&2
    echo "Set AGMIND_DIR if installed elsewhere" >&2
    exit 1
}

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/detect.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Colors — redeclare for safety in case sourced from a subshell
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------------------------------------------------------------------------
# _require_root — guard for privileged subcommands
# ---------------------------------------------------------------------------
_require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}Требуется root. Запустите: sudo agmind ${1:-}${NC}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# _read_env — safely read a value from ENV_FILE
# ---------------------------------------------------------------------------
_read_env() {
    local key="$1" default="${2:-}"
    if [[ -f "$ENV_FILE" ]]; then
        grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "$default"
    else
        echo "$default"
    fi
}

# ---------------------------------------------------------------------------
# cmd_status — show stack status dashboard or JSON
# ---------------------------------------------------------------------------

_status_dashboard() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  AGMind Status${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    # Services
    echo -e "${BOLD}Services:${NC}"
    check_all
    echo ""

    # GPU
    echo -e "${BOLD}GPU:${NC}"
    check_gpu_status

    # Models — only when LLM_PROVIDER=ollama
    local llm_prov
    llm_prov=$(_read_env LLM_PROVIDER "ollama")
    if [[ "$llm_prov" == "ollama" ]]; then
        echo -e "${BOLD}Models:${NC}"
        check_ollama_models
    fi

    # Endpoints
    echo -e "${BOLD}Endpoints:${NC}"
    local domain deploy_profile admin_ui_open server_ip
    domain=$(_read_env DOMAIN "")
    deploy_profile=$(_read_env DEPLOY_PROFILE "lan")
    admin_ui_open=$(_read_env ADMIN_UI_OPEN "false")

    if [[ -z "$domain" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            server_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "localhost")
        else
            server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
        fi
        domain="${server_ip:-localhost}"
    fi

    echo "  Open WebUI:   http://${domain}"
    echo "  Dify Console: http://${domain}:3000"

    if [[ "$admin_ui_open" == "true" ]]; then
        local ip_for_admin
        if [[ "$(uname)" == "Darwin" ]]; then
            ip_for_admin=$(ipconfig getifaddr en0 2>/dev/null || echo "localhost")
        else
            ip_for_admin=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
        fi
        echo "  Portainer:    https://${ip_for_admin:-localhost}:9443"
        echo "  Grafana:      http://${ip_for_admin:-localhost}:3001"
    fi
    echo ""

    # Backup
    echo -e "${BOLD}Backup:${NC}"
    check_backup_status

    # Credentials — path only, never content (Phase 2 decision)
    echo -e "${BOLD}Credentials:${NC}"
    echo "  ${AGMIND_DIR}/credentials.txt"
    echo ""
}

_status_as_json() {
    # Collect service statuses without calling text-output functions
    local services_arr
    read -ra services_arr <<< "$(get_service_list)"
    local total=${#services_arr[@]}
    local running=0
    local details_json=""
    local sep=""

    for svc in "${services_arr[@]}"; do
        local st
        st=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")
        local state
        if echo "$st" | grep -qi "up\|healthy"; then
            state="running"
            running=$((running + 1))
        else
            state="stopped"
        fi
        local svc_esc
        svc_esc=$(echo "$svc" | sed 's/"/\\"/g')
        details_json="${details_json}${sep}\"${svc_esc}\":\"${state}\""
        sep=","
    done

    # Overall status
    local overall_status
    if [[ $running -eq $total ]]; then
        overall_status="healthy"
    elif [[ $running -gt 0 ]]; then
        overall_status="degraded"
    else
        overall_status="unhealthy"
    fi

    # GPU info — read from .agmind_gpu_profile if available, else probe
    local gpu_type gpu_name gpu_util
    local gpu_profile="${AGMIND_DIR}/.agmind_gpu_profile"
    if [[ -f "$gpu_profile" ]]; then
        gpu_type=$(grep '^GPU_TYPE=' "$gpu_profile" 2>/dev/null | cut -d= -f2 | head -1 || echo "none")
        gpu_name=$(grep '^GPU_NAME=' "$gpu_profile" 2>/dev/null | cut -d= -f2- | head -1 || echo "")
    else
        gpu_type="none"
        gpu_name=""
    fi

    if [[ "$gpu_type" == "nvidia" ]] && command -v nvidia-smi &>/dev/null; then
        gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null | head -1 | xargs || echo "N/A")
    else
        gpu_util="N/A"
    fi

    local gpu_type_esc gpu_name_esc gpu_util_esc
    gpu_type_esc=$(echo "${gpu_type:-none}" | sed 's/"/\\"/g')
    gpu_name_esc=$(echo "${gpu_name:-}" | sed 's/"/\\"/g')
    gpu_util_esc=$(echo "${gpu_util:-N/A}" | sed 's/"/\\"/g')

    # Endpoints
    local domain
    domain=$(_read_env DOMAIN "")
    if [[ -z "$domain" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            domain=$(ipconfig getifaddr en0 2>/dev/null || echo "localhost")
        else
            domain=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
        fi
        domain="${domain:-localhost}"
    fi
    local domain_esc
    domain_esc=$(echo "$domain" | sed 's/"/\\"/g')

    # Backup age
    local backup_last="none" backup_age_hours=0 backup_status_val="none"
    local backup_dir="/var/backups/agmind"
    if [[ -d "$backup_dir" ]]; then
        local latest
        latest=$(ls -1d "${backup_dir}"/20* 2>/dev/null | sort -r | head -1 || true)
        if [[ -n "$latest" ]]; then
            backup_last=$(basename "$latest")
            local backup_ts now_ts
            backup_ts=$(date -d "${backup_last//_/ }" +%s 2>/dev/null || echo 0)
            now_ts=$(date +%s)
            if [[ "$backup_ts" -gt 0 ]]; then
                backup_age_hours=$(( (now_ts - backup_ts) / 3600 ))
            fi
            if [[ $backup_age_hours -lt 24 ]]; then
                backup_status_val="ok"
            elif [[ $backup_age_hours -lt 72 ]]; then
                backup_status_val="warning"
            else
                backup_status_val="stale"
            fi
        fi
    fi

    local backup_last_esc
    backup_last_esc=$(echo "$backup_last" | sed 's/"/\\"/g')

    # Output JSON
    cat <<ENDJSON
{
  "status": "${overall_status}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "services": {
    "total": ${total},
    "running": ${running},
    "details": {${details_json}}
  },
  "gpu": {"type": "${gpu_type_esc}", "name": "${gpu_name_esc}", "utilization": "${gpu_util_esc}"},
  "endpoints": {"webui": "http://${domain_esc}", "dify": "http://${domain_esc}:3000"},
  "backup": {"last": "${backup_last_esc}", "age_hours": ${backup_age_hours}, "status": "${backup_status_val}"}
}
ENDJSON
}

cmd_status() {
    local output_json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) output_json=true; shift ;;
            *) echo -e "${RED}Неизвестный флаг: $1${NC}" >&2; exit 1 ;;
        esac
    done

    if [[ "$output_json" == "true" ]]; then
        _status_as_json
    else
        _status_dashboard
    fi
}

# ---------------------------------------------------------------------------
# cmd_doctor — system diagnostics with [OK]/[WARN]/[FAIL] checks
# ---------------------------------------------------------------------------
cmd_doctor() {
    local errors=0 warnings=0
    local checks=()
    local output_json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) output_json=true; shift ;;
            *) echo -e "${RED}Неизвестный флаг: $1${NC}" >&2; exit 1 ;;
        esac
    done

    _check() {
        local severity="$1" label="$2" message="${3:-}" fix="${4:-}"
        if [[ "$output_json" == "true" ]]; then
            local msg_escaped fix_escaped
            msg_escaped=$(echo "$message" | sed 's/"/\\"/g')
            fix_escaped=$(echo "$fix" | sed 's/"/\\"/g')
            checks+=("{\"severity\":\"${severity}\",\"label\":\"${label}\",\"message\":\"${msg_escaped}\",\"fix\":\"${fix_escaped}\"}")
        else
            case "$severity" in
                OK)   echo -e "  ${GREEN}[OK]${NC}   $label" ;;
                WARN) echo -e "  ${YELLOW}[WARN]${NC} $label — $message"
                      [[ -n "$fix" ]] && echo -e "         ${CYAN}-> $fix${NC}"
                      ;;
                FAIL) echo -e "  ${RED}[FAIL]${NC} $label — $message"
                      [[ -n "$fix" ]] && echo -e "         ${CYAN}-> $fix${NC}"
                      ;;
                SKIP) echo -e "  ${CYAN}[SKIP]${NC} $label — $message" ;;
            esac
        fi
        case "$severity" in
            WARN) warnings=$((warnings+1)) ;;
            FAIL) errors=$((errors+1)) ;;
        esac
    }

    # -----------------------------------------------------------------------
    # Category 1: Docker + Compose
    # -----------------------------------------------------------------------
    [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}Docker + Compose:${NC}"

    if ! command -v docker &>/dev/null; then
        _check FAIL "Docker" "не установлен" "curl -fsSL https://get.docker.com | sh"
    else
        local docker_ver docker_major
        docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")
        docker_major="${docker_ver%%.*}"
        if [[ "$docker_major" -ge 24 ]] 2>/dev/null; then
            _check OK "Docker v${docker_ver}"
        elif [[ "$docker_major" -ge 20 ]] 2>/dev/null; then
            _check WARN "Docker v${docker_ver}" "Рекомендуется 24.0+" "apt-get install docker-ce"
        else
            _check FAIL "Docker v${docker_ver}" "Требуется 24.0+" "apt-get install docker-ce"
        fi
    fi

    if docker compose version &>/dev/null; then
        local compose_ver compose_minor
        compose_ver=$(docker compose version --short 2>/dev/null || echo "0")
        compose_minor=$(echo "$compose_ver" | cut -d'.' -f2)
        if [[ "${compose_minor:-0}" -ge 20 ]] 2>/dev/null; then
            _check OK "Compose v${compose_ver}"
        else
            _check WARN "Compose v${compose_ver}" "Рекомендуется V2.20+" "apt-get install docker-compose-plugin"
        fi
    else
        _check FAIL "Docker Compose" "не установлен" "apt-get install docker-compose-plugin"
    fi

    # -----------------------------------------------------------------------
    # Category 2: DNS + Network
    # -----------------------------------------------------------------------
    [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}DNS + Network:${NC}"

    if host registry.ollama.ai &>/dev/null 2>&1 || nslookup registry.ollama.ai &>/dev/null 2>&1; then
        _check OK "DNS (registry.ollama.ai)"
    else
        _check WARN "DNS" "Не удается разрешить registry.ollama.ai" "Проверьте /etc/resolv.conf и DNS-сервер"
    fi

    if curl -sf --max-time 5 https://registry-1.docker.io/v2/ &>/dev/null; then
        _check OK "Docker Hub"
    else
        _check WARN "Docker Hub" "Недоступен" "Проверьте интернет-соединение или настройки прокси"
    fi

    # -----------------------------------------------------------------------
    # Category 3: GPU (skip if both providers are external)
    # -----------------------------------------------------------------------
    [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}GPU:${NC}"

    local llm_prov embed_prov
    llm_prov=$(_read_env LLM_PROVIDER "unknown")
    embed_prov=$(_read_env EMBED_PROVIDER "unknown")

    if [[ "$llm_prov" == "external" && "$embed_prov" == "external" ]]; then
        _check SKIP "GPU" "Внешний провайдер — GPU не требуется"
    else
        if command -v nvidia-smi &>/dev/null; then
            local gpu_name
            gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
            _check OK "NVIDIA GPU: ${gpu_name}"
            if docker info 2>/dev/null | grep -qi "nvidia"; then
                _check OK "NVIDIA Container Toolkit"
            else
                _check WARN "NVIDIA Container Toolkit" "Docker runtime nvidia не настроен" \
                    "apt-get install nvidia-container-toolkit && systemctl restart docker"
            fi
        elif command -v rocm-smi &>/dev/null; then
            _check OK "AMD GPU (ROCm)"
        else
            _check WARN "GPU" "nvidia-smi не найден" \
                "Установите NVIDIA драйвер или выберите LLM_PROVIDER=external"
        fi
    fi

    # -----------------------------------------------------------------------
    # Category 4: Ports + Disk + RAM
    # -----------------------------------------------------------------------
    [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}Ports + Disk + RAM:${NC}"

    local port80_pid
    port80_pid=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1 || true)
    if [[ -z "$port80_pid" ]]; then
        _check OK "Port 80 (free)"
    elif echo "$port80_pid" | grep -q "agmind\|nginx\|docker"; then
        _check OK "Port 80 (AGMind)"
    else
        _check FAIL "Port 80" "Занят другим процессом" "ss -tlnp | grep :80"
    fi

    local port443_pid
    port443_pid=$(ss -tlnp 2>/dev/null | grep ':443 ' | head -1 || true)
    if [[ -z "$port443_pid" ]]; then
        _check OK "Port 443 (free)"
    elif echo "$port443_pid" | grep -q "agmind\|nginx\|docker"; then
        _check OK "Port 443 (AGMind)"
    else
        _check FAIL "Port 443" "Занят другим процессом" "ss -tlnp | grep :443"
    fi

    local free_gb
    free_gb=$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo "0")
    if [[ "${free_gb:-0}" -ge 20 ]] 2>/dev/null; then
        _check OK "Disk: ${free_gb}GB free"
    elif [[ "${free_gb:-0}" -ge 10 ]] 2>/dev/null; then
        _check WARN "Disk: ${free_gb}GB free" "Рекомендуется 20GB+" "docker system prune -af"
    else
        _check FAIL "Disk: ${free_gb}GB free" "Мало места" "docker system prune -af && apt autoremove"
    fi

    local total_ram_gb
    total_ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    if [[ "${total_ram_gb:-0}" -ge 8 ]] 2>/dev/null; then
        _check OK "RAM: ${total_ram_gb}GB"
    elif [[ "${total_ram_gb:-0}" -ge 4 ]] 2>/dev/null; then
        _check WARN "RAM: ${total_ram_gb}GB" "Рекомендуется 8GB+" ""
    else
        _check FAIL "RAM: ${total_ram_gb}GB" "Требуется минимум 4GB" ""
    fi

    # -----------------------------------------------------------------------
    # Post-install checks (only if .agmind_installed marker exists)
    # -----------------------------------------------------------------------
    if [[ -f "${AGMIND_DIR}/.agmind_installed" ]]; then
        [[ "$output_json" != "true" ]] && echo -e "\n${BOLD}Post-Install:${NC}"

        if [[ -f "$ENV_FILE" ]]; then
            _check OK ".env exists"
        else
            _check FAIL ".env" "Файл не найден" "Перезапустите установку: sudo bash install.sh"
        fi

        local restarting
        restarting=$(docker ps --filter "name=agmind-" --filter "status=restarting" \
            --format '{{.Names}}' 2>/dev/null || true)
        if [[ -z "$restarting" ]]; then
            _check OK "Нет контейнеров в restart loop"
        else
            _check FAIL "Restart loop" "${restarting}" \
                "docker compose -f ${COMPOSE_FILE} logs ${restarting}"
        fi

        if [[ -f "${AGMIND_DIR}/install.log" ]]; then
            _check OK "install.log exists"
        else
            _check WARN "install.log" "Файл не найден" ""
        fi
    fi

    # -----------------------------------------------------------------------
    # Output assembly
    # -----------------------------------------------------------------------
    if [[ "$output_json" == "true" ]]; then
        local checks_json
        checks_json=$(printf '%s,' "${checks[@]}" | sed 's/,$//')
        local overall="ok"
        [[ $warnings -gt 0 ]] && overall="warnings"
        [[ $errors -gt 0 ]] && overall="failures"
        cat <<ENDJSON
{
  "status": "${overall}",
  "errors": ${errors},
  "warnings": ${warnings},
  "checks": [${checks_json}]
}
ENDJSON
    else
        echo ""
        if [[ $errors -gt 0 ]]; then
            echo -e "${RED}${errors} ошибок, ${warnings} предупреждений${NC}"
        elif [[ $warnings -gt 0 ]]; then
            echo -e "${YELLOW}${warnings} предупреждений${NC}"
        else
            echo -e "${GREEN}Все проверки пройдены${NC}"
        fi
    fi

    if [[ $errors -gt 0 ]]; then return 2
    elif [[ $warnings -gt 0 ]]; then return 1
    else return 0; fi
}

# ---------------------------------------------------------------------------
# cmd_help — usage information
# ---------------------------------------------------------------------------
cmd_help() {
    cat <<'HELP'
Usage: agmind <command> [options]

Commands:
  status          Show stack status (services, GPU, models, endpoints)
  status --json   Machine-readable JSON output
  doctor          Run system diagnostics
  doctor --json   Machine-readable JSON output
  backup          Create backup (requires root)
  restore         Restore from backup (requires root)
  update          Update AGMind stack (requires root)
  uninstall       Remove AGMind (requires root)
  rotate-secrets  Rotate passwords and keys (requires root)
  logs [service]  Show container logs (pass -f for follow)
  help            Show this help

Environment:
  AGMIND_DIR      Override install directory (default: /opt/agmind)
HELP
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
case "${1:-help}" in
    status)         shift; cmd_status "$@" ;;
    doctor)         shift; cmd_doctor "$@" ;;
    backup)         shift; _require_root backup; exec "${SCRIPTS_DIR}/backup.sh" "$@" ;;
    restore)        shift; _require_root restore; exec "${SCRIPTS_DIR}/restore.sh" "$@" ;;
    update)         shift; _require_root update; exec "${SCRIPTS_DIR}/update.sh" "$@" ;;
    uninstall)      shift; _require_root uninstall; exec "${SCRIPTS_DIR}/uninstall.sh" "$@" ;;
    rotate-secrets) shift; _require_root rotate-secrets; exec "${SCRIPTS_DIR}/rotate_secrets.sh" "$@" ;;
    logs)           shift; exec docker compose -f "$COMPOSE_FILE" logs "$@" ;;
    help|--help|-h) cmd_help ;;
    *)              echo -e "${RED}Неизвестная команда: ${1}${NC}" >&2; cmd_help; exit 1 ;;
esac
