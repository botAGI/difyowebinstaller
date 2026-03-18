#!/usr/bin/env bash
# AGMind Security Hardening Module

# Colors (may be inherited from install.sh)
RED="${RED:-\033[0;31m}"; GREEN="${GREEN:-\033[0;32m}"; YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"; BOLD="${BOLD:-\033[1m}"; NC="${NC:-\033[0m}"

configure_ufw() {
    if [[ "${ENABLE_UFW:-false}" != "true" ]]; then return 0; fi
    if ! command -v ufw &>/dev/null; then
        echo -e "${YELLOW}UFW не найден — пропускаем firewall. Установите: apt install ufw${NC}"
        return 0
    fi
    echo -e "${CYAN}→ configure_ufw: настройка файрвола...${NC}"

    # Backup existing UFW rules before reset
    if ufw status 2>/dev/null | grep -q "active"; then
        ufw status numbered > "/tmp/ufw-backup-$(date +%s).txt" 2>/dev/null || true
    fi
    ufw --force reset

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh comment "SSH"
    ufw allow 80/tcp comment "AGMind HTTP"
    ufw allow 443/tcp comment "AGMind HTTPS"

    if [[ "${DEPLOY_PROFILE}" == "lan" ]]; then
        ufw allow from "${LAN_SUBNET:-192.168.0.0/16}" comment "LAN access"
    fi
    if [[ "${DEPLOY_PROFILE}" == "vpn" ]]; then
        ufw allow in on "${VPN_INTERFACE:-tun0}" comment "VPN access"
    fi
    # Monitoring ports (if local monitoring enabled)
    if [[ "${MONITORING_MODE}" == "local" ]]; then
        ufw allow 3001/tcp comment "Grafana"
        ufw allow 9443/tcp comment "Portainer"
    fi
    ufw --force enable
    echo -e "${GREEN}✓ configure_ufw: done${NC}"
    ufw status numbered
}

configure_fail2ban() {
    if [[ "${ENABLE_FAIL2BAN:-false}" != "true" ]]; then return 0; fi
    echo -e "${CYAN}→ configure_fail2ban: настройка защиты от bruteforce...${NC}"

    # Install if missing
    if ! command -v fail2ban-server &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y fail2ban >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y fail2ban >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y fail2ban >/dev/null 2>&1
        else
            echo -e "${YELLOW}Не удалось установить fail2ban автоматически${NC}"
            return 0
        fi
    fi

    # Create jail config — SSH only (nginx jail removed: Docker logpath mismatch makes it non-functional)
    cat > /etc/fail2ban/jail.d/agmind.conf << 'EOF'
[sshd]
enabled = true
maxretry = 3
bantime = 864000
findtime = 600
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    echo -e "${GREEN}✓ configure_fail2ban: done${NC}"
}

encrypt_secrets() {
    if [[ "${ENABLE_SOPS:-false}" != "true" ]]; then return 0; fi
    echo -e "${CYAN}→ encrypt_secrets: настройка шифрования...${NC}"

    local install_dir="${INSTALL_DIR:-/opt/agmind}"

    # Validate INSTALL_DIR is absolute path
    [[ "${install_dir}" == /* ]] || { echo -e "${RED}INSTALL_DIR must be absolute${NC}"; return 1; }

    local age_dir="${install_dir}/.age"
    local age_key="${age_dir}/agmind.key"

    # Install age if missing
    if ! command -v age &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get install -y age >/dev/null 2>&1
        else
            echo -e "${YELLOW}Установите age вручную: https://github.com/FiloSottile/age${NC}"
            return 0
        fi
    fi

    # Install sops if missing
    if ! command -v sops &>/dev/null; then
        local arch="amd64"
        [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && arch="arm64"
        local sops_url="https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.${arch}"
        if curl -sSL "$sops_url" -o /usr/local/bin/sops; then
            # Verify SHA256 checksum — HARD FAIL if hash is set and doesn't match
            if [[ -n "${SOPS_EXPECTED_SHA256:-}" ]]; then
                if ! echo "${SOPS_EXPECTED_SHA256}  /usr/local/bin/sops" | sha256sum -c - >/dev/null 2>&1; then
                    echo -e "${RED}SECURITY FAIL: SOPS binary checksum mismatch!${NC}"
                    echo -e "${RED}Expected: ${SOPS_EXPECTED_SHA256}${NC}"
                    echo -e "${RED}Got:      $(sha256sum /usr/local/bin/sops | cut -d' ' -f1)${NC}"
                    rm -f /usr/local/bin/sops
                    return 1
                fi
                echo -e "${GREEN}✓ SOPS checksum verified${NC}"
            else
                echo -e "${YELLOW}⚠ SOPS checksum not verified (set SOPS_EXPECTED_SHA256 to enable)${NC}"
            fi
            chmod +x /usr/local/bin/sops
        else
            echo -e "${YELLOW}Не удалось скачать sops${NC}"
            return 0
        fi
    fi

    # Generate age keypair (umask prevents TOCTOU: files created with correct perms)
    (
        umask 077
        mkdir -p "$age_dir"
        if [[ ! -f "$age_key" ]]; then
            age-keygen -o "$age_key" 2>/dev/null
            chown root:root "$age_key" 2>/dev/null || true
        fi
    )

    local pub_key
    pub_key=$(grep 'public key:' "$age_key" | cut -d: -f2- | tr -d ' ')

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
        echo -e "${GREEN}✓ encrypt_secrets: .env зашифрован → .env.enc${NC}"
        echo -e "${YELLOW}⚠ ВАЖНО: Сохраните ключ ${age_key} в безопасное место!${NC}"
        echo -e "${YELLOW}  Без него невозможно расшифровать секреты.${NC}"
        echo -e "${YELLOW}WARNING: Plaintext .env file still exists. Consider running: shred -u ${env_file}${NC}"
    fi

    # Add .env to .gitignore
    local gitignore="${install_dir}/.gitignore"
    if [[ ! -f "$gitignore" ]] || ! grep -q '^\.env$' "$gitignore" 2>/dev/null; then
        echo ".env" >> "$gitignore"
    fi
}

harden_docker_compose() {
    if [[ "${SKIP_DOCKER_HARDENING:-false}" == "true" ]]; then return 0; fi
    echo -e "${CYAN}→ harden_docker_compose: применение security defaults...${NC}"

    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    [[ ! -f "$compose_file" ]] && return 0

    # Add security_opt: no-new-privileges to all services EXCEPT:
    #   - cadvisor: requires privileged mode to read cgroups/proc/sys
    #   - sandbox: needs cap_add which conflicts with no-new-privileges
    # Only add if not already present (idempotent)
    if grep -q 'no-new-privileges' "$compose_file" 2>/dev/null; then
        echo -e "${GREEN}✓ security_opt уже применён${NC}"
        return 0
    fi

    # Use Python for reliable YAML-aware line insertion (avoid sed portability issues)
    python3 -c "
import re, sys
with open('$compose_file', 'r') as f:
    lines = f.readlines()
# Skip list: containers that need elevated privileges
skip = {'agmind-cadvisor', 'agmind-sandbox'}
result = []
for i, line in enumerate(lines):
    result.append(line)
    m = re.match(r'^(\s+)container_name:\s+(\S+)', line)
    if m and m.group(2) not in skip:
        # Check if next lines already have security_opt
        upcoming = ''.join(lines[i+1:i+5]) if i+1 < len(lines) else ''
        if 'security_opt' not in upcoming and 'no-new-privileges' not in upcoming:
            indent = m.group(1)
            result.append(f'{indent}security_opt:\n')
            result.append(f'{indent}  - no-new-privileges:true\n')
with open('$compose_file', 'w') as f:
    f.writelines(result)
" 2>/dev/null || {
        echo -e "${YELLOW}⚠ Не удалось применить security_opt автоматически${NC}"
        return 0
    }

    echo -e "${GREEN}✓ harden_docker_compose: no-new-privileges applied${NC}"
}

setup_security() {
    echo -e "${BOLD}Настройка безопасности...${NC}"
    configure_ufw
    configure_fail2ban
    harden_docker_compose
    encrypt_secrets
    echo ""
}
