#!/usr/bin/env bash
# health.sh — Healthcheck for all containers, extended reports, alerts.
# Dependencies: common.sh (log_*, colors)
# Functions: wait_healthy(timeout), check_all(), report_health(), send_alert(msg)
# Expects: INSTALL_DIR
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# SERVICE LIST (dynamic based on .env)
# ============================================================================

get_service_list() {
    local compose_dir="${INSTALL_DIR}/docker"
    local env_file="${compose_dir}/.env"
    local services=(db redis sandbox ssrf_proxy api worker web plugin_daemon pipelines nginx open-webui)

    if [[ -f "$env_file" ]]; then
        # Vector store
        local vector_store
        vector_store="$(grep '^VECTOR_STORE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")"
        if [[ "$vector_store" == "qdrant" ]]; then
            services+=(qdrant)
        else
            services+=(weaviate)
        fi

        # LLM/Embedding providers
        local llm_provider embed_provider
        llm_provider="$(grep '^LLM_PROVIDER=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
        embed_provider="$(grep '^EMBED_PROVIDER=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
        if [[ "$llm_provider" == "ollama" || "$embed_provider" == "ollama" ]]; then
            services+=(ollama)
        fi
        [[ "$llm_provider" == "vllm" ]] && services+=(vllm)
        [[ "$embed_provider" == "tei" ]] && services+=(tei)

        # Monitoring
        local monitoring_mode
        monitoring_mode="$(grep '^MONITORING_MODE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "none")"
        if [[ "$monitoring_mode" == "local" ]]; then
            services+=(prometheus alertmanager cadvisor node-exporter grafana portainer loki promtail)
        fi

        # ETL
        local etl_type
        etl_type="$(grep '^ETL_TYPE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "dify")"
        if [[ "$etl_type" == "unstructured_api" ]]; then
            services+=(docling xinference)
        fi
    else
        services+=(weaviate)
    fi

    echo "${services[@]}"
}

# ============================================================================
# CONTAINER CHECK
# ============================================================================

check_container() {
    local name="$1"
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    local status
    status="$(docker compose -f "$compose_file" ps --format '{{.Status}}' "$name" 2>/dev/null || echo "not found")"

    if echo "$status" | grep -qi "up\|healthy"; then
        echo -e "  ${GREEN}[OK]${NC}  ${name}"
        return 0
    elif echo "$status" | grep -qi "starting"; then
        echo -e "  ${YELLOW}[..]${NC}  ${name} (starting)"
        return 1
    else
        echo -e "  ${RED}[!!]${NC}  ${name} (${status})"
        return 1
    fi
}

# ============================================================================
# WAIT HEALTHY
# ============================================================================

wait_healthy() {
    local timeout="${1:-300}"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300
    local interval=5
    local elapsed=0
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"

    log_info "Waiting for containers to be healthy (timeout: ${timeout}s)..."
    echo ""

    local services
    read -ra services <<< "$(get_service_list)"

    while [[ $elapsed -lt $timeout ]]; do
        local all_ok=true

        for svc in "${services[@]}"; do
            local status
            status="$(docker compose -f "$compose_file" ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")"
            if ! echo "$status" | grep -qi "up\|healthy"; then
                all_ok=false
                break
            fi
        done

        if [[ "$all_ok" == "true" ]]; then
            log_success "All containers are up!"
            echo ""
            check_all
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -ne "\r  Waiting... ${elapsed}/${timeout}s"
    done

    echo ""
    log_error "Timeout! Not all containers started within ${timeout}s"
    echo ""
    check_all
    return 1
}

# ============================================================================
# CHECK ALL
# ============================================================================

check_all() {
    echo -e "${CYAN}=== Container Status ===${NC}"

    local services
    read -ra services <<< "$(get_service_list)"
    local failed=0

    for svc in "${services[@]}"; do
        check_container "$svc" || failed=$((failed + 1))
    done

    echo ""
    if [[ $failed -eq 0 ]]; then
        log_success "All services running"
    else
        log_warn "${failed} service(s) not running"
        local server_ip="unknown"
        if [[ "$(uname)" == "Darwin" ]]; then
            server_ip="$(ipconfig getifaddr en0 2>/dev/null || echo "unknown")"
        else
            server_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")"
        fi
        [[ -z "${server_ip:-}" ]] && server_ip="$(hostname 2>/dev/null || echo 'unknown')"
        send_alert "AGMind: ${failed} service(s) not running. Check: ${server_ip}"
        echo "  Check logs: docker compose logs <service>"
    fi

    return "$failed"
}

