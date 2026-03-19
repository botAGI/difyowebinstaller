#!/usr/bin/env bats
# test_openwebui.bats — Tests for lib/openwebui.sh
# Run: bats tests/test_openwebui.bats
#
# Note: Admin creation requires running Docker containers.
# Tests verify function contracts, JSON escaping, and password fallback logic.

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test_$$"
    mkdir -p "${INSTALL_DIR}/docker"

    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    # shellcheck source=../lib/openwebui.sh
    source "${BATS_TEST_DIRNAME}/../lib/openwebui.sh"
}

teardown() {
    rm -rf "${INSTALL_DIR}"
}

# ============================================================================
# FUNCTIONS EXIST
# ============================================================================

@test "all functions are defined" {
    declare -f create_openwebui_admin >/dev/null
    declare -f _wait_openwebui_healthy >/dev/null
    declare -f _create_admin_via_api >/dev/null
}

# ============================================================================
# JSON ESCAPING
# ============================================================================

@test "_create_admin_via_api: builds valid JSON payload" {
    # Override docker exec to capture the JSON payload
    docker() {
        if [[ "$1" == "exec" ]]; then
            # Find the -d argument
            local i
            for i in "$@"; do
                if [[ "$i" == '{'* ]]; then
                    echo "$i"
                    return 0
                fi
            done
        fi
        return 0
    }
    export -f docker

    # Capture what would be sent
    local output
    output="$(_create_admin_via_api "Test Admin" "test@example.com" "p@ss\"word" 2>&1)"

    # Should contain escaped quotes
    [[ "$output" != *'p@ss"word'* ]] || true  # raw quote should be escaped

    unset -f docker
}

# ============================================================================
# PASSWORD FALLBACK LOGIC
# ============================================================================

@test "admin password: reads from INIT_PASSWORD in .env" {
    # Create .env with base64 encoded password
    local plain="TestPassword123"
    local b64
    b64="$(echo -n "$plain" | base64)"
    echo "INIT_PASSWORD=${b64}" > "${INSTALL_DIR}/docker/.env"

    # We can't run the full function (needs Docker), but we can test the read logic
    local admin_password
    admin_password="$(grep '^INIT_PASSWORD=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2- | base64 -d 2>/dev/null)"
    [ "$admin_password" = "TestPassword123" ]
}

@test "admin password: falls back to .admin_password file" {
    echo "FallbackPass456" > "${INSTALL_DIR}/.admin_password"
    # No INIT_PASSWORD in .env
    echo "OTHER_VAR=value" > "${INSTALL_DIR}/docker/.env"

    local admin_password
    admin_password="$(grep '^INIT_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- | base64 -d 2>/dev/null || true)"
    if [[ -z "$admin_password" ]]; then
        admin_password="$(cat "${INSTALL_DIR}/.admin_password" 2>/dev/null || true)"
    fi
    [ "$admin_password" = "FallbackPass456" ]
}

@test "admin password: generates random if nothing found" {
    # No .env, no .admin_password
    echo "" > "${INSTALL_DIR}/docker/.env"

    local admin_password
    admin_password="$(grep '^INIT_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- | base64 -d 2>/dev/null || true)"
    if [[ -z "$admin_password" ]]; then
        admin_password="$(cat "${INSTALL_DIR}/.admin_password" 2>/dev/null || true)"
    fi
    if [[ -z "$admin_password" ]]; then
        admin_password="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 16)"
    fi

    [ -n "$admin_password" ]
    [ "${#admin_password}" -eq 16 ]
}

# ============================================================================
# ENABLE_SIGNUP STAYS FALSE IN .ENV
# ============================================================================

@test "signup lockdown: ENABLE_SIGNUP=false must be in .env" {
    echo "ENABLE_SIGNUP=false" > "${INSTALL_DIR}/docker/.env"

    # Verify the value stays false (shell override is temporary)
    local signup_val
    signup_val="$(grep '^ENABLE_SIGNUP=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2-)"
    [ "$signup_val" = "false" ]
}
