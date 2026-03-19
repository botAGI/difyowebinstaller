# Testing Patterns

**Analysis Date:** 2026-03-20

## Test Framework

**Runner:**
- BATS (Bash Automated Testing System) v1.8+
- Config: No config file; BATS reads test files directly
- Alternative syntax check: `bash -n` for all scripts (no execution)
- Linting: shellcheck integration in CI

**Assertion Library:**
- BATS built-in assertions (no external library)
- Standard: `[ $status -eq 0 ]`, `[[ "$output" == *"pattern"* ]]`
- Comparison operators: `-eq`, `-ne`, `-lt`, `-gt` (integers); `==`, `!=` (strings)

**Run Commands:**
```bash
bats tests/test_common.bats                    # Run single test file
bats tests/test_*.bats                         # Run all tests
bats tests/test_common.bats --verbose          # Verbose output
bats tests/test_common.bats --trace            # Trace mode (debug)
bash -n lib/common.sh                          # Syntax check without execution
shellcheck lib/*.sh scripts/*.sh                # Lint all scripts
```

**CI/CD Integration:**
- GitHub Actions workflow (`.github/workflows/ci.yml` implied by project structure)
- Runs: shellcheck + bats + bash -n on each commit
- Runs on: Ubuntu, CentOS, macOS (different OS implementations)

## Test File Organization

**Location:**
- All tests in `/d/Agmind/difyowebinstaller/tests/` directory
- Co-located with source code but in separate `tests/` directory (not mixed in source)

**Naming:**
- Pattern: `test_<module>.bats`
- Examples: `test_common.bats`, `test_detect.bats`, `test_config.bats`, `test_health.bats`
- One test file per lib module (loose coupling)

**Structure:**
```
tests/
├── test_common.bats              # Tests for lib/common.sh
├── test_detect.bats              # Tests for lib/detect.sh
├── test_wizard.bats              # Tests for lib/wizard.sh
├── test_config.bats              # Tests for lib/config.sh
├── test_compose.bats             # Tests for lib/compose.sh
├── test_docker.bats              # Tests for lib/docker.sh
├── test_security.bats            # Tests for lib/security.sh
├── test_health.bats              # Tests for lib/health.sh
├── test_openwebui.bats           # Tests for lib/openwebui.sh
├── test_models.bats              # Tests for lib/models.sh
├── test_backup.bats              # Tests for lib/backup.sh
├── test_compose_profiles.bats    # Integration: profile building
├── test_wizard_provider.bats     # Integration: wizard + provider logic
├── test_manifest.bats            # Manifest validation (check-manifest-versions.py)
├── test_agmind_cli.bats          # Integration: agmind.sh CLI
└── test_lifecycle.bats           # End-to-end: full install simulation
```

## Test Structure

**Suite Organization:**
```bash
#!/usr/bin/env bats
# test_common.bats — Tests for lib/common.sh
# Run: bats tests/test_common.bats

setup() {
    # Run before EACH test
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test"
    mkdir -p "$INSTALL_DIR"
    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
}

teardown() {
    # Run after EACH test
    rm -rf "${BATS_TMPDIR}/agmind_test"
}

# Test sections with ASCII headers
# ============================================================================
# LOGGING
# ============================================================================

@test "log_info outputs to stderr with arrow prefix" {
    run log_info "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"→ test message"* ]]
}

# ============================================================================
# VALIDATION
# ============================================================================

@test "validate_domain: valid domains pass" {
    run validate_domain "example.com"
    [ "$status" -eq 0 ]
}
```

**Patterns:**

1. **Setup/Teardown:**
   - `setup()`: Runs before each test, creates temp directory, sources module
   - `teardown()`: Runs after each test, cleans up temp files
   - Uses `${BATS_TMPDIR}` for isolation (unique per test)
   - Uses `${BATS_TEST_DIRNAME}` to source modules relative to test file

2. **Test naming convention:**
   - `@test "function: behavior expected"` format
   - Descriptive names that read like assertions
   - Examples:
     - `"log_info outputs to stderr with arrow prefix"`
     - `"validate_domain: valid domains pass"`
     - `"validate_domain: invalid domains fail"`

3. **Assertion structure:**
   ```bash
   run command_under_test arg1 arg2
   [ "$status" -eq 0 ]           # Check exit code
   [[ "$output" == *"pattern"* ]] # Check stdout content
   ```
   - `run` captures exit code in `$status` and output in `$output`
   - Status checks first (success/failure)
   - Output checks second (what was produced)

## Mocking

**Framework:** No mocking library used; tests use real functions with isolated environment

