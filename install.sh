#!/usr/bin/env bash
# ============================================================================
# AGMind Installer v3.0
# Full RAG stack: Dify + Open WebUI + Ollama/vLLM + Weaviate/Qdrant
# Usage: sudo bash install.sh [--non-interactive] [--force-restart]
# ============================================================================
set -euo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

VERSION="3.0.0"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/agmind"
TEMPLATE_DIR="${INSTALLER_DIR}/templates"

# Verify running from project directory
if [[ ! -f "${INSTALLER_DIR}/lib/common.sh" ]]; then
    echo "Error: run from project directory: sudo bash install.sh" >&2; exit 1
fi

# --- Source library modules ---
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/detect.sh"
source "${INSTALLER_DIR}/lib/wizard.sh"
source "${INSTALLER_DIR}/lib/docker.sh"
source "${INSTALLER_DIR}/lib/config.sh"
source "${INSTALLER_DIR}/lib/compose.sh"
source "${INSTALLER_DIR}/lib/health.sh"
source "${INSTALLER_DIR}/lib/models.sh"
source "${INSTALLER_DIR}/lib/backup.sh"
source "${INSTALLER_DIR}/lib/security.sh"
source "${INSTALLER_DIR}/lib/authelia.sh"
source "${INSTALLER_DIR}/lib/tunnel.sh"
source "${INSTALLER_DIR}/lib/openwebui.sh"

# --- Global defaults ---
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
FORCE_RESTART="${FORCE_RESTART:-false}"
TIMEOUT_START="${TIMEOUT_START:-300}"
TIMEOUT_HEALTH="${TIMEOUT_HEALTH:-300}"
TIMEOUT_GPU_HEALTH="${TIMEOUT_GPU_HEALTH:-600}"
TIMEOUT_MODELS="${TIMEOUT_MODELS:-1200}"

# --- Exclusive lock ---
_acquire_lock() {
    if [[ "$(uname)" == "Darwin" ]]; then
        LOCK_DIR="/tmp/agmind-install.lock"
        mkdir "$LOCK_DIR" 2>/dev/null || { echo "Another install is running" >&2; exit 1; }
        trap 'rmdir "$LOCK_DIR" 2>/dev/null; _cleanup_on_failure' EXIT
    else
        local lock="/var/lock/agmind-install.lock"
        [[ -L "$lock" ]] && { echo "Lock is a symlink, aborting" >&2; exit 1; }
        exec 9>"$lock"
        flock -n 9 || { log_error "Another install is running"; exit 1; }
        trap _cleanup_on_failure EXIT
    fi
}

_cleanup_on_failure() {
    local rc=$?
    [[ $rc -eq 0 ]] && return
    echo ""
    log_error "Installation aborted (code: ${rc})."
    if [[ -f "${INSTALL_DIR}/.install_phase" ]]; then
        local p; p="$(cat "${INSTALL_DIR}/.install_phase" 2>/dev/null)"
        log_warn "Failed at phase ${p}/9. Re-run: sudo bash install.sh"
    fi
}

# --- Banner ---
show_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "    _    ____ __  __ _           _ "
    echo "   / \\  / ___|  \\/  (_)_ __   __| |"
    echo "  / _ \\| |  _| |\\/| | | '_ \\ / _\` |"
    echo " / ___ \\ |_| | |  | | | | | | (_| |"
    echo "/_/   \\_\\____|_|  |_|_|_| |_|\\__,_|"
    echo ""
    echo -e "${NC}${BOLD}  RAG Stack Installer v${VERSION}${NC}"
    echo ""
}

# --- Phase runners ---
run_phase() {
    local num="$1" total="$2" name="$3" func="$4"
    echo "$num" > "${INSTALL_DIR}/.install_phase"
    echo -e "\n${BOLD}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} ===${NC}"
    "$func"
    echo -e "${GREEN}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} DONE ===${NC}"
}

