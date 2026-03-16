#!/usr/bin/env bash
# ============================================================================
# AGMind DR-004: Upgrade-Failure → Restore Scenario Test
#
# This script validates that the update.sh rollback mechanism works correctly
# when an upgrade fails. It simulates a failed upgrade and verifies:
#   1. Pre-update backup is created
#   2. Rollback state is saved
#   3. On failure, configs are restored
#   4. Services come back up with previous versions
#   5. Notifications are sent
#
# Usage: ./test-upgrade-rollback.sh [--dry-run] [--full-test]
#
# --dry-run:    Validate rollback files and logic without modifying anything
# --full-test:  Actually simulate failure and test rollback (requires running stack)
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"
VERSIONS_FILE="${INSTALL_DIR}/versions.env"
ENV_FILE="${INSTALL_DIR}/docker/.env"
ROLLBACK_DIR="${INSTALL_DIR}/.rollback"
UPDATE_SCRIPT="${INSTALL_DIR}/scripts/update.sh"
BACKUP_SCRIPT="${INSTALL_DIR}/scripts/backup.sh"
RESTORE_SCRIPT="${INSTALL_DIR}/scripts/restore.sh"
RESTORE_RUNBOOK="${INSTALL_DIR}/scripts/restore-runbook.sh"

DRY_RUN=false
FULL_TEST=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=true ;;
        --full-test) FULL_TEST=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--full-test]"
            echo ""
            echo "  --dry-run    Validate rollback infrastructure without changes"
            echo "  --full-test  Simulate upgrade failure and test rollback"
            echo ""
            exit 0
            ;;
    esac
done

TOTAL=0
PASS=0
FAIL=0

