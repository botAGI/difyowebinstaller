# Testing Patterns

**Analysis Date:** 2026-04-04

## Test Framework

**Framework:**
- Bash syntax validation via `bash -n`
- No dedicated unit test framework (BATS, Shelltest, pytest not used)
- Integration tested through Docker Compose deployments
- Security scanning via Trivy

**Configuration Files:**
- `.github/workflows/test.yml` — CI pipeline configuration

**Run Commands:**
```bash
# Syntax check all scripts (what CI runs)
for f in lib/*.sh scripts/*.sh install.sh; do
  bash -n "$f"
done

# Security scan (Trivy config scan)
trivy config . --severity CRITICAL,HIGH --exit-code 1

# Manual testing: full deployment
sudo bash install.sh

# Non-interactive test (CI/CD friendly)
NON_INTERACTIVE=true DEPLOY_PROFILE=lan bash install.sh

# Day-2 operations test
agmind status
agmind check-all
agmind logs <service>
```

## Test File Organization

**Location:**
- No separate `/tests` directory
- No `*.test.sh` or `*.spec.sh` files
- Test coverage is integration-based: full deployment via `install.sh`

**Testing happens at these stages:**
1. **Syntax validation** — CI runs `bash -n` on all scripts before merge
2. **Deployment validation** — Manual testing with `install.sh` against profiles
3. **Health checks** — `lib/health.sh` validates all containers post-launch
4. **Health monitoring** — Continuous health checks via `health-gen.sh` (cron)

**CI Configuration:**
- File: `.github/workflows/test.yml`
- Triggers: `push` to main/develop, `pull_request` to main
- Two jobs: `syntax` and `trivy`

## Test Structure

**Syntax Check (CI Job):**
```bash
errors=0
for f in lib/*.sh scripts/*.sh install.sh; do
  if ! bash -n "$f"; then
    echo "FAIL: $f"
    errors=$((errors + 1))
  fi
done
exit $errors
```

**Pattern:**
- Early validation: files syntactically correct before any execution
- Fail-fast: exit with error count if any script is malformed
- Scope: all executable shell scripts in project

**Pre-flight Validation (Before Docker Compose Up):**
- `preflight_bind_mount_check()` in `lib/common.sh` (lines 254-303)
- Verifies bind-mount files exist and are files (not dirs)
- Checks for unresolved placeholders in `.env`
- Aborts with clear error message if any check fails

**Health Checks (After Docker Compose Up):**
- `wait_healthy()` in `lib/health.sh` — waits for all containers healthy
- `check_all()` — reports status of each container
- Includes GPU service progress parsing (`_parse_gpu_progress`) for long-running model loads
- Timeout handling: `TIMEOUT_START`, `TIMEOUT_HEALTH`, `TIMEOUT_GPU_HEALTH` env vars

## Mocking

**Framework:** None (integration tests run real Docker containers)

**Approach:**
- Real container health checks via `docker ps`, `docker exec`, `docker compose logs`
- GPU health probed via HTTP (curl/wget/python3) or Docker exec
- DNS override available via `SKIP_DNS_FIX` env var
- Environment variables allow test overrides (e.g., `FORCE_GPU_TYPE`, `SKIP_GPU_DETECT`)

**What to Mock (in integration tests):**
- Registry API calls: HTTP HEAD requests to check image existence (`_get_registry_token`, `_check_image_exists`)
- Slow operations: timeouts for model downloads (configurable via `TIMEOUT_MODELS`)
- External services: LLM providers (Ollama, vLLM, TEI) deployed as services

**What NOT to Mock:**
- Docker itself (real deployment)
- Container startup (real orchestration)
- Database operations (real PostgreSQL in container)
- File operations on host filesystem (real directories)

## Fixtures and Factories

**Test Data:**
- No factory pattern; configuration-driven
- Secrets generated fresh during each install: `generate_random 32`
- Template files in `templates/` directory (docker-compose.yml, config files)

**Configuration Fixtures:**
```bash
# Non-interactive defaults (wizard.sh lines 23-69)
_init_wizard_defaults() {
    DEPLOY_PROFILE="${DEPLOY_PROFILE:-}"
    DOMAIN="${DOMAIN:-}"
    VECTOR_STORE="${VECTOR_STORE:-weaviate}"
    ENABLE_DOCLING="${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}"
    # ... 40+ environment variable defaults
}
```

**Location:**
- Defaults in `lib/wizard.sh` (lines 23-69)
- Templates in `templates/` directory
- Volumes initialized during `_create_directory_structure()` in `lib/config.sh` (lines 70-95)
- Credentials stored at `${INSTALL_DIR}/credentials.txt` (mode 600) after install

**Profile Test Fixtures:**
- LAN profile: local network deployment
- VPS profile: public server with domain/TLS
- Offline profile: air-gapped with pre-downloaded images
- Non-interactive mode: automated testing via env vars

## Coverage

**Requirements:** Not explicitly enforced

**Test Coverage by Component:**
1. **Installation logic** — Full end-to-end via `install.sh`
   - OS detection (Debian, RHEL, macOS)
   - Docker/Compose installation
   - Configuration generation with secrets
   - Service startup and health checks

