# Coding Conventions

**Analysis Date:** 2026-03-18

## Naming Patterns

**Files:**
- Shell scripts: lowercase with hyphens (`backup.sh`, `docker.sh`, `multi-instance.sh`)
- Library modules: descriptive names in `lib/` directory (`detect.sh`, `config.sh`, `security.sh`)
- Template files: explicit `.template` or in `templates/` directory
- Configuration files: `.conf`, `.env`, `.yml`, `.yaml` extensions

**Functions:**
- Snake_case with leading descriptor: `setup_backups()`, `detect_os()`, `install_docker_debian()`
- Utility functions lowercase with underscores: `safe_write_file()`, `escape_sed()`, `generate_random()`
- Local helper functions prefixed with context: `install_docker_debian()`, `pull_model()`, `check_container()`

**Variables:**
- Global state: UPPERCASE with underscores (`INSTALL_DIR`, `DEPLOY_PROFILE`, `DETECTED_GPU`)
- Local variables: lowercase with underscores (`local target_dir`, `local backup_schedule`)
- Constants defined at top: `VERSION="2.0.0"`, `LOCK_FILE="/var/lock/agmind-install.lock"`
- Booleans: explicit true/false values, never implicit (`DRY_RUN=false`, `FORCE=true`)

**Environment Variables:**
- Configuration: UPPERCASE_WITH_UNDERSCORES
- Version pinning: `DIFY_VERSION`, `POSTGRES_VERSION`, `OLLAMA_VERSION`
- Feature flags: `ENABLE_UFW`, `ENABLE_FAIL2BAN`, `ENABLE_SOPS`, `SKIP_GPU_DETECT`
- Paths: Absolute paths preferred, exported explicitly (`export DETECTED_GPU`)

## Code Style

**Formatting:**
- Shebang: `#!/usr/bin/env bash` (portable)
- Strict mode: `set -euo pipefail` on all scripts
- Line length: No hard limit, but functions organized logically with comment blocks

**Linting:**
- Target: `shellcheck` compliance
- Critical enforced via `set -euo pipefail`:
  - Fail on undefined variable references
  - Fail on unset variable expansion in arithmetic
  - Fail on pipe failures (not just last command)
- No disabling of safe modes without explicit justification

**Error Handling:**
- Error trap pattern: `trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR`
- Cleanup trap: `trap cleanup_on_exit EXIT` or `trap cleanup_backup EXIT`
- Root requirement: Explicit check early:
  ```bash
  if [[ $EUID -ne 0 ]]; then
      echo "This script must be run as root"
      exit 1
  fi
  ```

## Organization and Structure

**File Header Pattern:**
```bash
#!/usr/bin/env bash
# scriptname.sh — One-line description of purpose
set -euo pipefail
[additional trap setup if needed]

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Constants
INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"
```

**Section Markers:**
- Major sections: `# ============================================================================`
- Subsections: `# --- Description ---`
- Safety notes: Inline comments before dangerous operations

