#!/usr/bin/env bash
# common.sh — Shared utilities, logging, validation, safe file operations.
# Dependencies: none (must be sourced first by all other lib/*.sh modules)
# Exports: colors, log_*, validate_*, generate_random, _atomic_sed,
#          escape_sed, safe_write_file, init_detected_defaults
set -euo pipefail

# ============================================================================
# COLORS
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# LOGGING
# ============================================================================
# All log functions write to stderr so they don't pollute stdout pipelines.
# Timestamps are appended when LOG_FILE is set (install.sh sets this).

_log_ts() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s ' "$(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

log_info()    { echo -e "$(_log_ts)${CYAN}→ $*${NC}" >&2; }
log_warn()    { echo -e "$(_log_ts)${YELLOW}⚠ $*${NC}" >&2; }
log_error()   { echo -e "$(_log_ts)${RED}✗ $*${NC}" >&2; }
log_success() { echo -e "$(_log_ts)${GREEN}✓ $*${NC}" >&2; }

# ============================================================================
# VALIDATION
# ============================================================================
# Each validator returns 0 on success, 1 on failure.
# On failure, prints an error message to stderr.

validate_model_name() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "Model name cannot be empty"
        return 1
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9._:/-]+$ ]]; then
        log_error "Invalid model name '${name}'. Allowed: letters, digits, . _ : / -"
        return 1
    fi
}

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

validate_email() {
    local email="${1:-}"
    if [[ -z "$email" ]]; then
        log_error "Email cannot be empty"
        return 1
    fi
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid email: ${email}"
        return 1
    fi
}

