#!/usr/bin/env bash
# security.sh — UFW, fail2ban (SSH jail), SSH hardening, SOPS/age encryption, Docker hardening.
# Dependencies: common.sh (log_*, generate_random)
# Functions: setup_security(), configure_ufw(), configure_fail2ban(), harden_ssh(),
#            encrypt_secrets(), harden_docker_compose()
# Expects: INSTALL_DIR, DEPLOY_PROFILE, ENABLE_UFW, ENABLE_FAIL2BAN, ENABLE_SOPS,
#          ENABLE_SSH_HARDENING, MONITORING_MODE, NON_INTERACTIVE
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# UFW FIREWALL
# ============================================================================

configure_ufw() {
    if [[ "${ENABLE_UFW:-false}" != "true" ]]; then return 0; fi

    if ! command -v ufw &>/dev/null; then
        log_warn "UFW not found — skipping firewall. Install: apt install ufw"
        return 0
    fi

    log_info "Configuring UFW firewall..."

    # Backup existing rules
    if ufw status 2>/dev/null | grep -q "active"; then
        ufw status numbered > "/tmp/ufw-backup-$(date +%s).txt" 2>/dev/null || true
    fi

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh comment "SSH"
    ufw allow 80/tcp comment "AGMind HTTP"
    ufw allow 443/tcp comment "AGMind HTTPS"

    if [[ "${DEPLOY_PROFILE:-}" == "lan" ]]; then
        ufw allow from "${LAN_SUBNET:-192.168.0.0/16}" comment "LAN access"
    fi
    if [[ "${MONITORING_MODE:-none}" == "local" ]]; then
        ufw allow 3001/tcp comment "Grafana"
        ufw allow 9443/tcp comment "Portainer"
    fi

    ufw --force enable
    log_success "UFW configured"
    ufw status numbered
}

# ============================================================================
# FAIL2BAN (SSH JAIL ONLY)
# ============================================================================

configure_fail2ban() {
    if [[ "${ENABLE_FAIL2BAN:-false}" != "true" ]]; then return 0; fi

    log_info "Configuring fail2ban (SSH jail)..."

    # Install if missing
    if ! command -v fail2ban-server &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y fail2ban >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y fail2ban >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y fail2ban >/dev/null 2>&1
        else
            log_warn "Cannot install fail2ban automatically"
            return 0
        fi
    fi

    # SSH jail only — nginx rate limiting handles API protection
    cat > /etc/fail2ban/jail.d/agmind.conf << 'EOF'
[sshd]
enabled = true
maxretry = 3
bantime = 864000
findtime = 600
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    log_success "Fail2ban configured (SSH jail, maxretry=3, bantime=10d)"
}

# ============================================================================
# SSH HARDENING
# ============================================================================

