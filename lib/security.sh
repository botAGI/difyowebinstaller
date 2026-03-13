#!/usr/bin/env bash
# AGMind Security Hardening Module

configure_ufw() {
    if [[ "${ENABLE_UFW:-false}" != "true" ]]; then return 0; fi
    if ! command -v ufw &>/dev/null; then
        echo -e "${YELLOW}UFW не найден — пропускаем firewall. Установите: apt install ufw${NC}"
        return 0
    fi
    echo -e "${CYAN}→ configure_ufw: настройка файрвола...${NC}"
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

    # Create AGMind nginx filter
    cat > /etc/fail2ban/filter.d/agmind-nginx.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* "(POST|GET) /(api|login|console|install).* HTTP.* (401|403|429)
ignoreregex =
EOF

    # Create jail config
    cat > /etc/fail2ban/jail.d/agmind.conf << 'EOF'
[sshd]
enabled = true
maxretry = 3
bantime = 864000
findtime = 600

[agmind-nginx]
enabled = true
filter = agmind-nginx
logpath = /opt/agmind/docker/volumes/nginx/logs/access.log
maxretry = 10
bantime = 3600
findtime = 300
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    echo -e "${GREEN}✓ configure_fail2ban: done${NC}"
}

encrypt_secrets() {
    if [[ "${ENABLE_SOPS:-false}" != "true" ]]; then return 0; fi
    echo -e "${CYAN}→ encrypt_secrets: настройка шифрования...${NC}"

    local install_dir="${INSTALL_DIR:-/opt/agmind}"
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
            chmod +x /usr/local/bin/sops
        else
            echo -e "${YELLOW}Не удалось скачать sops${NC}"
            return 0
        fi
    fi

    # Generate age keypair
    mkdir -p "$age_dir"
    chmod 700 "$age_dir"
    if [[ ! -f "$age_key" ]]; then
        age-keygen -o "$age_key" 2>/dev/null
        chmod 600 "$age_key"
    fi

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
        SOPS_AGE_KEY_FILE="$age_key" sops --encrypt --age "$pub_key" "$env_file" > "${env_file}.enc"
        echo -e "${GREEN}✓ encrypt_secrets: .env зашифрован → .env.enc${NC}"
        echo -e "${YELLOW}⚠ ВАЖНО: Сохраните ключ ${age_key} в безопасное место!${NC}"
        echo -e "${YELLOW}  Без него невозможно расшифровать секреты.${NC}"
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

    # Add security_opt to all services via sed
    # Find each "container_name:" line and add security_opt after it
    # This is a lightweight approach — full YAML anchor would require rewriting the template
    # Only add if not already present (idempotent)
    if ! grep -q 'no-new-privileges' "$compose_file" 2>/dev/null; then
        sed -i.bak '/container_name: agmind-/a\    security_opt:\n      - no-new-privileges:true' "$compose_file" 2>/dev/null || true
        rm -f "${compose_file}.bak"
    else
        echo -e "${GREEN}✓ security_opt уже применён${NC}"
    fi

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
