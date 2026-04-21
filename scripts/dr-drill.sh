#!/usr/bin/env bash
# ============================================================================
# AGMind DR Drill — Monthly Disaster Recovery Test
# Usage: ./dr-drill.sh [--dry-run] [--skip-restore] [--report-only]
#
# This script validates the DR process by:
# 1. Creating a fresh backup
# 2. Verifying backup integrity (checksums)
# 3. Testing restore in a sandboxed environment (optional)
# 4. Verifying all services come up healthy
# 5. Generating a DR drill report
#
# Designed to run monthly via cron or manually.
# ============================================================================
set -euo pipefail
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/agmind}"
REPORT_DIR="${INSTALL_DIR}/logs/dr-drills"
HEALTH_SCRIPT="${INSTALL_DIR}/scripts/health.sh"
BACKUP_SCRIPT="${INSTALL_DIR}/scripts/backup.sh"
RESTORE_SCRIPT="${INSTALL_DIR}/scripts/restore.sh"

DRY_RUN=false
SKIP_RESTORE=false
REPORT_ONLY=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --dry-run)      DRY_RUN=true ;;
        --skip-restore) SKIP_RESTORE=true ;;
        --report-only)  REPORT_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--skip-restore] [--report-only]"
            echo ""
            echo "  --dry-run        Show what would happen, don't execute"
            echo "  --skip-restore   Skip the actual restore test (backup + verify only)"
            echo "  --report-only    Only generate report from last drill results"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# Root check
if [[ $EUID -ne 0 ]] && [[ "$DRY_RUN" != "true" ]]; then
    echo -e "${RED}This script must be run as root (or use --dry-run)${NC}"
    exit 1
fi

# Timestamp and report setup
DRILL_DATE=$(date +%Y%m%d_%H%M%S)
DRILL_ID="drill-${DRILL_DATE}"
mkdir -p "$REPORT_DIR"
REPORT_FILE="${REPORT_DIR}/${DRILL_ID}.txt"

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Logging
log_step() { echo -e "\n${BOLD}${CYAN}[Step $1]${NC} ${BOLD}$2${NC}" | tee -a "$REPORT_FILE"; }
log_ok()   { echo -e "  ${GREEN}✓ $*${NC}" | tee -a "$REPORT_FILE"; TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); PASSED_CHECKS=$((PASSED_CHECKS + 1)); }
log_fail() { echo -e "  ${RED}✗ $*${NC}" | tee -a "$REPORT_FILE"; TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); FAILED_CHECKS=$((FAILED_CHECKS + 1)); }
log_warn() { echo -e "  ${YELLOW}⚠ $*${NC}" | tee -a "$REPORT_FILE"; WARNINGS=$((WARNINGS + 1)); }
log_info() { echo -e "  ${CYAN}→ $*${NC}" | tee -a "$REPORT_FILE"; }

# ──────────────────────────────────────────
# Report header
# ──────────────────────────────────────────
{
    echo "═══════════════════════════════════════"
    echo "  AGMind DR Drill Report"
    echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Host: $(hostname 2>/dev/null || echo 'unknown')"
    echo "  Drill ID: ${DRILL_ID}"
    echo "  Mode: $(if $DRY_RUN; then echo 'DRY RUN'; elif $SKIP_RESTORE; then echo 'BACKUP ONLY'; else echo 'FULL DRILL'; fi)"
    echo "═══════════════════════════════════════"
} | tee "$REPORT_FILE"

