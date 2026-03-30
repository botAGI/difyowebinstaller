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
TIMEOUT_GPU_HEALTH="${TIMEOUT_GPU_HEALTH:-900}"  # 15 min default; 0 = no limit
TIMEOUT_MODELS="${TIMEOUT_MODELS:-1200}"
VDS_MODE="${VDS_MODE:-false}"

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
        # Pull is idempotent — retry directly, no compose down
        local retry=$((timeout * 2))
        log_warn "Phase ${name} timed out after ${timeout}s. Retrying (${retry}s)..."
        rc=0
        _run_with_timeout "$func" "$retry" || rc=$?
        if [[ $rc -eq 0 ]]; then
            echo -e "${GREEN}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} DONE (retry) ===${NC}"
            return 0
        fi
        if [[ $rc -eq 124 ]]; then
            log_warn "Phase ${name} timed out after ${retry}s"
            if [[ "$name" == "Models" ]]; then
                log_warn "Model download timed out. Containers continue downloading in background."
                local llm_provider="${LLM_PROVIDER:-ollama}"
                local embed_provider="${EMBED_PROVIDER:-ollama}"
                if [[ "$llm_provider" == "ollama" ]]; then
                    log_warn "Retry: docker exec agmind-ollama ollama pull ${LLM_MODEL:-qwen2.5:14b}"
                elif [[ "$llm_provider" == "vllm" ]]; then
                    log_warn "Monitor: docker logs -f agmind-vllm"
                fi
                if [[ "$embed_provider" == "tei" ]]; then
                    log_warn "Monitor: docker logs -f agmind-tei"
                elif [[ "$embed_provider" == "ollama" ]]; then
                    log_warn "Retry: docker exec agmind-ollama ollama pull ${EMBEDDING_MODEL:-bge-m3}"
                fi
                log_warn "Installation continues..."
                return 0
            fi
            log_error "Phase ${name} timed out after ${retry}s"
            return 1
        fi
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
phase_pull()        { compose_pull; }
phase_start()       { compose_start; create_openwebui_admin; }
phase_health()      { wait_healthy "$TIMEOUT_HEALTH" "$TIMEOUT_GPU_HEALTH"; _check_critical_services; _obtain_letsencrypt_cert; }
phase_models()      { download_models; }
phase_models_graceful() {
    local rc=0
    phase_models || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo ""
        log_warn "Models were not fully downloaded."
        log_warn "Containers continue downloading in background."
        echo ""
        local llm_provider="${LLM_PROVIDER:-ollama}"
        local embed_provider="${EMBED_PROVIDER:-ollama}"
        local llm_model="${LLM_MODEL:-qwen2.5:14b}"
        local embedding_model="${EMBEDDING_MODEL:-bge-m3}"
        if [[ "$llm_provider" == "ollama" ]]; then
            log_warn "Retry Ollama LLM:       docker exec agmind-ollama ollama pull ${llm_model}"
        elif [[ "$llm_provider" == "vllm" ]]; then
            log_warn "Monitor vLLM progress:  docker logs -f agmind-vllm"
        fi
        if [[ "$embed_provider" == "ollama" ]]; then
            log_warn "Retry Ollama Embedding: docker exec agmind-ollama ollama pull ${embedding_model}"
        elif [[ "$embed_provider" == "tei" ]]; then
            log_warn "Monitor TEI progress:   docker logs -f agmind-tei"
        fi
        echo ""
        log_warn "Installation continues..."
        return 0  # Do NOT propagate error — installation continues
    fi
}
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
    local scripts=(backup.sh restore.sh uninstall.sh update.sh agmind.sh health-gen.sh rotate_secrets.sh dr-drill.sh generate-manifest.sh redis-lock-cleanup.sh)
    for s in "${scripts[@]}"; do
        [[ -f "${INSTALLER_DIR}/scripts/${s}" ]] && cp "${INSTALLER_DIR}/scripts/${s}" "${INSTALL_DIR}/scripts/"
    done
    cp "${INSTALLER_DIR}/lib/health.sh" "${INSTALL_DIR}/scripts/health.sh" 2>/dev/null || true
    cp "${INSTALLER_DIR}/lib/detect.sh" "${INSTALL_DIR}/scripts/detect.sh" 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
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

    # Wait for Dify API health only (don't check init endpoint — its codes vary by version)
    local attempts=0 max_attempts=120  # 120 × 5s = 10 min
    while [[ $attempts -lt $max_attempts ]]; do
        if docker exec agmind-api curl -sf http://localhost:5001/health >/dev/null 2>&1; then
            break
        fi
        sleep 5
        attempts=$((attempts + 1))
    done
    if [[ $attempts -ge $max_attempts ]]; then
        log_warn "[dify-init] Dify API not ready after 10 min, skipping auto-init"
        log_warn "[dify-init] Run 'agmind init-dify' manually after API is healthy"
        return 0
    fi
    # Extra settle time — API may accept /health before init endpoints are ready
    sleep 5

    log_info "[dify-init] Initializing Dify admin (two-step: init → setup)..."

    # Two-step init: POST /console/api/init → check → POST /console/api/setup
    # Step 1 returns a session cookie required by step 2
    local try
    for try in 1 2 3; do
        local resp
        resp="$(docker exec \
            -e "INIT_PWD=${init_password}" \
            -e "ADMIN_PWD=${admin_password}" \
            agmind-api sh -c '
                # Step 1: init — get session cookie
                init_code=$(curl -s -o /tmp/dify_init_resp -w "%{http_code}" \
                    -c /tmp/dify_cookies \
                    -H "Content-Type: application/json" \
                    -d "{\"password\":\"$INIT_PWD\"}" \
                    http://localhost:5001/console/api/init)
                init_body=$(cat /tmp/dify_init_resp 2>/dev/null)

                # If init says already setup — we are done
                if echo "$init_body" | grep -qi "already"; then
                    echo "ALREADY_INIT"
                    rm -f /tmp/dify_cookies /tmp/dify_init_resp
                    exit 0
                fi

                # If init failed (non-2xx) — report and bail
                case "$init_code" in
                    2*) ;;  # 2xx — success, continue to setup
                    *)  echo "INIT_FAIL:${init_code}:${init_body}"
                        rm -f /tmp/dify_cookies /tmp/dify_init_resp
                        exit 0 ;;
                esac

                # Step 2: setup — create admin account using session cookie
                setup_resp=$(curl -s -w "\nHTTP_%{http_code}" \
                    -b /tmp/dify_cookies \
                    -H "Content-Type: application/json" \
                    -d "{\"email\":\"admin@agmind.ai\",\"name\":\"AGMind Admin\",\"password\":\"$ADMIN_PWD\"}" \
                    http://localhost:5001/console/api/setup)
                echo "$setup_resp"
                rm -f /tmp/dify_cookies /tmp/dify_init_resp
            ' 2>&1)" || true

        # Check result
        if echo "$resp" | grep -qi "ALREADY_INIT\|already.*setup\|already.*initialized"; then
            log_info "[dify-init] Dify already initialized"
            touch "${INSTALL_DIR}/.dify_initialized"
            return 0
        elif echo "$resp" | grep -q "HTTP_2"; then
            log_success "[dify-init] Dify admin initialized"
            touch "${INSTALL_DIR}/.dify_initialized"
            return 0
        elif echo "$resp" | grep -q "INIT_FAIL"; then
            log_warn "[dify-init] Dify init step failed (attempt ${try}/3): $(echo "$resp" | head -c 200)"
        else
            log_warn "[dify-init] Dify setup step failed (attempt ${try}/3): $(echo "$resp" | head -c 200)"
        fi

        [[ $try -lt 3 ]] || break
        sleep 60
    done
    log_warn "[dify-init] Dify init failed after 3 attempts — run 'agmind init-dify' manually"
}

