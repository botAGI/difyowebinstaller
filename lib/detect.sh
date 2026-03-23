#!/usr/bin/env bash
# detect.sh — System diagnostics: OS, GPU, RAM, disk, ports, Docker, network.
# Dependencies: common.sh (colors, log_*, init_detected_defaults)
# Exports: DETECTED_OS, DETECTED_OS_VERSION, DETECTED_OS_NAME, DETECTED_ARCH,
#          DETECTED_GPU, DETECTED_GPU_NAME, DETECTED_GPU_VRAM, DETECTED_GPU_COMPUTE,
#          DETECTED_RAM_TOTAL_MB, DETECTED_RAM_AVAILABLE_MB,
#          DETECTED_RAM_TOTAL_GB, DETECTED_RAM_AVAILABLE_GB,
#          DETECTED_DISK_FREE_GB,
#          DETECTED_DOCKER_INSTALLED, DETECTED_DOCKER_VERSION, DETECTED_DOCKER_COMPOSE,
#          DETECTED_NETWORK, DOCKER_PLATFORM, PORTS_IN_USE,
#          RECOMMENDED_MODEL, RECOMMENDED_REASON
# Functions: run_diagnostics(), preflight_checks()
# ENV overrides: FORCE_GPU_TYPE, SKIP_GPU_DETECT, SKIP_PREFLIGHT
set -euo pipefail

# ============================================================================
# OS DETECTION
# ============================================================================

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DETECTED_OS="${ID:-unknown}"
        DETECTED_OS_VERSION="${VERSION_ID:-}"
        DETECTED_OS_NAME="${PRETTY_NAME:-${ID:-unknown}}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        DETECTED_OS="macos"
        DETECTED_OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "0")"
        DETECTED_OS_NAME="macOS ${DETECTED_OS_VERSION}"
    else
        DETECTED_OS="unknown"
        DETECTED_OS_VERSION="0"
        DETECTED_OS_NAME="Unknown OS"
    fi
    DETECTED_ARCH="$(uname -m)"
    export DETECTED_OS DETECTED_OS_VERSION DETECTED_OS_NAME DETECTED_ARCH
}

# ============================================================================
# ARCHITECTURE / DOCKER PLATFORM
# ============================================================================

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  DOCKER_PLATFORM="linux/amd64" ;;
        aarch64|arm64) DOCKER_PLATFORM="linux/arm64" ;;
        armv7l)        DOCKER_PLATFORM="linux/arm/v7" ;;
        *)             DOCKER_PLATFORM="linux/amd64" ;;
    esac
    DETECTED_ARCH="$arch"
    export DOCKER_PLATFORM DETECTED_ARCH
}

# ============================================================================
# GPU DETECTION
# ============================================================================

