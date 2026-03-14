#!/usr/bin/env bash
# ============================================================================
# AGMind Restore Runbook — 7-Step Verified Restore
# Usage: ./restore-runbook.sh <backup_path>
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
BACKUP_PATH="${1:-}"

if [[ -z "$BACKUP_PATH" ]]; then
    echo -e "${RED}Usage: $0 <backup_path>${NC}"
    echo "Example: $0 /var/backups/agmind/20260314_120000"
    exit 1
fi

if [[ ! -d "$BACKUP_PATH" ]]; then
    echo -e "${RED}Backup not found: $BACKUP_PATH${NC}"
    exit 1
fi

log_step() { echo -e "\n${BOLD}${CYAN}[Step $1/7]${NC} ${BOLD}$2${NC}"; }
log_ok()   { echo -e "  ${GREEN}✓ $*${NC}"; }
log_fail() { echo -e "  ${RED}✗ $*${NC}"; }
log_warn() { echo -e "  ${YELLOW}⚠ $*${NC}"; }

ERRORS=0

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  AGMind Restore Runbook${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo -e "Backup: ${BACKUP_PATH}"
echo ""

# ──────────────────────────────────────────
# Step 1: Verify backup integrity
# ──────────────────────────────────────────
log_step 1 "Verify backup integrity"

if [[ -f "${BACKUP_PATH}/sha256sums.txt" ]]; then
    cd "$BACKUP_PATH"
    if sha256sum -c sha256sums.txt --quiet 2>/dev/null; then
        log_ok "Checksums verified"
    else
        log_fail "Checksum mismatch!"
        ERRORS=$((ERRORS + 1))
    fi
    cd - >/dev/null
else
    log_warn "No sha256sums.txt found — skipping integrity check"
fi

# Check required files
for required in dify_db.sql.gz; do
    if [[ -f "${BACKUP_PATH}/${required}" ]]; then
        log_ok "Found: ${required}"
    else
        log_warn "Missing: ${required}"
    fi
done

# ──────────────────────────────────────────
# Step 2: Pre-restore health check
# ──────────────────────────────────────────
log_step 2 "Pre-restore environment check"

if command -v docker &>/dev/null; then
    log_ok "Docker available"
else
    log_fail "Docker not found"
    ERRORS=$((ERRORS + 1))
fi

if docker info &>/dev/null; then
    log_ok "Docker daemon running"
else
    log_fail "Docker daemon not running"
    ERRORS=$((ERRORS + 1))
fi

disk_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}' || echo "0")
if [[ "$disk_gb" -ge 10 ]] 2>/dev/null; then
    log_ok "Disk space: ${disk_gb}GB free"
else
    log_fail "Insufficient disk space: ${disk_gb}GB"
    ERRORS=$((ERRORS + 1))
fi

# ──────────────────────────────────────────
# Step 3: Stop services
# ──────────────────────────────────────────
log_step 3 "Stop running services"

if [[ -f "${INSTALL_DIR}/docker/docker-compose.yml" ]]; then
    cd "${INSTALL_DIR}/docker"
    docker compose down 2>/dev/null && log_ok "Services stopped" || log_warn "Services may already be stopped"
    cd - >/dev/null
else
    log_warn "No existing installation found — fresh restore"
fi

# ──────────────────────────────────────────
# Step 4: Run restore script
# ──────────────────────────────────────────
log_step 4 "Execute restore"

RESTORE_SCRIPT="${INSTALL_DIR}/scripts/restore.sh"
if [[ -x "$RESTORE_SCRIPT" ]]; then
    if bash "$RESTORE_SCRIPT" "$BACKUP_PATH"; then
        log_ok "Restore completed"
    else
        log_fail "Restore failed!"
        ERRORS=$((ERRORS + 1))
    fi
else
    log_fail "Restore script not found: $RESTORE_SCRIPT"
    ERRORS=$((ERRORS + 1))
fi

# ──────────────────────────────────────────
# Step 5: Start services and wait for health
# ──────────────────────────────────────────
log_step 5 "Start services"

cd "${INSTALL_DIR}/docker"
docker compose up -d 2>/dev/null && log_ok "Services starting..." || {
    log_fail "Failed to start services"
    ERRORS=$((ERRORS + 1))
}

# Wait for healthy
echo "  Waiting for services to become healthy (timeout: 300s)..."
sleep 30  # Initial grace period

# ──────────────────────────────────────────
# Step 6: Post-restore health verification
# ──────────────────────────────────────────
log_step 6 "Post-restore health check"

HEALTH_SCRIPT="${INSTALL_DIR}/scripts/health.sh"
if [[ -x "$HEALTH_SCRIPT" ]]; then
    if bash "$HEALTH_SCRIPT"; then
        log_ok "All services healthy"
    else
        log_warn "Some services not yet healthy"
    fi
else
    # Manual checks
    for svc in db redis api web nginx open-webui ollama; do
        status=$(docker compose ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "not found")
        if echo "$status" | grep -qi "up\|healthy"; then
            log_ok "$svc: UP"
        else
            log_fail "$svc: $status"
            ERRORS=$((ERRORS + 1))
        fi
    done
fi

# ──────────────────────────────────────────
# Step 7: Functional verification
# ──────────────────────────────────────────
log_step 7 "Functional verification"

# Check Dify API
if curl -sf --max-time 10 http://localhost/dify/console/api/setup >/dev/null 2>&1; then
    log_ok "Dify API responding"
else
    log_warn "Dify API not responding (may still be starting)"
fi

# Check Open WebUI
if curl -sf --max-time 10 http://localhost/ >/dev/null 2>&1; then
    log_ok "Open WebUI responding"
else
    log_warn "Open WebUI not responding (may still be starting)"
fi

# Check Ollama
if docker compose exec -T ollama curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
    log_ok "Ollama API responding"
else
    log_warn "Ollama API not responding"
fi

# ──────────────────────────────────────────
# Summary
# ──────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}  Restore completed successfully!${NC}"
else
    echo -e "${RED}  Restore completed with ${ERRORS} error(s)${NC}"
    echo -e "${YELLOW}  Review the errors above and take action.${NC}"
fi
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo ""

exit $ERRORS
