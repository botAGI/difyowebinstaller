#!/usr/bin/env bash
# docker.sh — Install Docker CE + Compose plugin + NVIDIA toolkit + DNS fix.
# Dependencies: common.sh (log_*), detect.sh (DETECTED_OS, DETECTED_GPU, DETECTED_DOCKER_*)
# Functions: setup_docker()
# ENV overrides: SKIP_DNS_FIX, DOCKER_DNS, DEPLOY_PROFILE
set -euo pipefail

# ============================================================================
# DOCKER INSTALLATION
# ============================================================================

install_docker() {
    if [[ "${DETECTED_DOCKER_INSTALLED:-false}" == "true" && "${DETECTED_DOCKER_COMPOSE:-false}" == "true" ]]; then
        log_success "Docker and Compose already installed"
        return 0
    fi

    log_info "Installing Docker..."

    case "${DETECTED_OS:-unknown}" in
        ubuntu|debian)
            _install_docker_debian
            ;;
        centos|rhel|rocky|almalinux)
            _install_docker_rhel "yum"
            ;;
        fedora)
            _install_docker_rhel "dnf"
            ;;
        macos)
            _install_docker_macos
            ;;
        *)
            log_error "Unsupported OS: ${DETECTED_OS:-unknown}"
            echo "Install Docker manually: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac

    # Verify installation
    if ! docker --version &>/dev/null; then
        log_error "Docker installation failed"
        return 1
    fi
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose plugin not installed"
        return 1
    fi

    log_success "Docker installed successfully"
}

_install_docker_debian() {
    export DEBIAN_FRONTEND=noninteractive

    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    (umask 022; curl -fsSL "https://download.docker.com/linux/${DETECTED_OS:-ubuntu}/gpg" | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg)

    # Add Docker repository
    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DETECTED_OS:-ubuntu} ${codename} stable" | \
        tee /etc/apt/sources.list.d/docker.list >/dev/null

    # Install Docker CE + Compose
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start
    systemctl enable --now docker

    _add_user_to_docker_group
}

_install_docker_rhel() {
    local pkg_mgr="${1:-yum}"

    # Remove old versions
    "$pkg_mgr" remove -y docker docker-client docker-client-latest docker-common \
        docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

    # Install prerequisites and add repo
    if [[ "$pkg_mgr" == "dnf" ]]; then
        dnf install -y dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    else
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi

    # Install Docker CE + Compose
    "$pkg_mgr" install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start
    systemctl enable --now docker

    _add_user_to_docker_group
}

_install_docker_macos() {
    if command -v docker &>/dev/null; then
        log_success "Docker Desktop detected"
        return 0
    fi
    log_error "Docker Desktop not installed."
    echo "Download and install Docker Desktop:"
    echo "  https://www.docker.com/products/docker-desktop/"
    echo ""
    echo "After installation, start Docker Desktop and re-run the installer."
    return 1
}

_add_user_to_docker_group() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "User ${SUDO_USER} added to docker group"
    fi
}

# ============================================================================
# NVIDIA CONTAINER TOOLKIT
# ============================================================================

install_nvidia_toolkit() {
    if [[ "${DETECTED_GPU:-none}" != "nvidia" ]]; then
        return 0
    fi

    log_info "Installing NVIDIA Container Toolkit..."

    # Check if already installed
    if dpkg -l nvidia-container-toolkit &>/dev/null 2>&1 || \
       rpm -q nvidia-container-toolkit &>/dev/null 2>&1; then
        log_success "NVIDIA Container Toolkit already installed"
        return 0
    fi

    case "${DETECTED_OS:-unknown}" in
        ubuntu|debian)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
                gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

            apt-get update -qq
            apt-get install -y -qq nvidia-container-toolkit
            ;;
        centos|rhel|rocky|almalinux|fedora)
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
                tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
            if command -v dnf &>/dev/null; then
                dnf install -y nvidia-container-toolkit
            else
                yum install -y nvidia-container-toolkit
            fi
            ;;
        *)
            log_warn "Install nvidia-container-toolkit manually for ${DETECTED_OS:-unknown}"
            return 0
            ;;
    esac

    # Configure Docker runtime
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    log_success "NVIDIA Container Toolkit installed"
}

# ============================================================================
# DNS FIX (systemd-resolved stub)
# ============================================================================
# systemd-resolved stub mode (127.0.0.53) breaks Docker DNS.
# Docker sees loopback DNS → uses embedded resolver 127.0.0.11
# which can't forward queries on these systems.
# Fix: disable stub listener, preserve existing DNS, symlink resolv.conf.
# Ref: https://docs.docker.com/engine/daemon/troubleshoot/#dns-resolver-found-in-resolvconf-and-containers-cant-resolve-dns

configure_docker_dns() {
    # Skip for offline profile
    if [[ "${DEPLOY_PROFILE:-}" == "offline" ]]; then
        log_info "Offline profile: skipping DNS configuration"
        return 0
    fi

    # Allow user to skip DNS changes
    if [[ "${SKIP_DNS_FIX:-false}" == "true" ]]; then
        log_info "SKIP_DNS_FIX=true: skipping DNS configuration"
        return 0
    fi

    # Only apply if resolv.conf is a symlink pointing to stub-resolv
    if ! [[ -L /etc/resolv.conf ]] || ! readlink /etc/resolv.conf | grep -q stub; then
        return 0
    fi

    log_info "systemd-resolved stub detected — configuring Docker DNS..."

    # Detect current upstream DNS servers from systemd-resolved
    local dns_servers=""
    if command -v resolvectl &>/dev/null; then
        dns_servers="$(resolvectl status 2>/dev/null | grep -A1 'DNS Servers' | tail -1 | xargs 2>/dev/null || true)"
    fi
    # Filter out loopback addresses (127.x.x.x)
    dns_servers="$(echo "$dns_servers" | tr ' ' '\n' | grep -v '^127\.' | tr '\n' ' ' | xargs)"

    # Fallback to public DNS if no upstream detected
    if [[ -z "$dns_servers" ]]; then
        dns_servers="${DOCKER_DNS:-8.8.8.8 1.1.1.1}"
        log_warn "No upstream DNS detected — using: ${dns_servers}"
    else
        log_success "Upstream DNS detected: ${dns_servers}"
    fi

    # Configure systemd-resolved
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/docker-fix.conf << DNSEOF
[Resolve]
DNS=${dns_servers}
DNSStubListener=no
DNSEOF

    # Atomic symlink switch to real resolver file
    ln -sf /run/systemd/resolve/resolv.conf "/etc/resolv.conf.tmp.$$" \
        && mv -f "/etc/resolv.conf.tmp.$$" /etc/resolv.conf

    # Restart resolved first (creates new resolv.conf), then Docker
    systemctl restart systemd-resolved 2>/dev/null || true
    if systemctl is-active docker &>/dev/null; then
        systemctl restart docker
    fi

    log_success "Docker DNS: $(grep -m2 'nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

setup_docker() {
    install_docker
    configure_docker_dns
    install_nvidia_toolkit
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    # shellcheck source=detect.sh
    source "${SCRIPT_DIR}/detect.sh"
    run_diagnostics || true
    setup_docker
fi
