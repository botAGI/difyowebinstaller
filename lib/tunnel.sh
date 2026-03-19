#!/usr/bin/env bash
# tunnel.sh — Reverse SSH tunnel via autossh for LAN/VPN profiles.
# Dependencies: common.sh (log_*)
# Functions: setup_tunnel()
# Expects: INSTALL_DIR, ENABLE_TUNNEL, TUNNEL_VPS_HOST, TUNNEL_VPS_PORT,
#          TUNNEL_REMOTE_PORT, TUNNEL_LOCAL_PORT, TUNNEL_SSH_REMOTE_PORT
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# SETUP TUNNEL
# ============================================================================

setup_tunnel() {
    if [[ "${ENABLE_TUNNEL:-false}" != "true" ]]; then
        return 0
    fi

    local vps_host="${TUNNEL_VPS_HOST:-}"
    local vps_port="${TUNNEL_VPS_PORT:-22}"
    local remote_port="${TUNNEL_REMOTE_PORT:-8080}"
    local local_port="${TUNNEL_LOCAL_PORT:-80}"
    local ssh_remote_port="${TUNNEL_SSH_REMOTE_PORT:-8022}"

    if [[ -z "$vps_host" ]]; then
        log_warn "Reverse SSH tunnel not configured (VPS host not set)"
        return 0
    fi

    log_info "Setting up reverse SSH tunnel..."

    # Install autossh
    if ! command -v autossh &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq autossh
        elif command -v dnf &>/dev/null; then
            dnf install -y autossh
        elif command -v yum &>/dev/null; then
            yum install -y autossh
        else
            log_error "Cannot install autossh automatically"
            return 1
        fi
    fi

    # Generate SSH key for tunnel
    local ssh_dir="${INSTALL_DIR}/.ssh"
    (
        umask 077
        mkdir -p "$ssh_dir"
    )

    if [[ ! -f "${ssh_dir}/tunnel_key" ]]; then
        ssh-keygen -t ed25519 -f "${ssh_dir}/tunnel_key" -N "" -C "agmind-tunnel-$(hostname)"
        echo ""
        log_warn "=== IMPORTANT ==="
        echo "Add this public key to VPS (${vps_host}), user 'tunnel':"
        echo ""
        cat "${ssh_dir}/tunnel_key.pub"
        echo ""
        echo "Command for VPS:"
        echo "  echo '$(cat "${ssh_dir}/tunnel_key.pub")' >> /home/tunnel/.ssh/authorized_keys"
        echo ""
    fi

    # Create systemd service
    # IMPORTANT: Bind to 127.0.0.1 (not 0.0.0.0) to avoid exposing ports
    # Two tunnels: web (HTTP) + SSH
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

    log_success "Reverse SSH tunnel configured"
    echo "  VPS: ${vps_host}:${vps_port}"
    echo "  Web:  VPS 127.0.0.1:${remote_port} -> node localhost:${local_port}"
    echo "  SSH:  VPS 127.0.0.1:${ssh_remote_port} -> node localhost:22"
    echo ""
    echo "Start after adding key to VPS:"
    echo "  systemctl start agmind-tunnel"
}

# Standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    setup_tunnel
fi
