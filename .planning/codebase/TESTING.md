# Testing Patterns

**Analysis Date:** 2026-03-18

## Test Framework Status

**Current State:**
- **No automated test framework detected** (Jest, Vitest, Mocha, etc.)
- **No unit test files** (.test.js, .spec.js, etc.)
- **No E2E test suite** (Cypress, Playwright, etc.)
- **No test configuration** (jest.config.js, vitest.config.js, etc.)

**Implication:**
Testing is currently **manual and operational**. All validation happens at deployment time through health checks and integration verification rather than code-level unit tests.

## Manual Testing Patterns

**Pre-flight Validation (Code-level checks):**

**Script validation:**
- Bash scripts checked against `shellcheck` compliance implicitly via `set -euo pipefail`
- No formal CI/CD linting pipeline detected, but strict mode catches:
  - Undefined variables
  - Unset array expansions
  - Pipe failures (all stages, not just last)

**Health Check Patterns (`lib/health.sh`, `scripts/health-gen.sh`):**

Located: `lib/health.sh`

```bash
check_container() {
    local name="$1"
    local status
    status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$name" 2>/dev/null || echo "not found")

    if echo "$status" | grep -qi "up\|healthy"; then
        echo -e "  ${GREEN}[OK]${NC}  $name"
        return 0
    elif echo "$status" | grep -qi "starting"; then
        echo -e "  ${YELLOW}[..]${NC}  $name (starting)"
        return 1
    else
        echo -e "  ${RED}[!!]${NC}  $name ($status)"
        return 1
    fi
}

wait_healthy() {
    local timeout="${1:-300}"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300
    local interval=5
    local elapsed=0

    local services
    read -ra services <<< "$(get_service_list)"

    while [[ $elapsed -lt $timeout ]]; do
        local all_ok=true

        for svc in "${services[@]}"; do
            local status
            status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")
            if ! echo "$status" | grep -qi "up\|healthy"; then
                all_ok=false
                break
            fi
        done

        if [[ "$all_ok" == "true" ]]; then
            echo -e "${GREEN}All containers started!${NC}"
            check_all
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -ne "\r  Waiting... ${elapsed}/${timeout}s"
    done

    return 1
}
```

**Service List Detection (dynamic):**
```bash
get_service_list() {
    local services=(db redis sandbox ssrf_proxy api worker web plugin_daemon ollama pipeline nginx open-webui)

    # Read .env to determine which optional services are active
    if [[ -f "$env_file" ]]; then
        local vector_store
        vector_store=$(grep '^VECTOR_STORE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")
        if [[ "$vector_store" == "qdrant" ]]; then
            services+=(qdrant)
        else
            services+=(weaviate)
        fi
        # ... additional optional services ...
    fi

    echo "${services[@]}"
}
```

## Deployment Validation Scripts

**Scripts with validation:**

**`scripts/update.sh`** (Rolling update with validation):
- Located: `/d/Agmind/difyowebinstaller/scripts/update.sh`
- Validates:
  - Version file exists and parses correctly
  - `.env` file intact before/after update
  - Rollback capability maintained
  - Service health post-update
- Pattern: Backup `.env` before update, diff after to detect corruption

**`scripts/backup.sh`** (Pre-backup checks):
- Located: `scripts/backup.sh` (also executable standalone)
- Validates:
  - PostgreSQL connectivity: `pg_isready` check
  - Database dump succeeds (captures `pg_dump` return code to log file)
  - Required databases exist
  - Backup directory writable
  - Target disk space sufficient (implicit — fails if disk full)

**`scripts/test-upgrade-rollback.sh`** (Test harness):
- Purpose: Full end-to-end upgrade simulation
- Validates: Update process, rollback capability
- Pattern: Creates test environment, applies update, verifies functionality, performs rollback

**`scripts/dr-drill.sh`** (Disaster recovery test):
- Simulates: Backup and recovery without actually restoring
- Validates: Backup integrity, recovery process, time to recovery

## Configuration Validation

**Pre-flight Validation Pattern (from `lib/config.sh`):**

```bash
preflight_bind_mount_check() {
    local docker_dir="${INSTALL_DIR}/docker"

    # 1. Find .yml/.yaml files that are actually directories
    local yml_dirs
    yml_dirs=$(find "$docker_dir" -name "*.yml" -type d 2>/dev/null || true)

    # 2. Find .conf files that are actually directories
    local conf_dirs
    conf_dirs=$(find "$docker_dir" -name "*.conf" -type d 2>/dev/null || true)

    # 3. Verify ALL bind-mount source files exist
    local all_bind_files=(
        "nginx/nginx.conf"
        "volumes/redis/redis.conf"
        "volumes/ssrf_proxy/squid.conf"
        "monitoring/prometheus.yml"
        # ... more files
    )

    for f in "${all_bind_files[@]}"; do
        local full="${docker_dir}/${f}"
        if [[ ! -f "$full" ]]; then
            echo -e "${RED}✗ Missing: ${f}${NC}"
            errors=$((errors + 1))
        fi
    done

    return $errors
}
```

**Safe Config Parsing (minimal trust):**
Located: `scripts/backup.sh` lines 32-40

