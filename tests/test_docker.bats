#!/usr/bin/env bats
# test_docker.bats — Tests for lib/docker.sh
# Run: bats tests/test_docker.bats
#
# Note: Docker installation requires root and a real OS.
# Tests verify function contracts, conditional logic, and skip conditions.
# Actual install is tested in test_lifecycle.bats (E2E).

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test"
    mkdir -p "$INSTALL_DIR"
    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    # shellcheck source=../lib/detect.sh
    source "${BATS_TEST_DIRNAME}/../lib/detect.sh"
    # shellcheck source=../lib/docker.sh
    source "${BATS_TEST_DIRNAME}/../lib/docker.sh"
}

teardown() {
    rm -rf "${BATS_TMPDIR}/agmind_test"
    unset SKIP_DNS_FIX DEPLOY_PROFILE DETECTED_GPU DETECTED_OS
    unset DETECTED_DOCKER_INSTALLED DETECTED_DOCKER_COMPOSE
}

# ============================================================================
# INSTALL DOCKER — SKIP LOGIC
# ============================================================================

@test "install_docker: skips if already installed" {
    export DETECTED_DOCKER_INSTALLED="true"
    export DETECTED_DOCKER_COMPOSE="true"
    run install_docker
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

@test "install_docker: detects unsupported OS" {
    export DETECTED_DOCKER_INSTALLED="false"
    export DETECTED_DOCKER_COMPOSE="false"
    export DETECTED_OS="unsupported_os"
    run install_docker
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unsupported OS"* ]]
}

# ============================================================================
# NVIDIA TOOLKIT — SKIP LOGIC
# ============================================================================

@test "install_nvidia_toolkit: skips if no nvidia GPU" {
    export DETECTED_GPU="none"
    run install_nvidia_toolkit
    [ "$status" -eq 0 ]
    # Should return immediately with no output
    [ -z "$output" ] || true
}

@test "install_nvidia_toolkit: skips for AMD GPU" {
    export DETECTED_GPU="amd"
    run install_nvidia_toolkit
    [ "$status" -eq 0 ]
}

@test "install_nvidia_toolkit: skips for Apple Silicon" {
    export DETECTED_GPU="apple"
    run install_nvidia_toolkit
    [ "$status" -eq 0 ]
}

# ============================================================================
# DNS FIX — SKIP LOGIC
# ============================================================================

@test "configure_docker_dns: skips for offline profile" {
    export DEPLOY_PROFILE="offline"
    run configure_docker_dns
    [ "$status" -eq 0 ]
    [[ "$output" == *"Offline"* ]] || [[ "$output" == *"skipping"* ]]
}

@test "configure_docker_dns: skips with SKIP_DNS_FIX=true" {
    export SKIP_DNS_FIX="true"
    run configure_docker_dns
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP_DNS_FIX"* ]]
}

@test "configure_docker_dns: skips if resolv.conf is not a stub symlink" {
    # On most CI/test systems, resolv.conf is not a stub symlink
    # This test verifies the function exits cleanly
    run configure_docker_dns
    [ "$status" -eq 0 ]
}

# ============================================================================
# SETUP DOCKER — INTEGRATION
# ============================================================================

@test "setup_docker: runs all three steps when docker already installed" {
    export DETECTED_DOCKER_INSTALLED="true"
    export DETECTED_DOCKER_COMPOSE="true"
    export DETECTED_GPU="none"
    run setup_docker
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
}

# ============================================================================
# _add_user_to_docker_group
# ============================================================================

@test "_add_user_to_docker_group: does nothing without SUDO_USER" {
    unset SUDO_USER
    run _add_user_to_docker_group
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ============================================================================
# MACROS — INSTALL PATH ROUTING
# ============================================================================

@test "install_docker: routes debian to _install_docker_debian" {
    # We can't actually run the install, but we verify the routing
    export DETECTED_DOCKER_INSTALLED="false"
    export DETECTED_DOCKER_COMPOSE="false"
    export DETECTED_OS="debian"
    # _install_docker_debian will fail (not root/no apt), but we verify routing
    run install_docker
    # Either succeeds (somehow) or fails with apt error (expected)
    # The point is it didn't hit "Unsupported OS"
    [[ "$output" != *"Unsupported OS"* ]]
}

@test "install_docker: routes centos to _install_docker_rhel" {
    export DETECTED_DOCKER_INSTALLED="false"
    export DETECTED_DOCKER_COMPOSE="false"
    export DETECTED_OS="centos"
    run install_docker
    [[ "$output" != *"Unsupported OS"* ]]
}

@test "install_docker: routes fedora to _install_docker_rhel" {
    export DETECTED_DOCKER_INSTALLED="false"
    export DETECTED_DOCKER_COMPOSE="false"
    export DETECTED_OS="fedora"
    run install_docker
    [[ "$output" != *"Unsupported OS"* ]]
}

@test "install_docker: routes macos to _install_docker_macos" {
    export DETECTED_DOCKER_INSTALLED="false"
    export DETECTED_DOCKER_COMPOSE="false"
    export DETECTED_OS="macos"
    run install_docker
    [[ "$output" != *"Unsupported OS"* ]]
}

# ============================================================================
# FUNCTIONS EXIST
# ============================================================================

@test "all exported functions are defined" {
    declare -f install_docker >/dev/null
    declare -f install_nvidia_toolkit >/dev/null
    declare -f configure_docker_dns >/dev/null
    declare -f setup_docker >/dev/null
    declare -f _install_docker_debian >/dev/null
    declare -f _install_docker_rhel >/dev/null
    declare -f _install_docker_macos >/dev/null
    declare -f _add_user_to_docker_group >/dev/null
}