# ============================================================================
# SEND ALERT
# ============================================================================

send_alert() {
    local message="$1"
    local env_file="${INSTALL_DIR}/docker/.env"
    [[ -f "$env_file" ]] || return 0

    local alert_mode
    alert_mode="$(grep '^ALERT_MODE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "none")"

    case "$alert_mode" in
        webhook)
            local webhook_url
            webhook_url="$(grep '^ALERT_WEBHOOK_URL=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
            if [[ -n "$webhook_url" ]]; then
                local escaped_message
                escaped_message="$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')"
                curl -sf --max-time 10 -X POST "$webhook_url" \
                    -H "Content-Type: application/json" \
                    -d "{\"text\":\"${escaped_message}\",\"source\":\"agmind-health\"}" \
                    >/dev/null 2>&1 || true
            fi
            ;;
        telegram)
            local tg_token tg_chat_id
            tg_token="$(grep '^ALERT_TELEGRAM_TOKEN=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
            tg_chat_id="$(grep '^ALERT_TELEGRAM_CHAT_ID=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
            if [[ -n "$tg_token" && -n "$tg_chat_id" ]]; then
                curl -sf --max-time 10 -K - \
                    -d "chat_id=${tg_chat_id}" \
                    -d "text=${message}" \
                    -d "parse_mode=HTML" \
                    >/dev/null 2>&1 <<CURL_CFG || true
url = "https://api.telegram.org/bot${tg_token}/sendMessage"
CURL_CFG
            fi
            ;;
    esac
}

# ============================================================================
# EXTENDED CHECKS (for report_health)
# ============================================================================

check_gpu_status() {
    echo -e "${BOLD}GPU Status:${NC}"
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=name,memory.used,memory.free,temperature.gpu,utilization.gpu \
            --format=csv,noheader 2>/dev/null | while IFS=',' read -r name mem_used mem_free temp util; do
            printf "  %-20s | Mem: %s / %s | Temp: %s | Load: %s\n" \
                "$(echo "$name" | xargs)" "$(echo "$mem_used" | xargs)" \
                "$(echo "$mem_free" | xargs)" "$(echo "$temp" | xargs)" "$(echo "$util" | xargs)"
        done
    elif command -v rocm-smi &>/dev/null; then
        rocm-smi --showuse --showmemuse --showtemp 2>/dev/null | head -20
    else
        echo "  CPU mode (no GPU detected)"
    fi
    echo ""
}

check_ollama_models() {
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    echo -e "${BOLD}Ollama Models:${NC}"
    local response
    response="$(docker compose -f "$compose_file" exec -T ollama ollama list 2>/dev/null)" || {
        echo -e "  ${RED}Ollama API not available${NC}"
        echo ""
        return 1
    }

    if [[ -z "$response" ]] || ! echo "$response" | grep -q "NAME"; then
        echo "  (no models loaded)"
    else
        echo "$response" | tail -n +2 | while IFS= read -r line; do
            [[ -n "$line" ]] && echo "  $line"
        done
    fi
    echo ""
}

check_vector_health() {
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    local env_file="${INSTALL_DIR}/docker/.env"
    echo -e "${BOLD}Vector Store:${NC}"

    local vs="weaviate"
    [[ -f "$env_file" ]] && vs="$(grep '^VECTOR_STORE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")"

    case "$vs" in
        weaviate)
            local meta
            meta="$(docker compose -f "$compose_file" exec -T weaviate curl -sf --max-time 5 http://localhost:8080/v1/meta 2>/dev/null)" || {
                echo -e "  ${RED}Weaviate: not available${NC}"
                echo ""
                return 1
            }
            local version
            version="$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")"
            echo -e "  ${GREEN}Weaviate: v${version} — OK${NC}"
            ;;
        qdrant)
            if docker compose -f "$compose_file" exec -T qdrant curl -sf --max-time 5 http://localhost:6333/healthz >/dev/null 2>&1; then
                local collections
                collections="$(docker compose -f "$compose_file" exec -T qdrant curl -sf --max-time 5 http://localhost:6333/collections 2>/dev/null | \
                    python3 -c "import json,sys; colls=json.load(sys.stdin).get('result',{}).get('collections',[]); print(len(colls))" 2>/dev/null || echo "?")"
                echo -e "  ${GREEN}Qdrant: OK (${collections} collections)${NC}"
            else
                echo -e "  ${RED}Qdrant: not available${NC}"
            fi
            ;;
    esac
    echo ""
}