harden_ssh() {
    if [[ "${ENABLE_SSH_HARDENING:-true}" == "false" ]]; then return 0; fi

    local sshd_config="/etc/ssh/sshd_config"
    [[ -f "$sshd_config" ]] || { log_warn "sshd_config not found — skipping SSH hardening"; return 0; }

    # Check if PasswordAuthentication is already disabled
    if grep -qE '^\s*PasswordAuthentication\s+no' "$sshd_config" 2>/dev/null; then
        log_info "SSH PasswordAuthentication already disabled"
        return 0
    fi

    # Check if any SSH keys are authorized for current login user
    local login_user
    login_user="$(logname 2>/dev/null || echo "${SUDO_USER:-root}")"
    local user_home
    user_home="$(eval echo "~${login_user}" 2>/dev/null || echo "/root")"
    local has_keys=false
    if [[ -f "${user_home}/.ssh/authorized_keys" ]] && [[ -s "${user_home}/.ssh/authorized_keys" ]]; then
        has_keys=true
    fi

    # ====== PROMINENT WARNING ======
    echo ""
    echo -e "${RED}${BOLD}  ╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}  ║           ВНИМАНИЕ: ОТКЛЮЧЕНИЕ SSH ПАРОЛЕЙ                ║${NC}"
    echo -e "${RED}${BOLD}  ╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Сейчас будет отключён вход по паролю через SSH."
    echo -e "  ${RED}Если у вас нет SSH-ключа — вы потеряете удалённый доступ!${NC}"
    echo ""

    if [[ "$has_keys" == "true" ]]; then
        echo -e "  ${GREEN}[OK] SSH-ключ найден:${NC} ${user_home}/.ssh/authorized_keys"
    else
        echo -e "  ${RED}[!!] SSH-ключ НЕ НАЙДЕН${NC} для пользователя ${login_user}"
        echo ""
        echo -e "  ${BOLD}Как настроить SSH-ключ (выполните на ЛОКАЛЬНОЙ машине):${NC}"
        echo ""
        echo -e "  ${CYAN}1. Сгенерируйте ключ (если нет):${NC}"
        echo -e "     ssh-keygen -t ed25519 -C \"your_email@example.com\""
        echo ""
        echo -e "  ${CYAN}2. Скопируйте ключ на сервер:${NC}"
        echo -e "     ssh-copy-id ${login_user}@$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'SERVER_IP')"
        echo ""
        echo -e "  ${CYAN}3. Проверьте вход по ключу (в новом терминале!):${NC}"
        echo -e "     ssh ${login_user}@$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'SERVER_IP')"
        echo ""
    fi

    # Ask confirmation (unless non-interactive)
    if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
        local answer
        echo -e "  Отключить вход по паролю? (yes/no): \c"
        read -r answer
        if [[ "$answer" != "yes" && "$answer" != "y" ]]; then
            log_warn "SSH hardening пропущен по выбору пользователя"
            return 0
        fi
    else
        if [[ "$has_keys" != "true" ]]; then
            log_warn "Non-interactive: SSH-ключ не найден, пропускаем отключение паролей"
            return 0
        fi
        log_info "Non-interactive: SSH-ключ найден, отключаем пароли"
    fi

    # Backup sshd_config
    cp "$sshd_config" "${sshd_config}.bak.$(date +%s)"

    # Disable PasswordAuthentication
    if grep -qE '^\s*#?\s*PasswordAuthentication' "$sshd_config"; then
        sed -i 's/^\s*#\?\s*PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
    else
        echo "PasswordAuthentication no" >> "$sshd_config"
    fi

    # Also disable ChallengeResponseAuthentication (prevents password fallback)
    if grep -qE '^\s*#?\s*ChallengeResponseAuthentication' "$sshd_config"; then
        sed -i 's/^\s*#\?\s*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$sshd_config"
    fi

    # Reload sshd (do NOT restart to keep existing sessions alive)
    if systemctl is-active sshd >/dev/null 2>&1; then
        systemctl reload sshd
    elif systemctl is-active ssh >/dev/null 2>&1; then
        systemctl reload ssh
    fi

    log_success "SSH: PasswordAuthentication отключён"
    echo -e "  ${YELLOW}Резервная копия: ${sshd_config}.bak.*${NC}"
    echo ""
}

# ============================================================================
# SOPS / AGE ENCRYPTION
# ============================================================================