validate_url() {
    local url="${1:-}"
    if [[ -z "$url" ]]; then
        log_error "URL cannot be empty"
        return 1
    fi
    if [[ ! "$url" =~ ^https?://[a-zA-Z0-9._:/-]+$ ]]; then
        log_error "Invalid URL: ${url}"
        return 1
    fi
}

validate_port() {
    local port="${1:-}"
    if [[ -z "$port" ]]; then
        log_error "Port cannot be empty"
        return 1
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log_error "Invalid port: ${port} (must be 1-65535)"
        return 1
    fi
}

validate_cron() {
    local expr="${1:-}"
    if [[ -z "$expr" ]]; then
        log_error "Cron expression cannot be empty"
        return 1
    fi
    # 5 space-separated fields: min hour dom month dow
    if [[ ! "$expr" =~ ^[0-9*,/-]+\ [0-9*,/-]+\ [0-9*,/-]+\ [0-9*,/-]+\ [0-9*,/-]+$ ]]; then
        log_error "Invalid cron expression: ${expr}"
        return 1
    fi
}

validate_path() {
    local input="${1:-}"
    if [[ -z "$input" ]]; then
        log_error "Path cannot be empty"
        return 1
    fi
    local resolved
    resolved="$(realpath "$input" 2>/dev/null)" || {
        log_error "Cannot resolve path: ${input}"
        return 1
    }
    # Whitelist safe directories
    local allowed=false
    for prefix in /tmp /home /root /etc/ssl /opt /var/backups; do
        if [[ "$resolved" == "${prefix}"/* || "$resolved" == "$prefix" ]]; then
            allowed=true
            break
        fi
    done
    if [[ "$allowed" != "true" ]]; then
        log_error "Path must be under /tmp, /home, /root, /etc/ssl, /opt, or /var/backups: ${resolved}"
        return 1
    fi
    printf '%s' "$resolved"
}

validate_hostname() {
    local host="${1:-}"
    if [[ -z "$host" ]]; then
        log_error "Hostname cannot be empty"
        return 1
    fi
    if [[ ! "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        log_error "Invalid hostname: ${host}"
        return 1
    fi
}

# ============================================================================
# RANDOM / SECRETS
# ============================================================================

# Generate a random alphanumeric string.
# Usage: generate_random [length]   (default: 32)
generate_random() {
    local length="${1:-32}"
    local result
    result="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c "$length")"
    if [[ -z "$result" ]]; then
        log_error "FATAL: /dev/urandom produced empty output"
        return 1
    fi
    printf '%s' "$result"
}

# ============================================================================
# ATOMIC FILE OPERATIONS
# ============================================================================

# Atomic sed: write to temp file, then mv.
# Prevents TOCTOU races and partial writes.
# Usage: _atomic_sed "file" -e 's|old|new|g'
#    or: _atomic_sed "file" '/pattern/d'
_atomic_sed() {
    local file="$1"; shift
    if [[ ! -f "$file" ]]; then
        log_error "_atomic_sed: file not found: ${file}"
        return 1
    fi
    local tmp="${file}.tmp.$$"
    if ! sed "$@" "$file" > "$tmp"; then
        rm -f "$tmp"
        log_error "_atomic_sed: sed failed on ${file}"
        return 1
    fi
    mv "$tmp" "$file"
}

# Escape special characters for sed replacement strings (& | \ /)
escape_sed() {
    printf '%s' "${1:-}" | sed 's/[&/|\]/\\&/g'
}

# Prepare a path for writing: remove directory artifact, ensure parent exists.
# Docker creates directories when bind mount source files don't exist.
# On reinstall these stale directories block file creation.
# Usage: safe_write_file "/opt/agmind/docker/nginx/nginx.conf"
safe_write_file() {
    local filepath="${1:-}"
    if [[ -z "$filepath" ]]; then
        log_error "safe_write_file: filepath required"
        return 1
    fi
    # Safety: only operate within INSTALL_DIR
    local install_dir="${INSTALL_DIR:-/opt/agmind}"
    if [[ "$filepath" != "${install_dir}"/* ]]; then
        log_error "safe_write_file: path outside INSTALL_DIR: ${filepath}"
        return 1
    fi
    [[ -d "$filepath" ]] && rm -rf "${filepath:?}"
    mkdir -p "$(dirname "$filepath")"
}

# ============================================================================
# BIND MOUNT SAFETY
# ============================================================================

# Ensure all bind-mounted config files exist as FILES (not dirs, not missing).
# Call right before docker compose up as final safety net.
ensure_bind_mount_files() {
    local docker_dir="${INSTALL_DIR:-/opt/agmind}/docker"
    local files=(
        "monitoring/prometheus.yml"
        "monitoring/alert_rules.yml"
        "monitoring/alertmanager.yml"
        "monitoring/loki-config.yml"
        "monitoring/promtail-config.yml"
        "nginx/nginx.conf"
        "nginx/health.json"
        "volumes/redis/redis.conf"
        "volumes/ssrf_proxy/squid.conf"
        "volumes/sandbox/conf/config.yaml"
    )
    for f in "${files[@]}"; do
        local full="${docker_dir}/${f}"
        if [[ -d "$full" ]]; then
            rm -rf "${full:?}"
            mkdir -p "$(dirname "$full")"
            touch "$full"
            log_warn "Fixed directory artifact: ${f}"
        elif [[ ! -f "$full" ]]; then
            mkdir -p "$(dirname "$full")"
            touch "$full"
            log_warn "Created missing bind mount file: ${f}"
        fi
    done
}

# Pre-flight validation before docker compose up.
# Aborts with clear error if any bind mount source is wrong.
preflight_bind_mount_check() {
    local docker_dir="${INSTALL_DIR:-/opt/agmind}/docker"
    local errors=0

    log_info "Pre-flight: checking bind mount files..."

    # Find .yml/.yaml/.conf files that are actually directories
    local bad_dirs
    bad_dirs="$(find "$docker_dir" \( -name "*.yml" -o -name "*.yaml" -o -name "*.conf" \) -type d 2>/dev/null || true)"
    if [[ -n "$bad_dirs" ]]; then
        log_error "Config paths are directories (should be files):"
        while IFS= read -r d; do
            [[ -n "$d" ]] && echo -e "  ${RED}→ ${d}${NC}" >&2
        done <<< "$bad_dirs"
        errors=$((errors + 1))
    fi

    # Verify all bind-mount source files exist
    local all_bind_files=(
        "nginx/nginx.conf"
        "volumes/redis/redis.conf"
        "volumes/ssrf_proxy/squid.conf"
        "volumes/sandbox/conf/config.yaml"
        "litellm-config.yaml"
        "monitoring/prometheus.yml"
        "monitoring/alert_rules.yml"
        "monitoring/alertmanager.yml"
        "monitoring/loki-config.yml"
        "monitoring/promtail-config.yml"
    )
    for f in "${all_bind_files[@]}"; do
        local full="${docker_dir}/${f}"
        if [[ ! -f "$full" ]]; then
            log_error "Bind mount file missing: ${f}"
            errors=$((errors + 1))
        fi
    done

    if [[ $errors -gt 0 ]]; then
        echo "" >&2
        log_error "PRE-FLIGHT FAILED: ${errors} bind mount error(s)"
        log_error "docker compose up cancelled to prevent OCI errors"
        log_error "Remove ${INSTALL_DIR:-/opt/agmind} and re-run install"
        return 1
    fi

    log_success "Pre-flight: all bind mount files OK"
}

# ============================================================================
# SECRET VALIDATION
# ============================================================================

# Validate that .env contains no known default/weak passwords
validate_no_default_secrets() {
    local env_file="${1:-}"
    if [[ ! -f "$env_file" ]]; then
        log_error "validate_no_default_secrets: file not found: ${env_file}"
        return 1
    fi
    local known_defaults=(
        "difyai123456"
        "QaHbTe77"
        "changeme"
        "password"
        "admin123"
        "secret"
        "default"
        "test1234"
    )
    local found=0
    for default_pw in "${known_defaults[@]}"; do
        if grep -qE "^[^#].*=${default_pw}$" "$env_file" 2>/dev/null; then
            local offending
            offending="$(grep -nE "^[^#].*=${default_pw}$" "$env_file" | head -1 | cut -d: -f1)"
            log_error ".env line ${offending}: contains weak default password '${default_pw}'"
            found=$((found + 1))
        fi
    done
    # Check for unresolved placeholders __*__
    if grep -qE '^[^#].*__[A-Z_]+__' "$env_file" 2>/dev/null; then
        local placeholders
        placeholders="$(grep -oE '__[A-Z_]+__' "$env_file" | sort -u | tr '\n' ' ')"
        log_error ".env contains unresolved placeholders: ${placeholders}"
        found=$((found + 1))
    fi
    [[ $found -eq 0 ]]
}

# ============================================================================
# DETECTED DEFAULTS (BUG-001 fix)
# ============================================================================
# Initialize all DETECTED_* variables with safe defaults.
# Must be called before sourcing detect.sh so that `set -u` never fails
# on unset DETECTED_* variables.

init_detected_defaults() {
    # OS
    DETECTED_OS="${DETECTED_OS:-unknown}"
    DETECTED_OS_VERSION="${DETECTED_OS_VERSION:-}"
    DETECTED_OS_NAME="${DETECTED_OS_NAME:-unknown}"
    DETECTED_ARCH="${DETECTED_ARCH:-$(uname -m)}"

    # GPU
    DETECTED_GPU="${DETECTED_GPU:-none}"
    DETECTED_GPU_NAME="${DETECTED_GPU_NAME:-}"
    DETECTED_GPU_VRAM="${DETECTED_GPU_VRAM:-0}"

    # RAM
    DETECTED_RAM_TOTAL_MB="${DETECTED_RAM_TOTAL_MB:-0}"
    DETECTED_RAM_AVAILABLE_MB="${DETECTED_RAM_AVAILABLE_MB:-0}"
    DETECTED_RAM_TOTAL_GB="${DETECTED_RAM_TOTAL_GB:-0}"

    # Disk
    DETECTED_DISK_FREE_GB="${DETECTED_DISK_FREE_GB:-0}"

    # Docker
    DETECTED_DOCKER_INSTALLED="${DETECTED_DOCKER_INSTALLED:-false}"
    DETECTED_DOCKER_VERSION="${DETECTED_DOCKER_VERSION:-}"
    DETECTED_DOCKER_COMPOSE="${DETECTED_DOCKER_COMPOSE:-false}"

    # Network
    DETECTED_NETWORK="${DETECTED_NETWORK:-unknown}"

    # Model recommendation
    RECOMMENDED_MODEL="${RECOMMENDED_MODEL:-qwen2.5:7b}"
    RECOMMENDED_REASON="${RECOMMENDED_REASON:-default}"

    # Platform
    DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
    PORTS_IN_USE="${PORTS_IN_USE:-}"
}

# Auto-initialize on source
init_detected_defaults