run_phase_with_timeout() {
    local num="$1" total="$2" name="$3" func="$4" timeout="$5"
    echo "$num" > "${INSTALL_DIR}/.install_phase"
    echo -e "\n${BOLD}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} (timeout: ${timeout}s) ===${NC}"
    local rc=0
    _run_with_timeout "$func" "$timeout" || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} DONE ===${NC}"
        return 0
    fi
    if [[ $rc -eq 124 ]]; then
        local retry=$((timeout * 2))
        log_warn "Phase ${name} timed out after ${timeout}s. Retrying (${retry}s)..."
        rc=0
        _run_with_timeout "$func" "$retry" || rc=$?
        if [[ $rc -eq 0 ]]; then
            echo -e "${GREEN}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} DONE (retry) ===${NC}"
            return 0
        fi
        [[ $rc -eq 124 ]] && { log_error "Phase ${name} timed out after ${retry}s"; return 1; }
    fi
    log_error "Phase ${name} failed (code: ${rc})"
    return "$rc"
}

_run_with_timeout() {
    local func="$1" secs="$2"
    "$func" & local pid=$! elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        [[ $elapsed -ge $secs ]] && { kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true; return 124; }
        sleep 1; elapsed=$((elapsed + 1))
    done
    wait "$pid"
}

# --- Phase functions (thin wrappers) ---
phase_diagnostics() { run_diagnostics || _confirm_continue "System below minimum requirements"; preflight_checks || _confirm_continue "Pre-flight errors found"; }
phase_wizard()      { run_wizard; }
phase_docker()      { setup_docker; }
phase_config()      { ensure_bind_mount_files; export INSTALL_DIR; generate_config "$DEPLOY_PROFILE" "$TEMPLATE_DIR"; enable_gpu_compose; setup_security; [[ "$ENABLE_AUTHELIA" == "true" ]] && configure_authelia "$TEMPLATE_DIR"; _copy_runtime_files; }
phase_start()       { compose_up; create_openwebui_admin; }
phase_health()      { wait_healthy "$TIMEOUT_HEALTH" "$TIMEOUT_GPU_HEALTH"; _check_critical_services; }
phase_models()      { download_models; }
phase_backups()     { setup_backups; setup_tunnel; }
phase_complete()    { create_openwebui_admin; _init_dify_admin; _save_credentials; _install_cli; _install_crons; _install_systemd_service; verify_services || true; _show_final_summary; }

_confirm_continue() {
    if [[ "$NON_INTERACTIVE" == "true" ]]; then log_warn "Non-interactive: continuing despite: $1"; return 0; fi
    read -rp "$1. Continue? (yes/no): " r; [[ "$r" == "yes" ]] || exit 1
}

