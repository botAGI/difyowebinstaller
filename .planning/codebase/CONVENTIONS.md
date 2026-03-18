# Coding Conventions

**Analysis Date:** 2026-03-18

## Naming Patterns

**Files:**
- Snake_case for shell scripts: `config.sh`, `docker.sh`, `backup.sh`, `health.sh`
- Kebab-case for multi-word script names: `build-offline-bundle.sh`, `generate-manifest.sh`, `test-upgrade-rollback.sh`
- Modules in `lib/` directory are named after their function domain: `lib/detect.sh`, `lib/security.sh`, `lib/models.sh`

**Functions:**
- Snake_case throughout: `install_docker()`, `detect_os()`, `safe_write_file()`, `validate_no_default_secrets()`
- Prefix with action verb: `install_`, `detect_`, `setup_`, `configure_`, `validate_`, `check_`, `escape_`, `generate_`
- Domain functions grouped by module without redundant prefixes: `install_docker()` in `docker.sh` (not `docker_install_docker()`)
- Internal/helper functions use same naming convention as public functions

**Variables:**
- Global constants: UPPERCASE with underscores: `INSTALL_DIR`, `TEMPLATE_DIR`, `COMPOSE_FILE`, `RED`, `GREEN`, `YELLOW`, `CYAN`, `NC`
- Local variables: lowercase with underscores: `local env_file`, `local compose_dir`, `local status`, `local elapsed`
- Environment variable references: UPPERCASE: `${INSTALL_DIR}`, `${EUID}`, `${BASH_SOURCE[0]}`
- Temporary variables in loops: `svc`, `f`, `d` (single letter acceptable for short loops)

**Types:**
- Bash has no explicit type system; variables are strings by default
- Arrays declared with `declare -a` or implicit: `local array=(item1 item2)`
- Boolean-like values: strings `"true"` or `"false"`, tested with `[[ "$var" == "true" ]]`
- Return codes: integers where 0 = success, non-zero = failure

## Code Style

**Formatting:**
- No external formatter used (BASH not formatted by Prettier or similar)
- 4-space indentation for nested blocks (if/for/while/case)
- Function bodies indented one level; nested control structures add levels
- Lines wrapped at natural boundaries; no hard line limit enforced but keep readable

**Linting:**
- Uses `bash -n` for syntax validation (run in tests: `.github/workflows/test.yml`)
- All shell scripts begin with `#!/usr/bin/env bash` shebang
- `set -euo pipefail` on line 2 of all library and main scripts:
  - `-e`: exit on error
  - `-u`: error on undefined variables
  - `-o pipefail`: pipe failure propagates
- No linter config file (`.eslintrc`, `.shellcheckrc`) found; `bash -n` is primary check

**Error Handling:**
- `set -euo pipefail` at top of all scripts
- ERR trap pattern in main scripts:
  ```bash
  trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR
  ```
- Cleanup trap on EXIT:
  ```bash
  trap cleanup_on_failure EXIT
  ```
- Functions return 0 on success, non-zero on failure: `return 1` for error, `return 0` for success
- Error messages directed to stderr: `echo "message" >&2`

## Import Organization

**Source Pattern:**
- Main script sources all library modules at top after constants:
  ```bash
  source "${INSTALLER_DIR}/lib/detect.sh"
  source "${INSTALLER_DIR}/lib/docker.sh"
  source "${INSTALLER_DIR}/lib/config.sh"
  ```
- Each library file is self-contained with `set -euo pipefail` and no inter-library sourcing
- Uses absolute paths with variable substitution: `source "${INSTALLER_DIR}/lib/..."` not relative paths

**Module Structure:**
- Each `.sh` file in `lib/` is a separate module with related functions
- `lib/detect.sh`: System detection functions (OS, GPU, RAM, disk, ports, Docker, network)
- `lib/docker.sh`: Docker installation and configuration
- `lib/config.sh`: Config file generation and validation (largest module, ~900 lines)
- `lib/models.sh`: Ollama model operations
- `lib/backup.sh`: Backup scheduling
- `lib/health.sh`: Container health checks
- `lib/security.sh`: Firewall, fail2ban, secret encryption
- `lib/authelia.sh`: 2FA setup
- `lib/tunnel.sh`: Reverse SSH tunnel for LAN profile

## Error Handling

**Patterns:**

**Exit on Error:**
```bash
# Immediate abort if command fails
[[ "$INSTALL_DIR" == /opt/agmind* ]] || { echo "Invalid INSTALL_DIR"; exit 1; }
```

**Conditional Error:**
```bash
if ! docker --version &>/dev/null; then
    echo -e "${RED}Docker not installed${NC}"
    return 1
fi
```

**Function Return Validation:**
```bash
if ! bash -n "$f" 2>/dev/null; then
    echo "FAIL: $f"
    failed=$((failed + 1))
fi
```

