#!/usr/bin/env bash
# AGMind Secret Rotation Script
set -euo pipefail
umask 077

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
ENV_FILE="${INSTALL_DIR}/docker/.env"
LOG_FILE="${INSTALL_DIR}/logs/secret_rotation.log"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --- Exclusive lock ---
LOCK_FILE="/var/lock/agmind-operation.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "${RED}Another AGMind operation is running${NC}"
    exit 1
fi

# --- Rollback trap ---
ROTATION_STARTED=false
TIMESTAMP=""
cleanup_rotation() {
    if [[ "$ROTATION_STARTED" == "true" ]] && [[ -n "$TIMESTAMP" ]] && [[ -f "${ENV_FILE}.pre-rotation.${TIMESTAMP}" ]]; then
        echo -e "${RED}Rotation failed — restoring backup...${NC}"
        cp "${ENV_FILE}.pre-rotation.${TIMESTAMP}" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        cd "${INSTALL_DIR}/docker" && docker compose restart 2>/dev/null || true
    fi
}
trap cleanup_rotation EXIT

generate_secret() {
    local length="${1:-32}"
    head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c "$length"
}

rotate_secrets() {
    echo -e "${BOLD}=== Ротация секретов AGMind ===${NC}"
    echo ""

    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}Файл .env не найден: ${ENV_FILE}${NC}"
        exit 1
    fi

    mkdir -p "${INSTALL_DIR}/logs"

    # Backup current .env
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    cp "$ENV_FILE" "${ENV_FILE}.pre-rotation.${TIMESTAMP}"
    chmod 600 "${ENV_FILE}.pre-rotation.${TIMESTAMP}"

    local timestamp_log
    timestamp_log=$(date '+%Y-%m-%d %H:%M:%S')

    # Rotate secrets
    local new_secret_key new_redis_pass new_grafana_pass
    new_secret_key=$(generate_secret 64)
    new_redis_pass=$(generate_secret 32)
    new_grafana_pass=$(generate_secret 16)

    local new_sandbox_key
    new_sandbox_key="dify-sandbox-$(generate_secret 16)"
    local new_plugin_daemon_key
    new_plugin_daemon_key=$(generate_secret 48)
    local new_plugin_inner_key
    new_plugin_inner_key=$(generate_secret 48)

    ROTATION_STARTED=true

    # Atomic sed: write to temp, then mv (umask 077 already set at script top)
    local env_tmp="${ENV_FILE}.tmp.$$"
    sed \
        -e "s|^SECRET_KEY=.*|SECRET_KEY=${new_secret_key}|" \
        -e "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${new_redis_pass}|" \
        -e "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${new_grafana_pass}|" \
        -e "s|^SANDBOX_API_KEY=.*|SANDBOX_API_KEY=${new_sandbox_key}|" \
        -e "s|^PLUGIN_DAEMON_KEY=.*|PLUGIN_DAEMON_KEY=${new_plugin_daemon_key}|" \
        -e "s|^PLUGIN_INNER_API_KEY=.*|PLUGIN_INNER_API_KEY=${new_plugin_inner_key}|" \
        "$ENV_FILE" > "$env_tmp" || { rm -f "$env_tmp"; return 1; }
    mv "$env_tmp" "$ENV_FILE"

    echo -e "${GREEN}Секреты обновлены:${NC}"
    echo -e "  ${GREEN}✓${NC} SECRET_KEY rotated"
    echo -e "  ${GREEN}✓${NC} REDIS_PASSWORD rotated"
    echo -e "  ${GREEN}✓${NC} GRAFANA_ADMIN_PASSWORD rotated"
    echo -e "  ${GREEN}✓${NC} SANDBOX_API_KEY rotated"
    echo -e "  ${GREEN}✓${NC} PLUGIN_DAEMON_KEY rotated"
    echo -e "  ${GREEN}✓${NC} PLUGIN_INNER_API_KEY rotated"

    # Re-encrypt if SOPS is enabled
    if [[ -f "${INSTALL_DIR}/.age/agmind.key" && -f "${ENV_FILE}.enc" ]]; then
        local pub_key
        pub_key=$(grep 'public key:' "${INSTALL_DIR}/.age/agmind.key" | cut -d: -f2- | tr -d ' ')
        SOPS_AGE_KEY_FILE="${INSTALL_DIR}/.age/agmind.key" sops --encrypt --age "$pub_key" "$ENV_FILE" > "${ENV_FILE}.enc"
        echo -e "${GREEN}  .env.enc обновлён${NC}"
    fi

    # Update Redis config file BEFORE restart (so Redis loads new password)
    local redis_conf="${INSTALL_DIR}/docker/volumes/redis/redis.conf"
    if [[ -f "$redis_conf" ]]; then
        local redis_tmp="${redis_conf}.tmp.$$"
        sed "s|^requirepass .*|requirepass ${new_redis_pass}|" "$redis_conf" > "$redis_tmp" \
            && mv "$redis_tmp" "$redis_conf" \
            || rm -f "$redis_tmp"
    fi

    # Restart affected services
    echo ""
    echo -e "${CYAN}Перезапуск сервисов...${NC}"
    cd "${INSTALL_DIR}/docker"
    docker compose restart api worker redis grafana sandbox plugin_daemon 2>/dev/null || true

    ROTATION_STARTED=false

    # Log rotation
    echo "${timestamp_log} | Secrets rotated: SECRET_KEY, REDIS_PASSWORD, GRAFANA_ADMIN_PASSWORD, SANDBOX_API_KEY, PLUGIN_DAEMON_KEY, PLUGIN_INNER_API_KEY" >> "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    # Send notification
    local alert_mode
    alert_mode=$(grep '^ALERT_MODE=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "none")
    if [[ "$alert_mode" == "telegram" ]]; then
        local token chat_id
        token=$(grep '^ALERT_TELEGRAM_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
        chat_id=$(grep '^ALERT_TELEGRAM_CHAT_ID=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
        if [[ -n "$token" && -n "$chat_id" ]]; then
            curl -sf --max-time 10 "https://api.telegram.org/bot${token}/sendMessage" \
                -d "chat_id=${chat_id}" \
                -d "text=🔐 AGMind: секреты ротированы ($(hostname 2>/dev/null || echo 'unknown'))" \
                -d "parse_mode=HTML" >/dev/null 2>&1 || true
        fi
    fi

    echo ""
    echo -e "${GREEN}=== Ротация завершена ===${NC}"
}

# Setup cron for monthly rotation
setup_rotation_cron() {
    if [[ "${ENABLE_SECRET_ROTATION:-false}" != "true" ]]; then return 0; fi
    local script_path="${INSTALL_DIR}/scripts/rotate_secrets.sh"
    local cron_entry="0 3 1 * * ${script_path} >> ${INSTALL_DIR}/logs/secret_rotation.log 2>&1"

    # Add to crontab if not already there
    if ! crontab -l 2>/dev/null | grep -q 'rotate_secrets'; then
        (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
        echo -e "${GREEN}Ротация секретов добавлена в cron (1-е число каждого месяца)${NC}"
    fi
}

# Main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    rotate_secrets
fi