2. **Configuration generation** — Verified by binding checks
   - `.env` generation with all required vars
   - Redis, Nginx, Sandbox config files
   - LiteLLM, SearXNG, Monitoring configs (if enabled)
   - Placeholder resolution validation

3. **Health checks** — Container-level validation
   - Service startup within timeouts
   - Container status (running/healthy)
   - GPU service progress parsing
   - Endpoint accessibility

4. **Day-2 operations** — Functional tests via `agmind` CLI
   - Status dashboard
   - Service checks
   - Backup operations
   - Restore drills (dr-drill.sh)

**View Coverage:**
No automated coverage reporting. Manual verification:
```bash
# Test installation
sudo bash install.sh --non-interactive

# Test health
agmind check-all
agmind status

# Test backup/restore
agmind backup
bash scripts/dr-drill.sh  # Simulated restore

# Test day-2 operations
agmind logs api
agmind logs worker
agmind update  # Updates containers
```

## Test Types

**Syntax Tests:**
- **Scope:** Bash syntax correctness
- **Approach:** `bash -n` on all scripts
- **Framework:** CI job in `.github/workflows/test.yml`
- **Who runs:** Every push/PR to main
- **Failure handling:** Blocks merge if any script has syntax errors

**Deployment/Integration Tests:**
- **Scope:** Full stack installation and health
- **Approach:** Run `install.sh` with env overrides
- **Who runs:** Manual (before releases), CI optionally (resource-heavy)
- **Profiles tested:** LAN, VPS, Offline (via git branch)
- **Docker Compose:** Real containers, real services
- **Validation:** Health checks (`wait_healthy`), endpoint checks

**Security Scanning:**
- **Scope:** Container images, configuration, secrets
- **Tool:** Trivy (CLI)
- **Severity:** CRITICAL, HIGH severity only
- **Who runs:** Every push/PR in CI
- **Failure handling:** Blocks merge if high-severity issues found

**Functional Tests (Day-2):**
- **Scope:** AGMind CLI operations
- **Approach:** Manual via `agmind` commands
- **Examples:**
  - `agmind status` — display dashboard
  - `agmind check-all` — health check all services
  - `agmind backup` — backup full stack
  - `agmind update` — update container images
  - `agmind logs <service>` — view container logs
  - `scripts/dr-drill.sh` — simulate restore from backup

**Regression Tests (Implicit):**
- Phase-based install tracking: `.install_phase` file allows resume
- Service idempotency: re-running `install.sh` doesn't fail on existing setup
- Configuration preservation: `.env` and credentials survive re-runs
- Backwards compatibility: non-interactive mode supports old env var names (e.g., `ETL_ENHANCED` → `ENABLE_DOCLING`)

## Common Patterns

**Async Testing:**
- No async/await (Bash is single-threaded)
- Timeout loops use sleep and retry:
```bash
_run_with_timeout() {
    local func="$1" timeout="$2"
    local start
    start="$(date +%s)"
    while true; do
        if "$func"; then return 0; fi
        local elapsed=$(($(date +%s) - start))
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout after ${timeout}s"
            return 1
        fi
        sleep 1
    done
}
```

**Error Testing:**
- Validator returns 1 on failure:
```bash
validate_email "invalid" && echo "OK" || echo "FAIL"
# Output: FAIL
```

- Conditional handling of validation failures:
```bash
if ! validate_port "$port"; then
    log_error "Invalid port: $port"
    return 1
fi
```

**Health Check Pattern (Post-Deployment):**
```bash
check_container "api" || {
    log_error "Container failed to start"
    return 1
}

# Wait for all to be healthy
wait_healthy 300  # 5 minute timeout
```

**Idempotency Pattern:**
```bash
install_docker() {
    if [[ "${DETECTED_DOCKER_INSTALLED:-false}" == "true" && 
          "${DETECTED_DOCKER_COMPOSE:-false}" == "true" ]]; then
        log_success "Docker and Compose already installed"
        return 0
    fi
    # ... install logic
}
```

## Manual Testing Guide

**Before Merge:**
1. Run syntax check locally:
   ```bash
   for f in lib/*.sh scripts/*.sh install.sh; do bash -n "$f"; done
   ```
2. Run Trivy scan:
   ```bash
   trivy config . --severity CRITICAL,HIGH
   ```

**Before Release:**
1. Test LAN profile (local network):
   ```bash
   NON_INTERACTIVE=true DEPLOY_PROFILE=lan bash install.sh
   agmind status
   agmind check-all
   ```

2. Test VPS profile (VPS deployment):
   ```bash
   git checkout agmind-caddy
   NON_INTERACTIVE=true DEPLOY_PROFILE=vps DOMAIN=example.com bash install.sh
   ```

3. Test backup/restore:
   ```bash
   agmind backup
   bash scripts/dr-drill.sh  # Simulated restore
   ```

4. Test day-2 operations:
   ```bash
   agmind logs api
   agmind update
   agmind check-all  # Verify still healthy
   ```

---

*Testing analysis: 2026-04-04*
