#!/usr/bin/env bash
# restore.sh — thin entrypoint for AGmind restore. Delegates to lib/restore.sh.
# Back-compat: restore.sh [BACKUP_DIR|latest] [--auto-confirm]
# New:         restore.sh [BACKUP_DIR|latest] [--auto-confirm] [--dry-run] [--service <name>]
set -euo pipefail
umask 077

export RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

# R-13: Root check
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Exclusive lock — MUST be acquired before sourcing lib/restore.sh (parallel backup/update guard).
# WHY before source: lib functions assume flock is already held by the thin entrypoint (D-11/Pitfall 2).
LOCK_FILE="/var/lock/agmind-operation.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "${RED}Another AGMind operation is running. Wait for it to finish.${NC}"
    exit 1
fi

# R-08: Validate INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
[[ "$INSTALL_DIR" == /opt/agmind* ]] || { echo "Invalid INSTALL_DIR"; exit 1; }
export INSTALL_DIR
export BACKUP_BASE="${BACKUP_DIR:-/var/backups/agmind}"
export COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"

# Fallback log shims (mirror lib/health.sh:11-14) in case common.sh is unavailable.
command -v log_info    >/dev/null 2>&1 || log_info()    { echo -e "  -> $*"; }
command -v log_success >/dev/null 2>&1 || log_success() { echo -e "  ✓ $*"; }
command -v log_warn    >/dev/null 2>&1 || log_warn()    { echo -e "  ⚠ $*"; }
command -v log_error   >/dev/null 2>&1 || log_error()   { echo -e "  ✗ $*"; }

# Parse flags
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
DRY_RUN=false
SERVICE=""
BACKUP_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-confirm) AUTO_CONFIRM=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --service)      SERVICE="${2:-}"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: restore.sh [BACKUP_DIR|latest] [--auto-confirm] [--dry-run] [--service <name>]
  BACKUP_DIR     Path or directory name under ${BACKUP_BASE}, or 'latest'
  --auto-confirm Skip confirmation prompts (back-compat)
  --dry-run      Print the restore plan, change nothing (also runs verify)
  --service <n>  Restore only one group: dify | rag | ragflow | openwebui | ollama | config
EOF
            exit 0 ;;
        --*) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
        *)   BACKUP_ARG="$1"; shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${SCRIPT_DIR}/../lib/common.sh" ]] && source "${SCRIPT_DIR}/../lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/restore.sh"

# Resolve backup dir (default 'latest' when not given).
# Back-compat: an absolute path under BACKUP_BASE still works via _resolve_backup_dir.
RESTORE_DIR="$(_resolve_backup_dir "${BACKUP_ARG:-latest}")" || exit 1

if [[ "$DRY_RUN" == "true" ]]; then
    # shellcheck disable=SC2086
    restore_plan "$RESTORE_DIR" ${SERVICE:+--service "$SERVICE"} --dry-run
else
    # Build optional --auto-confirm flag into an array to avoid SC2046 word-splitting.
    _apply_extra=()
    [[ "$AUTO_CONFIRM" == "true" ]] && _apply_extra+=(--auto-confirm)
    # shellcheck disable=SC2086
    restore_apply "$RESTORE_DIR" ${SERVICE:+--service "$SERVICE"} "${_apply_extra[@]+"${_apply_extra[@]}"}"
fi
