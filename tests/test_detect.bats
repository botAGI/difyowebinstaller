#!/usr/bin/env bats
# test_detect.bats — Tests for lib/detect.sh
# Run: bats tests/test_detect.bats
#
# Note: detect.sh probes real system state (OS, GPU, RAM, disk, Docker).
# Tests verify function contracts and ENV overrides, not specific hardware.

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test"
    mkdir -p "$INSTALL_DIR"
    # Source common.sh first (dependency)
    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    # shellcheck source=../lib/detect.sh
    source "${BATS_TEST_DIRNAME}/../lib/detect.sh"
}

teardown() {
    rm -rf "${BATS_TMPDIR}/agmind_test"
    unset FORCE_GPU_TYPE SKIP_GPU_DETECT SKIP_PREFLIGHT
}

# ============================================================================
# DETECT OS
# ============================================================================

@test "detect_os: sets DETECTED_OS to non-empty value" {
    detect_os
    [ -n "$DETECTED_OS" ]
    [ "$DETECTED_OS" != "" ]
}

@test "detect_os: sets DETECTED_ARCH to uname -m" {
    detect_os
    local expected
    expected="$(uname -m)"
    [ "$DETECTED_ARCH" = "$expected" ]
}

@test "detect_os: sets DETECTED_OS_NAME" {
    detect_os
    [ -n "$DETECTED_OS_NAME" ]
}

# ============================================================================
# DETECT ARCH
# ============================================================================

