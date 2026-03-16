#!/usr/bin/env bash
# dokploy.sh — Prepare node for Dokploy remote management (NO agent install)
# Dokploy lives ONLY on the central VPS. Nodes connect via SSH.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

setup_dokploy() {
    local profile="${DEPLOY_PROFILE:-lan}"

    # Skip for offline profile
    if [[ "$profile" == "offline" ]]; then
        echo -e "${YELLOW}Профиль offline: Dokploy пропущен${NC}"
        return 0
    fi

    local enable_dokploy="${DOKPLOY_ENABLED:-}"
    if [[ -z "$enable_dokploy" ]]; then
        echo -e "${YELLOW}Dokploy не настроен${NC}"
        return 0
    fi

    echo -e "${YELLOW}Подготовка ноды для Dokploy...${NC}"
    echo ""

    # Generate SSH key for Dokploy access (if not exists)
    local ssh_dir="${INSTALL_DIR}/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    local key_file="${ssh_dir}/dokploy_key"
    if [[ ! -f "$key_file" ]]; then
        ssh-keygen -t ed25519 -f "$key_file" -N "" -C "dokploy-$(hostname)-$(date +%Y%m%d)"
    fi

    # Add pubkey to authorized_keys on this node so Dokploy VPS can SSH in
    local pubkey
    pubkey=$(cat "${key_file}.pub")
    local auth_keys="${HOME}/.ssh/authorized_keys"
    mkdir -p "$(dirname "$auth_keys")"
    touch "$auth_keys"
    chmod 600 "$auth_keys"

    if ! grep -qF "$pubkey" "$auth_keys" 2>/dev/null; then
        echo "$pubkey" >> "$auth_keys"
    fi

    # Determine connection info based on profile
    local node_ip
    if [[ "$(uname)" == "Darwin" ]]; then
        node_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "UNKNOWN")
    else
        node_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "UNKNOWN")
    fi
    local ssh_port=22

    echo ""
    echo -e "${CYAN}=== Инструкция: добавление ноды в Dokploy ===${NC}"
    echo ""
    echo "1. Откройте Dokploy Dashboard на центральном VPS"
    echo "2. Перейдите: Settings → Servers → Add Server"
    echo "3. Заполните:"
    echo ""

    case "$profile" in
        vps)
            echo -e "   Name:        ${GREEN}$(hostname)${NC}"
            echo -e "   IP Address:  ${GREEN}${node_ip}${NC}"
            echo -e "   SSH Port:    ${GREEN}${ssh_port}${NC}"
            echo -e "   SSH Key:     скопируйте приватный ключ ниже"
            ;;
        lan)
            local tunnel_port="${TUNNEL_SSH_REMOTE_PORT:-8022}"
            local tunnel_host="${TUNNEL_VPS_HOST:-YOUR_VPS}"
            echo -e "   Name:        ${GREEN}$(hostname)${NC}"
            echo -e "   IP Address:  ${GREEN}127.0.0.1${NC}  (через SSH-туннель)"
            echo -e "   SSH Port:    ${GREEN}${tunnel_port}${NC}  (проброшенный порт на VPS)"
            echo -e "   SSH Key:     скопируйте приватный ключ ниже"
            echo ""
            echo -e "   ${YELLOW}Требуется reverse SSH tunnel (настраивается в lib/tunnel.sh)${NC}"
            echo "   Tunnel пробрасывает SSH порт ноды на VPS: 127.0.0.1:${tunnel_port}"
            ;;
        vpn)
            echo -e "   Name:        ${GREEN}$(hostname)${NC}"
            echo -e "   IP Address:  ${GREEN}${node_ip}${NC}  (VPN-адрес ноды)"
            echo -e "   SSH Port:    ${GREEN}${ssh_port}${NC}"
            echo -e "   SSH Key:     скопируйте приватный ключ ниже"
            echo ""
            echo -e "   ${YELLOW}Dokploy VPS должен быть в той же VPN-сети${NC}"
            ;;
    esac

    echo ""
    echo -e "${YELLOW}Приватный SSH ключ (скопируйте в Dokploy):${NC}"
    echo "------- BEGIN KEY -------"
    cat "$key_file"
    echo "------- END KEY -------"
    echo ""
    echo "Ключ также сохранён: ${key_file}"
    echo ""
    echo -e "${GREEN}Dokploy: нода подготовлена${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_dokploy
fi
