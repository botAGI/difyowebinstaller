#!/usr/bin/env bash
# backup.sh — Setup backup schedule (cron)
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

setup_backups() {
    local backup_target="${BACKUP_TARGET:-local}"
    local backup_schedule="${BACKUP_SCHEDULE:-0 3 * * *}"
    local remote_host="${REMOTE_BACKUP_HOST:-}"
    local remote_port="${REMOTE_BACKUP_PORT:-22}"
    local remote_user="${REMOTE_BACKUP_USER:-}"
    local remote_path="${REMOTE_BACKUP_PATH:-/var/backups/agmind-remote}"
    local remote_key="${REMOTE_BACKUP_KEY:-}"

    echo -e "${YELLOW}Настройка бэкапов...${NC}"

    # Scripts are already copied to ${INSTALL_DIR}/scripts/ by phase_config()
    chmod +x "${INSTALL_DIR}/scripts/backup.sh" 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/restore.sh" 2>/dev/null || true

    # Create backup config
    cat > "${INSTALL_DIR}/scripts/backup.conf" << BKCONF
# AGMind Backup Configuration
INSTALL_DIR=${INSTALL_DIR}
BACKUP_DIR=/var/backups/agmind
BACKUP_RETENTION_DAYS=7
REMOTE_BACKUP_ENABLED=$([ "$backup_target" != "local" ] && echo "true" || echo "false")
REMOTE_BACKUP_HOST=${remote_host}
REMOTE_BACKUP_PORT=${remote_port}
REMOTE_BACKUP_USER=${remote_user}
REMOTE_BACKUP_PATH=${remote_path}
REMOTE_BACKUP_KEY=${remote_key}
BKCONF
    chmod 600 "${INSTALL_DIR}/scripts/backup.conf"

    # Setup crontab
    local cron_entry="${backup_schedule} ${INSTALL_DIR}/scripts/backup.sh >> /var/log/agmind-backup.log 2>&1"

    # Remove existing agmind backup entries
    crontab -l 2>/dev/null | grep -v 'agmind.*backup' | crontab - 2>/dev/null || true

    # Add new entry
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -

    echo -e "${GREEN}Бэкапы настроены${NC}"
    echo "  Расписание: ${backup_schedule}"
    echo "  Хранение:   /var/backups/agmind/"
    if [[ "$backup_target" != "local" && -n "$remote_host" ]]; then
        echo "  Удалённо:   ${remote_user}@${remote_host}:${remote_path}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_backups
fi
