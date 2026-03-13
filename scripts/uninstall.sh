#!/usr/bin/env bash
# uninstall.sh — Remove AGMind containers, volumes, and configuration
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"

echo -e "${RED}=== AGMind Uninstaller ===${NC}"
echo ""
echo "Это действие:"
echo "  1. Остановит все контейнеры AGMind"
echo "  2. Удалит Docker volumes (базы данных, модели, файлы)"
echo "  3. Удалит конфигурацию (/opt/agmind/)"
echo ""
echo -e "${RED}ВНИМАНИЕ: Все данные будут УДАЛЕНЫ БЕЗВОЗВРАТНО!${NC}"
echo ""

read -rp "Создать бэкап перед удалением? (yes/no): " DO_BACKUP
if [[ "$DO_BACKUP" == "yes" ]]; then
    echo -e "${YELLOW}Создание бэкапа...${NC}"
    "${INSTALL_DIR}/scripts/backup.sh" || true
    echo ""
fi

read -rp "Вы уверены? Введите 'DELETE' для подтверждения: " CONFIRM
if [[ "$CONFIRM" != "DELETE" ]]; then
    echo "Отменено."
    exit 0
fi

echo ""

# 1. Stop and remove containers
if [[ -f "$COMPOSE_FILE" ]]; then
    echo -e "${YELLOW}Остановка контейнеров...${NC}"
    docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
fi

# 2. Remove Docker volumes
echo -e "${YELLOW}Удаление Docker volumes...${NC}"
docker volume ls -q | grep -E "^agmind_|openwebui_data|ollama_data|xinference_data|grafana_data|portainer_data|prometheus_data" | while read -r vol; do
    docker volume rm "$vol" 2>/dev/null || true
    echo "  Удалён volume: $vol"
done

# 3. Remove systemd services
if [[ -f /etc/systemd/system/agmind-tunnel.service ]]; then
    echo -e "${YELLOW}Удаление systemd сервисов...${NC}"
    systemctl stop agmind-tunnel 2>/dev/null || true
    systemctl disable agmind-tunnel 2>/dev/null || true
    rm -f /etc/systemd/system/agmind-tunnel.service
    systemctl daemon-reload
fi

# 4. Remove cron entries
echo -e "${YELLOW}Удаление cron задач...${NC}"
crontab -l 2>/dev/null | grep -v 'agmind' | crontab - 2>/dev/null || true

# 5. Remove installation directory
echo -e "${YELLOW}Удаление ${INSTALL_DIR}...${NC}"
rm -rf "${INSTALL_DIR}"

echo ""
echo -e "${GREEN}=== AGMind удалён ===${NC}"
echo ""
echo "Бэкапы сохранены в /var/backups/agmind/ (удалите вручную при необходимости)"
echo "Docker остаётся установленным (удалите вручную при необходимости)"
