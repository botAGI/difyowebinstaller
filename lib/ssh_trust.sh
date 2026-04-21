#!/usr/bin/env bash
# ssh_trust.sh — Passwordless SSH bootstrap between master Spark and peer.
# Generates an isolated ed25519 key, uses sshpass for one-time ssh-copy-id,
# updates ~/.ssh/config for convenience. Password is NEVER written to disk.
#
# Dependencies: common.sh (log_*), tui.sh (wt_password), ssh-keygen, ssh-copy-id, sshpass
# Public API:
#   _ensure_ssh_trust <peer_ip> [peer_user]
#   _add_ssh_config_entry <peer_ip> [peer_user] [key_path]
#   _agmind_peer_ssh_opts
set -euo pipefail

# ============================================================================
# PUBLIC API
# ============================================================================

# _ensure_ssh_trust <peer_ip> [peer_user]
#   Ensures we can ssh to ${peer_user}@${peer_ip} using ed25519 key without
#   prompting for password. Creates key on first call, copies via sshpass,
#   verifies via BatchMode=yes.
#
# Returns:
#   0 — SSH trust established and verified
#   1 — failed (password wrong / peer unreachable / sshpass install failed)
_ensure_ssh_trust() {
    local peer_ip="${1:?peer_ip required}"
    local peer_user="${2:-${AGMIND_PEER_USER:-agmind2}}"
    local key_path="${AGMIND_PEER_SSH_KEY:-${HOME}/.ssh/agmind_peer_ed25519}"

    # 1. Generate key if missing
    if [[ ! -f "$key_path" ]]; then
        mkdir -p "$(dirname "$key_path")"
        chmod 0700 "$(dirname "$key_path")"
        ssh-keygen -t ed25519 \
            -C "agmind-peer-$(hostname -s 2>/dev/null || echo unknown)" \
            -f "$key_path" -N "" >/dev/null 2>&1 || {
            log_error "ssh-keygen failed — cannot create ${key_path}"
            return 1
        }
        chmod 0600 "$key_path"
        chmod 0644 "${key_path}.pub"
        log_info "Generated SSH key: ${key_path}.pub"
    fi

    # 2. Test BatchMode — if already works, skip password bootstrap
    if ssh -i "$key_path" \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
            "${peer_user}@${peer_ip}" true 2>/dev/null; then
        log_success "SSH trust already established with ${peer_user}@${peer_ip}"
        _add_ssh_config_entry "$peer_ip" "$peer_user" "$key_path" || true
        return 0
    fi

    # 3. Install sshpass if missing (one-time bootstrap dependency)
    if ! command -v sshpass >/dev/null 2>&1; then
        log_info "Installing sshpass for one-time SSH bootstrap..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q sshpass >/dev/null 2>&1 || {
                log_error "Cannot install sshpass. Manual fix:"
                log_error "  ssh-copy-id -i ${key_path}.pub ${peer_user}@${peer_ip}"
                return 1
            }
        else
            log_error "sshpass missing and apt-get unavailable — cannot bootstrap."
            log_error "Manual fix: ssh-copy-id -i ${key_path}.pub ${peer_user}@${peer_ip}"
            return 1
        fi
    fi

    # 4. Prompt for peer password via TUI (stays in memory only — never written to disk)
    local peer_password
    peer_password="$(wt_password \
        "SSH Bootstrap" \
        "Введите пароль для ${peer_user}@${peer_ip} (один раз, для установки SSH ключа):" \
    || true)"
    if [[ -z "$peer_password" ]]; then
        log_error "No password provided — SSH trust setup cancelled"
        return 1
    fi

    # 5. ssh-copy-id via sshpass -e (password via env var, not -p command line — safer)
    # SSHPASS set inline to prevent leaking into parent shell env or process list.
    if ! SSHPASS="$peer_password" sshpass -e ssh-copy-id \
            -i "${key_path}.pub" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
            "${peer_user}@${peer_ip}" >/dev/null 2>&1; then
        unset peer_password
        log_error "ssh-copy-id failed — check peer password, peer SSH availability, or peer user"
        return 1
    fi
    unset peer_password  # defence in depth: clear from this shell immediately

    # 6. Verify key-based auth works
    if ssh -i "$key_path" \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            "${peer_user}@${peer_ip}" true 2>/dev/null; then
        log_success "SSH trust established with ${peer_user}@${peer_ip}"
        _add_ssh_config_entry "$peer_ip" "$peer_user" "$key_path" || true
        return 0
    fi

    log_error "SSH key verification failed after copy-id — re-check peer sshd config"
    return 1
}

# ============================================================================
# SSH CONFIG — add Host entry for convenience (`ssh agmind-peer`)
# ============================================================================

# _add_ssh_config_entry <peer_ip> [peer_user] [key_path]
#   Adds a Host agmind-peer entry to ~/.ssh/config (idempotent by HostName).
_add_ssh_config_entry() {
    local peer_ip="${1:?peer_ip required}"
    local peer_user="${2:-agmind2}"
    local key_path="${3:-${HOME}/.ssh/agmind_peer_ed25519}"
    local config="${HOME}/.ssh/config"

    mkdir -p "$(dirname "$config")"
    touch "$config"
    chmod 0600 "$config"

    # Idempotent: skip if HostName already present
    if grep -qE "^\s*HostName\s+${peer_ip}\s*$" "$config" 2>/dev/null; then
        return 0
    fi

    cat >> "$config" <<EOF

# AGmind peer (added by lib/ssh_trust.sh)
Host agmind-peer
    HostName ${peer_ip}
    User ${peer_user}
    IdentityFile ${key_path}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF
}

# ============================================================================
# HELPER — standardized ssh options for scp/ssh in phase_deploy_peer
# ============================================================================

# _agmind_peer_ssh_opts
#   Echoes recommended SSH options string for use with ssh/scp in Plan 02-04.
#   Usage: ssh_opts="$(_agmind_peer_ssh_opts)"; ssh $ssh_opts ...
_agmind_peer_ssh_opts() {
    local key_path="${AGMIND_PEER_SSH_KEY:-${HOME}/.ssh/agmind_peer_ed25519}"
    printf '%s' "-i ${key_path} -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
}

# ============================================================================
# STANDALONE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    # shellcheck source=tui.sh
    source "${SCRIPT_DIR}/tui.sh"
    echo "ssh_trust.sh: source this file and call _ensure_ssh_trust <peer_ip> [peer_user]"
fi