detect_gpu() {
    DETECTED_GPU="none"
    DETECTED_GPU_NAME=""
    DETECTED_GPU_VRAM="0"
    DETECTED_GPU_COMPUTE=""

    # ENV override: force a specific GPU type
    if [[ -n "${FORCE_GPU_TYPE:-}" ]]; then
        case "${FORCE_GPU_TYPE}" in
            nvidia|amd|intel|apple|none)
                DETECTED_GPU="${FORCE_GPU_TYPE}"
                ;;
            *)
                log_warn "Unknown FORCE_GPU_TYPE '${FORCE_GPU_TYPE}', ignoring (valid: nvidia, amd, intel, apple, none)"
                ;;
        esac
        DETECTED_GPU_COMPUTE="${FORCE_GPU_COMPUTE:-}"
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM DETECTED_GPU_COMPUTE DETECTED_GPU_COMPUTE
        return 0
    fi

    # ENV override: skip detection entirely
    if [[ "${SKIP_GPU_DETECT:-false}" == "true" ]]; then
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM DETECTED_GPU_COMPUTE DETECTED_GPU_COMPUTE
        return 0
    fi

    # 1. NVIDIA — nvidia-smi
    if command -v nvidia-smi &>/dev/null; then
        local gpu_info
        gpu_info="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
        if [[ -n "$gpu_info" ]]; then
            DETECTED_GPU="nvidia"
            DETECTED_GPU_NAME="$(echo "$gpu_info" | head -1 | cut -d',' -f1 | xargs)"
            DETECTED_GPU_VRAM="$(echo "$gpu_info" | head -1 | cut -d',' -f2 | xargs)"
            [[ "${DETECTED_GPU_VRAM}" =~ ^[0-9]+$ ]] || DETECTED_GPU_VRAM="0"
            # Compute capability (e.g. "8.9", "12.0") — not all nvidia-smi versions support this
            DETECTED_GPU_COMPUTE="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | xargs || true)"
            [[ "${DETECTED_GPU_COMPUTE}" =~ ^[0-9]+\.[0-9]+$ ]] || DETECTED_GPU_COMPUTE=""
            export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM DETECTED_GPU_COMPUTE DETECTED_GPU_COMPUTE
            return 0
        fi
    fi

    # 2. AMD ROCm — /dev/kfd or rocminfo
    if [[ -e /dev/kfd ]] || command -v rocminfo &>/dev/null; then
        DETECTED_GPU="amd"
        DETECTED_GPU_NAME="$(rocminfo 2>/dev/null | grep 'Marketing Name' | head -1 | cut -d: -f2- | xargs 2>/dev/null || echo "")"
        DETECTED_GPU_VRAM="$(rocm-smi --showmeminfo vram 2>/dev/null | grep 'Total' | awk '{print $NF}' || echo "0")"
        [[ "${DETECTED_GPU_VRAM}" =~ ^[0-9]+$ ]] || DETECTED_GPU_VRAM="0"
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM DETECTED_GPU_COMPUTE
        return 0
    fi

    # 3. Intel Arc — /dev/dri/renderD128 + lspci VGA Intel
    if [[ -e /dev/dri/renderD128 ]]; then
        if lspci 2>/dev/null | grep -qi 'vga.*intel'; then
            DETECTED_GPU="intel"
            DETECTED_GPU_NAME="$(lspci 2>/dev/null | grep -i 'vga.*intel' | head -1 | sed 's/.*: //' || echo "")"
            export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM DETECTED_GPU_COMPUTE
            return 0
        fi
    fi

    # 4. Apple Silicon — arm64 Darwin
    if [[ "$(uname -m)" == "arm64" && "$(uname -s)" == "Darwin" ]]; then
        DETECTED_GPU="apple"
        DETECTED_GPU_NAME="Apple Silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'M-series'))"
        log_warn "Apple Silicon uses Metal natively, Docker GPU passthrough not supported"
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM DETECTED_GPU_COMPUTE
        return 0
    fi

    # 5. CPU fallback — defaults already set
    export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM DETECTED_GPU_COMPUTE
}

# ============================================================================
# RAM DETECTION
# ============================================================================

detect_ram() {
    if [[ "$(uname)" == "Darwin" ]]; then
        DETECTED_RAM_TOTAL_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
        local pages_free pages_inactive page_size
        page_size="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"
        pages_free="$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')"
        pages_inactive="$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')"
        DETECTED_RAM_AVAILABLE_MB=$(( (${pages_free:-0} + ${pages_inactive:-0}) * page_size / 1024 / 1024 ))
    else
        DETECTED_RAM_TOTAL_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
        DETECTED_RAM_AVAILABLE_MB="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    fi
    # Ensure non-empty (awk returns empty if pattern not found)
    DETECTED_RAM_TOTAL_MB="${DETECTED_RAM_TOTAL_MB:-0}"
    DETECTED_RAM_AVAILABLE_MB="${DETECTED_RAM_AVAILABLE_MB:-0}"
    DETECTED_RAM_TOTAL_GB=$(( DETECTED_RAM_TOTAL_MB / 1024 ))
    DETECTED_RAM_AVAILABLE_GB=$(( DETECTED_RAM_AVAILABLE_MB / 1024 ))
    export DETECTED_RAM_TOTAL_MB DETECTED_RAM_AVAILABLE_MB DETECTED_RAM_TOTAL_GB DETECTED_RAM_AVAILABLE_GB
}