_save_credentials() {
    local ip; ip="$(_get_ip)"
    local url="http://${ip}"; [[ "${DEPLOY_PROFILE:-}" == "vps" && -n "${DOMAIN:-}" ]] && url="https://${DOMAIN}"
    local owui_pass=""; [[ -f "${INSTALL_DIR}/.admin_password" ]] && owui_pass="$(cat "${INSTALL_DIR}/.admin_password")"
    {
        echo "# AGMind Credentials — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "Open WebUI:  ${url}"
        echo "  Login: admin@agmind.ai"
        echo "  Pass:  ${owui_pass:-N/A}"
        echo ""
        echo "Dify Console: http://${DOMAIN:-$ip}:3000"
        echo "  Login: admin@agmind.ai"
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
        if [[ ! -f "${INSTALL_DIR}/.dify_initialized" ]]; then
            echo ""
            echo "Dify Admin (ручная настройка):"
            echo "  Dify не был инициализирован автоматически."
            echo "  Откройте http://${DOMAIN:-$ip}:3000/install"
            echo "  Пароль инициализации: grep INIT_PASSWORD ${INSTALL_DIR}/docker/.env | cut -d= -f2-"
        fi
        # Model API Endpoints — Dify "Add Model" form fields, copy-paste ready
        if [[ "${LLM_PROVIDER:-}" == "vllm" ]]; then
            echo ""
            echo "=== vLLM (Dify → Settings → Model Provider → OpenAI-API-compatible) ==="
            echo "  Model Type:              LLM"
            echo "  Model Name:              ${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct}"
            echo "  API endpoint URL:        http://agmind-vllm:8000/v1"
            echo "  API Key:                 none"
            echo "  model name for endpoint: ${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct}"
        fi
        if [[ "${LLM_PROVIDER:-}" == "ollama" || "${EMBED_PROVIDER:-}" == "ollama" ]]; then
            echo ""
            echo "=== Ollama (Dify → Settings → Model Provider → Ollama) ==="
            echo "  Base URL:                http://agmind-ollama:11434"
            if [[ "${LLM_PROVIDER:-}" == "ollama" ]]; then
                echo "  Model Type:              LLM"
                echo "  Model Name:              ${LLM_MODEL:-qwen2.5:14b}"
            fi
            if [[ "${EMBED_PROVIDER:-}" == "ollama" ]]; then
                echo "  Model Type:              Text Embedding"
                echo "  Model Name:              ${EMBEDDING_MODEL:-bge-m3}"
            fi
        fi
        if [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then
            echo ""
            echo "=== TEI Embedding (Dify → Settings → Model Provider → OpenAI-API-compatible) ==="
            echo "  Model Type:              Text Embedding"
            echo "  Model Name:              ${EMBEDDING_MODEL:-deepvk/USER-bge-m3}"
            echo "  API endpoint URL:        http://agmind-tei:80/v1"
            echo "  API Key:                 none"
            echo "  model name for endpoint: ${EMBEDDING_MODEL:-deepvk/USER-bge-m3}"
        fi
        if [[ "${ENABLE_RERANKER:-false}" == "true" ]]; then
            echo ""
            echo "=== TEI Reranker (Dify → Settings → Model Provider → OpenAI-API-compatible) ==="
            echo "  Model Type:              Rerank"
            echo "  Model Name:              ${RERANK_MODEL:-BAAI/bge-reranker-base}"
            echo "  API endpoint URL:        http://agmind-tei-rerank:80/v1"
            echo "  API Key:                 none"
            echo "  model name for endpoint: ${RERANK_MODEL:-BAAI/bge-reranker-base}"
        fi
        # LiteLLM AI Gateway
        echo ""
        echo "=== LiteLLM AI Gateway ==="
        echo "  UI:        http://${DOMAIN:-$ip}/litellm/"
        echo "  API:       http://agmind-litellm:4000/v1  (internal, for Dify/OWUI)"
        echo "  Master Key: ${LITELLM_MASTER_KEY:-see .env}"
        echo ""
        echo "  Dify Model Provider (Settings -> Model Provider -> OpenAI-API-compatible):"
        echo "    Model Type:              LLM"
        echo "    Model Name:              litellm"
        echo "    API endpoint URL:        http://agmind-litellm:4000/v1"
        echo "    API Key:                 ${LITELLM_MASTER_KEY:-see .env}"
        echo "    model name for endpoint: *"
        # Optional Services
        if [[ "${ENABLE_SEARXNG:-false}" == "true" ]]; then
            echo ""
            echo "=== SearXNG (Поисковый движок) ==="
            echo "  URL:           http://${ip}:${SEARXNG_PORT:-8888}"
            echo "  JSON API:      http://${ip}:${SEARXNG_PORT:-8888}/search?q=test&format=json"
        fi
        if [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]]; then
            echo ""
            echo "=== Open Notebook (Исследовательский ассистент) ==="
            echo "  URL:           http://agmind-notebook:8502  (internal)"
            echo "  Настройте LLM провайдер в Settings после первого входа."
        fi
        if [[ "${ENABLE_DBGPT:-false}" == "true" ]]; then
            echo ""
            echo "=== DB-GPT (Аналитика данных) ==="
            echo "  URL:           http://agmind-dbgpt:5670  (internal)"
            echo "  LLM через LiteLLM (автонастройка)."
        fi
        if [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]]; then
            echo ""
            echo "=== Crawl4AI (Веб-краулер) ==="
            echo "  API:           http://agmind-crawl4ai:11235  (internal)"
            echo "  Playground:    http://agmind-crawl4ai:11235/playground  (internal)"
        fi
        echo ""
        echo "# ---"
        echo "# ВНИМАНИЕ: Эти пароли актуальны на момент установки."
        echo "# При смене пароля через UI обновите этот файл вручную."
        echo "# WARNING: Passwords reflect installation defaults."
        echo "# If changed via UI, update this file manually."
    } > "${INSTALL_DIR}/credentials.txt"
    chmod 600 "${INSTALL_DIR}/credentials.txt"
    log_info "Credentials: ${INSTALL_DIR}/credentials.txt"
}

