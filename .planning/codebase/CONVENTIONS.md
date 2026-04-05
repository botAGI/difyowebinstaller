# Coding Conventions

**Analysis Date:** 2026-04-04

## Naming Patterns

**Files:**
- Bash scripts: lowercase with hyphens for compound names (e.g., `check-upstream.sh`, `dr-drill.sh`)
- Library modules: single lowercase name (e.g., `common.sh`, `config.sh`, `docker.sh`)
- Configuration files: match their purpose (e.g., `docker-compose.yml`, `.env`, `nginx.conf`)
- Internal/private functions: prefix with underscore (e.g., `_atomic_sed`, `_install_docker_debian`, `_parse_image_ref`)

**Functions:**
- Public functions: snake_case, no prefix (e.g., `install_docker`, `wait_healthy`, `generate_config`)
- Private/internal functions: underscore prefix, snake_case (e.g., `_install_docker_debian`, `_add_user_to_docker_group`)
- Complex operations split into smaller private functions with clear responsibility
- Function names describe what they do: `setup_`, `install_`, `check_`, `generate_`, `validate_`, `configure_`

**Variables:**
- Global constants: UPPER_SNAKE_CASE (e.g., `INSTALL_DIR`, `TIMEOUT_START`, `DETECTED_OS`)
- Global variables set by modules: UPPER_SNAKE_CASE (e.g., `COMPOSE_PROFILE_STRING`, `LOG_FILE`)
- Local variables in functions: snake_case (e.g., `local pkg_mgr="${1:-yum}"`)
- Module-level privates (set by one function, used by another): underscore prefix, UPPER_SNAKE_CASE (e.g., `_SECRET_KEY`, `_DB_PASSWORD`, `_ADMIN_PASSWORD_PLAIN`)
- Loop variables: single letter or short (e.g., `local d; d="$(pwd)"`)

**Environment Overrides:**
- Pattern: `VAR_NAME="${VAR_NAME:-default_value}"`
- Allows tests/scripts to override without recompiling
- Example: `NON_INTERACTIVE="${NON_INTERACTIVE:-false}"`

## Code Style

**Formatting:**
- Strict Bash 5+ with `set -euo pipefail` on every script/module
- 4-space indentation (consistent throughout)
- No inline conditions without explicit blocks: prefer `if ... then` over ternary
- String literals: double-quoted for variable expansion, single-quoted for literals
- Multiline strings: use `<<<` heredoc with descriptive delimiters

**Linting:**
- CI enforces `bash -n` syntax check on all scripts in `lib/*.sh`, `scripts/*.sh`, and `install.sh`
- GitHub Actions workflow: `.github/workflows/test.yml` validates syntax on push
- Trivy security scanning enabled (severity: CRITICAL,HIGH)
- No explicit shellcheck configuration, but codebase follows shellcheck best practices
  - `set -euo pipefail` with trap for errors
  - Explicit variable quoting
  - Function names differ from command names
  - Proper subshell handling

**Strictness:**
- `-e`: Exit on first non-zero return (fail fast)
- `-u`: Error on undefined variable (prevents typos, requires defaults)
- `-o pipefail`: Pipeline fails if any stage fails (not just last)
- `trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR` in main scripts

## Import Organization

**Source Order (install.sh):**
1. Shebang and header comment
2. `set -euo pipefail` with trap
3. Global variable declarations (VERSION, INSTALLER_DIR, INSTALL_DIR)
4. Verify file location (early guard)
5. Source library modules in dependency order:
   - `common.sh` first (provides log_*, validate_*, colors)
   - `detect.sh` (uses common.sh; provides DETECTED_*)
   - `wizard.sh` (uses common.sh, detect.sh)
   - `docker.sh`, `config.sh`, `compose.sh`, etc. (uses common.sh)

**Module Header Format:**
```bash
#!/usr/bin/env bash
# [module name] — [short description]
# Dependencies: [required modules/functions]
# Functions: [exported functions]
# Expects: [required global variables]
set -euo pipefail
```

Example from `compose.sh`:
```bash
#!/usr/bin/env bash
# compose.sh — Docker compose up/down, DB sync, plugin DB, retry loop, post-launch.
# Dependencies: common.sh (log_*, ensure_bind_mount_files, preflight_bind_mount_check)
# Functions: compose_up(), compose_down(), sync_db_password(), create_plugin_db(),
#            post_launch_status(), build_compose_profiles()
# Expects: INSTALL_DIR, DEPLOY_PROFILE, wizard exports
set -euo pipefail
```

**No Path Aliases:**
- Uses absolute paths or relative paths resolved with `cd` and `pwd`
- INSTALLER_DIR pattern: `INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`

## Error Handling

**Return Codes:**
- 0 = success
- 1 = general failure (validation error, missing file, etc.)
- 2 = registry/HTTP error (skippable, not critical)
- Specific codes for retries (e.g., timeout loops)

**Validator Pattern:**
- Each validator returns 0 on success, 1 on failure
- Prints error to stderr via `log_error`
- Usage: `validate_model_name "model_name" || return 1`
- Validators in `lib/common.sh`: `validate_domain`, `validate_email`, `validate_port`, `validate_cron`, `validate_path`, `validate_hostname`, `validate_model_name`, `validate_url`