# ============================================================================
# DISK DETECTION
# ============================================================================

detect_disk() {
    if [[ "$(uname)" == "Darwin" ]]; then
        DETECTED_DISK_FREE_GB="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
    else
        DETECTED_DISK_FREE_GB="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
    fi
    DETECTED_DISK_FREE_GB="${DETECTED_DISK_FREE_GB:-0}"
    export DETECTED_DISK_FREE_GB
}

# ============================================================================
# PORT DETECTION
# ============================================================================

detect_ports() {
    PORTS_IN_USE=""
    local check_ports=(80 443 3000 5001 8080 11434)
    for port in "${check_ports[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           lsof -i ":${port}" -sTCP:LISTEN &>/dev/null 2>&1; then
            PORTS_IN_USE="${PORTS_IN_USE}${port} "
        fi
    done
    export PORTS_IN_USE
}

# ============================================================================
# DOCKER DETECTION
# ============================================================================

detect_docker() {
    DETECTED_DOCKER_INSTALLED="false"
    DETECTED_DOCKER_VERSION=""
    DETECTED_DOCKER_COMPOSE="false"

    if command -v docker &>/dev/null; then
        DETECTED_DOCKER_INSTALLED="true"
        DETECTED_DOCKER_VERSION="$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")"
        if docker compose version &>/dev/null 2>&1; then
            DETECTED_DOCKER_COMPOSE="true"
        fi
    fi
    export DETECTED_DOCKER_INSTALLED DETECTED_DOCKER_VERSION DETECTED_DOCKER_COMPOSE
}

# ============================================================================
# NETWORK DETECTION
# ============================================================================

detect_network() {
    DETECTED_NETWORK="false"
    if command -v curl &>/dev/null; then
        if curl -sf --connect-timeout 5 https://hub.docker.com >/dev/null 2>&1; then
            DETECTED_NETWORK="true"
        fi
    elif command -v wget &>/dev/null; then
        if wget -q --timeout=5 --spider https://hub.docker.com 2>/dev/null; then
            DETECTED_NETWORK="true"
        fi
    fi
    export DETECTED_NETWORK
}

# ============================================================================
# MODEL RECOMMENDATION
# ============================================================================

recommend_model() {
    local ram_gb="${DETECTED_RAM_TOTAL_GB:-0}"
    local gpu="${DETECTED_GPU:-none}"
    local vram="${DETECTED_GPU_VRAM:-0}"

    # Use VRAM if GPU available, otherwise fallback to RAM
    local effective_mem="$ram_gb"
    if [[ "$gpu" == "nvidia" || "$gpu" == "amd" ]] && [[ "${vram:-0}" -gt 0 ]]; then
        effective_mem=$(( vram / 1024 ))
    fi

    if [[ "$effective_mem" -ge 48 ]]; then
        RECOMMENDED_MODEL="qwen2.5:72b-instruct-q4_K_M"
        RECOMMENDED_REASON="48GB+ VRAM/RAM"
    elif [[ "$effective_mem" -ge 24 ]]; then
        RECOMMENDED_MODEL="qwen2.5:32b"
        RECOMMENDED_REASON="24GB+ VRAM/RAM"
    elif [[ "$effective_mem" -ge 12 ]]; then
        RECOMMENDED_MODEL="qwen2.5:14b"
        RECOMMENDED_REASON="12GB+ VRAM/RAM"
    elif [[ "$effective_mem" -ge 6 ]]; then
        RECOMMENDED_MODEL="qwen2.5:7b"
        RECOMMENDED_REASON="6GB+ VRAM/RAM"
    else
        RECOMMENDED_MODEL="gemma3:4b"
        RECOMMENDED_REASON="<6GB RAM"
    fi
    export RECOMMENDED_MODEL RECOMMENDED_REASON
}

# ============================================================================
# RUN DIAGNOSTICS (Phase 1 main function)
# ============================================================================

