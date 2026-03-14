#!/usr/bin/env bash
# health.sh — Health check for all containers
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

COMPOSE_DIR="${INSTALL_DIR:-/opt/agmind}/docker"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

get_service_list() {
    local services=(db redis sandbox ssrf_proxy api worker web plugin_daemon ollama pipeline nginx open-webui)

    # Read .env to determine which optional services are active
    local env_file="${COMPOSE_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        local vector_store
        vector_store=$(grep '^VECTOR_STORE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")
        if [[ "$vector_store" == "qdrant" ]]; then
            services+=(qdrant)
        else
            services+=(weaviate)
        fi

        local monitoring_mode
        monitoring_mode=$(grep '^MONITORING_MODE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "none")
        if [[ "$monitoring_mode" == "local" ]]; then
            services+=(prometheus cadvisor grafana portainer)
        fi

        local etl_type
        etl_type=$(grep '^ETL_TYPE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "dify")
        if [[ "$etl_type" == "unstructured_api" ]]; then
            services+=(docling xinference)
        fi
    else
        services+=(weaviate)
    fi

    echo "${services[@]}"
}

check_container() {
    local name="$1"
    local status
    status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$name" 2>/dev/null || echo "not found")

    if echo "$status" | grep -qi "up\|healthy"; then
        echo -e "  ${GREEN}[OK]${NC}  $name"
        return 0
    elif echo "$status" | grep -qi "starting"; then
        echo -e "  ${YELLOW}[..]${NC}  $name (запускается)"
        return 1
    else
        echo -e "  ${RED}[!!]${NC}  $name ($status)"
        return 1
    fi
}

wait_healthy() {
    local timeout="${1:-300}"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300
    local interval=5
    local elapsed=0

    echo -e "${YELLOW}Ожидание готовности контейнеров (таймаут: ${timeout}с)...${NC}"
    echo ""

    local services
    read -ra services <<< "$(get_service_list)"

    while [[ $elapsed -lt $timeout ]]; do
        local all_ok=true

        for svc in "${services[@]}"; do
            local status
            status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")
            if ! echo "$status" | grep -qi "up\|healthy"; then
                all_ok=false
                break
            fi
        done

        if [[ "$all_ok" == "true" ]]; then
            echo -e "${GREEN}Все контейнеры запущены!${NC}"
            echo ""
            check_all
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -ne "\r  Ожидание... ${elapsed}/${timeout}с"
    done

    echo ""
    echo -e "${RED}Таймаут! Не все контейнеры запустились за ${timeout}с${NC}"
    echo ""
    check_all
    return 1
}

check_all() {
    echo -e "${YELLOW}=== Статус контейнеров ===${NC}"

    local services
    read -ra services <<< "$(get_service_list)"
    local failed=0

    for svc in "${services[@]}"; do
        check_container "$svc" || failed=$((failed + 1))
    done

    echo ""
    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}Все сервисы работают${NC}"
    else
        echo -e "${YELLOW}${failed} сервис(ов) не запущен(о)${NC}"
        local server_ip
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "$server_ip" ]] && server_ip=$(hostname 2>/dev/null || echo 'unknown')
        send_alert "⚠️ AGMind: ${failed} сервис(ов) не работает. Проверьте: ${server_ip}"
        echo "Проверьте логи: docker compose -f ${COMPOSE_FILE} logs <service>"
    fi

    return $failed
}