_get_ip() { if [[ "$(uname)" == "Darwin" ]]; then ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1"; else hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"; fi; }

_obtain_letsencrypt_cert() {
    [[ "${TLS_MODE:-none}" != "letsencrypt" ]] && return 0
    [[ -z "${DOMAIN:-}" ]] && { log_warn "TLS: letsencrypt requires DOMAIN — skipping cert obtain"; return 0; }
    [[ -z "${CERTBOT_EMAIL:-}" ]] && { log_warn "TLS: letsencrypt requires CERTBOT_EMAIL — skipping cert obtain"; return 0; }

    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"

    log_info "Obtaining Let's Encrypt certificate for ${DOMAIN}..."

    # Certbot obtains cert via webroot (nginx serves /.well-known/acme-challenge/)
    if docker compose -f "$compose_file" run --rm certbot \
        certonly --webroot \
        --webroot-path=/var/www/certbot \
        --email "${CERTBOT_EMAIL}" \
        --agree-tos --no-eff-email \
        -d "${DOMAIN}" \
        --non-interactive 2>&1 | tail -5; then

        log_success "Let's Encrypt certificate obtained for ${DOMAIN}"

        # Update nginx config to use real LE cert paths
        local nginx_conf="${INSTALL_DIR}/docker/nginx/nginx.conf"
        local le_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        local le_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        sed -i "s|/etc/nginx/ssl/cert.pem|${le_cert}|g" "$nginx_conf"
        sed -i "s|/etc/nginx/ssl/key.pem|${le_key}|g" "$nginx_conf"

        # Reload nginx to pick up real cert
        docker compose -f "$compose_file" exec -T nginx nginx -s reload 2>/dev/null || {
            log_warn "nginx reload failed — restart nginx manually: docker compose restart nginx"
        }
        log_success "Nginx reloaded with Let's Encrypt certificate"
    else
        log_warn "Let's Encrypt cert obtain failed — nginx continues with self-signed placeholder"
        log_warn "Retry manually: docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot -d ${DOMAIN} --email ${CERTBOT_EMAIL} --agree-tos"
    fi
}

