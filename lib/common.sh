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
# shellcheck disable=SC2034  # BOLD and NC are sourced globals used by other scripts
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
# AGMIND_TEST_SEED PRODUCTION GUARD
# ============================================================================
# Phase 13 TEST-04 mitigation against an environment leak: AGMIND_TEST_SEED
# enables deterministic secret generation for the golden test harness and must
# never be active in a real install. Test suites set AGMIND_ALLOW_TEST_SEED=true
# to opt in. Production sourcing of common.sh with TEST_SEED set but ALLOW unset
# aborts loudly so secrets cannot become predictable by accident.
if [[ -n "${AGMIND_TEST_SEED:-}" && "${AGMIND_ALLOW_TEST_SEED:-false}" != "true" ]]; then
    echo "FATAL: AGMIND_TEST_SEED is set in this environment." >&2
    echo "       This variable enables deterministic secret generation for golden tests" >&2
    echo "       and must NEVER be active in a real install." >&2
    echo "       If you intentionally want to run tests, set AGMIND_ALLOW_TEST_SEED=true." >&2
    echo "       If this leaked from your dev shell, run: unset AGMIND_TEST_SEED" >&2
    exit 1
fi

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
    if [[ ! "$length" =~ ^[1-9][0-9]*$ ]]; then
        log_error "generate_random: invalid length: ${length}"
        return 1
    fi

    # Prefer python3 — uses secrets module (CSPRNG, exact-length output).
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$length" <<'PY'
import secrets, string, sys
n = int(sys.argv[1])
print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n)), end='')
PY
        return $?
    fi

    # Bash-only fallback. dd reads fixed blocks; tr filters from regular file
    # (no pipe — SIGPIPE-safe under `set -o pipefail`). Retry up to 100 times
    # so `generate_random 1` doesn't false-abort on an unlucky block.
    local out="" block tmpf attempts=0
    local block_size=$(( length * 8 ))
    [[ $block_size -lt 64 ]] && block_size=64
    tmpf="$(mktemp)"
    trap 'rm -f "$tmpf"' RETURN
    while [[ ${#out} -lt $length ]]; do
        attempts=$((attempts + 1))
        if [[ $attempts -gt 100 ]]; then
            log_error "generate_random: failed to produce ${length} chars in 100 attempts"
            return 1
        fi
        dd if=/dev/urandom of="$tmpf" bs="$block_size" count=1 2>/dev/null
        block="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < "$tmpf")"
        out+="$block"
    done
    printf '%s' "${out:0:length}"
}

# Name-based deterministic RNG (TEST-04 / D-07).
# Under AGMIND_TEST_SEED: keyed by f"{seed}:{slug}:{length}" via python3 random.Random.
# Without seed: delegates to generate_random (CSPRNG via secrets.choice) — zero
# security regression vs production behavior.
# Usage: generate_random_named <slug> [length]   (slug MUST match ^[A-Za-z][A-Za-z0-9_]*$)
generate_random_named() {
    local slug="${1:-}"
    local length="${2:-32}"

    if [[ -z "$slug" || ! "$slug" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
        log_error "generate_random_named: invalid slug: '${slug}' (must match ^[A-Za-z][A-Za-z0-9_]*\$)"
        return 1
    fi
    if [[ ! "$length" =~ ^[1-9][0-9]*$ ]]; then
        log_error "generate_random_named: invalid length: '${length}'"
        return 1
    fi

    if [[ -n "${AGMIND_TEST_SEED:-}" ]]; then
        python3 - "$AGMIND_TEST_SEED" "$slug" "$length" <<'PY'
import random, string, sys
seed, slug, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
r = random.Random(f"{seed}:{slug}:{n}")
print(''.join(r.choice(string.ascii_letters + string.digits) for _ in range(n)), end='')
PY
        return $?
    fi

    # Unseeded path — production CSPRNG (zero regression vs prior callers).
    generate_random "$length"
}

# Deterministic clock helper (D-22). Under AGMIND_TEST_SEED → fixed value,
# else delegates to real `date -u`. Use everywhere template-rendering would
# embed a timestamp.
_now_utc() {
    if [[ -n "${AGMIND_TEST_SEED:-}" ]]; then
        printf '%s' '2026-01-01T00:00:00Z'
    else
        date -u +'%Y-%m-%dT%H:%M:%SZ'
    fi
}

# Deterministic hostname helper (D-22). Symmetric to _now_utc.
_host_name() {
    if [[ -n "${AGMIND_TEST_SEED:-}" ]]; then
        printf '%s' 'agmind-golden-host'
    else
        hostname
    fi
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
    if [[ -d "$filepath" ]]; then rm -rf "${filepath:?}"; fi
    mkdir -p "$(dirname "$filepath")"
}

# ============================================================================
# ENV FILE PARSING
# ============================================================================
# Two helpers replace ad-hoc one-liners that read a single env-file key via
# `grep` piped to `cut`, which silently truncate multiline values and cannot
# distinguish "missing key" from "key=empty". Choose by value type:
#
#   _env_get      — source-based; strips quotes, joins multiline, drops
#                   trailing `# comment` after whitespace. USE FOR:
#                   booleans, numeric ranges, slugs, single-token strings.
#                   DO NOT USE FOR SECRETS containing `$` — bash expands
#                   `$foo` → "" silently. Use _env_get_raw instead.
#
#   _env_get_raw  — awk; byte-exact within the matched line. Preserves
#                   quotes, $, inline #, trailing whitespace. USE FOR:
#                   passwords, tokens, keys — anything where shell
#                   interpretation would corrupt the value.
#                   Trailing LF from `awk print` is consumed by the
#                   standard `var="$(_env_get_raw ...)"` pattern.
#
# Both return 1 if file unreadable. _env_get returns 0 with empty stdout
# for missing key; _env_get_raw returns 1 for missing key (distinguishable
# from key=empty which is 0 + empty stdout).
#
# Phase 10 lands these DORMANT — zero callsite migration in v3.2.0.
# Phase 14 (ENV-03b canary + ENV-03c bulk) migrates the 123 legacy
# `grep|cut` callsites in batches: booleans → numerics → secrets.
# ============================================================================

# _env_get KEY ENV_FILE
# Read a value from a KEY=VALUE env file using bash source semantics.
# Handles quoted strings, multiline values, trailing comments correctly.
# Returns 1 if file unreadable. Otherwise 0 — empty stdout means
# "key not found OR key is empty" (use _env_get_raw to distinguish).
# Caller MUST use _env_get_raw for SECRETS containing `$` (bash expands
# `$bar` → "").  Runs source inside subshell with `set +u; set +e` so a
# malformed env file won't crash the caller.
_env_get() {
    local key="$1" file="$2"
    [[ -r "$file" ]] || return 1
    (
        set +u
        set +e
        # shellcheck disable=SC1090
        source "$file" >/dev/null 2>&1 || true
        printf '%s' "${!key:-}"
    )
}

# _env_get_raw KEY ENV_FILE
# Byte-exact read of a KEY=VALUE line — preserves quotes, $-signs, trailing
# whitespace, inline `#`. Use for SECRETS (passwords, tokens, keys) where
# shell interpretation would corrupt the value. First-match-wins.
# awk adds trailing newline via `print` — stripped by usual
# `var="$(_env_get_raw ...)"` command-substitution.
# Returns 1 if file unreadable OR key not found.
_env_get_raw() {
    local key="$1" file="$2"
    [[ -r "$file" ]] || return 1
    awk -v k="$key" '
        BEGIN { FS = "="; found = 0 }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            eq = index(line, "=")
            if (eq == 0) next
            name = substr(line, 1, eq - 1)
            if (name != k) next
            val = substr(line, eq + 1)
            print val
            found = 1
            exit
        }
        END { exit (found ? 0 : 1) }
    ' "$file"
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
        "monitoring/alloy-config.river"
        "nginx/nginx.conf"
        "nginx/health/health.json"
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
            if [[ -n "$d" ]]; then echo -e "  ${RED}→ ${d}${NC}" >&2; fi
        done <<< "$bad_dirs"
        errors=$((errors + 1))
    fi

    # Verify all bind-mount source files exist
    local all_bind_files=(
        "nginx/nginx.conf"
        "nginx/health/health.json"
        "volumes/redis/redis.conf"
        "volumes/ssrf_proxy/squid.conf"
        "volumes/sandbox/conf/config.yaml"
        "monitoring/prometheus.yml"
        "monitoring/alert_rules.yml"
        "monitoring/alertmanager.yml"
        "monitoring/loki-config.yml"
        "monitoring/alloy-config.river"
    )
    local enable_litellm
    enable_litellm="$(_env_get ENABLE_LITELLM "${docker_dir}/.env")"
    [[ -z "$enable_litellm" ]] && enable_litellm="true"
    if [[ "$enable_litellm" == "true" ]]; then all_bind_files+=("litellm-config.yaml"); fi
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