@test "detect_arch: sets DOCKER_PLATFORM" {
    detect_arch
    [ -n "$DOCKER_PLATFORM" ]
    # Must start with linux/
    [[ "$DOCKER_PLATFORM" == linux/* ]]
}

@test "detect_arch: DOCKER_PLATFORM matches architecture" {
    detect_arch
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  [ "$DOCKER_PLATFORM" = "linux/amd64" ] ;;
        aarch64|arm64) [ "$DOCKER_PLATFORM" = "linux/arm64" ] ;;
        armv7l)        [ "$DOCKER_PLATFORM" = "linux/arm/v7" ] ;;
        *)             [ "$DOCKER_PLATFORM" = "linux/amd64" ] ;;
    esac
}

# ============================================================================
# DETECT GPU
# ============================================================================

@test "detect_gpu: FORCE_GPU_TYPE=nvidia overrides detection" {
    export FORCE_GPU_TYPE="nvidia"
    detect_gpu
    [ "$DETECTED_GPU" = "nvidia" ]
}

@test "detect_gpu: FORCE_GPU_TYPE=none overrides detection" {
    export FORCE_GPU_TYPE="none"
    detect_gpu
    [ "$DETECTED_GPU" = "none" ]
}

@test "detect_gpu: FORCE_GPU_TYPE=apple overrides detection" {
    export FORCE_GPU_TYPE="apple"
    detect_gpu
    [ "$DETECTED_GPU" = "apple" ]
}

@test "detect_gpu: invalid FORCE_GPU_TYPE is ignored" {
    export FORCE_GPU_TYPE="invalid_type"
    detect_gpu
    # Should remain at default (none) or whatever real detection finds
    [[ "$DETECTED_GPU" =~ ^(none|nvidia|amd|intel|apple)$ ]]
}

@test "detect_gpu: SKIP_GPU_DETECT=true skips detection" {
    export SKIP_GPU_DETECT="true"
    detect_gpu
    [ "$DETECTED_GPU" = "none" ]
    [ "$DETECTED_GPU_VRAM" = "0" ]
}

@test "detect_gpu: result is one of known types" {
    detect_gpu
    [[ "$DETECTED_GPU" =~ ^(none|nvidia|amd|intel|apple)$ ]]
}

@test "detect_gpu: DETECTED_GPU_VRAM is numeric" {
    detect_gpu
    [[ "$DETECTED_GPU_VRAM" =~ ^[0-9]+$ ]]
}

# ============================================================================
# DETECT RAM
# ============================================================================

@test "detect_ram: DETECTED_RAM_TOTAL_MB is positive" {
    detect_ram
    [ "$DETECTED_RAM_TOTAL_MB" -gt 0 ]
}

@test "detect_ram: DETECTED_RAM_TOTAL_GB is calculated" {
    detect_ram
    [ -n "$DETECTED_RAM_TOTAL_GB" ]
    [[ "$DETECTED_RAM_TOTAL_GB" =~ ^[0-9]+$ ]]
}

@test "detect_ram: DETECTED_RAM_AVAILABLE_MB is set" {
    detect_ram
    [[ "$DETECTED_RAM_AVAILABLE_MB" =~ ^[0-9]+$ ]]
}

@test "detect_ram: total >= available" {
    detect_ram
    [ "$DETECTED_RAM_TOTAL_MB" -ge "$DETECTED_RAM_AVAILABLE_MB" ]
}

# ============================================================================
# DETECT DISK
# ============================================================================

@test "detect_disk: DETECTED_DISK_FREE_GB is numeric" {
    detect_disk
    [[ "$DETECTED_DISK_FREE_GB" =~ ^[0-9]+$ ]]
}

@test "detect_disk: DETECTED_DISK_FREE_GB is positive" {
    detect_disk
    [ "$DETECTED_DISK_FREE_GB" -gt 0 ]
}

# ============================================================================
# DETECT PORTS
# ============================================================================

@test "detect_ports: PORTS_IN_USE is set (may be empty)" {
    detect_ports
    # Variable must be declared (even if empty)
    [ "${PORTS_IN_USE+set}" = "set" ]
}

@test "detect_ports: ports in use contain only numbers and spaces" {
    detect_ports
    if [[ -n "$PORTS_IN_USE" ]]; then
        [[ "$PORTS_IN_USE" =~ ^[0-9\ ]+$ ]]
    fi
}

# ============================================================================
# DETECT DOCKER
# ============================================================================

@test "detect_docker: DETECTED_DOCKER_INSTALLED is true or false" {
    detect_docker
    [[ "$DETECTED_DOCKER_INSTALLED" =~ ^(true|false)$ ]]
}

@test "detect_docker: DETECTED_DOCKER_COMPOSE is true or false" {
    detect_docker
    [[ "$DETECTED_DOCKER_COMPOSE" =~ ^(true|false)$ ]]
}

@test "detect_docker: if installed, version is set" {
    detect_docker
    if [[ "$DETECTED_DOCKER_INSTALLED" == "true" ]]; then
        [ -n "$DETECTED_DOCKER_VERSION" ]
    fi
}

# ============================================================================
# DETECT NETWORK
# ============================================================================

@test "detect_network: DETECTED_NETWORK is true or false" {
    detect_network
    [[ "$DETECTED_NETWORK" =~ ^(true|false)$ ]]
}

# ============================================================================
# RECOMMEND MODEL
# ============================================================================

@test "recommend_model: sets RECOMMENDED_MODEL" {
    detect_ram
    detect_gpu
    recommend_model
    [ -n "$RECOMMENDED_MODEL" ]
}

@test "recommend_model: sets RECOMMENDED_REASON" {
    detect_ram
    detect_gpu
    recommend_model
    [ -n "$RECOMMENDED_REASON" ]
}

@test "recommend_model: 48GB+ recommends 72b" {
    DETECTED_RAM_TOTAL_GB=64
    DETECTED_GPU="none"
    DETECTED_GPU_VRAM=0
    recommend_model
    [[ "$RECOMMENDED_MODEL" == *"72b"* ]]
}

@test "recommend_model: 24GB recommends 32b" {
    DETECTED_RAM_TOTAL_GB=24
    DETECTED_GPU="none"
    DETECTED_GPU_VRAM=0
    recommend_model
    [[ "$RECOMMENDED_MODEL" == *"32b"* ]]
}

@test "recommend_model: 12GB recommends 14b" {
    DETECTED_RAM_TOTAL_GB=12
    DETECTED_GPU="none"
    DETECTED_GPU_VRAM=0
    recommend_model
    [[ "$RECOMMENDED_MODEL" == *"14b"* ]]
}

@test "recommend_model: 6GB recommends 7b" {
    DETECTED_RAM_TOTAL_GB=6
    DETECTED_GPU="none"
    DETECTED_GPU_VRAM=0
    recommend_model
    [[ "$RECOMMENDED_MODEL" == *"7b"* ]]
}

@test "recommend_model: <6GB recommends 4b" {
    DETECTED_RAM_TOTAL_GB=4
    DETECTED_GPU="none"
    DETECTED_GPU_VRAM=0
    recommend_model
    [[ "$RECOMMENDED_MODEL" == *"4b"* ]]
}

@test "recommend_model: NVIDIA VRAM takes priority over RAM" {
    DETECTED_RAM_TOTAL_GB=8
    DETECTED_GPU="nvidia"
    DETECTED_GPU_VRAM=24576  # 24GB VRAM
    recommend_model
    # 24GB VRAM → should recommend 32b, not 7b based on 8GB RAM
    [[ "$RECOMMENDED_MODEL" == *"32b"* ]]
}

# ============================================================================
# RUN DIAGNOSTICS
# ============================================================================

@test "run_diagnostics: runs without error on supported system" {
    # May return non-zero if RAM/disk below minimum — that's OK for CI
    run run_diagnostics
    # Should produce output regardless
    [ -n "$output" ]
    [[ "$output" == *"System Diagnostics"* ]]
}

@test "run_diagnostics: exports all DETECTED_* variables" {
    run_diagnostics || true  # ignore min-resource failures
    [ -n "$DETECTED_OS" ]
    [ -n "$DETECTED_ARCH" ]
    [ -n "$DOCKER_PLATFORM" ]
    [[ "$DETECTED_GPU" =~ ^(none|nvidia|amd|intel|apple)$ ]]
    [[ "$DETECTED_RAM_TOTAL_MB" =~ ^[0-9]+$ ]]
    [[ "$DETECTED_DISK_FREE_GB" =~ ^[0-9]+$ ]]
    [[ "$DETECTED_DOCKER_INSTALLED" =~ ^(true|false)$ ]]
    [[ "$DETECTED_NETWORK" =~ ^(true|false)$ ]]
    [ -n "$RECOMMENDED_MODEL" ]
}

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

@test "preflight_checks: SKIP_PREFLIGHT=true skips all checks" {
    export SKIP_PREFLIGHT="true"
    run preflight_checks
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped"* ]]
}

@test "preflight_checks: produces structured output" {
    run preflight_checks
    # May fail on resource checks — we just verify structure
    [[ "$output" == *"Pre-flight checks"* ]]
    # Should have at least one [PASS], [WARN], or [FAIL]
    [[ "$output" =~ \[(PASS|WARN|FAIL|SKIP)\] ]]
}

@test "preflight_checks: offline profile skips internet check" {
    export DEPLOY_PROFILE="offline"
    run preflight_checks
    [[ "$output" == *"[SKIP]"* ]] || [[ "$output" == *"offline"* ]]
}

# ============================================================================
# INIT DEFAULTS INTEGRATION
# ============================================================================

@test "detect functions work with init_detected_defaults pre-set" {
    # common.sh already called init_detected_defaults
    # Verify detect functions can override the defaults
    detect_os
    [ "$DETECTED_OS" != "unknown" ] || [ "$(uname)" != "Linux" ]

    detect_ram
    [ "$DETECTED_RAM_TOTAL_MB" -gt 0 ]

    detect_disk
    [ "$DETECTED_DISK_FREE_GB" -gt 0 ]
}
