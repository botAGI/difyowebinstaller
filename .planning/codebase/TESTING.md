# Testing Patterns

**Analysis Date:** 2026-03-18

## Test Framework

**Runner:**
- BATS (Bash Automated Testing System) [version detected in workflow]
- Config: `.github/workflows/test.yml` defines CI pipeline

**Assertion Library:**
- BATS built-in assertions: `[ condition ]`, `[[ condition ]]`, `run` command capture
- No external assertion library; uses bash conditionals and BATS run wrapper

**Run Commands:**
```bash
bats tests/                        # Run all tests
bats tests/test_config.bats        # Run single test file
bats tests/ --tap                  # TAP (Test Anything Protocol) output
bash -n *.sh                       # Syntax validation (used in tests)
python3 -m py_compile script.py    # Python syntax check
```

**CI Pipeline:**
- GitHub Actions workflow: `.github/workflows/test.yml`
- Runs on: `push` to `main`/`develop`, `pull_request` to `main`
- Two parallel jobs:
  1. `bats`: Install BATS, run `bats tests/`
  2. `trivy`: Security scan on config files (CRITICAL/HIGH severity)

## Test File Organization

**Location:**
- Separate directory: `tests/` (co-located with source, not embedded)
- Test files do NOT mirror source tree; flat structure in `tests/`

**Naming:**
- Pattern: `test_*.bats` (BATS convention)
- Files: `test_config.bats`, `test_lifecycle.bats`, `test_manifest.bats`
- Each file focuses on single domain (config, lifecycle, manifest)

**Structure:**
```
tests/
├── test_config.bats              # Config.sh function tests + template validation
├── test_lifecycle.bats           # Syntax checks + integration scenarios
└── test_manifest.bats            # Release manifest JSON + image list validation
```

## Test Structure

**Suite Organization:**

```bash
#!/usr/bin/env bats

# Comment line documenting test purpose

setup() {
    # Run before EACH test
    export INSTALL_DIR="$(mktemp -d)"
    mkdir -p "${INSTALL_DIR}/docker"
    source "$(dirname "$BATS_TEST_FILENAME")/../lib/config.sh" 2>/dev/null || true
}

teardown() {
    # Run after EACH test
    rm -rf "$INSTALL_DIR"
}

@test "test description" {
    # Single test assertion
    [ ${#result} -eq 16 ]
}

@test "another test" {
    run bash -n "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}
```

**Patterns:**

**Setup Pattern:**
- Create temporary directory: `export INSTALL_DIR="$(mktemp -d)"`
- Source module being tested: `source "$(dirname "$BATS_TEST_FILENAME")/../lib/config.sh"`
- Suppress errors on missing modules: `2>/dev/null || true`
- Pre-create directory structures needed by tests: `mkdir -p "${INSTALL_DIR}/docker"`

**Teardown Pattern:**
- Remove temporary directories: `rm -rf "$INSTALL_DIR"`
- Clean up lock files if created during test
- No cleanup needed for environment variables (BATS resets per-test)

**Assertion Pattern:**
```bash
# Simple exit code test
[ $status -eq 0 ]

# String comparison
[ "$result" = "expected_value" ]

# Numeric comparison
[ ${#result} -eq 16 ]

# Regex match (bash extended glob)
[[ "$result" =~ ^[a-zA-Z0-9]+$ ]]

# Negative assertion (grep fails = test passes)
run grep -i "latest" "$versions_file"
[ "$status" -ne 0 ]  # Non-zero status means test passes
```

**Using `run` Wrapper:**
```bash
@test "command must succeed" {
    run bash -n "${ROOT_DIR}/install.sh"
    # $status: exit code of command
    # $output: combined stdout/stderr
    # $lines: array of output lines
    [ "$status" -eq 0 ]
    [[ "$output" =~ "success message" ]]
}
```

## Mocking

**Framework:** Manual shell simulation (no mocking library)

**Patterns:**

**Temporary Environment:**
```bash
@test "function with isolated env" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_PASSWORD=changeme" > "$env_file"

    run validate_no_default_secrets "$env_file"
    [ "$status" -ne 0 ]
}
```

**Function Isolation:**
```bash
@test "bash syntax validation" {
    run bash -n "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}
```

**What to Mock:**
- Temporary directories for config files (always done: `mktemp -d`)
- Environment variables for test scope (exported at setup)
- File states (create files for "file exists" tests, omit for "file missing" tests)

**What NOT to Mock:**
- Docker commands (tests run on CI without Docker, so tests check syntax only)
- External services (Weaviate, Qdrant, Ollama) — never invoked in tests
- Real system calls — tests validate file generation, not actual system changes

## Fixtures and Factories

**Test Data:**

**Password/Key Generation:**
```bash
@test "generate_random produces correct length" {
    result=$(generate_random 16)
    [ ${#result} -eq 16 ]
}
```

**Environment Files:**
```bash
@test "validate_no_default_secrets rejects 'changeme'" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_PASSWORD=changeme" > "$env_file"
    run validate_no_default_secrets "$env_file"
    [ "$status" -ne 0 ]
}
```

