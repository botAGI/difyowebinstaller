#!/usr/bin/env bash
# authelia.sh — Authelia 2FA configuration for /console/* routes.
# Dependencies: common.sh (log_*, generate_random, escape_sed, _atomic_sed)
# Functions: configure_authelia(template_dir), generate_argon2_hash(password),
#            create_authelia_user(email, password)
# Expects: INSTALL_DIR, ENABLE_AUTHELIA, DOMAIN
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# CONFIGURE AUTHELIA
# ============================================================================

configure_authelia() {
    if [[ "${ENABLE_AUTHELIA:-false}" != "true" ]]; then
        return 0
    fi

    local template_dir="$1"
    local authelia_dir="${INSTALL_DIR}/docker/authelia"
    mkdir -p "$authelia_dir"

    log_info "Configuring Authelia 2FA..."

    # Copy templates
    cp "${template_dir}/authelia/configuration.yml.template" "${authelia_dir}/configuration.yml"
    cp "${template_dir}/authelia/users_database.yml.template" "${authelia_dir}/users_database.yml"

    # Read admin password
    local admin_password
    admin_password="$(grep '^INIT_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- | base64 -d 2>/dev/null || true)"
    if [[ -z "$admin_password" ]]; then
        admin_password="$(cat "${INSTALL_DIR}/.admin_password" 2>/dev/null || true)"
    fi
    if [[ -z "$admin_password" ]]; then
        admin_password="$(generate_random 16)"
    fi

    # Generate argon2 hash
    local admin_hash
    admin_hash="$(generate_argon2_hash "$admin_password")" || {
        log_error "Failed to generate argon2 hash for Authelia"
        log_warn "Install argon2 or Docker for hash generation"
        return 1
    }

    # Generate JWT secret
    local jwt_secret
    jwt_secret="$(generate_random 64)"

    # Escape user-controlled values for sed
    local safe_domain safe_company
    safe_domain="$(escape_sed "${DOMAIN:-localhost}")"
    safe_company="$(escape_sed "AGMind")"

    # Replace placeholders in configuration.yml (atomic)
    local conf_tmp="${authelia_dir}/configuration.yml.tmp.$$"
    sed \
        -e "s|__AUTHELIA_JWT_SECRET__|${jwt_secret}|g" \
        -e "s|__DOMAIN__|${safe_domain}|g" \
        -e "s|__COMPANY_NAME__|${safe_company}|g" \
        "${authelia_dir}/configuration.yml" > "$conf_tmp" || { rm -f "$conf_tmp"; return 1; }
    mv "$conf_tmp" "${authelia_dir}/configuration.yml"

    # Replace placeholders in users_database.yml (atomic)
    local users_tmp="${authelia_dir}/users_database.yml.tmp.$$"
    sed \
        -e "s|__AUTHELIA_ADMIN_HASH__|${admin_hash}|g" \
        -e "s|__ADMIN_EMAIL__|admin@${DOMAIN:-localhost}|g" \
        -e "s|__COMPANY_NAME__|${safe_company}|g" \
        "${authelia_dir}/users_database.yml" > "$users_tmp" || { rm -f "$users_tmp"; return 1; }
    mv "$users_tmp" "${authelia_dir}/users_database.yml"

    # Restrictive permissions
    chmod 600 "${authelia_dir}/configuration.yml" "${authelia_dir}/users_database.yml"

    # Update JWT secret in .env
    local env_file="${INSTALL_DIR}/docker/.env"
    if [[ -f "$env_file" ]]; then
        _atomic_sed "$env_file" "s|AUTHELIA_JWT_SECRET=.*|AUTHELIA_JWT_SECRET=${jwt_secret}|"
    fi

    log_success "Authelia 2FA configured: ${authelia_dir}"
}

# ============================================================================
# ARGON2 HASH GENERATION
# ============================================================================

generate_argon2_hash() {
    local password="$1"
    local hash=""

    # Preferred: use Docker + Authelia image
    if command -v docker &>/dev/null; then
        hash="$(echo -n "$password" | docker run --rm -i "authelia/authelia:${AUTHELIA_VERSION:-4.38}" \
            authelia crypto hash generate argon2 --stdin 2>/dev/null | tail -1)" || true
        if [[ -n "${hash:-}" ]]; then
            echo "$hash"
            return 0
        fi
    fi

    # Fallback: python3 scrypt (degraded — may not work with all Authelia versions)
    if command -v python3 &>/dev/null; then
        hash="$(AUTHELIA_PW="$password" python3 -c "
import os, hashlib, base64
password = os.environ['AUTHELIA_PW'].encode()
salt = os.urandom(16)
h = hashlib.scrypt(password, salt=salt, n=65536, r=8, p=1, dklen=32)
print(base64.b64encode(salt).decode() + '\$' + base64.b64encode(h).decode())
" 2>/dev/null)" || true
        if [[ -n "${hash:-}" ]]; then
            echo "$hash"
            return 0
        fi
    fi

    # Last resort: placeholder
    log_error "Cannot generate argon2 hash. Replace manually." >&2
    echo '$argon2id$v=19$m=65536,t=3,p=4$PLACEHOLDER_SALT$PLACEHOLDER_HASH'
    return 1
}

# ============================================================================
# CREATE ADDITIONAL USER
# ============================================================================

create_authelia_user() {
    local email="${1:-}"
    local password="${2:-}"

    if [[ -z "$email" || -z "$password" ]]; then
        log_error "Usage: create_authelia_user <email> <password>"
        return 1
    fi

    local authelia_dir="${INSTALL_DIR}/docker/authelia"
    local users_file="${authelia_dir}/users_database.yml"

    if [[ ! -f "$users_file" ]]; then
        log_error "Users file not found: ${users_file}"
        return 1
    fi

    # Derive username from email
    local username
    username="$(echo "$email" | cut -d'@' -f1 | tr '.' '_' | tr '[:upper:]' '[:lower:]')"

    local password_hash
    password_hash="$(generate_argon2_hash "$password")"

    printf '  %s:\n    displayname: "%s"\n    password: "%s"\n    email: %s\n    groups:\n      - admins\n      - users\n' \
        "$username" "$username" "$password_hash" "$email" >> "$users_file"

    log_success "User ${username} (${email}) added to Authelia"
}

# Standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    echo "authelia.sh: use configure_authelia(template_dir)"
fi