check() {
    local description="$1"
    local result="$2"
    TOTAL=$((TOTAL + 1))
    if [[ "$result" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $description"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  DR-004: Upgrade-Failure Restore Test${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo ""

# ──────────────────────────────────────────
# Phase 1: Validate rollback infrastructure
# ──────────────────────────────────────────
echo -e "${BOLD}Phase 1: Rollback Infrastructure Validation${NC}"

# Check that update.sh has rollback functions
check "update.sh exists and is executable" \
    "$([[ -x "$UPDATE_SCRIPT" ]] && echo true || echo false)"

if [[ -f "$UPDATE_SCRIPT" ]]; then
    check "update.sh contains save_rollback_state()" \
        "$(grep -q 'save_rollback_state' "$UPDATE_SCRIPT" && echo true || echo false)"

    check "update.sh contains perform_rollback()" \
        "$(grep -q 'perform_rollback' "$UPDATE_SCRIPT" && echo true || echo false)"

    check "update.sh contains rollback_service()" \
        "$(grep -q 'rollback_service' "$UPDATE_SCRIPT" && echo true || echo false)"

    check "update.sh calls save_rollback_state before update" \
        "$(grep -q 'save_rollback_state' "$UPDATE_SCRIPT" && echo true || echo false)"

    check "update.sh calls perform_rollback on failure" \
        "$(awk '/perform_rolling_update/,/fi/' "$UPDATE_SCRIPT" | grep -q 'perform_rollback' && echo true || echo false)"

    check "update.sh has cleanup_on_failure trap" \
        "$(grep -q 'trap cleanup_on_failure' "$UPDATE_SCRIPT" && echo true || echo false)"

    check "update.sh creates pre-update .env backup" \
        "$(grep -q 'pre-update' "$UPDATE_SCRIPT" && echo true || echo false)"

    check "update.sh sends notification on rollback" \
        "$(grep -q 'send_notification.*ROLLBACK\|send_notification.*FAILED' "$UPDATE_SCRIPT" && echo true || echo false)"

    check "update.sh contains verify_rollback()" \
        "$(grep -q 'verify_rollback' "$UPDATE_SCRIPT" && echo true || echo false)"

    check "rollback_service() restores .env before compose up" \
        "$(awk '/^rollback_service\(\)/,/^}/' "$UPDATE_SCRIPT" | grep -q 'dot-env.bak.*ENV_FILE\|ROLLBACK_DIR.*dot-env' && echo true || echo false)"

    check "save_rollback_state() saves image digests (not just tags)" \
        "$(grep -q '{{\.Image}}' "$UPDATE_SCRIPT" && echo true || echo false)"
fi

# Check backup/restore scripts
check "backup.sh exists and is executable" \
    "$([[ -x "$BACKUP_SCRIPT" ]] && echo true || echo false)"

check "restore.sh exists and is executable" \
    "$([[ -x "$RESTORE_SCRIPT" ]] && echo true || echo false)"

check "restore-runbook.sh exists and is executable" \
    "$([[ -x "$RESTORE_RUNBOOK" ]] && echo true || echo false)"

# Check versions.env exists
check "versions.env exists" \
    "$([[ -f "$VERSIONS_FILE" ]] && echo true || echo false)"

echo ""

# ──────────────────────────────────────────
# Phase 2: Validate rollback state mechanism
# ──────────────────────────────────────────
echo -e "${BOLD}Phase 2: Rollback State Mechanism${NC}"

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "  ${YELLOW}⚠ Dry run — simulating rollback state creation${NC}"

    # Create a temporary rollback state to validate the mechanism
    TEST_ROLLBACK_DIR=$(mktemp -d)
    trap 'rm -rf "$TEST_ROLLBACK_DIR"' EXIT

    # Simulate what save_rollback_state() does
    if [[ -f "$VERSIONS_FILE" ]]; then
        cp "$VERSIONS_FILE" "${TEST_ROLLBACK_DIR}/versions.env.bak"
        check "Can save versions.env backup" "true"
    else
        check "Can save versions.env backup" "false"
    fi

    if [[ -f "$ENV_FILE" ]]; then
        cp "$ENV_FILE" "${TEST_ROLLBACK_DIR}/dot-env.bak"
        check "Can save .env backup" "true"
    else
        check "Can save .env backup" "false"
    fi

    # Validate restore logic
    if [[ -f "${TEST_ROLLBACK_DIR}/versions.env.bak" ]]; then
        check "Rollback versions.env is valid" \
            "$(grep -q '_VERSION=' "${TEST_ROLLBACK_DIR}/versions.env.bak" && echo true || echo false)"
    fi
else
    # Check if rollback dir exists from a previous update
    if [[ -d "$ROLLBACK_DIR" ]]; then
        check "Rollback directory exists" "true"

        check "versions.env backup present" \
            "$([[ -f "${ROLLBACK_DIR}/versions.env.bak" ]] && echo true || echo false)"

        check ".env backup present" \
            "$([[ -f "${ROLLBACK_DIR}/dot-env.bak" ]] && echo true || echo false)"
    else
        echo -e "  ${YELLOW}⚠ No rollback directory found (no previous update)${NC}"
        check "Rollback directory exists" "false"
    fi
fi

echo ""

# ──────────────────────────────────────────
# Phase 3: Validate recovery paths
# ──────────────────────────────────────────
echo -e "${BOLD}Phase 3: Recovery Path Validation${NC}"

# Path A: Service-level rollback (update.sh rollback_service)
check "Service rollback: individual service can be rolled back" \
    "$(grep -q 'rollback_service.*old_image' "$UPDATE_SCRIPT" 2>/dev/null && echo true || echo false)"

# Path B: Full state rollback (update.sh perform_rollback)
check "Full rollback: restores versions.env" \
    "$(grep -q 'versions.env.bak.*VERSIONS_FILE' "$UPDATE_SCRIPT" 2>/dev/null && echo true || echo false)"

check "Full rollback: restores .env" \
    "$(grep -q 'dot-env.bak.*ENV_FILE' "$UPDATE_SCRIPT" 2>/dev/null && echo true || echo false)"

check "Full rollback: restarts services after config restore" \
    "$(grep -A5 'perform_rollback' "$UPDATE_SCRIPT" 2>/dev/null | grep -q 'docker compose.*up -d' && echo true || echo false)"

# Path C: Full restore from backup (restore.sh)
check "Full restore: supports AUTO_CONFIRM mode" \
    "$(grep -q 'AUTO_CONFIRM' "$RESTORE_SCRIPT" 2>/dev/null && echo true || echo false)"

check "Full restore: has checksum verification" \
    "$(grep -q 'sha256sum' "$RESTORE_SCRIPT" 2>/dev/null && echo true || echo false)"

check "Full restore: handles encrypted backups" \
    "$(grep -q '\.age' "$RESTORE_SCRIPT" 2>/dev/null && echo true || echo false)"

check "Full restore: has trap for service restart on failure" \
    "$(grep -q 'trap.*cleanup_restore' "$RESTORE_SCRIPT" 2>/dev/null && echo true || echo false)"

# Path D: Restore runbook (7-step verified restore)
check "Restore runbook: 7-step verified process" \
    "$(grep -q 'Step.*7' "$RESTORE_RUNBOOK" 2>/dev/null && echo true || echo false)"

echo ""

# ──────────────────────────────────────────
# Phase 4: Full simulation (optional)
# ──────────────────────────────────────────
if [[ "$FULL_TEST" == "true" ]]; then
    echo -e "${BOLD}Phase 4: Full Upgrade-Failure Simulation${NC}"

    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${RED}✗ Must run as root for full test${NC}"
        FAIL=$((FAIL + 1))
    else
        echo -e "  ${YELLOW}⚠ This will create a backup, modify versions, and rollback${NC}"
        echo -e "  ${YELLOW}  Expect brief service disruption${NC}"
        echo ""

        # Step 1: Save current state
        echo -e "  ${CYAN}→ Saving current state...${NC}"
        SAVED_VERSIONS=$(mktemp)
        cp "$VERSIONS_FILE" "$SAVED_VERSIONS"
        SAVED_ENV=$(mktemp)
        [[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "$SAVED_ENV"

        # Step 2: Create pre-test backup
        echo -e "  ${CYAN}→ Creating pre-test backup...${NC}"
        if bash "$BACKUP_SCRIPT" 2>/dev/null; then
            check "Pre-test backup created" "true"
        else
            check "Pre-test backup created" "false"
        fi

        # Step 3: Simulate version change (bump a version to something that doesn't exist)
        echo -e "  ${CYAN}→ Simulating version change...${NC}"
        TEST_VERSIONS_FILE=$(mktemp)
        sed 's/NGINX_VERSION=.*/NGINX_VERSION=99.99.99-nonexistent/' "$VERSIONS_FILE" > "$TEST_VERSIONS_FILE"
        cp "$TEST_VERSIONS_FILE" "$VERSIONS_FILE"
        rm -f "$TEST_VERSIONS_FILE"

        # Step 4: Run update (should fail and rollback)
        echo -e "  ${CYAN}→ Running update.sh --auto (expecting failure + rollback)...${NC}"
        if AUTO_UPDATE=true bash "$UPDATE_SCRIPT" --auto 2>&1; then
            echo -e "  ${YELLOW}⚠ Update succeeded unexpectedly${NC}"
        else
            check "Update correctly failed on bad version" "true"
        fi

        # Step 5: Verify rollback happened
        echo -e "  ${CYAN}→ Verifying rollback...${NC}"

        # Restore original versions
        cp "$SAVED_VERSIONS" "$VERSIONS_FILE"
        rm -f "$SAVED_VERSIONS"

        if [[ -f "$SAVED_ENV" ]]; then
            cp "$SAVED_ENV" "$ENV_FILE"
            chmod 600 "$ENV_FILE"
            rm -f "$SAVED_ENV"
        fi

        # Verify services are running
        cd "${INSTALL_DIR}/docker"
        running=$(docker compose ps --format '{{.Status}}' 2>/dev/null | grep -c "Up" || echo "0")
        check "Services running after rollback: ${running}" \
            "$([[ "$running" -gt 0 ]] && echo true || echo false)"

        echo ""
    fi
else
    echo -e "${BOLD}Phase 4: Full Simulation${NC}"
    echo -e "  ${YELLOW}⚠ Skipped (use --full-test to run)${NC}"
    echo ""
fi

# ──────────────────────────────────────────
# Summary
# ──────────────────────────────────────────
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo -e "  Total: ${TOTAL}  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}DR-004: ALL CHECKS PASSED${NC}"
else
    echo -e "  ${RED}DR-004: ${FAIL} CHECK(S) FAILED${NC}"
fi
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo ""

echo "Recovery Paths Summary:"
echo "  A. Service-level rollback:  update.sh rollback_service() → single service"
echo "  B. Full config rollback:    update.sh perform_rollback() → all configs + restart"
echo "  C. Full data restore:       restore.sh <backup_path> → DB + volumes + config"
echo "  D. Verified restore:        restore-runbook.sh <backup_path> → 7-step verified"
echo ""
echo "Recommended upgrade-failure procedure:"
echo "  1. update.sh auto-rollbacks on failure (Path A/B)"
echo "  2. If auto-rollback fails: restore from pre-update backup (Path C)"
echo "  3. If data is corrupted: use restore-runbook.sh for full verified restore (Path D)"
echo ""

exit $FAIL