**Location:**
- No separate fixtures directory
- Test data created inline in test functions
- Template files sourced from `templates/` directory (actual project files, not test-specific)

## Coverage

**Requirements:** No explicit coverage target enforced; CI passes if all BATS tests pass

**View Coverage:**
- Not measured by BATS natively
- `bash -n` provides syntax coverage verification
- Manual visual inspection of test files to identify untested code paths

**Current Coverage (by domain):**
1. **Config (test_config.bats):** 13 tests
   - Random generation (length, uniqueness, character set)
   - Password validation (reject known defaults, placeholders)
   - YAML syntax validation
   - Template compliance (no "latest" tags, no unresolved variables)
   - Service defaults in docker-compose.yml

2. **Lifecycle (test_lifecycle.bats):** 11 tests
   - Bash syntax for all shell scripts
   - Deprecated endpoint removal (localhost:6333)
   - Rollback function presence and correctness
   - Image digest capture mechanism

3. **Manifest (test_manifest.bats):** 11 tests
   - JSON structure validation
   - Required fields presence
   - Image count verification
   - Version consistency between manifest and versions.env
   - Python script compilation

## Test Types

**Unit Tests:**
- Scope: Individual functions from `lib/` modules
- Approach: Call function with known inputs, verify output and exit code
- Examples: `generate_random()`, `escape_sed()`, `validate_no_default_secrets()`
- These are the core of test_config.bats

**Integration Tests:**
- Scope: Multi-step workflows (install → backup → restore)
- Approach: Verify script syntax and function presence; don't execute
- Examples: "backup.sh has valid bash syntax", "rollback_service restores .env before compose up"
- These are the core of test_lifecycle.bats

**E2E Tests:**
- Framework: Not used (no full container orchestration in CI)
- Manual tests: `scripts/dr-drill.sh` is local disaster recovery test (not automated in CI)
- Real-world validation: `health.sh` run post-install to verify containers (manual invocation)

## Common Patterns

**Async Testing:**
```bash
# Wait for condition to become true (example from health.sh invocation pattern)
while [[ $elapsed -lt $timeout ]]; do
    status=$(docker compose ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")
    if echo "$status" | grep -qi "up\|healthy"; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
```
- Not directly tested in BATS (would require real Docker containers)
- Health check logic tested manually by running `scripts/health.sh` after install

**Error Testing:**
```bash
@test "validate_no_default_secrets rejects 'changeme'" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_PASSWORD=changeme" > "$env_file"
    run validate_no_default_secrets "$env_file"
    [ "$status" -ne 0 ]  # Assert function returns failure
}

@test "validate_no_default_secrets accepts random passwords" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_PASSWORD=$(generate_random 32)" > "$env_file"
    run validate_no_default_secrets "$env_file"
    [ "$status" -eq 0 ]  # Assert function succeeds
}
```

**Conditional Execution (Skipping):**
- BATS has no native skip mechanism
- Tests use grep with `$status -ne 0` pattern (test passes if command NOT found):
  ```bash
  @test "nginx template has no __ADMIN_TOKEN__" {
      run grep "__ADMIN_TOKEN__" "${nginx_template}"
      [ "$status" -ne 0 ]  # Test passes if grep finds nothing
  }
  ```

## Test Execution in CI

**Workflow File:** `.github/workflows/test.yml`

**BATS Job:**
```yaml
bats:
  name: BATS Unit Tests
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Install BATS
      run: |
        sudo apt-get update
        sudo apt-get install -y bats
    - name: Run BATS tests
      run: bats tests/
```

**Trivy Security Job:**
```yaml
trivy:
  name: Trivy Security Scan
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Run Trivy config scan
      uses: aquasecurity/trivy-action@master
      with:
        scan-type: 'config'
        scan-ref: '.'
        severity: 'CRITICAL,HIGH'
        exit-code: '1'  # Fail on CRITICAL/HIGH issues
```

## Test Data Files

**Real Templates Used in Tests:**
- `templates/versions.env`: Checked for "latest" tags and version consistency
- `templates/docker-compose.yml`: Validated as YAML, checked for service defaults
- `templates/nginx.conf.template`: Checked for placeholders that should be resolved
- `scripts/backup.sh`, `scripts/restore.sh`: Checked for deprecated endpoints and rollback logic

## Testing Guidelines for Future Work

**When Adding New Functions:**
1. Add unit test to appropriate test file (config → test_config.bats, etc.)
2. Test success path with valid inputs
3. Test failure path with invalid inputs
4. Use temporary `INSTALL_DIR` for file-based tests

**When Adding New Scripts:**
1. Add `bash -n` syntax check to test_lifecycle.bats "all .sh files pass bash -n"
2. If script has critical functions, add specific tests (e.g., rollback functions in update.sh)
3. If script processes files, add integration test validating template usage

**Debugging Failed Tests:**
```bash
# Run single test with verbose output
bats tests/test_config.bats -f "generate_random"

# Run test with bash debug output
bash -x /path/to/test_file.bats

# Check BATS temp files
cat /tmp/bats-*
```

---

*Testing analysis: 2026-03-18*