send_alert() {
    local message="$1"
    local env_file="${COMPOSE_DIR}/.env"

    local alert_mode
    alert_mode=$(grep '^ALERT_MODE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "none")

    case "$alert_mode" in
        webhook)
            local webhook_url
            webhook_url=$(grep '^ALERT_WEBHOOK_URL=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")
            if [[ -n "$webhook_url" ]]; then
                # Escape special JSON characters in message
                local escaped_message
                escaped_message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
                curl -sf --max-time 10 -X POST "$webhook_url" \
                    -H "Content-Type: application/json" \
                    -d "{\"text\":\"$escaped_message\",\"source\":\"agmind-health\"}" \
                    >/dev/null 2>&1 || true
            fi
            ;;
        telegram)
            local tg_token tg_chat_id
            tg_token=$(grep '^ALERT_TELEGRAM_TOKEN=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")
            tg_chat_id=$(grep '^ALERT_TELEGRAM_CHAT_ID=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")
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

check_gpu_status() {
    echo -e "${BOLD}GPU Status:${NC}"
    local gpu_profile="${INSTALL_DIR}/.agmind_gpu_profile"
    if [[ -f "$gpu_profile" ]]; then
        GPU_TYPE=$(grep '^GPU_TYPE=' "$gpu_profile" | cut -d= -f2 | head -1)
        GPU_NAME=$(grep '^GPU_NAME=' "$gpu_profile" | cut -d= -f2- | head -1)
        GPU_VRAM=$(grep '^GPU_VRAM=' "$gpu_profile" | cut -d= -f2 | head -1)
    fi

    case "${GPU_TYPE:-none}" in
        nvidia)
            if command -v nvidia-smi &>/dev/null; then
                nvidia-smi --query-gpu=name,memory.used,memory.free,temperature.gpu,utilization.gpu \
                    --format=csv,noheader 2>/dev/null | while IFS=',' read -r name mem_used mem_free temp util; do
                    printf "  %-20s | Mem: %s / %s | Temp: %s | Load: %s\n" \
                        "$(echo "$name" | xargs)" "$(echo "$mem_used" | xargs)" \
                        "$(echo "$mem_free" | xargs)" "$(echo "$temp" | xargs)" "$(echo "$util" | xargs)"
                done
            else
                echo -e "  ${YELLOW}nvidia-smi не найден${NC}"
            fi
            ;;
        amd)
            if command -v rocm-smi &>/dev/null; then
                rocm-smi --showuse --showmemuse --showtemp 2>/dev/null | head -20
            else
                echo -e "  ${YELLOW}rocm-smi не найден${NC}"
            fi
            ;;
        intel)
            echo "  Intel GPU (мониторинг через intel_gpu_top)"
            ;;
        none|cpu)
            echo "  CPU mode (GPU не обнаружен)"
            ;;
        *)
            echo "  GPU: ${GPU_TYPE:-unknown}"
            ;;
    esac
    echo ""
}

check_ollama_models() {
    echo -e "${BOLD}Ollama Models:${NC}"
    local response
    response=$(docker compose -f "$COMPOSE_FILE" exec -T ollama curl -sf --max-time 5 http://localhost:11434/api/tags 2>/dev/null) || {
        echo -e "  ${RED}Ollama API недоступен${NC}"
        echo ""
        return 1
    }

    # Parse JSON response — extract model names and sizes
    echo "$response" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    models = data.get('models', [])
    if not models:
        print('  (нет загруженных моделей)')
    for m in models:
        name = m.get('name', 'unknown')
        size_bytes = m.get('size', 0)
        size_gb = size_bytes / (1024**3)
        modified = m.get('modified_at', '')[:10]
        print(f'  {name:<40} {size_gb:.1f} GB  ({modified})')
except Exception as e:
    print(f'  Ошибка парсинга: {e}')
" 2>/dev/null || echo "  (не удалось прочитать список моделей)"
    echo ""
}

check_vector_health() {
    echo -e "${BOLD}Vector Store:${NC}"
    local env_file="${INSTALL_DIR}/docker/.env"
    local vs="weaviate"
    [[ -f "$env_file" ]] && vs=$(grep '^VECTOR_STORE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")

    case "$vs" in
        weaviate)
            local meta
            meta=$(docker compose -f "$COMPOSE_FILE" exec -T weaviate curl -sf --max-time 5 http://localhost:8080/v1/meta 2>/dev/null) || {
                echo -e "  ${RED}Weaviate: недоступен${NC}"
                echo ""
                return 1
            }
            local version
            version=$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
            echo -e "  ${GREEN}Weaviate: v${version} — OK${NC}"
            ;;
        qdrant)
            if docker compose -f "$COMPOSE_FILE" exec -T qdrant curl -sf --max-time 5 http://localhost:6333/healthz >/dev/null 2>&1; then
                local collections
                collections=$(docker compose -f "$COMPOSE_FILE" exec -T qdrant curl -sf --max-time 5 http://localhost:6333/collections 2>/dev/null | \
                    python3 -c "import json,sys; colls=json.load(sys.stdin).get('result',{}).get('collections',[]); print(len(colls))" 2>/dev/null || echo "?")
                echo -e "  ${GREEN}Qdrant: OK (${collections} коллекций)${NC}"
            else
                echo -e "  ${RED}Qdrant: недоступен${NC}"
            fi
            ;;
    esac
    echo ""
}