encrypt_secrets() {
    if [[ "${ENABLE_SOPS:-false}" != "true" ]]; then return 0; fi

    log_info "Setting up SOPS encryption..."

    local install_dir="${INSTALL_DIR}"
    [[ "${install_dir}" == /* ]] || { log_error "INSTALL_DIR must be absolute"; return 1; }

    local age_dir="${install_dir}/.age"
    local age_key="${age_dir}/agmind.key"

    # Install age if missing
    if ! command -v age &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y age >/dev/null 2>&1
        else
            log_warn "Install age manually: https://github.com/FiloSottile/age"
            return 0
        fi
    fi

    # Install sops if missing
    if ! command -v sops &>/dev/null; then
        local arch="amd64"
        if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then arch="arm64"; fi
        local sops_url="https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.${arch}"
        if curl -sSL "$sops_url" -o /usr/local/bin/sops; then
            # Verify checksum if provided
            if [[ -n "${SOPS_EXPECTED_SHA256:-}" ]]; then
                if ! echo "${SOPS_EXPECTED_SHA256}  /usr/local/bin/sops" | sha256sum -c - >/dev/null 2>&1; then
                    log_error "SOPS binary checksum mismatch!"
                    rm -f /usr/local/bin/sops
                    return 1
                fi
                log_success "SOPS checksum verified"
            else
                log_warn "SOPS checksum not verified (set SOPS_EXPECTED_SHA256 to enable)"
            fi
            chmod +x /usr/local/bin/sops
        else
            log_warn "Failed to download sops"
            return 0
        fi
    fi

    # Generate age keypair (umask ensures correct perms from creation)
    (
        umask 077
        mkdir -p "$age_dir"
        if [[ ! -f "$age_key" ]]; then
            age-keygen -o "$age_key" 2>/dev/null
            chown root:root "$age_key" 2>/dev/null || true
        fi
    )

    local pub_key
    pub_key="$(grep 'public key:' "$age_key" | cut -d: -f2- | tr -d ' ')"

    # Create .sops.yaml
    cat > "${install_dir}/.sops.yaml" << EOF
creation_rules:
  - path_regex: \.env\.enc$
    age: ${pub_key}
EOF

    # Encrypt .env
    local env_file="${install_dir}/docker/.env"
    if [[ -f "$env_file" ]]; then
        (umask 077; SOPS_AGE_KEY_FILE="$age_key" sops --encrypt --age "$pub_key" "$env_file" > "${env_file}.enc")
        log_success ".env encrypted → .env.enc"
        log_warn "IMPORTANT: Back up ${age_key} — without it, secrets cannot be decrypted"
        log_warn "Plaintext .env still exists. Consider: shred -u ${env_file}"
    fi

    # Add .env to .gitignore
    local gitignore="${install_dir}/.gitignore"
    if [[ ! -f "$gitignore" ]] || ! grep -q '^\.env$' "$gitignore" 2>/dev/null; then
        echo ".env" >> "$gitignore"
    fi
}

# ============================================================================
# DOCKER HARDENING
# ============================================================================

harden_docker_compose() {
    if [[ "${SKIP_DOCKER_HARDENING:-false}" == "true" ]]; then return 0; fi

    log_info "Applying Docker security defaults..."

    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then return 0; fi

    # no-new-privileges on all services EXCEPT cadvisor (needs privileged) and sandbox (needs cap_add)
    if grep -q 'no-new-privileges' "$compose_file" 2>/dev/null; then
        log_success "security_opt already applied"
        return 0
    fi

    python3 -c "
import re, sys
with open('$compose_file', 'r') as f:
    lines = f.readlines()
skip = {'agmind-cadvisor', 'agmind-sandbox'}
result = []
for i, line in enumerate(lines):
    result.append(line)
    m = re.match(r'^(\s+)container_name:\s+(\S+)', line)
    if m and m.group(2) not in skip:
        upcoming = ''.join(lines[i+1:i+5]) if i+1 < len(lines) else ''
        if 'security_opt' not in upcoming and 'no-new-privileges' not in upcoming:
            indent = m.group(1)
            result.append(f'{indent}security_opt:\n')
            result.append(f'{indent}  - no-new-privileges:true\n')
with open('$compose_file', 'w') as f:
    f.writelines(result)
" 2>/dev/null || {
        log_warn "Could not apply security_opt automatically"
        return 0
    }

    log_success "Docker hardening: no-new-privileges applied"
}

# ============================================================================
# MAIN ENTRY
# ============================================================================

setup_security() {
    log_info "Setting up security..."
    configure_ufw
    configure_fail2ban
    harden_ssh
    harden_docker_compose
    encrypt_secrets
    echo ""
}

# Standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    setup_security
fi