**Patterns:**
```bash
# Pattern 1: Override function temporarily in test
test_function_override() {
    # Mock a helper
    docker() {
        # Fake docker behavior
        if [[ "$1" == "ps" ]]; then
            echo "mock output"
            return 0
        fi
        command docker "$@"  # Fall back to real docker for other commands
    }
    export -f docker  # Export if needed for subshells

    run function_that_calls_docker
    [ "$status" -eq 0 ]
}

# Pattern 2: Use temp files as stubs
test_with_stub_files() {
    # Create fake .env
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test"
    mkdir -p "${INSTALL_DIR}/docker"
    echo "DOMAIN=test.local" > "${INSTALL_DIR}/docker/.env"

    run function_that_reads_env
    [ "$status" -eq 0 ]
}

# Pattern 3: Subshell isolation for side effects
test_isolated_side_effect() {
    # Global variable change doesn't affect other tests
    (
        GLOBAL_VAR="changed"
        run function_with_side_effect
    )
    [ "$status" -eq 0 ]
    # GLOBAL_VAR is still original in parent shell
}
```

**What to Mock:**
- Docker commands (test without running containers): Use stub functions
- File operations (test without actual filesystem): Use `${BATS_TMPDIR}`
- System commands that require root: Mock to return fake data
- Network calls (curl, API): Provide canned responses

**What NOT to Mock:**
- Core shell features (set -e, pipefail, variable expansion)
- Utility functions from common.sh (log_*, validate_*, generate_random)
- Basic filesystem operations (mkdir, rm, touch) on ${BATS_TMPDIR}
- String manipulation and regex matching

## Fixtures and Factories

**Test Data:**
```bash
# Example from test_config.bats: Setup wizard variables
setup_wizard_vars() {
    # Factory function to set common wizard exports
    export DEPLOY_PROFILE="lan"
    export DOMAIN="test.local"
    export CERTBOT_EMAIL="admin@test.local"
    export VECTOR_STORE="weaviate"
    export ETL_ENHANCED="false"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:14b"
    export EMBED_PROVIDER="ollama"
    export EMBEDDING_MODEL="bge-m3"
    export TLS_MODE="self-signed"
    export MONITORING_MODE="none"
    export ENABLE_UFW="false"
    export ENABLE_FAIL2BAN="false"
}

@test "generate_config respects DEPLOY_PROFILE" {
    setup_wizard_vars
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test"
    mkdir -p "${INSTALL_DIR}/docker"

    run generate_config "lan" "${BATS_TEST_DIRNAME}/../templates"
    [ "$status" -eq 0 ]
    grep -q "DEPLOY_PROFILE=lan" "${INSTALL_DIR}/docker/.env"
}
```

**Location:**
- Fixtures created inline in test functions (within setup/teardown or in individual @test blocks)
- Shared setup code extracted to helper functions (e.g., `setup_wizard_vars()`)
- No separate fixture files; BATS encourages inline setup
- Temporary files always in `${BATS_TMPDIR}/agmind_test/` for isolation

## Coverage

**Requirements:** Not enforced; no coverage metrics collected

**View Coverage:** Coverage tracking not implemented (pure shell testing)

## Test Types

**Unit Tests:**
- Scope: Individual functions from a single module
- Approach: Call function with known inputs, verify outputs
- Example from `test_common.bats`:
  ```bash
  @test "validate_email: valid emails pass" {
      run validate_email "user@example.com"
      [ "$status" -eq 0 ]
  }

  @test "validate_email: invalid emails fail" {
      run validate_email "noatsign.com"
      [ "$status" -eq 1 ]
      [[ "$output" == *"Invalid email"* ]]
  }
  ```
- Focus: Return codes, error messages, output format
- Isolation: Each test has its own INSTALL_DIR via setup/teardown

**Integration Tests:**
- Scope: Multiple modules working together
- Files: `test_compose_profiles.bats`, `test_wizard_provider.bats`, `test_agmind_cli.bats`
- Approach: Load multiple lib modules, verify they work together
- Example from implied `test_compose_profiles.bats`:
  ```bash
  @test "compose profiles built correctly for vps+monitoring+vllm" {
      export DEPLOY_PROFILE="vps"
      export MONITORING_MODE="local"
      export LLM_PROVIDER="vllm"
      export VECTOR_STORE="weaviate"

      source lib/compose.sh
      run build_compose_profiles
      [ "$status" -eq 0 ]
      [[ "$COMPOSE_PROFILE_STRING" == *"vps"* ]]
      [[ "$COMPOSE_PROFILE_STRING" == *"monitoring"* ]]
      [[ "$COMPOSE_PROFILE_STRING" == *"vllm"* ]]
  }
  ```
- Verifies: Profile logic, variable coupling, compose file generation

**E2E Tests:**
- Scope: Full installation flow (test_lifecycle.bats)
- Approach: Mock Docker, simulate all phases, verify outputs
- Cannot run in CI fully (requires actual Docker/sudo); marked as integration
- Local testing: Run after install with `--non-interactive` mode
- Validates: Checkpoint resume, error recovery, phase completion

