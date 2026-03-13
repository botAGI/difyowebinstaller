#!/usr/bin/env bash
# health.sh — Health check for all containers
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

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

        sleep $interval
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
        send_alert "⚠️ AGMind: ${failed} сервис(ов) не работает. Проверьте: $(hostname -I 2>/dev/null | awk '{print $1}')"
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
                curl -sf -X POST "$webhook_url" \
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
                curl -sf "https://api.telegram.org/bot${tg_token}/sendMessage" \
                    -d "chat_id=${tg_chat_id}" \
                    -d "text=${message}" \
                    -d "parse_mode=HTML" \
                    >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_all
fi