run_diagnostics() {
    echo -e "${CYAN}=== System Diagnostics ===${NC}"
    echo ""

    detect_os
    detect_arch
    echo -e "  OS:           ${GREEN}${DETECTED_OS_NAME}, ${DETECTED_ARCH}${NC}"
    echo -e "  Platform:     ${GREEN}${DOCKER_PLATFORM}${NC}"

    detect_gpu
    case "${DETECTED_GPU}" in
        nvidia) echo -e "  GPU:          ${GREEN}NVIDIA ${DETECTED_GPU_NAME} (${DETECTED_GPU_VRAM} MB VRAM${DETECTED_GPU_COMPUTE:+, sm ${DETECTED_GPU_COMPUTE}})${NC}" ;;
        amd)    echo -e "  GPU:          ${GREEN}AMD ${DETECTED_GPU_NAME} ${DETECTED_GPU_VRAM:+(${DETECTED_GPU_VRAM} MB VRAM)}${NC}" ;;
        intel)  echo -e "  GPU:          ${GREEN}Intel ${DETECTED_GPU_NAME}${NC}" ;;
        apple)  echo -e "  GPU:          ${GREEN}${DETECTED_GPU_NAME} (Metal)${NC}" ;;
        *)      echo -e "  GPU:          ${YELLOW}Not detected (CPU only)${NC}" ;;
    esac

    detect_ram
    echo -e "  RAM:          ${GREEN}${DETECTED_RAM_TOTAL_GB}GB (${DETECTED_RAM_AVAILABLE_GB}GB available)${NC}"
    if [[ "${DETECTED_RAM_TOTAL_GB}" -lt 4 ]]; then
        echo -e "                ${RED}WARNING: minimum 4GB RAM, 16GB+ recommended${NC}"
    elif [[ "${DETECTED_RAM_TOTAL_GB}" -lt 16 ]]; then
        echo -e "                ${YELLOW}16GB+ recommended for full stack${NC}"
    fi

    detect_disk
    echo -e "  Disk:         ${GREEN}${DETECTED_DISK_FREE_GB}GB free${NC}"
    if [[ "${DETECTED_DISK_FREE_GB}" -lt 30 ]]; then
        echo -e "                ${RED}WARNING: minimum 30GB, 50GB+ recommended${NC}"
    fi

    detect_ports
    if [[ -n "${PORTS_IN_USE}" ]]; then
        echo -e "  Ports:        ${YELLOW}In use: ${PORTS_IN_USE}${NC}"
    else
        echo -e "  Ports:        ${GREEN}80, 443, 3000, 5001, 8080, 11434 free${NC}"
    fi

    detect_docker
    if [[ "${DETECTED_DOCKER_INSTALLED}" == "true" ]]; then
        echo -e "  Docker:       ${GREEN}${DETECTED_DOCKER_VERSION}${NC}"
        if [[ "${DETECTED_DOCKER_COMPOSE}" == "true" ]]; then
            echo -e "  Compose:      ${GREEN}installed${NC}"
        else
            echo -e "  Compose:      ${YELLOW}not installed${NC}"
        fi
    else
        echo -e "  Docker:       ${YELLOW}not installed${NC}"
    fi

    detect_network
    if [[ "${DETECTED_NETWORK}" == "true" ]]; then
        echo -e "  Network:      ${GREEN}available${NC}"
    else
        echo -e "  Network:      ${YELLOW}unavailable${NC}"
    fi

    recommend_model
    echo ""

    # Validate minimum requirements
    local errors=0
    if [[ "${DETECTED_RAM_TOTAL_GB}" -lt 4 ]]; then
        log_error "Insufficient RAM (minimum 4GB)"
        errors=$((errors + 1))
    fi
    if [[ "${DETECTED_DISK_FREE_GB}" -lt 30 ]]; then
        log_error "Insufficient disk space (minimum 30GB)"
        errors=$((errors + 1))
    fi

    return "$errors"
}

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