```bash
# B-08: Safe config parsing (no source)
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$key" in
        BACKUP_RETENTION_COUNT|BACKUP_RETENTION_DAYS|ENABLE_S3_BACKUP|...)
            declare "$key=$value" ;;
    esac
done < <(grep -E '^[A-Za-z_]' "${INSTALL_DIR}/scripts/backup.conf")
```

- **Pattern:** Whitelist allowed variables, skip invalid keys, parse only expected keys
- **Reason:** Avoid code injection from malformed config files
- **Never source untrusted files:** Uses `declare` instead of `source`

## Integration Testing

**Docker Compose Health Checks:**
- Each service defines healthcheck in `templates/docker-compose.yml`
- Example pattern: HTTP GET to health endpoint with timeout and retry
- Validated by: `docker compose ps --format '{{.Status}}'` grep for "healthy"

**Environment Variable Validation:**

**Version Pinning Test (implicit):**
- Located: `templates/versions.env`
- Validates: All critical services have explicit versions (no `:latest`)
- Test: `install.sh` fails if any `_VERSION` variable is empty or uses `:latest`

**Required Env Vars Validation:**
```bash
validate_no_default_secrets() {
    local env_file="$1"
    local has_errors=false

    # Check for placeholder values that should be configured
    grep -E '(TODO|CHANGEME|changeme|placeholder)' "$env_file" && {
        echo "ERROR: Config contains unconfigured placeholders"
        has_errors=true
    }

    return $([ "$has_errors" = true ] && echo 1 || echo 0)
}
```

## Operational Testing Patterns

**Rollback Testing (`scripts/test-upgrade-rollback.sh`):**
- Purpose: Validate update → rollback cycle without data loss
- Validates:
  - State backup before update
  - Update application succeeds
  - Rollback to previous state succeeds
  - Data integrity post-rollback

**Multi-instance Testing (`scripts/multi-instance.sh`):**
- Purpose: Test parallel installations on same host
- Validates: Isolation, port conflicts, resource limits
- Test: Multiple `INSTALL_DIR` variants don't interfere

**Security Validation (implicit):**
- UFW rules: `configure_ufw()` in `lib/security.sh`
- Fail2ban: `configure_fail2ban()` with email alerts
- Secrets encryption: `encrypt_secrets()` with age

## Test Data and Fixtures

**Configuration Templates:**
Located: `templates/` directory

- `docker-compose.yml` — Full stack template
- `versions.env` — Version pinning (changes tested via update cycle)
- `release-manifest.json` — Version manifest for releases
- Nginx, Redis, Prometheus, Loki configs — Validated by preflight checks

**Mock Data:**
- Test models: Ollama pulls small models (`qwen2.5:7b` for quick tests, `qwen2.5:14b` for production)
- Test data: None persistent — uses live PostgreSQL in containers

## Coverage

**Requirements:** Not formally enforced

**What IS Tested (operationally):**
- Docker Compose stack brings up (health checks pass)
- PostgreSQL backup/restore cycle
- Update and rollback capability
- Service isolation and networking

**What is NOT Tested:**
- Unit tests for individual functions
- Integration tests for API endpoints
- UI/UX functionality
- Performance/load testing
- Chaos engineering / failure injection

**Gaps Identified:**
1. No automated unit tests — all functions tested only through deployment
2. No API integration tests — endpoints tested manually or through UI
3. No database migration tests — tested only during rolling update
4. No load testing — capacity unknown until production

## How to Test Locally

**Full Stack Test:**
```bash
# Start fresh installation in test environment
export INSTALL_DIR="/opt/agmind-test"
sudo bash install.sh
# Runs diagnostics, health checks automatically
```

**Update/Rollback Test:**
```bash
cd /opt/agmind
sudo bash scripts/test-upgrade-rollback.sh
# Applies available updates, verifies health, rolls back
```

**Backup/Restore Test:**
```bash
# Create backup
sudo bash /opt/agmind/scripts/backup.sh

# Run DR drill (backup-only, no restore)
sudo bash /opt/agmind/scripts/dr-drill.sh --skip-restore

# Test full restore
sudo bash /opt/agmind/scripts/restore.sh /var/backups/agmind/YYYY-MM-DD_HHMM
```

**Health Check Only:**
```bash
# Verify running services
bash lib/health.sh
# or generate HTML report
bash scripts/health-gen.sh > /tmp/health.html
```

**Shellcheck Compliance:**
```bash
# Check all scripts for bash compliance
for script in install.sh lib/*.sh scripts/*.sh; do
    shellcheck "$script"
done
```

## Continuous Testing Strategy

**Currently Implemented:**
- Pre-deployment validation in `install.sh`
- Health checks after container startup
- Backup integrity checks in `scripts/backup.sh`

**Missing:**
- No CI/CD pipeline detected (no GitHub Actions, GitLab CI, etc.)
- No automated regression testing
- No version compatibility matrix

**Recommendation for Future:**
- Add GitHub Actions workflow to run `shellcheck` on all `.sh` files
- Add automated backup verification in CI
- Create integration tests for critical update paths
- Add security scanning (SOPS config, no hardcoded secrets)

---

*Testing analysis: 2026-03-18*