## Common Patterns

**Async Testing:**
```bash
# Not typically needed for shell scripts, but example if waiting for background job
@test "function completes within timeout" {
    run timeout 5 function_that_should_complete_quickly
    [ "$status" -eq 0 ]
}
```

**Error Testing:**
```bash
# Example from test_common.bats
@test "validate_domain: empty domain fails" {
    run validate_domain ""
    [ "$status" -eq 1 ]              # Must fail
    [[ "$output" == *"cannot be empty"* ]]  # Check error message
}

@test "validate_port: out of range fails" {
    run validate_port "99999"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be 1-65535"* ]]
}

# Test fatal errors in generate_random
@test "generate_random returns non-empty string" {
    run generate_random 32
    [ "$status" -eq 0 ]
    [[ -n "$output" ]]
    [[ ${#output} -eq 32 ]]
}
```

**Regex matching:**
```bash
@test "log_info includes timestamp when LOG_FILE is set" {
    export LOG_FILE="/tmp/test.log"
    run log_info "timestamped"
    [ "$status" -eq 0 ]
    # Should contain date-like pattern YYYY-MM-DD
    [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]
    unset LOG_FILE
}

@test "validate_cron: valid cron expressions pass" {
    run validate_cron "0 3 * * *"
    [ "$status" -eq 0 ]

    run validate_cron "*/5 * * * *"
    [ "$status" -eq 0 ]
}
```

## Real Test Example: test_common.bats excerpt

```bash
#!/usr/bin/env bats
# test_common.bats — Tests for lib/common.sh
# Run: bats tests/test_common.bats

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test"
    mkdir -p "$INSTALL_DIR"
    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
}

teardown() {
    rm -rf "${BATS_TMPDIR}/agmind_test"
}

# ============================================================================
# LOGGING
# ============================================================================

@test "log_info outputs to stderr with arrow prefix" {
    run log_info "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"→ test message"* ]]
}

@test "log_warn outputs to stderr with warning prefix" {
    run log_warn "warning message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ warning message"* ]]
}

# ============================================================================
# VALIDATION: MODEL NAMES
# ============================================================================

@test "validate_model_name: valid names pass" {
    run validate_model_name "qwen2.5:14b"
    [ "$status" -eq 0 ]

    run validate_model_name "bge-m3"
    [ "$status" -eq 0 ]

    run validate_model_name "library/llama3:latest"
    [ "$status" -eq 0 ]
}

@test "validate_model_name: empty name fails" {
    run validate_model_name ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot be empty"* ]]
}

@test "validate_model_name: invalid characters fail" {
    run validate_model_name "model name with spaces"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid model name"* ]]

    run validate_model_name 'model;rm -rf'
    [ "$status" -eq 1 ]
}

# ============================================================================
# ATOMIC FILE OPERATIONS
# ============================================================================

@test "_atomic_sed: applies substitution atomically" {
    local test_file="${INSTALL_DIR}/test.conf"
    echo "old_value" > "$test_file"

    run _atomic_sed "$test_file" 's|old_value|new_value|'
    [ "$status" -eq 0 ]

    [[ "$(cat "$test_file")" == "new_value" ]]
}

@test "_atomic_sed: fails on missing file" {
    run _atomic_sed "/nonexistent/file" 's|a|b|'
    [ "$status" -eq 1 ]
    [[ "$output" == *"file not found"* ]]
}

# ============================================================================
# SECRET GENERATION
# ============================================================================

@test "generate_random: produces correct length" {
    run generate_random 32
    [ "$status" -eq 0 ]
    [[ ${#output} -eq 32 ]]
}

@test "generate_random: produces alphanumeric only" {
    run generate_random 64
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[a-zA-Z0-9]+$ ]]
}

@test "generate_random: produces different values" {
    val1="$(generate_random 32)"
    val2="$(generate_random 32)"
    [[ "$val1" != "$val2" ]]
}
```

**Key patterns in this example:**
- Each test focuses on one behavior
- Setup/teardown ensures clean isolation
- Both positive and negative cases tested
- Error messages checked (not just exit codes)
- BATS_TMPDIR used for file operations
- Clear test names describing expected behavior

## CI/CD Pipeline

Tests integrated into GitHub Actions:
1. **Lint stage:** `shellcheck lib/*.sh scripts/*.sh` — catches syntax/style issues
2. **Syntax check:** `bash -n lib/*.sh scripts/*.sh` — catches parsing errors
3. **Unit tests:** `bats tests/test_*.bats` — function-level tests
4. **Integration tests:** `bats tests/test_lifecycle.bats` — full flow simulation
5. **Manifest validation:** `python3 scripts/check-manifest-versions.py` — CI validator

Runs on every commit to main and PRs.

---

*Testing analysis: 2026-03-20*