_install_cli() {
    [[ -d /usr/local/bin ]] && ln -sf "${INSTALL_DIR}/scripts/agmind.sh" /usr/local/bin/agmind && log_success "'agmind' command available"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${INSTALL_DIR}/.agmind_installed"
    # Write current release tag for update system (BUG-V3-044)
    if [[ -f "${INSTALLER_DIR}/RELEASE" ]]; then
        cp "${INSTALLER_DIR}/RELEASE" "${INSTALL_DIR}/RELEASE"
    fi
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
    echo -e "    Login:         admin@agmind.ai"
    echo -e "    Pass:          ${owui_pass:-см. credentials.txt}"
    echo ""
    echo -e "  ${BOLD}Dify Console:${NC}    ${GREEN}${dify_url}${NC}"
    echo -e "    Login:         admin@agmind.ai"
    echo -e "    Pass:          ${owui_pass:-см. credentials.txt}"
    echo ""
    echo -e "  ${BOLD}LiteLLM UI:${NC}      ${GREEN}http://${ip}/litellm/${NC}"
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
    echo -e "  ${BOLD}Credentials:${NC}     nano ${INSTALL_DIR}/credentials.txt"
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
            --non-interactive) NON_INTERACTIVE=true;;
            --force-restart) FORCE_RESTART=true;;
            --dry-run) DRY_RUN=true;;
            --vds) DEPLOY_PROFILE="vps"; VDS_MODE=true;;
            --help|-h) echo "Usage: sudo bash install.sh [--non-interactive] [--force-restart] [--dry-run] [--vds]"; exit 0;;
        esac; shift
    done

    # Root check
    [[ "$(id -u)" -ne 0 && "$(uname)" != "Darwin" ]] && { log_error "Run as root: sudo bash install.sh"; exit 1; }

    _acquire_lock
    mkdir -p "$INSTALL_DIR"

    # Initialize git repo so agmind update --main works after fresh install
    if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
        git -C "$INSTALL_DIR" init -b main >/dev/null 2>&1
        git -C "$INSTALL_DIR" remote add origin https://github.com/botAGI/AGmind.git 2>/dev/null || true
    fi

    # Save original TTY fd before tee redirect (used by docker compose pull for progress)
    ORIGINAL_TTY_FD=""
    if [ -t 1 ]; then
        exec 3>&1
        ORIGINAL_TTY_FD=3
    fi
    export ORIGINAL_TTY_FD

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

    # On resume: always re-run diagnostics to populate DETECTED_* vars (BFIX-42)
    # Only run_diagnostics (lightweight detection, no prompts) -- NOT phase_diagnostics
    # which would re-run preflight_checks and may prompt the user.
    # || true: detection may partially fail (e.g. no nvidia-smi) but sets safe defaults.
    if [[ $start -gt 1 ]]; then
        log_info "Resume: re-running system diagnostics..."
        run_diagnostics || true
    fi

    # Phase table
    local t=10
    [[ $start -le 1  ]] && run_phase 1  $t "Diagnostics"   phase_diagnostics
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        preflight_checks || true
        preflight_rc=$?
        log_info "Dry-run complete — exiting without starting containers"
        exit "$preflight_rc"
    fi
    [[ $start -le 2  ]] && run_phase 2  $t "Wizard"        phase_wizard
    [[ $start -le 3  ]] && run_phase 3  $t "Docker"        phase_docker
    [[ $start -le 4  ]] && run_phase 4  $t "Configuration" phase_config
    [[ $start -le 5  ]] && run_phase 5  $t "Pull"   phase_pull   # inactivity timeout inside _pull_with_progress
    [[ $start -le 6  ]] && run_phase_with_timeout 6  $t "Start"  phase_start  "$TIMEOUT_START"
    [[ $start -le 7  ]] && run_phase 7  $t "Health" phase_health   # inactivity timeout inside wait_healthy
    [[ $start -le 8  ]] && run_phase 8  $t "Models" phase_models_graceful  # graceful: non-fatal on timeout
    [[ $start -le 9  ]] && run_phase 9  $t "Backups"       phase_backups
    [[ $start -le 10 ]] && run_phase 10 $t "Complete"      phase_complete

    rm -f "${INSTALL_DIR}/.install_phase"
}

main "$@"
