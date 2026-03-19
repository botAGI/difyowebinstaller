#!/usr/bin/env bash
# openwebui.sh — Create admin user in Open WebUI.
# Dependencies: common.sh (log_*)
# Functions: create_openwebui_admin()
# Expects: INSTALL_DIR
#
# Open WebUI persists ENABLE_SIGNUP in SQLite on first boot.
# After that, env var is ignored ("loaded from the latest database entry").
# Strategy: delete webui.db → start with ENABLE_SIGNUP=true → create admin
# → restart without override. Nginx stopped during the whole process.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# CREATE ADMIN
# ============================================================================

create_openwebui_admin() {
    local docker_dir="${INSTALL_DIR}/docker"
    local env_file="${docker_dir}/.env"

    # Skip if admin already created in a previous run
    if [[ -f "${INSTALL_DIR}/.admin_created" ]]; then
        log_info "Open WebUI admin already configured"
        return 0
    fi

    # Read admin password
    local admin_password
    admin_password="$(grep '^INIT_PASSWORD=' "$env_file" 2>/dev/null | cut -d'=' -f2- | base64 -d 2>/dev/null || true)"
    if [[ -z "$admin_password" ]]; then
        admin_password="$(cat "${INSTALL_DIR}/.admin_password" 2>/dev/null || true)"
    fi
    if [[ -z "$admin_password" ]]; then
        log_warn "No admin password found, generating random"
        admin_password="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 16)"
    fi

    log_info "Creating Open WebUI admin account..."
    cd "$docker_dir"

    # Step 1: Stop nginx (no public access during signup window)
    docker compose stop nginx >/dev/null 2>&1 || true

    # Step 2: Stop open-webui and delete webui.db
    # ENABLE_SIGNUP env var only sets the initial value on first DB creation.
    # If DB already exists with signup=false, env override is ignored.
    # Deleting webui.db lets the next start with ENABLE_SIGNUP=true take effect.
    docker compose stop open-webui >/dev/null 2>&1 || true
    local vol_name
    vol_name="$(docker volume ls -q 2>/dev/null | grep 'openwebui_data' | head -1)"
    if [[ -n "$vol_name" ]]; then
        docker run --rm -v "${vol_name}:/data" alpine rm -f /data/webui.db 2>/dev/null || true
    fi

    # Step 3: Start open-webui with signup enabled (first boot → DB stores true)
    ENABLE_SIGNUP=true docker compose up -d open-webui >/dev/null 2>&1 || true

    # Step 4: Wait for health
    if ! _wait_openwebui_healthy; then
        log_error "Open WebUI did not respond within 120s, skipping admin creation"
        docker compose up -d nginx >/dev/null 2>&1 || true
        return 0
    fi

    # Step 5: Create admin via signup API
    _create_admin_via_api "AGMind Admin" "admin@agmind.local" "$admin_password"

    # Step 6: Restart open-webui normally (reads ENABLE_SIGNUP from DB)
    docker compose up -d open-webui >/dev/null 2>&1 || true

    # Step 7: Start nginx
    docker compose up -d nginx >/dev/null 2>&1 || true

    # Mark as done (idempotent on re-runs)
    touch "${INSTALL_DIR}/.admin_created"
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