check_disk_usage() {
    echo -e "${BOLD}Disk Usage:${NC}"
    local docker_df
    docker_df="$(docker system df 2>/dev/null)" || {
        log_warn "docker system df not available"
        echo ""
        return 0
    }
    echo "$docker_df" | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""
    if [[ -d "${INSTALL_DIR}" ]]; then
        local dir_size
        dir_size="$(du -sh "${INSTALL_DIR}" 2>/dev/null | cut -f1 || echo "?")"
        echo "  Install dir (${INSTALL_DIR}): ${dir_size}"
    fi
    if [[ -d "/var/backups/agmind" ]]; then
        local backup_size
        backup_size="$(du -sh /var/backups/agmind 2>/dev/null | cut -f1 || echo "?")"
        echo "  Backups (/var/backups/agmind): ${backup_size}"
    fi
    echo ""
}

check_backup_status() {
    echo -e "${BOLD}Last Backup:${NC}"
    local backup_dir="/var/backups/agmind"

    if [[ ! -d "$backup_dir" ]]; then
        echo -e "  ${YELLOW}Backup directory not found${NC}"
        echo ""
        return 0
    fi

    local latest
    latest="$(ls -1d "${backup_dir}"/20* 2>/dev/null | sort -r | head -1)"
    if [[ -z "$latest" ]]; then
        echo -e "  ${YELLOW}No backups found${NC}"
        echo ""
        return 0
    fi

    local backup_date backup_size
    backup_date="$(basename "$latest")"
    backup_size="$(du -sh "$latest" 2>/dev/null | cut -f1 || echo "?")"

    local backup_ts now_ts age_hours
    backup_ts="$(date -d "${backup_date//_/ }" +%s 2>/dev/null || stat -f %m "$latest" 2>/dev/null || echo 0)"
    now_ts="$(date +%s)"
    if [[ "$backup_ts" -gt 0 ]]; then
        age_hours=$(( (now_ts - backup_ts) / 3600 ))
        if [[ $age_hours -lt 24 ]]; then
            echo -e "  ${GREEN}${backup_date} (${backup_size}, ${age_hours}h ago)${NC}"
        elif [[ $age_hours -lt 72 ]]; then
            echo -e "  ${YELLOW}${backup_date} (${backup_size}, ${age_hours}h ago)${NC}"
        else
            echo -e "  ${RED}${backup_date} (${backup_size}, ${age_hours}h ago — stale!)${NC}"
        fi
    else
        echo "  ${backup_date} (${backup_size})"
    fi

    if [[ -f "${latest}/sha256sums.txt" ]]; then
        echo -e "  ${GREEN}Checksums: present${NC}"
    fi
    echo ""
}

# ============================================================================
# FULL HEALTH REPORT
# ============================================================================

report_health() {
    echo ""
    echo -e "${BOLD}${CYAN}=========================================${NC}"
    echo -e "${BOLD}${CYAN}  AGMind Health Report${NC}"
    echo -e "${BOLD}${CYAN}=========================================${NC}"
    echo ""

    check_all || true
    echo ""
    check_gpu_status
    check_ollama_models || true
    check_vector_health || true
    check_disk_usage
    check_backup_status
}

# ============================================================================
# STANDALONE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"

    INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

    case "${1:-}" in
        --send-test)
            log_info "Sending test alert..."
            send_alert "Test alert AGMind — system operating normally"
            log_success "Test sent!"
            ;;
        --full)
            report_health
            ;;
        *)
            check_all
            ;;
    esac
fi
