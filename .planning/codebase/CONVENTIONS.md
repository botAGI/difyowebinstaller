# Coding Conventions

**Analysis Date:** 2026-03-20

## Naming Patterns

**Files:**
- Bash scripts use lowercase with hyphens: `lib/common.sh`, `scripts/build-offline-bundle.sh`
- Internal helper functions (private to module) use leading underscore: `_atomic_sed()`, `_cleanup_stale_containers()`
- Public functions (exported by module) use no prefix: `log_info()`, `validate_domain()`
- Python scripts use lowercase with hyphens: `check-manifest-versions.py`

**Functions:**
- Shell functions use snake_case: `validate_domain`, `wait_healthy`, `sync_db_password`
- No parentheses in definition when using `function` keyword; function name + `()` syntax used throughout
- Format: `function_name() { ... }` with opening brace on same line
- Private functions prefixed with single underscore: `_atomic_sed()`, `_generate_secrets()`

**Variables:**
- Global configuration: UPPERCASE: `INSTALL_DIR`, `DOMAIN`, `DEPLOY_PROFILE`, `LLM_PROVIDER`
- Local variables: lowercase with underscores: `safe_domain`, `retry`, `compose_file`
- Readonly/constant globals: UPPERCASE: `VERSION="3.0.0"`, `TIMEOUT_START=300`
- Function parameters: prefix with `$1`, `$2`, accessed via `"${1:-default}"` pattern for safety

**Types/Constants:**
- Color codes: UPPERCASE: `RED`, `GREEN`, `CYAN`, `BOLD`, `NC` (defined in `lib/common.sh`)
- Boolean: string literals `"true"` or `"false"`, checked with `[[ "$var" == "true" ]]`
- Paths: use absolute paths, no relative paths (INSTALL_DIR is `/opt/agmind` in production)

## Code Style

**Formatting:**
- No external formatter required; manual formatting consistent with Bash idioms
- Indentation: 4 spaces (not tabs)
- Line length: no hard limit but keep functions < 50 lines where practical
- Brace style: Opening brace on same line as function/if/for/while
  ```bash
  function_name() {
      local var="value"
      if [[ condition ]]; then
          action
      fi
  }
  ```

**Linting:**
- Tool: shellcheck (invoked in CI via GitHub Actions)
- Source annotations used: `# shellcheck source=../lib/common.sh` for sourced files
- Disable annotations for specific rules: `# shellcheck disable=SC2086` (word splitting intentional)
- Files must pass shellcheck without warnings
- All shell scripts must run with `bash -n` (syntax check)

**Strict mode always enabled:**
- Every shell script starts with: `set -euo pipefail`
- `-e`: Exit on any error (no `|| true` unless intentional)
- `-u`: Unset variables cause error (use `"${var:-default}"` syntax)
- `-o pipefail`: Pipe failures propagate (catch errors in chains)
- Error traps defined early: `trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR`

## Import Organization

**Order:**
1. Shebang: `#!/usr/bin/env bash`
2. File header comment (purpose, dependencies, exports, set -euo pipefail)
3. Global variable declarations
4. Function definitions (public functions first, private helpers after)
5. Conditional execution (main code at end of script)

**Path Aliases:**
- No aliases used; absolute paths consistently used
- INSTALL_DIR expansion: `"${INSTALL_DIR:-/opt/agmind}"`
- All sourced files use absolute patterns: `source "${INSTALLER_DIR}/lib/common.sh"`

**Module sourcing pattern:**
- `install.sh` sources all lib modules once at top
- Each lib module has dependencies comment: `# Dependencies: common.sh (log_*), detect.sh (DETECTED_OS, DETECTED_GPU)`
- Modules are sourced in dependency order (common.sh first)
- Example from `install.sh`:
  ```bash
  source "${INSTALLER_DIR}/lib/common.sh"
  source "${INSTALLER_DIR}/lib/detect.sh"
  source "${INSTALLER_DIR}/lib/wizard.sh"
  # ... rest in order
  ```

## Error Handling

**Patterns:**
- Return codes: `0` = success, `1` = failure, specific codes for specific failures
- Functions return explicitly: `return 0` on success, `return 1` on error
- Error messages go to stderr: `echo "message" >&2` or via `log_error()`
- Critical failures use exit: `exit 1` only in main scripts, return in functions
- Conditionals check return codes: `func || log_error "Failed"; return 1`
- Example from `lib/common.sh`:
  ```bash
  validate_domain() {
      local domain="${1:-}"
      if [[ -z "$domain" ]]; then
          log_error "Domain cannot be empty"
          return 1
      fi
      if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
          log_error "Invalid domain: ${domain}"
          return 1
      fi
  }
  ```

**Signal handling:**
- Cleanup handlers registered with trap: `trap _cleanup_on_failure EXIT`
- Acquire exclusive lock to prevent concurrent runs: `trap 'rmdir "$LOCK_DIR"' EXIT` (macOS) or flock (Linux)
- Safe temp file cleanup: `local tmp="${file}.tmp.$$"; ... mv "$tmp" "$file"`

## Logging

**Framework:** Built-in using color-coded stderr output (no external logging library)

**Functions:**
- `log_info()` — informational message with cyan arrow `→`
- `log_warn()` — warning with yellow warning symbol `⚠`
- `log_error()` — error with red X `✗`
- `log_success()` — success with green checkmark `✓`