preflight_checks() {
    if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then
        log_warn "Pre-flight checks skipped (SKIP_PREFLIGHT=true)"
        return 0
    fi

    echo -e "${BOLD}Pre-flight checks:${NC}"
    echo ""

    local errors=0
    local warnings=0

    # --- 1. OS version ---
    if [[ -f /etc/os-release ]]; then
        local os_name os_ver
        os_name="$(. /etc/os-release && echo "$ID")"
        os_ver="$(. /etc/os-release && echo "${VERSION_ID:-0}")"
        case "$os_name" in
            ubuntu)
                local os_major="${os_ver%%.*}"
                local os_minor="${os_ver#*.}"; os_minor="${os_minor%%.*}"
                if [[ "$os_major" -gt 20 ]] 2>/dev/null || \
                   [[ "$os_major" -eq 20 && "${os_minor:-0}" -ge 4 ]] 2>/dev/null; then
                    echo -e "  ${GREEN}[PASS]${NC} OS: Ubuntu ${os_ver}"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} OS: Ubuntu ${os_ver} (20.04+ recommended)"
                    warnings=$((warnings + 1))
                fi ;;
            debian)
                if [[ "${os_ver%%.*}" -ge 11 ]] 2>/dev/null; then
                    echo -e "  ${GREEN}[PASS]${NC} OS: Debian ${os_ver}"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} OS: Debian ${os_ver} (11+ recommended)"
                    warnings=$((warnings + 1))
                fi ;;
            centos|rhel|rocky|almalinux)
                if [[ "${os_ver%%.*}" -ge 8 ]] 2>/dev/null; then
                    echo -e "  ${GREEN}[PASS]${NC} OS: ${os_name} ${os_ver}"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} OS: ${os_name} ${os_ver} (8+ recommended)"
                    warnings=$((warnings + 1))
                fi ;;
            fedora)
                if [[ "${os_ver%%.*}" -ge 38 ]] 2>/dev/null; then
                    echo -e "  ${GREEN}[PASS]${NC} OS: Fedora ${os_ver}"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} OS: Fedora ${os_ver} (38+ recommended)"
                    warnings=$((warnings + 1))
                fi ;;
            *)
                echo -e "  ${YELLOW}[WARN]${NC} OS: ${os_name} ${os_ver} (untested)"
                warnings=$((warnings + 1)) ;;
        esac
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        echo -e "  ${YELLOW}[WARN]${NC} OS: macOS (development only)"
        warnings=$((warnings + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} OS: unknown"
        warnings=$((warnings + 1))
    fi

    # --- 2. Docker version >= 24.0 ---
    if command -v docker &>/dev/null; then
        local docker_ver docker_major
        docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")"
        docker_major="${docker_ver%%.*}"
        if [[ "$docker_major" -ge 24 ]] 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} Docker: v${docker_ver}"
        elif [[ "$docker_major" -ge 20 ]] 2>/dev/null; then
            echo -e "  ${YELLOW}[WARN]${NC} Docker: v${docker_ver} (24.0+ recommended)"
            warnings=$((warnings + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} Docker: v${docker_ver} (24.0+ required)"
            errors=$((errors + 1))
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} Docker: not installed (will be installed automatically)"
        warnings=$((warnings + 1))
    fi

    # --- 3. Docker Compose >= 2.20 ---
    if docker compose version &>/dev/null 2>&1; then
        local compose_ver compose_major compose_minor
        compose_ver="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
        compose_major="${compose_ver%%.*}"
        compose_minor="${compose_ver#*.}"; compose_minor="${compose_minor%%.*}"
        if [[ "$compose_major" -gt 2 ]] 2>/dev/null || \
           [[ "$compose_major" -eq 2 && "$compose_minor" -ge 20 ]] 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} Docker Compose: v${compose_ver}"
        else
            echo -e "  ${YELLOW}[WARN]${NC} Docker Compose: v${compose_ver} (2.20+ recommended)"
            warnings=$((warnings + 1))
        fi
    elif command -v docker &>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} Docker Compose: not found"
        warnings=$((warnings + 1))
    fi

    # --- 4. Disk space ---
    local disk_gb
    if [[ "$(uname)" == "Darwin" ]]; then
        disk_gb="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
    else
        disk_gb="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')"
    fi
    disk_gb="${disk_gb:-0}"
    if [[ "$disk_gb" -ge 30 ]] 2>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} Disk: ${disk_gb}GB free"
    elif [[ "$disk_gb" -ge 20 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} Disk: ${disk_gb}GB free (30GB+ recommended)"
        warnings=$((warnings + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Disk: ${disk_gb}GB free (30GB+ required)"
        errors=$((errors + 1))
    fi

    # --- 5. RAM >= 4GB ---
    local ram_gb="${DETECTED_RAM_TOTAL_GB:-0}"
    if [[ "$ram_gb" -ge 8 ]] 2>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} RAM: ${ram_gb}GB"
    elif [[ "$ram_gb" -ge 4 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} RAM: ${ram_gb}GB (8GB+ recommended for full stack)"
        warnings=$((warnings + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} RAM: ${ram_gb}GB (4GB minimum required)"
        errors=$((errors + 1))
    fi

    # --- 6. CPU cores >= 2 ---
    local cpu_cores
    cpu_cores="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "1")"
    if [[ "$cpu_cores" -ge 4 ]] 2>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} CPU: ${cpu_cores} cores"
    elif [[ "$cpu_cores" -ge 2 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} CPU: ${cpu_cores} cores (4+ recommended)"
        warnings=$((warnings + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} CPU: ${cpu_cores} core (2+ required)"
        errors=$((errors + 1))
    fi

    # --- 7. Key ports ---
    # Check if agmind nginx owns the port (reinstall scenario should not warn)
    local agmind_nginx_up=false
    if docker compose -f "${INSTALL_DIR:-/opt/agmind}/docker/docker-compose.yml" ps --status running nginx 2>/dev/null | grep -q nginx; then
        agmind_nginx_up=true
    fi
    for port in 80 443; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           lsof -i ":${port}" -sTCP:LISTEN &>/dev/null 2>&1; then
            if [[ "$agmind_nginx_up" == "true" ]]; then
                echo -e "  ${GREEN}[PASS]${NC} Port ${port}: in use (agmind)"
            else
                echo -e "  ${YELLOW}[WARN]${NC} Port ${port}: in use"
                warnings=$((warnings + 1))
            fi
        else
            echo -e "  ${GREEN}[PASS]${NC} Port ${port}: free"
        fi
    done

    # --- 8. Docker daemon running ---
    if command -v docker &>/dev/null; then
        if docker info &>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} Docker daemon: running"
        else
            echo -e "  ${YELLOW}[WARN]${NC} Docker daemon: not running"
            warnings=$((warnings + 1))
        fi
    fi

    # --- 9. Docker socket ---
    if [[ -S /var/run/docker.sock ]]; then
        if [[ -r /var/run/docker.sock ]]; then
            echo -e "  ${GREEN}[PASS]${NC} Docker socket: accessible"
        else
            echo -e "  ${YELLOW}[WARN]${NC} Docker socket: no read permission"
            warnings=$((warnings + 1))
        fi
    elif command -v docker &>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} Docker socket: /var/run/docker.sock not found"
        warnings=$((warnings + 1))
    fi

    # --- 10. Internet connectivity ---
    if [[ "${DEPLOY_PROFILE:-}" != "offline" ]]; then
        if curl -sf --connect-timeout 5 https://hub.docker.com >/dev/null 2>&1 || \
           wget -q --spider --timeout=5 https://hub.docker.com 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} Internet: available"
        else
            echo -e "  ${YELLOW}[WARN]${NC} Internet: unavailable (required for image pulls)"
            warnings=$((warnings + 1))
        fi
    else
        echo -e "  ${CYAN}[SKIP]${NC} Internet: skipped (offline profile)"
    fi

    # --- Summary ---
    echo ""
    if [[ $errors -gt 0 ]]; then
        echo -e "  ${RED}Errors: ${errors}, Warnings: ${warnings}${NC}"
        echo -e "  ${RED}Fix errors before continuing.${NC}"
    elif [[ $warnings -gt 0 ]]; then
        echo -e "  ${YELLOW}Warnings: ${warnings} (installation can proceed)${NC}"
    else
        echo -e "  ${GREEN}All checks passed!${NC}"
    fi
    echo ""

    return "$errors"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Source common.sh for colors and logging
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    run_diagnostics
fi
