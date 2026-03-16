#!/usr/bin/env bash
# docker.sh — Install Docker, Docker Compose, and nvidia-container-toolkit
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

install_docker() {
    if [[ "$DETECTED_DOCKER_INSTALLED" == "true" && "$DETECTED_DOCKER_COMPOSE" == "true" ]]; then
        echo -e "${GREEN}Docker и Compose уже установлены${NC}"
        return 0
    fi

    echo -e "${YELLOW}Установка Docker...${NC}"

    case "$DETECTED_OS" in
        ubuntu|debian)
            install_docker_debian
            ;;
        centos|rhel|rocky|almalinux|fedora)
            install_docker_rhel
            ;;
        macos)
            install_docker_macos
            ;;
        *)
            echo -e "${RED}Неподдерживаемая ОС: $DETECTED_OS${NC}"
            echo "Установите Docker вручную: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac

    # Verify installation
    if ! docker --version &>/dev/null; then
        echo -e "${RED}Docker не установился корректно${NC}"
        return 1
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}Docker Compose plugin не установился${NC}"
        return 1
    fi

    echo -e "${GREEN}Docker установлен успешно${NC}"
}

install_docker_debian() {
    export DEBIAN_FRONTEND=noninteractive

    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$DETECTED_OS/gpg" | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    local arch
    arch=$(dpkg --print-architecture)
    local codename
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$DETECTED_OS $codename stable" | \
        tee /etc/apt/sources.list.d/docker.list >/dev/null

    # Install Docker
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start
    systemctl enable --now docker

    # Add current user to docker group
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        echo -e "${YELLOW}Пользователь $SUDO_USER добавлен в группу docker${NC}"
    fi
}

install_docker_rhel() {
    # Remove old versions
    yum remove -y docker docker-client docker-client-latest docker-common \
        docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

    # Install prerequisites
    yum install -y yum-utils

    # Add Docker repository
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    # Install Docker
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start
    systemctl enable --now docker

    # Add current user to docker group
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        echo -e "${YELLOW}Пользователь $SUDO_USER добавлен в группу docker${NC}"
    fi
}

install_docker_macos() {
    if command -v docker &>/dev/null; then
        echo -e "${GREEN}Docker Desktop обнаружен${NC}"
        return 0
    fi
    echo -e "${RED}Docker Desktop не установлен.${NC}"
    echo "Скачайте и установите Docker Desktop:"
    echo "  https://www.docker.com/products/docker-desktop/"
    echo ""
    echo "После установки запустите Docker Desktop и повторите установку."
    return 1
}

install_nvidia_toolkit() {
    if [[ "$DETECTED_GPU" != "nvidia" ]]; then
        return 0
    fi

    echo -e "${YELLOW}Установка NVIDIA Container Toolkit...${NC}"

    # Check if already installed
    if dpkg -l nvidia-container-toolkit &>/dev/null 2>&1 || \
       rpm -q nvidia-container-toolkit &>/dev/null 2>&1; then
        echo -e "${GREEN}NVIDIA Container Toolkit уже установлен${NC}"
        return 0
    fi

    case "$DETECTED_OS" in
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
            yum install -y nvidia-container-toolkit
            ;;
        *)
            echo -e "${YELLOW}Установите nvidia-container-toolkit вручную${NC}"
            return 0
            ;;
    esac

    # Configure Docker runtime
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    echo -e "${GREEN}NVIDIA Container Toolkit установлен${NC}"
}

configure_docker_dns() {
    # systemd-resolved stub mode (127.0.0.53) breaks Docker DNS.
    # Docker sees loopback DNS → uses embedded resolver 127.0.0.11
    # which can't forward queries on these systems.
    # Fix: symlink resolv.conf to the real resolver file with upstream DNS.
    # Ref: https://docs.docker.com/engine/daemon/troubleshoot/#dns-resolver-found-in-resolvconf-and-containers-cant-resolve-dns

    # Only apply if resolv.conf points to stub-resolv.conf
    if ! readlink -f /etc/resolv.conf 2>/dev/null | grep -q 'stub-resolv'; then
        return 0
    fi

    # Check that the real resolv.conf exists
    if [[ ! -f /run/systemd/resolve/resolv.conf ]]; then
        echo -e "${YELLOW}systemd-resolved stub detected but /run/systemd/resolve/resolv.conf not found${NC}"
        return 0
    fi

    echo -e "${YELLOW}Переключение resolv.conf со stub на реальный DNS...${NC}"
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

    # Restart Docker so it picks up the new resolv.conf
    if systemctl is-active docker &>/dev/null; then
        systemctl restart docker
    fi

    echo -e "${GREEN}Docker DNS: $(grep -m2 'nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')${NC}"
}

setup_docker() {
    install_docker
    configure_docker_dns
    install_nvidia_toolkit
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_docker
fi
