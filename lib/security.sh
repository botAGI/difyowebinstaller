#!/usr/bin/env bash
# security.sh — UFW, fail2ban (SSH jail), SSH hardening, SOPS/age encryption, Docker hardening.
# Dependencies: common.sh (log_*, generate_random)
# Functions: setup_security(), configure_ufw(), configure_fail2ban(), harden_ssh(),
#            encrypt_secrets(), harden_docker_compose(), pin_nvidia_driver_dgx_spark()
# Expects: INSTALL_DIR, DEPLOY_PROFILE, ENABLE_UFW, ENABLE_FAIL2BAN, ENABLE_SOPS,
#          ENABLE_SSH_HARDENING, MONITORING_MODE, NON_INTERACTIVE, DETECTED_DGX_SPARK
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# DGX SPARK NVIDIA DRIVER HOLD (CLAUDE.md §8 — Driver 580 HOLD)
# ============================================================================

# NVIDIA staff explicitly state: "we do not support new drivers past version
# 580.126.09 on Spark". 590+/595+ have 3 hard regressions on GB10 unified
# memory: CUDAGraph deadlock, UMA leak (~80 GiB), TMA bug in 595.58.03.
# Without apt-mark hold, unattended-upgrades will pull 590+ → next reboot
# breaks vLLM. This function is idempotent — safe to call repeatedly.
pin_nvidia_driver_dgx_spark() {
    if [[ "${DETECTED_DGX_SPARK:-false}" != "true" ]]; then return 0; fi
    if ! command -v apt-mark >/dev/null 2>&1; then
        log_warn "apt-mark not found — cannot pin NVIDIA driver (non-Debian system?)"
        return 0
    fi
    log_info "DGX Spark detected — pinning NVIDIA driver 580 (CLAUDE.md §8 mandatory)"
    local pkgs=()
    # Discover installed nvidia-* packages matching driver/kernel/dkms patterns.
    # Avoid hardcoding exact package list — Ubuntu version may rename slightly.
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && pkgs+=("$pkg")
    done < <(dpkg -l 2>/dev/null | awk '/^ii  nvidia-(driver|dkms|kernel)/ {print $2}')
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        log_warn "No nvidia-driver packages installed yet — pin deferred"
        return 0
    fi
    if apt-mark hold "${pkgs[@]}" >/dev/null 2>&1; then
        log_success "NVIDIA driver pinned: ${pkgs[*]}"
    else
        log_warn "apt-mark hold failed — manual: sudo apt-mark hold ${pkgs[*]}"
    fi
}

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

    # LAN profile (always since 2026-04-25, VPS dropped): allow internal subnet.
    ufw allow from "${LAN_SUBNET:-192.168.0.0/16}" comment "LAN access"
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

    # Source pinned versions (SOPS_VERSION + SOPS_SHA256_*). _copy_versions
    # writes only *_VERSION to .env, but SHA256 pins live in versions.env itself.
    if [[ -f "${install_dir}/versions.env" ]]; then
        # shellcheck disable=SC1091
        source "${install_dir}/versions.env"
    fi

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

    # Install sops if missing — SHA256 verification is MANDATORY to defend
    # against supply-chain compromise of github.com/getsops/sops releases.
    # Hashes pinned in templates/versions.env (cross-checked against vendor
    # checksums.txt). If hash unset or mismatch — refuse install.
    if ! command -v sops &>/dev/null; then
        local arch="amd64" sops_expected
        if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
            arch="arm64"
            sops_expected="${SOPS_SHA256_ARM64:-${SOPS_EXPECTED_SHA256:-}}"
        else
            sops_expected="${SOPS_SHA256_AMD64:-${SOPS_EXPECTED_SHA256:-}}"
        fi
        local sops_ver="${SOPS_VERSION:-v3.9.4}"
        local sops_url="https://github.com/getsops/sops/releases/download/${sops_ver}/sops-${sops_ver}.linux.${arch}"

        if [[ -z "$sops_expected" ]]; then
            log_error "SOPS install refused: SHA256 not pinned (SOPS_SHA256_${arch^^} unset)"
            log_error "Fix: ensure templates/versions.env is sourced (versions.env defines SOPS_SHA256_${arch^^})"
            return 1
        fi

        if ! curl -sSL --fail "$sops_url" -o /usr/local/bin/sops; then
            log_error "Failed to download sops from ${sops_url}"
            rm -f /usr/local/bin/sops
            return 1
        fi

        if ! echo "${sops_expected}  /usr/local/bin/sops" | sha256sum -c - >/dev/null 2>&1; then
            log_error "SOPS binary SHA256 mismatch — supply-chain compromise risk!"
            log_error "  expected: ${sops_expected}"
            log_error "  got:      $(sha256sum /usr/local/bin/sops 2>/dev/null | awk '{print $1}')"
            rm -f /usr/local/bin/sops
            return 1
        fi
        log_success "SOPS ${sops_ver} ${arch} checksum verified"
        chmod +x /usr/local/bin/sops
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
    # SSH hardening пропускается на LAN (DGX Spark) — server обычно за NAT,
    # риск locking out себя > benefit. VPS path удалён 2026-04-25.
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
