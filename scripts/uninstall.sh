#!/usr/bin/env bash
# uninstall.sh — Remove AGMind containers, volumes, and configuration
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# --- Validate INSTALL_DIR ---
INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
[[ "$INSTALL_DIR" == /opt/agmind* ]] || { echo -e "${RED}Invalid INSTALL_DIR: must start with /opt/agmind${NC}"; exit 1; }

COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"

# --- Trap for partial cleanup tracking ---
CLEANUP_STAGE=""
cleanup_status() {
    if [[ -n "$CLEANUP_STAGE" ]]; then
        echo -e "${YELLOW}Uninstall interrupted at stage: ${CLEANUP_STAGE}${NC}"
        echo -e "${YELLOW}Run again with --force to continue cleanup${NC}"
    fi
}
trap cleanup_status EXIT

# Parse flags
FORCE=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}=== DRY RUN — ничего не будет удалено ===${NC}"
    echo ""
    echo "Будет удалено:"
    echo "  - Docker контейнеры и volumes AGMind"
    [[ -f /etc/systemd/system/agmind-tunnel.service ]] && echo "  - Systemd сервис agmind-tunnel"
    echo "  - Cron задачи AGMind"
    [[ -f /etc/fail2ban/filter.d/agmind-nginx.conf ]] && echo "  - Fail2ban конфигурация"
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'AGMind' && echo "  - UFW правила AGMind"
    [[ -d "${INSTALL_DIR}/.age" ]] && echo "  - Age ключи шифрования"
    [[ -d "/opt/agmind-instances" ]] && echo "  - Multi-instance директории"
    echo "  - ${INSTALL_DIR}/"
    echo ""
    echo "НЕ будет удалено:"
    echo "  - /var/backups/agmind/ (бэкапы)"
    echo "  - Docker Engine"
    echo "  - Установленные пакеты (age, sops, fail2ban)"
    exit 0
fi

echo -e "${RED}=== AGMind Uninstaller ===${NC}"
echo ""
echo "Это действие:"
echo "  1. Остановит все контейнеры AGMind"
echo "  2. Удалит Docker volumes (базы данных, модели, файлы)"
echo "  3. Удалит конфигурацию (/opt/agmind/)"
echo ""
echo -e "${RED}ВНИМАНИЕ: Все данные будут УДАЛЕНЫ БЕЗВОЗВРАТНО!${NC}"
echo ""

if [[ "$FORCE" == "true" ]]; then
    DO_BACKUP="no"
else
    read -rp "Создать бэкап перед удалением? (yes/no): " DO_BACKUP
fi
if [[ "$DO_BACKUP" == "yes" ]]; then
    echo -e "${YELLOW}Создание бэкапа...${NC}"
    "${INSTALL_DIR}/scripts/backup.sh" || true
    echo ""
fi

if [[ "$FORCE" != "true" ]]; then
    read -rp "Вы уверены? Введите 'DELETE' для подтверждения: " CONFIRM
    if [[ "$CONFIRM" != "DELETE" ]]; then
        echo "Отменено."
        exit 0
    fi
fi

echo ""

# 1. Stop and remove containers
CLEANUP_STAGE="docker-compose-down"
if [[ -f "$COMPOSE_FILE" ]]; then
    echo -e "${YELLOW}Остановка контейнеров...${NC}"
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
fi

# 2. Remove Docker volumes (including Loki; removed promtail_data — not a named volume)
CLEANUP_STAGE="docker-volumes"
echo -e "${YELLOW}Удаление Docker volumes...${NC}"
docker volume ls -q | grep -E "^agmind_|_openwebui_data$|_ollama_data$|_xinference_data$|_grafana_data$|_portainer_data$|_prometheus_data$|_loki_data$|_authelia_data$" | while read -r vol; do
    docker volume rm "$vol" 2>/dev/null || true
    echo "  Удалён volume: $vol"
done

# 3. Remove systemd services
CLEANUP_STAGE="systemd-services"
if [[ -f /etc/systemd/system/agmind-tunnel.service ]]; then
    echo -e "${YELLOW}Удаление systemd сервисов...${NC}"
    systemctl stop agmind-tunnel 2>/dev/null || true
    systemctl disable agmind-tunnel 2>/dev/null || true
    rm -f /etc/systemd/system/agmind-tunnel.service
    systemctl daemon-reload
fi

# 4. Remove cron entries (backup + secret rotation)
CLEANUP_STAGE="cron-entries"
echo -e "${YELLOW}Удаление cron задач...${NC}"
crontab -l 2>/dev/null | grep -v 'agmind\|rotate_secrets' | crontab - 2>/dev/null || true

# 5. Remove Fail2ban filter and jail
CLEANUP_STAGE="fail2ban"
if [[ -f /etc/fail2ban/filter.d/agmind-nginx.conf ]]; then
    echo -e "${YELLOW}Удаление Fail2ban конфигурации...${NC}"
    rm -f /etc/fail2ban/filter.d/agmind-nginx.conf
    rm -f /etc/fail2ban/jail.d/agmind.conf
    systemctl restart fail2ban 2>/dev/null || true
fi

# 6. Remove UFW rules
CLEANUP_STAGE="ufw-rules"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'AGMind'; then
    echo -e "${YELLOW}Удаление UFW правил AGMind...${NC}"
    ufw status numbered 2>/dev/null | grep -i 'agmind\|Grafana\|Portainer' | \
        awk -F'[][]' '{print $2}' | sort -rn | while read -r num; do
        ufw --force delete "$num" 2>/dev/null || true
    done
fi

# 7. Remove age encryption keys
CLEANUP_STAGE="age-keys"
if [[ -d "${INSTALL_DIR}/.age" ]]; then
    echo -e "${YELLOW}Удаление ключей шифрования (.age)...${NC}"
    rm -rf "${INSTALL_DIR}/.age"
fi

# 8. Remove GPU profile file
CLEANUP_STAGE="gpu-profile"
rm -f "${INSTALL_DIR}/.agmind_gpu_profile" 2>/dev/null || true

# 9. Remove multi-instance directories
CLEANUP_STAGE="multi-instance"
if [[ -d "/opt/agmind-instances" ]]; then
    echo -e "${YELLOW}Обнаружены multi-instance директории в /opt/agmind-instances/${NC}"
    if [[ "$FORCE" == "true" ]]; then
        DEL_MULTI="yes"
    else
        read -rp "Удалить multi-instance директории? (yes/no): " DEL_MULTI
    fi
    if [[ "$DEL_MULTI" == "yes" ]]; then
        # Stop all instances first
        for inst_dir in /opt/agmind-instances/*/; do
            [[ -f "${inst_dir}docker-compose.yml" ]] && \
                docker compose -f "${inst_dir}docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
        done
        rm -rf /opt/agmind-instances
        echo -e "${GREEN}Multi-instance директории удалены${NC}"
    fi
fi

# 10. Remove installation directory
CLEANUP_STAGE="install-dir"
echo -e "${YELLOW}Удаление ${INSTALL_DIR}...${NC}"
rm -rf "${INSTALL_DIR}"

# All done — clear stage so trap doesn't fire
CLEANUP_STAGE=""

echo ""
echo -e "${GREEN}=== AGMind удалён ===${NC}"
echo ""
echo "Бэкапы сохранены в /var/backups/agmind/ (удалите вручную при необходимости)"
echo "Docker остаётся установленным (удалите вручную при необходимости)"