**Exclusive Lock (Prevent Parallel Execution):**
```bash
LOCK_FILE="/var/lock/agmind-operation.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "${RED}Another operation is running${NC}"
    exit 1
fi
```

**Safe Parameter Validation:**
```bash
# Validate numeric parameter
[[ "${BACKUP_RETENTION_COUNT:-10}" =~ ^[0-9]+$ ]] || BACKUP_RETENTION_COUNT=10
[[ "$BACKUP_RETENTION_COUNT" -gt 0 ]] || BACKUP_RETENTION_COUNT=10

# Validate path is within safe directory
if [[ -n "${INSTALL_DIR:-}" && "$filepath" != "${INSTALL_DIR}"/* ]]; then
    echo -e "${RED}ERROR: path outside INSTALL_DIR${NC}" >&2
    return 1
fi
```

## Logging

**Framework:** Bash `echo` with color codes (no external logging framework)

**Color Variables:**
- Defined early in scripts, inherited by sourced modules:
  ```bash
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'  # No Color
  ```

**Patterns:**
- Success messages: `echo -e "${GREEN}Message${NC}"`
- Warning messages: `echo -e "${YELLOW}Message${NC}"`
- Error messages: `echo -e "${RED}Message${NC}" >&2`
- Info messages: `echo -e "${CYAN}Message${NC}"`
- Formatted progress: `echo -e "${CYAN}→ function_name: description...${NC}"` then `echo -e "${GREEN}✓ function_name: done${NC}"`

**When to Log:**
- Start of major operations: `echo -e "${YELLOW}Installing Docker...${NC}"`
- Status checks before actions: `echo -e "${CYAN}Checking for Docker...${NC}"`
- Completion: `echo -e "${GREEN}Docker installed${NC}"`
- Errors and warnings: Always with context
- Debug details: None by default (can be added with `bash -x`)

## Comments

**When to Comment:**
- Function headers (required): Purpose, parameters, usage examples
- Complex logic blocks: Explain why, not what
- Security-critical sections: Why this approach was chosen
- TODOs: None observed in codebase; prefer pull request discussions
- Inline comments for non-obvious operations: Sparingly

**JSDoc/TSDoc:**
- Not applicable; bash has no equivalent formal standard
- Function documentation uses inline comment headers:
  ```bash
  # Prepare a path for writing: remove directory artifact, ensure parent exists.
  # Usage: safe_write_file "/path/to/file.yml"
  #   then: cat > "/path/to/file.yml" <<EOF ...
  #   or:   cp source "/path/to/file.yml"
  safe_write_file() {
      local filepath="$1"
      ...
  }
  ```

**Section Headers:**
- Major sections marked with 70-character comment blocks:
  ```bash
  # ============================================================================
  # SAFE FILE OPERATIONS
  # ============================================================================
  ```

**Language in Comments:**
- Mix of English and Russian (installer is bilingual)
- English for technical explanation, Russian for user-facing messages
- Error messages in output often dual-language

## Function Design

**Size:** Functions range from 5 to 100+ lines; no hard limit enforced

**Small Functions (5-20 lines):**
- `escape_sed()`: Single-purpose utility
- `generate_random()`: Utility returning a value
- `get_service_list()`: Reads env and returns array

**Medium Functions (20-60 lines):**
- `install_docker_debian()`: Procedural steps with validation
- `validate_no_default_secrets()`: Loop with conditional logic
- `safe_write_file()`: Precondition checking + action

**Large Functions (60+ lines):**
- `configure_ufw()`: Many firewall rules and conditionals
- `generate_config()`: Complex template substitution and file generation
- `check_all()`: Orchestrates multiple health checks

**Parameters:**
- Simple pattern: `function_name() { local param1="$1" local param2="$2" ... }`
- Maximum 3-4 parameters typical; more indicates function should be split
- No parameter validation idiom; functions assume correct input

**Return Values:**
- Exit code (0 or non-zero) primary return mechanism
- Optional: echo output captured by caller: `result=$(generate_random 32)`
- Multiple returns not used; echo for data, exit code for status

## Module Design

**Exports:**
- All functions at module level are "public" (no underscore prefix for private)
- Helper functions mixed with public functions (no convention to distinguish)

**Barrel Files:**
- Not applicable; bash modules are single-file

**Module Initialization:**
- Each module sets its own globals and sources dependencies
- `config.sh` defines `INSTALL_DIR` default and dependencies on global state
- Order of sourcing in main script matters: detect.sh before docker.sh (detect sets DETECTED_* globals)

**Cross-Module Dependencies:**
- `lib/health.sh` depends on `lib/docker.sh` (uses docker compose commands)
- `scripts/backup.sh` depends on `lib/config.sh` logic (replicates safe config parsing)
- Minimal explicit imports; mostly implicit via global variable state

---

*Convention analysis: 2026-03-18*