_check_critical_services() {
    local svc failed=0
    for svc in db redis api worker web nginx; do
        local st; st="$(docker ps --filter "name=agmind-${svc}" --format "{{.Status}}" 2>/dev/null | head -1)"
        if echo "$st" | grep -qi "unhealthy\|restarting\|exited"; then
            log_error "Critical service ${svc}: ${st}"; docker logs --tail 5 "agmind-${svc}" 2>&1 | sed 's/^/    /'; failed=$((failed+1))
        fi
    done
    # GPU compatibility hint for vLLM (warning only — not critical)
    if [[ "${LLM_PROVIDER:-}" == "vllm" ]]; then
        local vllm_st; vllm_st="$(docker ps --filter "name=agmind-vllm" --format "{{.Status}}" 2>/dev/null | head -1)"
        if echo "$vllm_st" | grep -qi "exited\|restarting"; then
            log_warn "vLLM не запустился: ${vllm_st}"
            if docker logs --tail 20 agmind-vllm 2>&1 | grep -qi "no kernel image"; then
                log_warn "GPU compute capability не поддерживается данной сборкой vLLM."
                log_warn "Решение: переустановите с VLLM_CUDA_SUFFIX=-cu130 или переключитесь на Ollama."
            elif docker logs --tail 20 agmind-vllm 2>&1 | grep -qi "out of memory\|OOM\|CUDA.*memory"; then
                log_warn "Недостаточно VRAM для выбранной модели."
                if [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then
                    log_warn "TEI занимает ~1.5-2 GB VRAM на той же GPU."
                fi
                log_warn "Решение: выберите AWQ-квантизированную модель (например Qwen/Qwen2.5-7B-Instruct-AWQ)."
            fi
        fi
    fi
    # TEI hint (warning only — not critical)
    if [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then
        local tei_st; tei_st="$(docker ps --filter "name=agmind-tei" --format "{{.Status}}" 2>/dev/null | head -1)"
        if echo "$tei_st" | grep -qi "exited\|restarting"; then
            log_warn "TEI не запустился: ${tei_st}"
            docker logs --tail 5 agmind-tei 2>&1 | sed 's/^/    /' || true
        fi
    fi
    if [[ $failed -gt 0 ]]; then
        log_error "${failed} critical service(s) failed"
        return 1
    fi
}

_copy_runtime_files() {
    local scripts=(backup.sh restore.sh uninstall.sh update.sh agmind.sh health-gen.sh rotate_secrets.sh dr-drill.sh build-offline-bundle.sh generate-manifest.sh redis-lock-cleanup.sh)
    for s in "${scripts[@]}"; do
        [[ -f "${INSTALLER_DIR}/scripts/${s}" ]] && cp "${INSTALLER_DIR}/scripts/${s}" "${INSTALL_DIR}/scripts/"
    done
    cp "${INSTALLER_DIR}/lib/health.sh" "${INSTALL_DIR}/scripts/health.sh" 2>/dev/null || true
    cp "${INSTALLER_DIR}/lib/detect.sh" "${INSTALL_DIR}/scripts/detect.sh" 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
    cp "${INSTALLER_DIR}/workflows/rag-assistant.json" "${INSTALL_DIR}/workflows/" 2>/dev/null || true
}

_init_dify_admin() {
    # Skip if already initialized
    [[ -f "${INSTALL_DIR}/.dify_initialized" ]] && { log_info "Dify already initialized"; return 0; }

    local env_file="${INSTALL_DIR}/docker/.env"
    local init_password
    init_password="$(grep '^INIT_PASSWORD=' "$env_file" 2>/dev/null | cut -d'=' -f2-)"
    [[ -z "$init_password" ]] && return 0

    local admin_password
    admin_password="$(echo "$init_password" | base64 -d 2>/dev/null || echo "$init_password")"

    # Wait for Dify API to be ready
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        docker exec agmind-api curl -sf http://localhost:5001/health >/dev/null 2>&1 && break
        sleep 5
        attempts=$((attempts + 1))
    done
    if [[ $attempts -ge 30 ]]; then
        log_warn "Dify API not ready, skipping init"
        return 0
    fi

    log_info "Initializing Dify admin (1.13 two-step)..."

    # Two-step init: POST /console/api/init → POST /console/api/setup
    # Uses curl cookie jar inside the container for session handling
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
                -d "{\"email\":\"admin@agmind.local\",\"name\":\"AGMind Admin\",\"password\":\"$ADMIN_PWD\"}" \
                http://localhost:5001/console/api/setup 2>/dev/null
            rm -f /tmp/dify_cookies
        ' 2>&1)" || true

    if echo "$resp" | grep -qi '"result"\|"id"\|"token"\|success'; then
        log_success "Dify admin initialized"
        touch "${INSTALL_DIR}/.dify_initialized"
    elif echo "$resp" | grep -qi "already\|initialized\|repeat"; then
        log_info "Dify already initialized"
        touch "${INSTALL_DIR}/.dify_initialized"
    else
        log_warn "Dify init: $(echo "$resp" | head -c 200)"
    fi
}

_save_credentials() {
    local ip; ip="$(_get_ip)"
    local url="http://${ip}"; [[ "${DEPLOY_PROFILE:-}" == "vps" && -n "${DOMAIN:-}" ]] && url="https://${DOMAIN}"
    local owui_pass=""; [[ -f "${INSTALL_DIR}/.admin_password" ]] && owui_pass="$(cat "${INSTALL_DIR}/.admin_password")"
    {
        echo "# AGMind Credentials — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "Open WebUI:  ${url}"
        echo "  Login: admin@agmind.local"
        echo "  Pass:  ${owui_pass:-N/A}"
        echo ""
        echo "Dify Console: http://${DOMAIN:-$ip}:3000"
        echo "  Login: admin@agmind.local"
        echo "  Pass:  ${owui_pass:-N/A}"
        if [[ "${MONITORING_MODE:-}" == "local" ]]; then
            echo ""
            echo "Grafana: http://${ip}:${GRAFANA_PORT:-3001}"
            echo "  Login: admin"
            echo "  Pass:  ${GRAFANA_ADMIN_PASSWORD:-admin}"
            echo ""
            echo "Portainer: https://${ip}:${PORTAINER_PORT:-9443}"
            echo "  (создайте admin при первом входе)"
            if [[ "${ADMIN_UI_OPEN:-false}" != "true" ]]; then
                echo ""
                echo "Portainer SSH tunnel (если Portainer недоступен извне):"
                echo "  ssh -L 9443:127.0.0.1:9443 $(whoami)@${ip}"
                echo "  Затем откройте: https://localhost:9443"
            fi
        fi
    } > "${INSTALL_DIR}/credentials.txt"
    chmod 600 "${INSTALL_DIR}/credentials.txt"
    log_info "Credentials: ${INSTALL_DIR}/credentials.txt"
}

_get_ip() { if [[ "$(uname)" == "Darwin" ]]; then ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1"; else hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"; fi; }

_install_cli() {
    [[ -d /usr/local/bin ]] && ln -sf "${INSTALL_DIR}/scripts/agmind.sh" /usr/local/bin/agmind && log_success "'agmind' command available"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${INSTALL_DIR}/.agmind_installed"
}

_install_crons() {
    if [[ -d /etc/cron.d ]]; then
        echo "* * * * * root ${INSTALL_DIR}/scripts/health-gen.sh >> ${INSTALL_DIR}/health-gen.log 2>&1" > /etc/cron.d/agmind-health
        chmod 644 /etc/cron.d/agmind-health
    fi
    # Create initial health.json placeholder so nginx /health works before first cron tick
    local health_dir="${INSTALL_DIR}/docker/nginx"
    mkdir -p "$health_dir"
    # Docker creates a directory if the file didn't exist at bind mount time
    [[ -d "${health_dir}/health.json" ]] && rm -rf "${health_dir}/health.json"
    if [[ ! -f "${health_dir}/health.json" ]]; then
        echo '{"status": "starting", "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "${health_dir}/health.json"
    fi
}

_install_systemd_service() {
    # Install systemd service for auto-start after reboot
    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found — skipping auto-start service"
        return 0
    fi

    local service_src="${TEMPLATE_DIR}/agmind-stack.service.template"
    local service_dst="/etc/systemd/system/agmind-stack.service"

    if [[ ! -f "$service_src" ]]; then
        log_warn "Service template not found: ${service_src}"
        return 0
    fi

    sed "s|__INSTALL_DIR__|${INSTALL_DIR}|g" "$service_src" > "$service_dst"
    chmod 644 "$service_dst"
    systemctl daemon-reload
    systemctl enable agmind-stack.service
    log_success "Auto-start service installed (agmind-stack.service)"
}

_show_final_summary() {
    local ip; ip="$(_get_ip)"
    local url="http://${ip}"
    [[ "${DEPLOY_PROFILE:-}" == "vps" && -n "${DOMAIN:-}" ]] && url="https://${DOMAIN}"
    local owui_pass=""
    [[ -f "${INSTALL_DIR}/.admin_password" ]] && owui_pass="$(cat "${INSTALL_DIR}/.admin_password")"
    local dify_url="http://${DOMAIN:-$ip}:3000"

    local container_count
    container_count="$(docker ps --filter "name=agmind-" -q 2>/dev/null | wc -l | tr -d ' ')"

    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  +--------------------------------------------------+"
    echo "  |            AGMind — Установка завершена           |"
    echo "  +--------------------------------------------------+"
    echo -e "${NC}"
    echo -e "  ${BOLD}Open WebUI:${NC}      ${GREEN}${url}${NC}"
    echo -e "    Login:         admin@agmind.local"
    echo -e "    Pass:          ${owui_pass:-см. credentials.txt}"
    echo ""
    echo -e "  ${BOLD}Dify Console:${NC}    ${GREEN}${dify_url}${NC}"
    echo -e "    Login:         admin@agmind.local"
    echo -e "    Pass:          ${owui_pass:-см. credentials.txt}"
    if [[ "${MONITORING_MODE:-}" == "local" ]]; then
        echo ""
        echo -e "  ${BOLD}Grafana:${NC}         ${GREEN}http://${ip}:${GRAFANA_PORT:-3001}${NC}"
        echo -e "    Login:         admin"
        echo -e "    Pass:          ${GRAFANA_ADMIN_PASSWORD:-admin}"
        echo ""
        echo -e "  ${BOLD}Portainer:${NC}       ${GREEN}https://${ip}:${PORTAINER_PORT:-9443}${NC}"
        echo -e "    (создайте admin при первом входе)"
        if [[ "${ADMIN_UI_OPEN:-false}" != "true" ]]; then
            echo ""
            echo -e "  ${YELLOW}${BOLD}Portainer доступен только через SSH tunnel:${NC}"
            echo -e "  ${CYAN}ssh -L 9443:127.0.0.1:9443 $(whoami)@${ip}${NC}"
            echo -e "  Затем откройте: ${GREEN}https://localhost:9443${NC}"
        fi
    fi
    echo ""
    # Service verification results (populated by verify_services)
    if [[ ${#VERIFY_RESULTS[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Проверка сервисов:${NC}"
        for entry in "${VERIFY_RESULTS[@]}"; do
            IFS='|' read -r name url status <<< "$entry"
            if [[ "$status" == "OK" ]]; then
                echo -e "    ${GREEN}[OK]${NC}   ${name}"
            else
                echo -e "    ${RED}[FAIL]${NC} ${name} — проверьте: agmind logs"
            fi
        done
        echo ""
    fi
    echo -e "  ${BOLD}Профиль:${NC}         ${DEPLOY_PROFILE:-lan}"
    echo -e "  ${BOLD}LLM:${NC}             ${LLM_PROVIDER:-ollama} ${LLM_MODEL:-}${VLLM_MODEL:+ (${VLLM_MODEL})}"
    echo -e "  ${BOLD}Эмбеддинги:${NC}      ${EMBED_PROVIDER:-ollama} ${EMBEDDING_MODEL:-bge-m3}"
    echo -e "  ${BOLD}Контейнеры:${NC}      ${container_count} запущено"
    echo ""
    echo -e "  ${BOLD}Credentials:${NC}     ${INSTALL_DIR}/credentials.txt"
    echo -e "  ${BOLD}Логи:${NC}            ${INSTALL_DIR}/install.log"
    echo -e "  ${BOLD}CLI:${NC}             agmind status | agmind health"
    echo ""
    echo -e "  +--------------------------------------------------+"
    echo ""
}

# --- Main ---
main() {
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE=true;; --force-restart) FORCE_RESTART=true;;
            --help|-h) echo "Usage: sudo bash install.sh [--non-interactive] [--force-restart]"; exit 0;;
        esac; shift
    done

    # Root check
    [[ "$(id -u)" -ne 0 && "$(uname)" != "Darwin" ]] && { log_error "Run as root: sudo bash install.sh"; exit 1; }

    _acquire_lock
    mkdir -p "$INSTALL_DIR"

    # Logging (BUG-002 fix: touch+chmod BEFORE tee)
    local LOG_FILE="${INSTALL_DIR}/install.log"
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    show_banner

    # Checkpoint resume
    local start=1
    [[ "$FORCE_RESTART" == "true" ]] && rm -f "${INSTALL_DIR}/.install_phase"
    if [[ -f "${INSTALL_DIR}/.install_phase" ]]; then
        local saved; saved="$(cat "${INSTALL_DIR}/.install_phase" 2>/dev/null)"
        if [[ "$saved" =~ ^[1-9]$ ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then start="$saved"
            else read -rp "Resume from phase ${saved}/9? (yes/no/restart): " r
                case "$r" in yes|y) start="$saved";; restart) rm -f "${INSTALL_DIR}/.install_phase";; *) exit 0;; esac
            fi
        fi
    fi
    # On resume past wizard: load existing .env
    if [[ $start -gt 2 && -f "${INSTALL_DIR}/docker/.env" ]]; then
        set +u; source "${INSTALL_DIR}/docker/.env"; set -u
    fi

    # Phase table
    local t=9
    [[ $start -le 1 ]] && run_phase 1 $t "Diagnostics"   phase_diagnostics
    [[ $start -le 2 ]] && run_phase 2 $t "Wizard"        phase_wizard
    [[ $start -le 3 ]] && run_phase 3 $t "Docker"        phase_docker
    [[ $start -le 4 ]] && run_phase 4 $t "Configuration" phase_config
    [[ $start -le 5 ]] && run_phase_with_timeout 5 $t "Start"  phase_start  "$TIMEOUT_START"
    [[ $start -le 6 ]] && run_phase_with_timeout 6 $t "Health" phase_health "$TIMEOUT_HEALTH"
    [[ $start -le 7 ]] && run_phase_with_timeout 7 $t "Models" phase_models "$TIMEOUT_MODELS"
    [[ $start -le 8 ]] && run_phase 8 $t "Backups"       phase_backups
    [[ $start -le 9 ]] && run_phase 9 $t "Complete"      phase_complete

    rm -f "${INSTALL_DIR}/.install_phase"
}

main "$@"
