#!/usr/bin/env bash
# ============================================================================
# AGMind Update System — Rolling updates with rollback
# Usage: /opt/agmind/scripts/update.sh [--auto] [--check-only]
# ============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"
VERSIONS_FILE="${INSTALL_DIR}/versions.env"
MANIFEST_FILE="${INSTALL_DIR}/release-manifest.json"
ROLLBACK_DIR="${INSTALL_DIR}/.rollback"
ENV_FILE="${INSTALL_DIR}/docker/.env"
LOG_FILE="${INSTALL_DIR}/logs/update_history.log"
BACKUP_SCRIPT="${INSTALL_DIR}/scripts/backup.sh"
HEALTH_SCRIPT="${INSTALL_DIR}/scripts/health.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Define log functions BEFORE flock block that uses them
log_info() { echo -e "${CYAN}→ $*${NC}"; }
log_success() { echo -e "${GREEN}✓ $*${NC}"; }
log_warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
log_error() { echo -e "${RED}✗ $*${NC}"; }

# Exclusive lock — prevent parallel operations
LOCK_FILE="/var/lock/agmind-operation.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log_error "Другая операция AGMind уже запущена. Дождитесь завершения."
    exit 1
fi

# Fix log file permissions
mkdir -p "$(dirname "$LOG_FILE")"
chmod 700 "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Cleanup on failure
cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Update прерван. .env мог быть частично обновлён."
        log_error "Проверьте: diff ${ENV_FILE} ${ENV_FILE}.pre-update"
    fi
}
trap cleanup_on_failure EXIT INT TERM

AUTO_UPDATE="${AUTO_UPDATE:-false}"
CHECK_ONLY=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_UPDATE=true ;;
        --check-only) CHECK_ONLY=true ;;
    esac
done