**Function Organization:**
- Utility functions first (often reusable)
- Main logic functions after
- Guard clause at bottom: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main_function; fi`

**Library Pattern (in `lib/*.sh`):**
- Define all functions and helpers
- No auto-execution — only define for sourcing
- Expect `INSTALL_DIR` and colors to be inherited from caller

## Import Organization

**Module Loading (install.sh pattern):**
```bash
source "${INSTALLER_DIR}/lib/detect.sh"
source "${INSTALLER_DIR}/lib/docker.sh"
source "${INSTALLER_DIR}/lib/config.sh"
source "${INSTALLER_DIR}/lib/models.sh"
source "${INSTALLER_DIR}/lib/backup.sh"
source "${INSTALLER_DIR}/lib/health.sh"
source "${INSTALLER_DIR}/lib/security.sh"
source "${INSTALLER_DIR}/lib/authelia.sh"
```

**Order:**
1. Path validation and constants
2. Colors and formatting
3. Core utilities (logging, validation)
4. Infrastructure (Docker, OS detection)
5. Feature-specific modules

**Path Aliases:**
- Not used (no package.json or TypeScript)
- Docker Compose file references: Always use absolute `${INSTALL_DIR}/docker/docker-compose.yml`
- Template directory: `${INSTALLER_DIR}/templates` or `${INSTALL_DIR}/templates`

## Comments

**When to Comment:**
- Explain non-obvious logic (regex patterns, complex conditionals)
- Document parameter requirements for functions
- Explain why a workaround or special case exists
- Reference GitHub issues or security notes
- Above dangerous operations (`rm -rf`, Docker commands affecting production)

**Style:**
- Lowercase for descriptions: `# backup retention policy`
- Reference codes in comments: `# B-04: Restrict file permissions`, `# B-13: Root check`
- Before each major operation: `# === Backup PostgreSQL ===`
- Inline for quick clarifications: `umask 077  # Restrict file permissions`

**JSDoc/TSDoc:**
- Not applicable (Bash scripts, no TypeScript)
- Function documentation done via inline comments before `function_name()` definition

**Example:**
```bash
# safe_write_file — Prepare path for writing
# Usage: safe_write_file "/path/to/file.yml"
# then:  cat > "/path/to/file.yml" << EOF ... EOF
safe_write_file() {
    local filepath="$1"
    # Safety: only operate within INSTALL_DIR
    if [[ -n "${INSTALL_DIR:-}" && "$filepath" != "${INSTALL_DIR}"/* ]]; then
        echo -e "${RED}ERROR: path outside INSTALL_DIR: ${filepath}${NC}" >&2
        return 1
    fi
    [[ -d "$filepath" ]] && rm -rf "${filepath:?}"
    mkdir -p "$(dirname "$filepath")"
}
```

## Error Handling

**Exit Code Pattern:**
- Success: `return 0` or implicit success
- Failure: `return 1` for all errors
- Fatal: `exit 1` at script level

**Validation Pattern:**
```bash
# Numeric validation
[[ "${var}" =~ ^[0-9]+$ ]] || { echo "ERROR: not numeric"; exit 1; }

# Path validation (common pattern for INSTALL_DIR)
[[ "$INSTALL_DIR" == /opt/agmind* ]] || { echo "Invalid path"; exit 1; }

# Safe arithmetic
[[ "$value" -gt 0 ]] || BACKUP_RETENTION_COUNT=10
```

**Config Parsing (secure pattern from backup.sh):**
```bash
# B-08: Safe config parsing (no source)
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$key" in
        ALLOWED_VAR1|ALLOWED_VAR2)
            declare "$key=$value" ;;
    esac
done < <(grep -E '^[A-Za-z_]' "${config_file}")
```

## Logging

**Framework:** Native `echo` with color codes

**Patterns:**
- Info: `echo -e "${CYAN}→ message${NC}"` or `echo -e "${CYAN}Description...${NC}"`
- Success: `echo -e "${GREEN}✓ message${NC}"` or `echo -e "${GREEN}Done${NC}"`
- Warning: `echo -e "${YELLOW}⚠ message${NC}"` or `echo -e "${YELLOW}Caution${NC}"`
- Error: `echo -e "${RED}✗ message${NC}"` or `echo -e "${RED}FAILED${NC}"`

**Log Functions (update.sh pattern):**
```bash
log_info() { echo -e "${CYAN}→ $*${NC}"; }
log_success() { echo -e "${GREEN}✓ $*${NC}"; }
log_warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
log_error() { echo -e "${RED}✗ $*${NC}"; }
```

**File Logging:**
- Append to logs: `>> /var/log/agmind-backup.log 2>&1`
- Temporary log files: `PGDUMP_LOG="${TARGET_DIR}/pgdump.log"`
- Log directory permissions: `chmod 700 "$(dirname "$LOG_FILE")"`

**When to Log:**
- Phase transitions: `echo "=== Phase 1: Prerequisites ==="`
- Major operations: before backup, before upgrade, Docker operations
- Waiting states: `echo -ne "\r  Waiting... ${elapsed}/${timeout}s"`
- Status checks: Success/failure of critical operations

## Module Design

**Exports:**
- Functions are exported implicitly after sourcing
- Global variables set: `export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM`
- No explicit export list — all defined functions are callable

**Barrel Files:**
- Not applicable (no module system)
- Instead: single utility module per concern (e.g., `lib/detect.sh` exports ~6 functions)

**Dependency Order:**
1. `install.sh` loads all `lib/*.sh`
2. Library modules use variables inherited from caller
3. Helper functions defined before use

## Function Design

**Size:** Functions should fit on single screen (~40 lines max)
- Larger functions refactored into helper functions
- Example: `generate_config()` broken into `generate_nginx_config()`, `generate_redis_config()`

**Parameters:**
- Required parameters: positional (`function_name "$param1" "$param2"`)
- Optional: use `${2:-default}` pattern
- No named parameters — use local parsing for complex functions

**Return Values:**
- Status only (0/1): used by callers in conditionals
- Output via echo: captured with command substitution `$(detect_os)`
- Side effects: File creation, variable modification

**Example:**
```bash
detect_gpu() {
    # Accepts environment overrides
    if [[ -n "${FORCE_GPU_TYPE:-}" ]]; then
        # ... handle override
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
        return 0
    fi
    # ... detection logic ...
    # Export detected values
    export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
}
```

## Safety Practices

**File Operations:**
- Use `${var:?}` in destructive commands: `rm -rf "${filepath:?}"`
- Validate paths before operations: Check within `INSTALL_DIR` boundaries
- Create parent directories: `mkdir -p "$(dirname "$filepath")"`

**Docker Operations:**
- Always use `docker compose` (not deprecated `docker-compose`)
- Reference compose file explicitly: `docker compose -f "$COMPOSE_FILE" ...`
- Use `-T` flag for db operations: `docker compose exec -T db ...` (disable TTY)

**Command Substitution:**
- Always quote: `local arch="$(uname -m)"`
- Use `<(...)` for process substitution in loops (not subshelling)
- Suppress stderr for optional checks: `command -v program &>/dev/null`

**Lock Mechanisms:**
```bash
LOCK_FILE="/var/lock/agmind-install.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another process is running"
    exit 1
fi
```

---

*Convention analysis: 2026-03-18*