**Atomic Operations:**
- `_atomic_sed`: write to temp file, check success, then mv (prevents TOCTOU)
- `safe_write_file`: remove directory artifacts, ensure parent dirs exist (Docker bind mount safety)
- `ensure_bind_mount_files`: verify all bind-mount sources are files not dirs before `docker compose up`

**Cleanup on Exit:**
- `_cleanup_on_failure` in install.sh saves phase number to `${INSTALL_DIR}/.install_phase` for resume
- Lock mechanism: `_acquire_lock` uses `flock` (Linux) or `mkdir` (macOS) for exclusive execution

**Error Context:**
- Include file paths, line numbers, and variable values in errors
- Example: `log_error "Bind mount file missing: ${f}"`
- Trap errors with context: `trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR`

## Logging

**Framework:** Custom color-coded functions (no external logger)

**Functions:**
- `log_info()`: cyan arrow (`→`)
- `log_success()`: green checkmark (`✓`)
- `log_warn()`: yellow warning (`⚠`)
- `log_error()`: red X (`✗`)

**All Logs to stderr:**
- `>&2` redirect ensures logs don't pollute stdout (which may be piped)
- Timestamps appended when `LOG_FILE` is set (by install.sh)

**Timestamp Format:**
```bash
_log_ts() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s ' "$(date '+%Y-%m-%d %H:%M:%S')"
    fi
}
```

**Usage Example:**
```bash
log_info "Installing Docker..."
log_success "Docker installed successfully"
log_warn "Cannot create ${d} (may need root)"
log_error "Docker installation failed"
```

**Fallback for Scripts Sourced Without common.sh:**
- `health.sh` provides inline fallback functions (lines 11-14)
- Checks: `command -v log_info >/dev/null 2>&1 || log_info() { ... }`
- Allows `health.sh` to work standalone via `agmind.sh`

## Comments

**When to Comment:**
- Section headers: `# ============================================================================`
- Function purpose and parameters: right after function name
- Complex logic: explain the "why" not the "what"
- TODOs and known issues: prefix with `# TODO:`, `# BUG:`, `# FIXME:` (format used: `BUG-V3-039`)
- Dependencies and assumptions: document at module level

**JSDoc/TSDoc-like Headers:**
- Not used (Bash doesn't have a standard)
- Instead: comment block at module level with Dependencies, Functions, Expects
- Usage examples in comments for complex helpers

**Example:**
```bash
# Parse image reference into registry, repo, tag components.
# Examples:
#   nginx:1.25           -> docker.io, library/nginx, 1.25
#   ghcr.io/org/img:v1   -> ghcr.io, org/img, v1
#   quay.io/org/img:v1   -> quay.io, org/img, v1
_parse_image_ref() {
    local image="$1"
    local -n _registry=$2 _repo=$3 _tag=$4
    ...
}
```

## Function Design

**Size:** 
- Most functions 30-80 lines; largest are `wizard.sh` (1185 LOC total across many functions)
- Private helpers extracted for complex operations
- Example: `install_docker()` delegates to `_install_docker_debian()`, `_install_docker_rhel()`, etc.

**Parameters:**
- Positional arguments with defaults: `local domain="${1:-}" email="${2:-}"`
- Use `local -n nameref` for output parameters (pass arrays by reference)
- Validation at function entry: early return on invalid args

**Return Values:**
- Explicit return codes (0 success, 1 failure)
- Complex output: write to globals (e.g., `DETECTED_GPU="nvidia"`) or output via stdout capture
- Avoid mixing stdout data with log messages (logs to stderr)

**Defensive Practices:**
- Always quote variables: `"${var}"` not `$var`
- Use `[[ ]]` not `[ ]` (Bash-specific, safer)
- Null-safe checks: `[[ -z "${var:-}" ]]` for optional vars
- Array assignment with `local -a arr=()` before populating
- Temp file cleanup: `local tmp="${file}.tmp.$$"; ... mv "$tmp" "$file"`

## Module Design

**Exports:**
- Functions: listed at top-level (no explicit export needed in Bash)
- Globals: document as UPPER_SNAKE_CASE at module level
- Module-level privates: use underscore prefix to signal "internal use only"

**Barrel Files / Aggregation:**
- `install.sh` sources all lib modules (lines 20-33)
- `agmind.sh` sources `health.sh` and `detect.sh` (lines 18-24)
- No "main entry point" per module; each is designed to be sourced

**Module Interdependencies:**
- `common.sh`: no deps (utilities only)
- `detect.sh`: depends on `common.sh` (uses log_*, colors)
- `wizard.sh`: depends on `common.sh`, `detect.sh`
- `docker.sh`, `config.sh`, `compose.sh`, etc.: depend on `common.sh`
- Circular dependencies: none detected

**Reentrancy:**
- Functions are idempotent where possible (e.g., `install_docker()` checks if already installed first)
- State file: `.install_phase` tracks progress for resumable installs

---

*Convention analysis: 2026-04-04*