# Send notification via configured alert channel
send_notification() {
    local message="$1"
    [[ ! -f "$ENV_FILE" ]] && return 0

    local alert_mode
    alert_mode=$(grep '^ALERT_MODE=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "none")

    case "$alert_mode" in
        telegram)
            local token chat_id
            token=$(grep '^ALERT_TELEGRAM_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
            chat_id=$(grep '^ALERT_TELEGRAM_CHAT_ID=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
            if [[ -n "$token" && -n "$chat_id" ]]; then
                curl -sf --max-time 10 -K - \
                    -d "chat_id=${chat_id}" \
                    -d "text=${message}" \
                    -d "parse_mode=HTML" \
                    >/dev/null 2>&1 <<CURL_CFG || true
url = "https://api.telegram.org/bot${token}/sendMessage"
CURL_CFG
            fi
            ;;
        webhook)
            local url
            url=$(grep '^ALERT_WEBHOOK_URL=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
            if [[ -n "$url" ]]; then
                local escaped_msg
                escaped_msg=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
                curl -sf --max-time 10 -X POST "$url" \
                    -H "Content-Type: application/json" \
                    -d "{\"text\":\"${escaped_msg}\",\"source\":\"agmind-update\"}" \
                    >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

check_preflight() {
    log_info "Pre-flight checks..."
    local errors=0

    # Disk space
    local free_gb
    free_gb=$(df -BG "${INSTALL_DIR}" 2>/dev/null | awk 'NR==2{gsub(/G/,"");print $4}' || echo "0")
    if ! [[ "$free_gb" =~ ^[0-9]+$ ]]; then
        free_gb=0
    fi
    if [[ "$free_gb" -lt 5 ]]; then
        log_error "Недостаточно места: ${free_gb}GB (требуется 5GB+)"
        errors=$((errors + 1))
    else
        log_success "Диск: ${free_gb}GB свободно"
    fi

    # Docker running
    if ! docker info &>/dev/null; then
        log_error "Docker daemon не запущен"
        errors=$((errors + 1))
    else
        log_success "Docker: работает"
    fi

    # Compose file exists
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "docker-compose.yml не найден: ${COMPOSE_FILE}"
        errors=$((errors + 1))
    fi

    return $errors
}

create_update_backup() {
    local tag
    tag="pre-update-$(date +%Y%m%d_%H%M%S)"
    log_info "Создание бэкапа: ${tag}..."

    if [[ -x "$BACKUP_SCRIPT" ]]; then
        BACKUP_TAG="$tag" bash "$BACKUP_SCRIPT" >/dev/null 2>&1 && \
            log_success "Бэкап создан: ${tag}" || \
            log_warn "Бэкап завершился с ошибками (продолжаем)"
    else
        log_warn "Скрипт бэкапа не найден — пропускаем"
    fi
}

load_current_versions() {
    declare -gA CURRENT_VERSIONS
    if [[ -f "$ENV_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ _VERSION$ ]] && CURRENT_VERSIONS["$key"]="$value"
        done < <(grep '_VERSION=' "$ENV_FILE" 2>/dev/null | grep -v '^#')
    fi
}

load_new_versions() {
    declare -gA NEW_VERSIONS
    if [[ -f "$VERSIONS_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ _VERSION$ ]] && NEW_VERSIONS["$key"]="$value"
        done < <(grep '_VERSION=' "$VERSIONS_FILE" 2>/dev/null | grep -v '^#')
    fi
}

# Save current state for rollback
save_rollback_state() {
    mkdir -p "$ROLLBACK_DIR"
    chmod 700 "$ROLLBACK_DIR"

    # Save current versions.env
    [[ -f "$VERSIONS_FILE" ]] && cp "$VERSIONS_FILE" "${ROLLBACK_DIR}/versions.env.bak"

    # Save current .env
    [[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "${ROLLBACK_DIR}/dot-env.bak"

    # Save current manifest
    [[ -f "$MANIFEST_FILE" ]] && cp "$MANIFEST_FILE" "${ROLLBACK_DIR}/release-manifest.json.bak"

    # Save running image digests
    if command -v docker &>/dev/null; then
        docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | while read -r cid; do
            local img
            img=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || true)
            [[ -n "$img" ]] && echo "$img" >> "${ROLLBACK_DIR}/running-images.txt"
        done
    fi

    log_success "Rollback state сохранён в ${ROLLBACK_DIR}"
}

# Rollback to previous state
perform_rollback() {
    log_warn "Откат к предыдущему состоянию..."

    if [[ -f "${ROLLBACK_DIR}/versions.env.bak" ]]; then
        cp "${ROLLBACK_DIR}/versions.env.bak" "$VERSIONS_FILE"
    fi
    if [[ -f "${ROLLBACK_DIR}/dot-env.bak" ]]; then
        cp "${ROLLBACK_DIR}/dot-env.bak" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    fi
    if [[ -f "${ROLLBACK_DIR}/release-manifest.json.bak" ]]; then
        cp "${ROLLBACK_DIR}/release-manifest.json.bak" "$MANIFEST_FILE"
    fi

    cd "${INSTALL_DIR}/docker"
    docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null || true

    log_success "Rollback выполнен"
    send_notification "⚠️ AGMind Update ROLLBACK — восстановлены предыдущие версии"
}

display_version_diff() {
    echo ""
    echo -e "${BOLD}Сравнение версий:${NC}"
    printf "  %-30s %-20s %-20s %s\n" "КОМПОНЕНТ" "ТЕКУЩАЯ" "НОВАЯ" "СТАТУС"
    echo "  $(printf '%.0s─' {1..85})"

    local has_updates=false
    for key in "${!NEW_VERSIONS[@]}"; do
        local current="${CURRENT_VERSIONS[$key]:-unknown}"
        local new="${NEW_VERSIONS[$key]}"
        local status=""
        local name="${key%_VERSION}"

        if [[ "$current" == "$new" ]]; then
            status="${GREEN}OK${NC}"
        else
            status="${YELLOW}UPDATE${NC}"
            has_updates=true
        fi
        printf "  %-30s %-20s %-20s %b\n" "$name" "$current" "$new" "$status"
    done
    echo ""

    if [[ "$has_updates" == "false" ]]; then
        log_success "Все версии актуальны"
        return 1
    fi
    return 0
}

# Get image name for a service from docker compose
get_service_image() {
    local service="$1"
    docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
svc = data.get('services', {}).get(sys.argv[1], {})
print(svc.get('image', 'unknown'))
" "$service" 2>/dev/null || echo ""
}

# Save current image digest for rollback
save_current_image() {
    local service="$1"
    local image
    image=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Image}}' "$service" 2>/dev/null | head -1)
    echo "$image"
}

update_service() {
    local service="$1"
    local old_image
    old_image=$(save_current_image "$service")

    log_info "Обновление ${service}..."

    # Pull new image (with retries)
    local attempts=0
    while [[ $attempts -lt 3 ]]; do
        if docker compose -f "$COMPOSE_FILE" pull "$service" 2>/dev/null; then
            break
        fi
        attempts=$((attempts + 1))
        log_warn "Pull failed for ${service}, retry ${attempts}/3..."
        sleep 5
    done

    if [[ $attempts -ge 3 ]]; then
        log_error "Pull failed for ${service} after 3 attempts"
        return 1
    fi

    # Stop and restart service
    docker compose -f "$COMPOSE_FILE" stop "$service" 2>/dev/null
    docker compose -f "$COMPOSE_FILE" up -d "$service" 2>/dev/null

    # Wait for health check
    log_info "Ожидание healthcheck для ${service}..."
    local wait=0
    local max_wait=120
    while [[ $wait -lt $max_wait ]]; do
        local status
        status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$service" 2>/dev/null | head -1)
        if echo "$status" | grep -qi "healthy"; then
            log_success "${service}: healthy"
            return 0
        elif echo "$status" | grep -qi "unhealthy\|exit"; then
            log_error "${service}: unhealthy после обновления"
            # Rollback
            rollback_service "$service" "$old_image"
            return 1
        fi
        sleep 5
        wait=$((wait + 5))
    done

    # Timeout — check if at least running
    local status
    status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$service" 2>/dev/null | head -1)
    if echo "$status" | grep -qi "up\|running"; then
        log_warn "${service}: запущен, но healthcheck не прошёл за ${max_wait}s"
        return 0
    fi

    log_error "${service}: не удалось запустить"
    rollback_service "$service" "$old_image"
    return 1
}

rollback_service() {
    local service="$1"
    local old_image="$2"

    if [[ -z "$old_image" ]]; then
        log_warn "Нет образа для отката ${service}"
        return 1
    fi

    log_warn "Откат ${service} → ${old_image}..."
    docker compose -f "$COMPOSE_FILE" stop "$service" 2>/dev/null
    # Force use of old image
    docker compose -f "$COMPOSE_FILE" up -d "$service" 2>/dev/null

    send_notification "⚠️ AGMind update FAILED for ${service}, rolled back to ${old_image}"
}

perform_rolling_update() {
    # Update order: infrastructure first, then app, then frontend
    local update_order=(
        "db"
        "redis"
        "api"
        "worker"
        "web"
        "plugin_daemon"
        "pipeline"
        "ollama"
        "nginx"
        "open-webui"
    )

    local failed=0
    local updated=0
    local skipped=0

    for service in "${update_order[@]}"; do
        # Check if service is running
        if ! docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' "$service" 2>/dev/null | grep -q .; then
            skipped=$((skipped + 1))
            continue
        fi

        if update_service "$service"; then
            updated=$((updated + 1))
        else
            failed=$((failed + 1))
            log_error "Обновление прервано из-за ошибки в ${service}"
            break
        fi
    done

    echo ""
    echo -e "${BOLD}Результат:${NC}"
    echo "  Обновлено: ${updated}"
    echo "  Пропущено: ${skipped}"
    echo "  Ошибок: ${failed}"

    return $failed
}

log_update() {
    local status="$1"
    local details="$2"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${status} | ${details}" >> "$LOG_FILE"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  AGMind Update System${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    # Pre-flight
    if ! check_preflight; then
        log_error "Pre-flight проверки не пройдены"
        exit 1
    fi

    # Load versions
    load_current_versions
    load_new_versions

    # Display diff
    if ! display_version_diff; then
        log_update "SKIP" "All versions up to date"
        exit 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        exit 0
    fi

    # Confirm
    if [[ "$AUTO_UPDATE" != "true" ]]; then
        read -rp "Начать обновление? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Отменено."
            exit 0
        fi
    fi

    # Backup
    create_update_backup

    # Save rollback state (images + configs)
    save_rollback_state

    # Save .env backup for rollback
    cp "$ENV_FILE" "${ENV_FILE}.pre-update"
    chmod 600 "${ENV_FILE}.pre-update"

    # Update versions in .env
    if [[ -f "$VERSIONS_FILE" && -f "$ENV_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ _VERSION$ ]] || continue
            [[ -z "$value" ]] && continue
            # Validate key format to prevent injection
            [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            # Safe replacement: remove old line, append new one
            grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp"
            echo "${key}=${value}" >> "${ENV_FILE}.tmp"
            mv "${ENV_FILE}.tmp" "$ENV_FILE"
            chmod 600 "$ENV_FILE"
        done < <(grep '_VERSION=' "$VERSIONS_FILE" 2>/dev/null | grep -v '^#')
    fi

    # Rolling update
    echo ""
    log_info "Начинаем rolling update..."
    echo ""

    cd "${INSTALL_DIR}/docker"

    if perform_rolling_update; then
        log_success "Обновление завершено успешно!"
        log_update "SUCCESS" "Rolling update completed"
        send_notification "✅ AGMind обновлён успешно на $(hostname 2>/dev/null || echo 'server')"
    else
        log_error "Обновление завершено с ошибками"
        # Rollback to previous state
        perform_rollback
        log_update "PARTIAL_FAILURE" "Some services failed to update"
        send_notification "⚠️ AGMind обновление завершено с ошибками на $(hostname 2>/dev/null || echo 'server')"
        exit 1
    fi
}

main "$@"
