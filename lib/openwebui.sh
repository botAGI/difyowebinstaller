#!/usr/bin/env bash
# openwebui.sh — Create admin user in Open WebUI, lock down signups.
# Dependencies: common.sh (log_*)
# Functions: create_openwebui_admin()
# Expects: INSTALL_DIR
#
# Strategy: Stop nginx → enable signup → create admin via container-internal
# API → disable signup → start nginx. This prevents public exposure of the
# signup endpoint (race condition fix from v2).
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# CREATE ADMIN
# ============================================================================

create_openwebui_admin() {
    local docker_dir="${INSTALL_DIR}/docker"
    local env_file="${docker_dir}/.env"

    # Read admin password from .env (Base64-encoded INIT_PASSWORD)
    local admin_email="admin@localhost"
    local admin_name="AGMind Admin"
    local admin_password
    admin_password="$(grep '^INIT_PASSWORD=' "$env_file" 2>/dev/null | cut -d'=' -f2- | base64 -d 2>/dev/null || true)"
    if [[ -z "$admin_password" ]]; then
        # Fallback: read from .admin_password file
        admin_password="$(cat "${INSTALL_DIR}/.admin_password" 2>/dev/null || true)"
    fi
    if [[ -z "$admin_password" ]]; then
        log_warn "No admin password found, generating random"
        admin_password="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 16)"
    fi

    log_info "Creating Open WebUI admin account..."
    cd "$docker_dir"

    # Step 1: Stop nginx to prevent external access during signup window
    docker compose stop nginx >/dev/null 2>&1 || true

    # Step 2: Restart open-webui with signup enabled
    # Shell env overrides .env file (ENABLE_SIGNUP=false stays in .env permanently)
    ENABLE_SIGNUP=true docker compose up -d open-webui >/dev/null 2>&1 || true

    # Step 3: Wait for Open WebUI to be healthy (up to 120s)
    if ! _wait_openwebui_healthy; then
        log_error "Open WebUI did not respond within 120s, skipping admin creation"
        docker compose up -d nginx >/dev/null 2>&1 || true
        return 0
    fi

    # Step 4: Create admin via container-internal API
    _create_admin_via_api "$admin_name" "$admin_email" "$admin_password"

    # Step 5: Restart open-webui with signup locked (reads .env: ENABLE_SIGNUP=false)
    docker compose up -d open-webui >/dev/null 2>&1 || true

    # Step 6: Start nginx (public access begins AFTER signup is locked)
    docker compose up -d nginx >/dev/null 2>&1 || true
    log_success "Signup locked (ENABLE_SIGNUP=false)"
}

# ============================================================================
# HELPERS
# ============================================================================

_wait_openwebui_healthy() {
    local attempts=0
    while [[ $attempts -lt 24 ]]; do
        if docker exec agmind-openwebui curl -sf http://localhost:8080/health >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
        attempts=$((attempts + 1))
    done
    return 1
}

_create_admin_via_api() {
    local name="$1"
    local email="$2"
    local password="$3"

    # Escape double quotes in JSON values
    local json_payload
    json_payload="$(printf '{"name":"%s","email":"%s","password":"%s"}' \
        "$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        "$(printf '%s' "$email" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        "$(printf '%s' "$password" | sed 's/\\/\\\\/g; s/"/\\"/g')")"

    local resp
    resp="$(docker exec agmind-openwebui curl -sf \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        http://localhost:8080/api/v1/auths/signup 2>&1)" || true

    if echo "$resp" | grep -q '"token"'; then
        log_success "Open WebUI admin created (${email})"
    elif echo "$resp" | grep -qi "already"; then
        log_info "Open WebUI admin already exists"
    else
        log_warn "Open WebUI signup response: $(echo "$resp" | head -c 200)"
    fi
}

# ============================================================================
# STANDALONE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    create_openwebui_admin
fi