check_disk_usage() {
    echo -e "${BOLD}Disk Usage:${NC}"
    # Docker volumes summary
    local docker_df
    docker_df=$(docker system df 2>/dev/null) || {
        echo -e "  ${YELLOW}docker system df недоступен${NC}"
        echo ""
        return 0
    }
    echo "$docker_df" | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""
    # Install dir size
    if [[ -d "${INSTALL_DIR}" ]]; then
        local dir_size
        dir_size=$(du -sh "${INSTALL_DIR}" 2>/dev/null | cut -f1 || echo "?")
        echo "  Install dir (${INSTALL_DIR}): ${dir_size}"
    fi

    # Backup dir size
    if [[ -d "/var/backups/agmind" ]]; then
        local backup_size
        backup_size=$(du -sh /var/backups/agmind 2>/dev/null | cut -f1 || echo "?")
        echo "  Backups (/var/backups/agmind): ${backup_size}"
    fi
    echo ""
}

check_backup_status() {
    echo -e "${BOLD}Last Backup:${NC}"
    local backup_dir="/var/backups/agmind"

    if [[ ! -d "$backup_dir" ]]; then
        echo -e "  ${YELLOW}Директория бэкапов не найдена${NC}"
        echo ""
        return 0
    fi

    # Find latest backup directory
    local latest
    latest=$(ls -1d "${backup_dir}"/20* 2>/dev/null | sort -r | head -1)

    if [[ -z "$latest" ]]; then
        echo -e "  ${YELLOW}Бэкапов не найдено${NC}"
        echo ""
        return 0
    fi

    local backup_date
    backup_date=$(basename "$latest")
    local backup_size
    backup_size=$(du -sh "$latest" 2>/dev/null | cut -f1 || echo "?")

    # Calculate age
    local backup_ts now_ts age_hours
    backup_ts=$(date -d "${backup_date//_/ }" +%s 2>/dev/null || stat -f %m "$latest" 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    if [[ "$backup_ts" -gt 0 ]]; then
        age_hours=$(( (now_ts - backup_ts) / 3600 ))
        if [[ $age_hours -lt 24 ]]; then
            echo -e "  ${GREEN}${backup_date} (${backup_size}, ${age_hours}ч назад)${NC}"
        elif [[ $age_hours -lt 72 ]]; then
            echo -e "  ${YELLOW}${backup_date} (${backup_size}, ${age_hours}ч назад)${NC}"
        else
            echo -e "  ${RED}${backup_date} (${backup_size}, ${age_hours}ч назад — устарел!)${NC}"
        fi
    else
        echo "  ${backup_date} (${backup_size})"
    fi

    # Check sha256sums
    if [[ -f "${latest}/sha256sums.txt" ]]; then
        echo -e "  ${GREEN}Контрольные суммы: присутствуют${NC}"
    fi
    echo ""
}

# Full extended health report
report_health() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  AGMind Health Report${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    # Standard service checks
    check_all
    echo ""

    # Extended checks
    check_gpu_status
    check_ollama_models
    check_vector_health
    check_disk_usage
    check_backup_status
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

    # Handle --send-test flag
    if [[ "${1:-}" == "--send-test" ]]; then
        echo -e "${BOLD}Отправка тестового алерта...${NC}"
        send_alert "🧪 Тестовый алерт AGMind — система работает нормально"
        echo -e "${GREEN}Тест отправлен!${NC}"
        exit 0
    fi

    # Handle --full flag for extended report
    if [[ "${1:-}" == "--full" ]]; then
        report_health
        exit $?
    fi

    # Default: basic check
    check_all
    exit $?
fi
