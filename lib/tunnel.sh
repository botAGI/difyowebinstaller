#!/usr/bin/env bash
# tunnel.sh — Setup reverse SSH tunnel with autossh (LAN profile only)
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

setup_tunnel() {
    local vps_host="${TUNNEL_VPS_HOST:-}"
    local vps_port="${TUNNEL_VPS_PORT:-22}"
    local remote_port="${TUNNEL_REMOTE_PORT:-8080}"
    local local_port="${TUNNEL_LOCAL_PORT:-80}"
    local ssh_remote_port="${TUNNEL_SSH_REMOTE_PORT:-8022}"

    if [[ -z "$vps_host" ]]; then
        echo -e "${YELLOW}Reverse SSH tunnel не настроен (VPS хост не указан)${NC}"
        return 0
    fi

    echo -e "${YELLOW}Настройка reverse SSH tunnel...${NC}"

    # Install autossh
    if ! command -v autossh &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq autossh
        elif command -v yum &>/dev/null; then
            yum install -y autossh
        else
            echo -e "${RED}Не удалось установить autossh${NC}"
            return 1
        fi
    fi

    # Generate SSH key for tunnel
    local ssh_dir="${INSTALL_DIR}/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ ! -f "${ssh_dir}/tunnel_key" ]]; then
        ssh-keygen -t ed25519 -f "${ssh_dir}/tunnel_key" -N "" -C "agmind-tunnel-$(hostname)"
        echo ""
        echo -e "${YELLOW}=== ВАЖНО ===${NC}"
        echo "Добавьте этот публичный ключ на VPS (${vps_host}),"
        echo "пользователю tunnel:"
        echo ""
        cat "${ssh_dir}/tunnel_key.pub"
        echo ""
        echo "Команда для VPS:"
        echo "  echo '$(cat "${ssh_dir}/tunnel_key.pub")' >> /home/tunnel/.ssh/authorized_keys"
        echo ""
    fi

    # Create systemd service
    # IMPORTANT: Use 127.0.0.1 (not 0.0.0.0) to avoid exposing ports to the internet
    # Two tunnels:
    #   1. Web access: VPS:remote_port → node:local_port (HTTP)
    #   2. SSH access: VPS:ssh_remote_port → node:22 (for Dokploy)
    cat > /etc/systemd/system/agmind-tunnel.service << TUNNELEOF
[Unit]
Description=AGMind Reverse SSH Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/autossh -M 0 -N \
  -o "ServerAliveInterval=15" \
  -o "ServerAliveCountMax=3" \
  -o "ExitOnForwardFailure=yes" \
  -o "StrictHostKeyChecking=accept-new" \
  -R 127.0.0.1:${remote_port}:localhost:${local_port} \
  -R 127.0.0.1:${ssh_remote_port}:localhost:22 \
  -i ${ssh_dir}/tunnel_key \
  -p ${vps_port} tunnel@${vps_host}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
TUNNELEOF

    systemctl daemon-reload
    systemctl enable agmind-tunnel

    echo -e "${GREEN}Reverse SSH tunnel настроен${NC}"
    echo "  VPS: ${vps_host}:${vps_port}"
    echo "  Web:  VPS 127.0.0.1:${remote_port} → node localhost:${local_port}"
    echo "  SSH:  VPS 127.0.0.1:${ssh_remote_port} → node localhost:22 (для Dokploy)"
    echo ""
    echo "Запустите после добавления ключа на VPS:"
    echo "  systemctl start agmind-tunnel"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_tunnel
fi
