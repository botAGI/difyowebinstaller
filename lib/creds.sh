#!/usr/bin/env bash
# creds.sh — AGmind credentials display module (SC2).
# Reads ${INSTALL_DIR}/.admin_password + ${INSTALL_DIR}/credentials.txt (free-form text).
# Masking: lines matching /^\s*(Pass|Password|Key|Token|Secret):\s+<value>=/ → first3…last3.
# Zero-logging promise: credential values NEVER written to log files or log_* calls.
# Source only — do NOT execute directly.
set -euo pipefail

# Guard against double-sourcing
[[ -n "${_CREDS_LOADED:-}" ]] && return 0
_CREDS_LOADED=1

# ============================================================================
# FALLBACK SHIMS (when sourced without common.sh / health.sh)
# ============================================================================

# Fallback colors when sourced without agmind.sh or common.sh
: "${RED:=\033[0;31m}"
: "${YELLOW:=\033[1;33m}"
: "${GREEN:=\033[0;32m}"
: "${NC:=\033[0m}"

# Default install dir — override via INSTALL_DIR env
: "${INSTALL_DIR:=/opt/agmind}"

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

# _creds_mask_value <raw>
# Returns masked form: first3…last3 (len ≥ 8), or •••• (shorter).
_creds_mask_value() {
    local v="$1"
    if [[ "${#v}" -ge 8 ]]; then
        printf '%s' "${v:0:3}…${v: -3}"
    else
        printf '%s' "••••"
    fi
}

# _creds_mask_line <line>
# If line matches the secret-bearing pattern, masks the value; otherwise passes through verbatim.
# Pattern: leading whitespace + (Pass|Password|Key|Token|Secret): + whitespace + 8+ word-chars
_creds_mask_line() {
    local line="$1"
    # Regex: optional whitespace + secret label + colon + whitespace + value (≥8 alphanumeric/_./+=-) + optional whitespace
    if [[ "$line" =~ ^([[:space:]]*(Pass|Password|Key|Token|Secret):[[:space:]]+)([A-Za-z0-9_./+=-]{8,})[[:space:]]*$ ]]; then
        printf '%s%s\n' "${BASH_REMATCH[1]}" "$(_creds_mask_value "${BASH_REMATCH[3]}")"
    else
        printf '%s\n' "$line"
    fi
}

# _creds_admin_password
# Reads single-line admin password from ${INSTALL_DIR}/.admin_password.
# Prints to stdout; returns 1 if unreadable.
_creds_admin_password() {
    local f="${INSTALL_DIR}/.admin_password"
    if [[ ! -r "$f" ]]; then
        return 1
    fi
    head -n1 "$f"
}

# ============================================================================
# PUBLIC — creds_show
# ============================================================================

# creds_show [--show] [--json]
# Root-gated credential display. Masked by default; --show reveals plaintext.
# ZERO LOGGING: credential values never passed to log_* or written to log files.
creds_show() {
    local show_plain=0 json_mode=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --show)         show_plain=1 ;;
            --json)         json_mode=1 ;;
            -h|--help)
                echo "Usage: agmind creds show [--show] [--json]"
                echo "  (no flags)  Show credentials with values masked (root-only)"
                echo "  --show      Reveal plaintext values + stderr warning"
                echo "  --json      Machine-readable JSON; values masked unless --show"
                return 0
                ;;
            *)
                printf '%s\n' "Unknown flag: ${arg}" >&2
                printf '%s\n' "Usage: agmind creds show [--show] [--json]" >&2
                return 1
                ;;
        esac
    done

    # ── Root gate (FIRST — before any 600-file read) ──────────────────────────
    if [[ "$(id -u)" -ne 0 ]]; then
        printf '%b%s%b\n' "${RED}" "credentials are root-only — run: sudo agmind creds show" "${NC}" >&2
        return 1
    fi

    # ── Plaintext warning ─────────────────────────────────────────────────────
    if [[ "$show_plain" -eq 1 ]]; then
        printf '%b%s%b\n' "${YELLOW}" "WARNING: showing plaintext credentials — do not screenshot or paste into logs" "${NC}" >&2
    fi

    # ── Read .admin_password ──────────────────────────────────────────────────
    local admin_pw=""
    if [[ ! -d "$INSTALL_DIR" ]]; then
        printf '%b%s%b\n' "${RED}" "AGmind not installed at ${INSTALL_DIR}" "${NC}" >&2
        return 1
    fi
    if ! admin_pw="$(_creds_admin_password)"; then
        printf '%b%s%b\n' "${YELLOW}" "no credentials found (.admin_password missing) — was install interrupted?" "${NC}" >&2
        return 1
    fi

    # ── Read credentials.txt (optional) ──────────────────────────────────────
    local creds_file="${INSTALL_DIR}/credentials.txt"
    local creds_file_exists=0
    [[ -r "$creds_file" ]] && creds_file_exists=1

    # ── JSON output ───────────────────────────────────────────────────────────
    if [[ "$json_mode" -eq 1 ]]; then
        # Use python3 for safe JSON construction (mirrors _status_render_json pattern)
        SHOW_PLAIN="$show_plain" \
        ADMIN_PW="$admin_pw" \
        CREDS_FILE="$creds_file" \
        CREDS_FILE_EXISTS="$creds_file_exists" \
        python3 - <<'PYEOF'
import json, sys, os, re, datetime

show = os.environ.get("SHOW_PLAIN", "0") == "1"
admin_pw = os.environ.get("ADMIN_PW", "")
creds_file = os.environ.get("CREDS_FILE", "")
creds_file_exists = os.environ.get("CREDS_FILE_EXISTS", "0") == "1"

SECRET_RE = re.compile(
    r'^(\s*(?:Pass|Password|Key|Token|Secret):\s+)([A-Za-z0-9_.\/+=-]{8,})\s*$'
)

def mask(v):
    if len(v) >= 8:
        return v[:3] + "…" + v[-3:]
    return "••••"

def mask_line(line):
    m = SECRET_RE.match(line)
    if m:
        return m.group(1) + mask(m.group(2))
    return line

admin_display = admin_pw if show else mask(admin_pw)

lines = []
if creds_file_exists:
    try:
        with open(creds_file, "r", encoding="utf-8") as f:
            for raw in f:
                raw = raw.rstrip("\n")
                lines.append(raw if show else mask_line(raw))
    except Exception:
        pass

print(json.dumps({
    "generated_at": datetime.datetime.utcnow().isoformat() + "Z",
    "install_dir": creds_file,
    "admin_password": admin_display,
    "credentials_file": creds_file if creds_file_exists else None,
    "masked": not show,
    "lines": lines
}))
PYEOF
        return 0
    fi

    # ── Human output ──────────────────────────────────────────────────────────
    printf '=== AGmind credentials (%s) ===\n' "${INSTALL_DIR}"

    local admin_display
    if [[ "$show_plain" -eq 1 ]]; then
        admin_display="$admin_pw"
    else
        admin_display="$(_creds_mask_value "$admin_pw") (use --show to reveal)"
    fi
    printf 'Admin Password: %s\n' "$admin_display"
    printf '\n'

    if [[ "$creds_file_exists" -eq 1 ]]; then
        if [[ "$show_plain" -eq 1 ]]; then
            cat "$creds_file"
        else
            while IFS= read -r line || [[ -n "$line" ]]; do
                _creds_mask_line "$line"
            done < "$creds_file"
        fi
    else
        printf '%b%s%b\n' "${YELLOW}" \
            "note: ${creds_file} not present (older install) — only the admin password is available" \
            "${NC}" >&2
    fi

    return 0
}
