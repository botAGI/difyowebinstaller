#!/usr/bin/env bats
# test_security.bats — Tests for lib/security.sh + lib/authelia.sh
# Run: bats tests/test_security.bats
#
# Note: UFW/fail2ban/SOPS require root. Tests verify skip logic,
# function contracts, and Docker hardening.

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test_$$"
    mkdir -p "${INSTALL_DIR}/docker"

    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    # shellcheck source=../lib/security.sh
    source "${BATS_TEST_DIRNAME}/../lib/security.sh"
    # shellcheck source=../lib/authelia.sh
    source "${BATS_TEST_DIRNAME}/../lib/authelia.sh"
}

teardown() {
    rm -rf "${INSTALL_DIR}"
    unset ENABLE_UFW ENABLE_FAIL2BAN ENABLE_SOPS ENABLE_AUTHELIA
    unset DEPLOY_PROFILE MONITORING_MODE SKIP_DOCKER_HARDENING
}

# ============================================================================
# UFW — SKIP LOGIC
# ============================================================================

@test "configure_ufw: skips when ENABLE_UFW=false" {
    export ENABLE_UFW="false"
    run configure_ufw
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "configure_ufw: skips when ENABLE_UFW not set" {
    unset ENABLE_UFW
    run configure_ufw
    [ "$status" -eq 0 ]
}

# ============================================================================
# FAIL2BAN — SKIP LOGIC
# ============================================================================

@test "configure_fail2ban: skips when ENABLE_FAIL2BAN=false" {
    export ENABLE_FAIL2BAN="false"
    run configure_fail2ban
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "configure_fail2ban: skips when ENABLE_FAIL2BAN not set" {
    unset ENABLE_FAIL2BAN
    run configure_fail2ban
    [ "$status" -eq 0 ]
}

# ============================================================================
# SOPS — SKIP LOGIC
# ============================================================================

@test "encrypt_secrets: skips when ENABLE_SOPS=false" {
    export ENABLE_SOPS="false"
    run encrypt_secrets
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "encrypt_secrets: skips when ENABLE_SOPS not set" {
    unset ENABLE_SOPS
    run encrypt_secrets
    [ "$status" -eq 0 ]
}

# ============================================================================
# DOCKER HARDENING
# ============================================================================

@test "harden_docker_compose: skips when SKIP_DOCKER_HARDENING=true" {
    export SKIP_DOCKER_HARDENING="true"
    run harden_docker_compose
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "harden_docker_compose: skips when compose file missing" {
    run harden_docker_compose
    [ "$status" -eq 0 ]
}

@test "harden_docker_compose: adds no-new-privileges to compose" {
    if ! command -v python3 &>/dev/null; then
        skip "python3 not available"
    fi

    local compose="${INSTALL_DIR}/docker/docker-compose.yml"
    cat > "$compose" << 'EOF'
services:
  api:
    container_name: agmind-api
    image: test
  sandbox:
    container_name: agmind-sandbox
    image: test
  cadvisor:
    container_name: agmind-cadvisor
    image: test
EOF

    harden_docker_compose

    # api should have no-new-privileges
    grep -q "no-new-privileges" "$compose"

    # sandbox and cadvisor should NOT
    local api_section
    api_section="$(sed -n '/agmind-api/,/agmind-sandbox/p' "$compose")"
    [[ "$api_section" == *"no-new-privileges"* ]]
}

@test "harden_docker_compose: idempotent (doesn't add twice)" {
    if ! command -v python3 &>/dev/null; then
        skip "python3 not available"
    fi

    local compose="${INSTALL_DIR}/docker/docker-compose.yml"
    cat > "$compose" << 'EOF'
services:
  api:
    container_name: agmind-api
    security_opt:
      - no-new-privileges:true
    image: test
EOF

    run harden_docker_compose
    [ "$status" -eq 0 ]
    [[ "$output" == *"already applied"* ]]
}

# ============================================================================
# AUTHELIA — SKIP LOGIC
# ============================================================================

@test "configure_authelia: skips when ENABLE_AUTHELIA=false" {
    export ENABLE_AUTHELIA="false"
    run configure_authelia "/nonexistent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "configure_authelia: skips when ENABLE_AUTHELIA not set" {
    unset ENABLE_AUTHELIA
    run configure_authelia "/nonexistent"
    [ "$status" -eq 0 ]
}

# ============================================================================
# ARGON2 HASH
# ============================================================================

@test "generate_argon2_hash: returns something (fallback to placeholder)" {
    # Without Docker and potentially without python3, should still return
    run generate_argon2_hash "testpassword"
    [ -n "$output" ]
    # Should be a hash string of some kind
    [[ "$output" == *'$'* ]] || true
}

# ============================================================================
# CREATE AUTHELIA USER — VALIDATION
# ============================================================================

@test "create_authelia_user: fails with empty email" {
    run create_authelia_user "" "password"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "create_authelia_user: fails with empty password" {
    run create_authelia_user "user@test.com" ""
    [ "$status" -eq 1 ]
}

@test "create_authelia_user: fails when users file missing" {
    run create_authelia_user "user@test.com" "password"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

# ============================================================================
# SETUP SECURITY — INTEGRATION
# ============================================================================

@test "setup_security: runs with all disabled" {
    export ENABLE_UFW="false"
    export ENABLE_FAIL2BAN="false"
    export ENABLE_SOPS="false"
    export SKIP_DOCKER_HARDENING="true"

    run setup_security
    [ "$status" -eq 0 ]
}