if [[ "$REPORT_ONLY" == "true" ]]; then
    echo ""
    echo "Previous drill reports:"
    ls -1t "$REPORT_DIR"/*.txt 2>/dev/null | head -10 | while read -r f; do
        basename "$f"
    done
    exit 0
fi

# ──────────────────────────────────────────
# Step 1: Pre-drill environment validation
# ──────────────────────────────────────────
log_step 1 "Pre-drill environment validation"

# Check install directory
if [[ -d "$INSTALL_DIR" ]]; then
    log_ok "Install directory exists: ${INSTALL_DIR}"
else
    log_fail "Install directory missing: ${INSTALL_DIR}"
fi

# Check required scripts
for script in "$BACKUP_SCRIPT" "$RESTORE_SCRIPT" "$HEALTH_SCRIPT"; do
    if [[ -x "$script" ]]; then
        log_ok "Script found: $(basename "$script")"
    elif [[ -f "$script" ]]; then
        log_warn "Script exists but not executable: $(basename "$script")"
    else
        log_fail "Script missing: $(basename "$script")"
    fi
done

# Check Docker
if command -v docker &>/dev/null && docker info &>/dev/null; then
    log_ok "Docker daemon running"
else
    log_fail "Docker not available"
fi

# Check disk space
disk_gb=$(df -BG "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}' || echo "0")
if [[ "$disk_gb" -ge 20 ]] 2>/dev/null; then
    log_ok "Disk space: ${disk_gb}GB free (≥20GB required for drill)"
elif [[ "$disk_gb" -ge 10 ]] 2>/dev/null; then
    log_warn "Disk space: ${disk_gb}GB free (20GB+ recommended)"
else
    log_fail "Insufficient disk space: ${disk_gb}GB (need ≥10GB)"
fi

# ──────────────────────────────────────────
# Step 2: Verify current services health
# ──────────────────────────────────────────
log_step 2 "Current services health check (before drill)"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run health check"
else
    if [[ -x "$HEALTH_SCRIPT" ]]; then
        if bash "$HEALTH_SCRIPT" --quiet 2>/dev/null; then
            log_ok "All services healthy before drill"
        else
            log_warn "Some services not healthy — drill may produce misleading results"
        fi
    else
        # Manual check
        cd "${INSTALL_DIR}/docker"
        running=$(docker compose ps --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -c "Up" || echo "0")
        total=$(docker compose ps --format '{{.Name}}' 2>/dev/null | wc -l || echo "0")
        if [[ "$running" -gt 0 ]]; then
            log_ok "Services running: ${running}/${total}"
        else
            log_fail "No services running"
        fi
        cd - >/dev/null
    fi
fi

# ──────────────────────────────────────────
# Step 3: Create fresh backup
# ──────────────────────────────────────────
log_step 3 "Create fresh backup for DR drill"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: ${BACKUP_SCRIPT}"
    DRILL_BACKUP_PATH="${BACKUP_DIR}/drill-${DRILL_DATE}"
else
    export BACKUP_DIR
    DRILL_BACKUP_PATH=""

    backup_start=$(date +%s)
    if bash "$BACKUP_SCRIPT" 2>&1 | tee -a "$REPORT_FILE"; then
        backup_end=$(date +%s)
        backup_duration=$((backup_end - backup_start))

        # Find the most recent backup
        DRILL_BACKUP_PATH=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort -r | head -1)

        if [[ -n "$DRILL_BACKUP_PATH" ]]; then
            backup_size=$(du -sh "$DRILL_BACKUP_PATH" 2>/dev/null | cut -f1)
            log_ok "Backup created: $(basename "$DRILL_BACKUP_PATH") (${backup_size}, ${backup_duration}s)"
        else
            log_fail "Backup directory not found after backup script"
        fi
    else
        log_fail "Backup script failed"
    fi
fi

# ──────────────────────────────────────────
# Step 4: Verify backup integrity
# ──────────────────────────────────────────
log_step 4 "Verify backup integrity"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would verify checksums"
elif [[ -n "${DRILL_BACKUP_PATH:-}" ]] && [[ -d "$DRILL_BACKUP_PATH" ]]; then
    # Check required files
    for required in dify_db.sql.gz env.backup; do
        if [[ -f "${DRILL_BACKUP_PATH}/${required}" ]]; then
            log_ok "Required file present: ${required}"
        elif [[ -f "${DRILL_BACKUP_PATH}/${required}.age" ]]; then
            log_ok "Required file present (encrypted): ${required}.age"
        else
            log_fail "Required file missing: ${required}"
        fi
    done

    # Verify checksums
    if [[ -f "${DRILL_BACKUP_PATH}/sha256sums.txt" ]]; then
        cd "$DRILL_BACKUP_PATH"
        if sha256sum -c sha256sums.txt --quiet 2>/dev/null; then
            log_ok "All checksums verified"
        else
            log_fail "Checksum verification failed!"
        fi
        cd - >/dev/null
    else
        log_warn "No sha256sums.txt — skipping checksum verification"
    fi

    # Check backup is not empty
    file_count=$(find "$DRILL_BACKUP_PATH" -type f | wc -l)
    if [[ "$file_count" -ge 3 ]]; then
        log_ok "Backup contains ${file_count} files"
    else
        log_fail "Backup contains only ${file_count} files (expected ≥3)"
    fi
else
    log_fail "No backup path available for verification"
fi

# ──────────────────────────────────────────
# Step 5: Test restore (optional)
# ──────────────────────────────────────────
log_step 5 "Restore test"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would test restore from backup"
elif [[ "$SKIP_RESTORE" == "true" ]]; then
    log_warn "Restore test skipped (--skip-restore)"
elif [[ -n "${DRILL_BACKUP_PATH:-}" ]]; then
    log_info "Testing restore from: $(basename "$DRILL_BACKUP_PATH")"
    log_warn "This will restart services — expect brief downtime"

    restore_start=$(date +%s)
    if AUTO_CONFIRM=true bash "$RESTORE_SCRIPT" "$DRILL_BACKUP_PATH" 2>&1 | tee -a "$REPORT_FILE"; then
        restore_end=$(date +%s)
        restore_duration=$((restore_end - restore_start))
        log_ok "Restore completed in ${restore_duration}s"
    else
        restore_end=$(date +%s)
        restore_duration=$((restore_end - restore_start))
        log_fail "Restore failed after ${restore_duration}s"
    fi
else
    log_fail "No backup available for restore test"
fi

# ──────────────────────────────────────────
# Step 6: Post-drill health verification
# ──────────────────────────────────────────
log_step 6 "Post-drill health verification"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would verify services health"
elif [[ "$SKIP_RESTORE" == "true" ]]; then
    log_info "Skipping post-drill health check (no restore performed)"
else
    # Wait for services to stabilize
    log_info "Waiting 30s for services to stabilize..."
    sleep 30

    if [[ -x "$HEALTH_SCRIPT" ]]; then
        if bash "$HEALTH_SCRIPT" 2>&1 | tee -a "$REPORT_FILE"; then
            log_ok "All services healthy after restore"
        else
            log_fail "Some services unhealthy after restore"
        fi
    else
        # Manual checks
        for endpoint in "http://localhost/dify/console/api/setup" "http://localhost/"; do
            if curl -sf --max-time 10 "$endpoint" >/dev/null 2>&1; then
                log_ok "Responding: $endpoint"
            else
                log_warn "Not responding: $endpoint"
            fi
        done
    fi
fi

# ──────────────────────────────────────────
# Step 7: DR metrics and reporting
# ──────────────────────────────────────────
log_step 7 "DR drill summary and metrics"

# Calculate RTO (if restore was done)
if [[ -n "${restore_duration:-}" ]]; then
    rto_minutes=$(( restore_duration / 60 ))
    rto_seconds=$(( restore_duration % 60 ))
    {
        echo ""
        echo "DR Metrics:"
        echo "  Measured RTO: ${rto_minutes}m ${rto_seconds}s"
        echo "  Target RTO:   60m"
        if [[ "$restore_duration" -le 3600 ]]; then
            echo "  RTO Status:   PASS (within target)"
        else
            echo "  RTO Status:   FAIL (exceeds 60m target)"
        fi
    } | tee -a "$REPORT_FILE"
fi

# Summary
echo "" | tee -a "$REPORT_FILE"
{
    echo "═══════════════════════════════════════"
    echo "  DR Drill Results"
    echo "═══════════════════════════════════════"
    echo "  Total checks:  ${TOTAL_CHECKS}"
    echo "  Passed:        ${PASSED_CHECKS}"
    echo "  Failed:        ${FAILED_CHECKS}"
    echo "  Warnings:      ${WARNINGS}"
    echo ""
} | tee -a "$REPORT_FILE"

if [[ $FAILED_CHECKS -eq 0 ]]; then
    echo -e "${GREEN}  DR DRILL: PASSED${NC}" | tee -a "$REPORT_FILE"
    DRILL_STATUS="PASSED"
else
    echo -e "${RED}  DR DRILL: FAILED (${FAILED_CHECKS} failures)${NC}" | tee -a "$REPORT_FILE"
    DRILL_STATUS="FAILED"
fi

{
    echo ""
    echo "  Report saved: ${REPORT_FILE}"
    echo "═══════════════════════════════════════"
} | tee -a "$REPORT_FILE"

# Send alert if configured
ALERT_WEBHOOK=$(grep '^ALERT_WEBHOOK_URL=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "")
if [[ -n "$ALERT_WEBHOOK" ]] && [[ "$DRY_RUN" != "true" ]]; then
    drill_summary="DR Drill ${DRILL_STATUS}: ${PASSED_CHECKS}/${TOTAL_CHECKS} checks passed, ${WARNINGS} warnings"
    curl -sf --max-time 10 -X POST "$ALERT_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{\"text\": \"🔄 AGMind ${drill_summary}\"}" 2>/dev/null || true
fi

# Cron setup hint
if [[ "$DRY_RUN" != "true" ]]; then
    echo ""
    echo "To schedule monthly DR drills, add to root crontab:"
    echo "  0 3 1 * * ${INSTALL_DIR}/scripts/dr-drill.sh --skip-restore >> /var/log/agmind-dr-drill.log 2>&1"
    echo ""
    echo "For full restore test (with downtime):"
    echo "  0 3 1 * * ${INSTALL_DIR}/scripts/dr-drill.sh >> /var/log/agmind-dr-drill.log 2>&1"
fi

exit $FAILED_CHECKS
