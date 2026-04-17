#!/usr/bin/env bash
# backup.sh — Setup automatic backups via cron.
# Dependencies: common.sh (log_*)
# Functions: setup_backups()
# Expects: INSTALL_DIR, BACKUP_TARGET, BACKUP_SCHEDULE, REMOTE_BACKUP_*,
#          ENABLE_DR_DRILL
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# SETUP BACKUPS
# ============================================================================

setup_backups() {
    local backup_target="${BACKUP_TARGET:-local}"
    local backup_schedule="${BACKUP_SCHEDULE:-0 3 * * *}"
    local remote_host="${REMOTE_BACKUP_HOST:-}"
    local remote_port="${REMOTE_BACKUP_PORT:-22}"
    local remote_user="${REMOTE_BACKUP_USER:-}"
    local remote_path="${REMOTE_BACKUP_PATH:-/var/backups/agmind-remote}"
    local remote_key="${REMOTE_BACKUP_KEY:-}"

    log_info "Setting up backups..."

    # Ensure scripts are executable
    chmod +x "${INSTALL_DIR}/scripts/backup.sh" 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/restore.sh" 2>/dev/null || true

    # Generate backup config
    _generate_backup_conf "$backup_target" "$remote_host" "$remote_port" \
        "$remote_user" "$remote_path" "$remote_key"

    # Setup crontab entries
    _setup_backup_cron "$backup_schedule"

    # Optional monthly DR drill
    if [[ "${ENABLE_DR_DRILL:-true}" == "true" ]]; then
        _setup_dr_drill_cron
    fi

    log_success "Backups configured"
    echo "  Schedule:  ${backup_schedule}"
    echo "  Local dir: ${BACKUP_DIR:-/var/backups/agmind}/"
    if [[ "$backup_target" != "local" && -n "$remote_host" ]]; then
        echo "  Remote:    ${remote_user}@${remote_host}:${remote_path}"
    fi
    if [[ "${ENABLE_DR_DRILL:-true}" == "true" ]]; then
        echo "  DR Drill:  monthly (1st at 03:00)"
    fi
}

# ============================================================================
# HELPERS
# ============================================================================

_generate_backup_conf() {
    local target="$1" host="$2" port="$3" user="$4" path="$5" key="$6"
    local conf="${INSTALL_DIR}/scripts/backup.conf"

    cat > "$conf" << BKCONF
# AGMind Backup Configuration
INSTALL_DIR=${INSTALL_DIR}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/agmind}
BACKUP_RETENTION_DAYS=7
REMOTE_BACKUP_ENABLED=$([ "$target" != "local" ] && echo "true" || echo "false")
REMOTE_BACKUP_HOST=${host}
REMOTE_BACKUP_PORT=${port}
REMOTE_BACKUP_USER=${user}
REMOTE_BACKUP_PATH=${path}
REMOTE_BACKUP_KEY=${key}
BKCONF

    chmod 600 "$conf"
}

_setup_backup_cron() {
    local schedule="$1"
    local cron_entry="${schedule} ${INSTALL_DIR}/scripts/backup.sh >> /var/log/agmind-backup.log 2>&1"

    # Remove existing agmind backup entries, add new
    crontab -l 2>/dev/null | grep -v 'agmind.*backup' | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
}

_setup_dr_drill_cron() {
    local dr_entry="0 3 1 * * ${INSTALL_DIR}/scripts/dr-drill.sh --skip-restore >> /var/log/agmind-dr-drill.log 2>&1"

    crontab -l 2>/dev/null | grep -v 'dr-drill' | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "$dr_entry") | crontab -
}

# ============================================================================
# STANDALONE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    setup_backups
fi