**Patterns:**
- All logging to stderr: `>&2` suffix prevents pollution of stdout pipelines
- Timestamps added when `LOG_FILE` is set (by install.sh): `$(date '+%Y-%m-%d %H:%M:%S')`
- Structure: `→ Action started` then `✓ Action completed` or `✗ Action failed`
- Progress indication: `echo -ne "\r  Waiting... ${elapsed}/${timeout}s"` for long operations
- Examples from `lib/health.sh`:
  ```bash
  log_info "Waiting for containers to be healthy (timeout: ${timeout}s)..."
  # ... loop ...
  log_success "All containers are up!"
  ```

## Comments

**When to Comment:**
- File header: Always include purpose, dependencies, exports, functions list
- Section headers: Use ASCII separator lines for major code blocks: `# ============================================================================`
- Complex logic: Explain WHY not WHAT (WHAT is obvious from code)
- Gotchas: Docker bind mount issues, atomic sed operations, shellcheck disables
- Dependencies: When one function relies on another's side effects

**JSDoc/TSDoc:** Not applicable (Bash project)

**Example from `lib/config.sh`:**
```bash
#!/usr/bin/env bash
# config.sh — Generate .env, nginx.conf, redis.conf, sandbox config, compose GPU setup.
# Dependencies: common.sh (log_*, generate_random, _atomic_sed, escape_sed,
#               safe_write_file, validate_no_default_secrets, ensure_bind_mount_files)
# Functions: generate_config(profile, template_dir), enable_gpu_compose()
# Expects: wizard exports (DEPLOY_PROFILE, LLM_PROVIDER, DOMAIN, etc.)
set -euo pipefail

# Module-level variables set by _generate_secrets, consumed by _generate_env_file
_SECRET_KEY=""
_DB_PASSWORD=""
# ... comments explain why these are at module level
```

## Function Design

**Size:** Functions should do one thing and be under 50 lines when possible. Larger functions split into private helpers.
- Example: `generate_config()` (50 lines) calls `_create_directory_structure()`, `_generate_secrets()`, `_generate_env_file()`, etc.

**Parameters:**
- Use `"${1:-default}"` for safe parameter access with default fallback
- Validate parameters at function start, return early on error
- Named parameters via comments when count > 3: Document in function header
- Example from `lib/health.sh`:
  ```bash
  wait_healthy() {
      local timeout="${1:-300}"  # First param: timeout in seconds
      [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300  # Validate immediately
      local interval=5
      # ... rest of function
  }
  ```

**Return Values:**
- Functions return 0/1 (success/failure)
- Larger outputs via stdout for piping (e.g., `generate_random()` outputs the random string)
- Configuration written to module-level variables accessible after function call (e.g., `_generate_secrets()` sets `_SECRET_KEY`, `_DB_PASSWORD`, etc.)
- Example from `lib/compose.sh`:
  ```bash
  build_compose_profiles() {
      local profiles=""
      # ... build string ...
      COMPOSE_PROFILE_STRING="$profiles"  # Set module-level variable
      export COMPOSE_PROFILE_STRING       # Export for docker compose
  }
  ```

## Module Design

**Exports:** Functions documented in file header comment with `# Functions: func1(), func2()`
- Public functions (no underscore prefix) are callable by other modules
- Private functions (underscore prefix) are for internal use only
- Example from `lib/common.sh` header:
  ```bash
  # Exports: colors, log_*, validate_*, generate_random, _atomic_sed,
  #          escape_sed, safe_write_file, init_detected_defaults
  ```

**Barrel Files:** Not used (no index.sh or similar). Each module is sourced individually as needed.

**Variable scoping:**
- Global config variables (INSTALL_DIR, DOMAIN, etc.) accessible across all modules
- Module-level variables prefixed with underscore: `_SECRET_KEY` in `lib/config.sh`
- Local function variables declared with `local` keyword
- Variables persist across function calls in module (side effects documented in function header)

**Module dependencies pattern:**
- `install.sh` sources dependencies in order (common.sh first)
- Each lib module declares its dependencies in header comment
- No circular dependencies (acyclic dependency graph)
- Example dependency chain: `common.sh` (no deps) → `detect.sh` (uses common.sh) → `wizard.sh` (uses common.sh + detect.sh)

## Example: Full Function with All Conventions

From `lib/docker.sh`:
```bash
# Private helper: install Docker for Debian-based systems
# Validated with shellcheck, uses strict mode, clear error messages
_install_docker_debian() {
    export DEBIAN_FRONTEND=noninteractive

    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    (umask 022; curl -fsSL "https://download.docker.com/linux/${DETECTED_OS:-ubuntu}/gpg" | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg)

    # Add Docker repository
    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DETECTED_OS:-ubuntu} ${codename} stable" | \
        tee /etc/apt/sources.list.d/docker.list >/dev/null

    # Install Docker CE + Compose
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start
    systemctl enable --now docker

    _add_user_to_docker_group
}
```

**Key conventions demonstrated:**
- Private function (underscore prefix)
- Safe parameter access in subshells (`${DETECTED_OS:-ubuntu}`)
- Error suppression with `|| true` when expected
- Local variables (`arch`, `codename`)
- Comments above sections explaining intent
- Single responsibility (install Debian Docker only)
- Returns implicitly (0 if all commands succeed due to `set -e`)

---

*Convention analysis: 2026-03-20*
