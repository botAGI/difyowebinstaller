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
    log_info "DGX Spark detected — pinning NVIDIA driver 580 (590+ breaks vLLM on GB10)"
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
# SECURITY AUDIT (agmind security audit) — read-only scanner
# ============================================================================
# Reuses lib/doctor.sh::doctor_check_security_exposure for exposed-ports +
# docker.sock-consumers data; adds privileged-containers / weak-env / file-perms.
# Report-only — no --fix (operator applies fixes). Secret VALUES are never printed.
# WHY: SC2 requirement — closes "weak/default secrets undetected",
#      "world-readable secret files", "Portainer rw-socket not behind auth".

# Fallback log/color shims if sourced standalone (mirror lib/doctor.sh)
command -v log_info    >/dev/null 2>&1 || log_info()    { echo "  -> $*"; }
command -v log_warn    >/dev/null 2>&1 || log_warn()    { echo "  ! $*" >&2; }
command -v log_error   >/dev/null 2>&1 || log_error()   { echo "  ✗ $*" >&2; }
command -v log_success >/dev/null 2>&1 || log_success() { echo "  ✓ $*"; }

# _SEC_SEP — ASCII Unit Separator, same pattern as DOCTOR_REGISTRY (not in normal messages)
_SEC_SEP=$'\x1f'
# SECURITY_AUDIT_CHECKS — array of \x1f-records: id|severity|target|detail|fix
SECURITY_AUDIT_CHECKS=()

_sec_registry_add() {
    # Usage: _sec_registry_add id severity target detail [fix]
    local id="$1" severity="$2" target="$3" detail="$4" fix="${5:-}"
    SECURITY_AUDIT_CHECKS+=("${id}${_SEC_SEP}${severity}${_SEC_SEP}${target}${_SEC_SEP}${detail}${_SEC_SEP}${fix}")
}

# _sec_severity_rank — maps severity string to integer for comparison
_sec_severity_rank() {
    case "${1:-info}" in
        info)     echo 0 ;;
        low)      echo 1 ;;
        medium)   echo 2 ;;
        high)     echo 3 ;;
        critical) echo 4 ;;
        *)        echo 0 ;;
    esac
}

# _sec_check_exposed_ports — reads compose file for admin-UI ports bound to 0.0.0.0
# WHY T-07-12: admin UIs bound to all interfaces expose them to the LAN (CLAUDE.md §8 nginx §5)
_sec_check_exposed_ports() {
    local install_dir="${INSTALL_DIR:-/opt/agmind}"
    local compose_file="${install_dir}/docker/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        _sec_registry_add "exposed_compose_missing" "info" "compose" \
            "docker-compose.yml not found at ${compose_file} — exposed-ports check skipped" \
            ""
        return 0
    fi
    # Parse ports: lines matching 0.0.0.0:HOSTPORT:CONTAINERPORT in compose file
    # Use python3 for precise regex extraction of host port number (avoids bash regex pitfalls)
    # WHY python3: grep -oE on '0.0.0.0:N' returns 'N' but '0:N' also matches last IP octet
    local found_any=false
    local ports_found
    ports_found="$(python3 - "$compose_file" <<'PYEOF'
import re, sys

compose_path = sys.argv[1]
try:
    with open(compose_path) as f:
        content = f.read()
except Exception:
    sys.exit(0)

# Match 0.0.0.0:HOSTPORT:CONTAINERPORT (with or without surrounding quotes)
pattern = re.compile(r'0\.0\.0\.0:(\d+):\d+')
for m in pattern.finditer(content):
    print(m.group(1))
PYEOF
)" || true

    if [[ -n "$ports_found" ]]; then
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            found_any=true
            # Determine severity by port number
            # WHY critical for Portainer: direct Docker daemon access = host root equivalent
            local sev fix_hint
            fix_hint="bind to 127.0.0.1 or \${SERVICE_BIND_ADDR} in .env"
            case "$port" in
                9443|9000|3001|3000|9090) sev="high" ;;  # Admin UIs — WHY high: LAN-only deploy, no public internet exposure
                *)                        sev="medium" ;; # Other admin UIs
            esac
            _sec_registry_add "exposed_port_${port}" "${sev}" "0.0.0.0:${port}" \
                "Admin UI port ${port} bound to 0.0.0.0 — accessible from all network interfaces" \
                "${fix_hint}"
        done <<< "$ports_found"
    fi

    if [[ "$found_any" == "false" ]]; then
        _sec_registry_add "exposed_none" "info" "compose" \
            "No admin UI ports bound to 0.0.0.0 in compose file" ""
    fi
}

# _sec_check_privileged_containers — checks for privileged:true on running agmind-* containers
# WHY T-07-11: privileged containers bypass namespacing — full root on host
_sec_check_privileged_containers() {
    local _docker_ok=true
    if ! command -v docker >/dev/null 2>&1; then
        _docker_ok=false
    else
        if ! docker info >/dev/null 2>&1; then
            _docker_ok=false
        fi
    fi
    if [[ "$_docker_ok" == "false" ]]; then
        echo "docker unavailable — skipping privileged-containers check" >&2
        _sec_registry_add "priv_skip" "info" "docker" \
            "docker unavailable — privileged-containers check skipped" ""
        return 0
    fi

    local containers
    containers="$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^agmind-' || true)"
    if [[ -z "$containers" ]]; then
        _sec_registry_add "priv_none" "info" "docker" \
            "No agmind-* containers running — privileged check skipped" ""
        return 0
    fi

    local found_any=false
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        local priv
        set +e
        priv="$(docker inspect "$c" --format '{{.HostConfig.Privileged}}' 2>/dev/null || echo "false")"
        set -e
        if [[ "$priv" == "true" ]]; then
            found_any=true
            _sec_registry_add "priv_${c}" "medium" "$c" \
                "${c} is privileged — justification? (cadvisor: reads cgroups/sysfs — expected)" \
                "review necessity; remove privileged: true if not required"
        fi
    done <<< "$containers"

    if [[ "$found_any" == "false" ]]; then
        _sec_registry_add "priv_ok" "info" "docker" \
            "No privileged agmind-* containers found" ""
    fi
}

# _sec_check_docker_sock_consumers — checks for containers mounting /var/run/docker.sock
# WHY T-07-11: rw docker.sock = root-equivalent on host (CLAUDE.md §8 security notes)
_sec_check_docker_sock_consumers() {
    local _docker_ok=true
    if ! command -v docker >/dev/null 2>&1; then
        _docker_ok=false
    else
        if ! docker info >/dev/null 2>&1; then
            _docker_ok=false
        fi
    fi
    if [[ "$_docker_ok" == "false" ]]; then
        echo "docker unavailable — skipping docker.sock-consumers check" >&2
        _sec_registry_add "sock_skip" "info" "docker" \
            "docker unavailable — docker.sock-consumers check skipped" ""
        return 0
    fi

    local containers
    containers="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
    if [[ -z "$containers" ]]; then
        _sec_registry_add "sock_none" "info" "docker" \
            "No running containers — docker.sock check skipped" ""
        return 0
    fi

    local found_any=false
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        local raw_json
        set +e
        raw_json="$(docker inspect "$c" 2>/dev/null || true)"
        set -e
        [[ -z "$raw_json" ]] && continue
        # Parse Mounts from raw JSON with python3 (mock returns raw JSON; avoids --format Go template)
        # WHY python3: Go template format is not supported by the mock; python3 handles both
        local sock_result
        sock_result="$(python3 - "$c" <<PYEOF
import json, sys
cname = sys.argv[1]
try:
    data = json.loads('''${raw_json}''')
    if not isinstance(data, list):
        data = [data]
    for obj in data:
        for m in obj.get('Mounts', []):
            src = m.get('Source', '')
            rw = m.get('RW', False)
            if src == '/var/run/docker.sock':
                print('rw' if rw else 'ro')
except Exception:
    pass
PYEOF
)" || true
        case "${sock_result:-}" in
            rw)
                found_any=true
                # WHY high: rw docker.sock = host root equivalent (CLAUDE.md §5, T-07-11)
                local _detail _fix
                _detail="${c}: mounts /var/run/docker.sock rw — elevated risk"
                _fix="use docker-socket-proxy (read-only) or set PORTAINER_BEHIND_AUTHELIA=true"
                if [[ "$c" == *"portainer"* && "${PORTAINER_BEHIND_AUTHELIA:-false}" != "true" ]]; then
                    _detail="${c}: mounts /var/run/docker.sock rw — not behind Authelia (SSH-tunnel only or set PORTAINER_BEHIND_AUTHELIA=true)"
                fi
                _sec_registry_add "sock_rw_${c}" "high" "$c" "$_detail" "$_fix"
                ;;
            ro)
                found_any=true
                _sec_registry_add "sock_ro_${c}" "medium" "$c" \
                    "${c}: mounts /var/run/docker.sock ro (raw, not via proxy)" \
                    "route through docker-socket-proxy for read-only controlled access"
                ;;
        esac
    done <<< "$containers"

    if [[ "$found_any" == "false" ]]; then
        _sec_registry_add "sock_ok" "info" "docker" \
            "No containers mounting /var/run/docker.sock found" ""
    fi
}

# _sec_check_weak_env — scans .env for weak/default secret values
# WHY T-07-09: weak defaults are a critical security hole (CLAUDE.md §5 credentials)
# CRITICAL: NEVER print the value — only the key name and reason (SC2 invariant)
_sec_check_weak_env() {
    local install_dir="${INSTALL_DIR:-/opt/agmind}"
    local env_file="${install_dir}/docker/.env"
    if [[ ! -f "$env_file" ]]; then
        _sec_registry_add "weak_env_missing" "info" ".env" \
            ".env not found at ${env_file} — weak-env check skipped" ""
        return 0
    fi

    # Default placeholder patterns (case-insensitive match later via lowercase)
    local -a _defaults=("changeme" "admin" "password" "admin123" "test" "123456" "difyai123456")

    local found_any=false
    while IFS= read -r line; do
        # Skip comments and blanks
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Match key=value for secret-looking keys
        local key value
        case "$line" in
            *_PASSWORD=*|*_SECRET=*|SECRET_KEY=*|*_API_KEY=*|*_TOKEN=*)
                key="${line%%=*}"
                value="${line#*=}"
                ;;
            *)
                continue
                ;;
        esac

        # RESEARCH Pitfall 7: empty value → unconfigured, not a finding
        [[ -z "$value" ]] && continue

        # Check for default/placeholder values (case-insensitive)
        local lc_value
        lc_value="$(echo "$value" | tr '[:upper:]' '[:lower:]')"
        local is_default=false
        local d
        for d in "${_defaults[@]}"; do
            if [[ "$lc_value" == "$d" ]]; then
                is_default=true
                break
            fi
        done

        if [[ "$is_default" == "true" ]]; then
            found_any=true
            # WHY: only key + reason in detail — NEVER the value (T-07-09, SC2 invariant)
            _sec_registry_add "weak_env_default_${key}" "high" "${key}" \
                "${key} weak: matches default placeholder" \
                "set a strong value in .env then restart; or run: agmind creds rotate"
        elif [[ "${#value}" -lt 12 ]]; then
            found_any=true
            # WHY: only key + char count — NEVER the value (T-07-09, SC2 invariant)
            _sec_registry_add "weak_env_short_${key}" "high" "${key}" \
                "${key} weak: only ${#value} chars (minimum 12 recommended)" \
                "set a strong value in .env then restart; or run: agmind creds rotate"
        fi
    done < "$env_file"

    if [[ "$found_any" == "false" ]]; then
        _sec_registry_add "weak_env_ok" "info" ".env" \
            "No weak/default secret values detected in .env" ""
    fi
}

# _sec_check_file_perms — checks secret files are not world/group-readable
# WHY T-07-10: world-readable credential files allow any local user to read secrets (CLAUDE.md §5)
_sec_check_file_perms() {
    local install_dir="${INSTALL_DIR:-/opt/agmind}"
    # Files to check — skip those that don't exist
    local -a files_to_check=(
        "${install_dir}/docker/.env"
        "${install_dir}/credentials.txt"
        "${install_dir}/.admin_password"
    )

    # Also add .secrets/* if the dir exists
    if [[ -d "${install_dir}/.secrets" ]]; then
        while IFS= read -r sf; do
            files_to_check+=("$sf")
        done < <(find "${install_dir}/.secrets" -maxdepth 1 -type f 2>/dev/null || true)
    fi

    local found_any=false
    for f in "${files_to_check[@]}"; do
        [[ -e "$f" ]] || continue
        local perm
        perm="$(stat -c '%a' "$f" 2>/dev/null || echo "unknown")"
        case "$perm" in
            600|640)
                # OK — owner-only or owner+group read (WHY 640: group may be root:docker)
                _sec_registry_add "perm_ok_$(basename "$f")" "info" "$f" \
                    "$(basename "$f"): permissions ${perm} — OK" ""
                ;;
            unknown)
                _sec_registry_add "perm_unknown_$(basename "$f")" "info" "$f" \
                    "$(basename "$f"): could not stat — skipped" ""
                ;;
            *)
                found_any=true
                # WHY high: world-readable secrets = any local user can read creds (T-07-10)
                _sec_registry_add "perm_bad_$(basename "$f")" "high" "$f" \
                    "$(basename "$f"): permissions ${perm} — world/group-readable (expected 600)" \
                    "chmod 600 ${f}"
                ;;
        esac
    done
}

# _sec_render_text — human-readable text output
# Format: [<severity>] <check> — <target>: <detail>  → fix: <fix>
_sec_render_text() {
    local rc="${1:-0}" block="${2:-high}"
    local -A sev_counts=([info]=0 [low]=0 [medium]=0 [high]=0 [critical]=0)
    local rec id sev target detail fix

    for rec in "${SECURITY_AUDIT_CHECKS[@]+"${SECURITY_AUDIT_CHECKS[@]}"}"; do
        IFS="${_SEC_SEP}" read -r id sev target detail fix <<< "$rec"
        sev_counts["${sev:-info}"]=$(( ${sev_counts["${sev:-info}"]:-0} + 1 ))
        local line="[${sev}] ${id} — ${target}: ${detail}"
        [[ -n "$fix" ]] && line="${line}  → fix: ${fix}"
        echo "$line"
    done

    echo ""
    echo "=== Security Audit Summary ==="
    local total=0
    for s in critical high medium low info; do
        local n="${sev_counts[$s]:-0}"
        total=$(( total + n ))
        [[ "$n" -gt 0 ]] && echo "  ${s}: ${n}"
    done
    echo "  total: ${total} findings"
    echo "  block_severity: ${block}"
    if [[ "$rc" -eq 0 ]]; then
        echo "  result: OK (no findings >= block severity)"
    elif [[ "$rc" -eq 1 ]]; then
        echo "  result: BLOCK (findings >= ${block} found)"
    else
        echo "  result: ERROR (could not run)"
    fi
}

# _sec_render_json — machine-readable JSON output
# WHY python3: safe JSON encoding avoids escaping issues in bash (mirror _registry_render_json)
_sec_render_json() {
    local rc="${1:-0}" block="${2:-high}"
    local rec id sev target detail fix
    local -a findings=()

    for rec in "${SECURITY_AUDIT_CHECKS[@]+"${SECURITY_AUDIT_CHECKS[@]}"}"; do
        IFS="${_SEC_SEP}" read -r id sev target detail fix <<< "$rec"
        # Use python3 for safe JSON encoding (handles quotes/newlines in messages)
        local json_rec
        json_rec="$(python3 -c "
import json, sys
print(json.dumps({
    'check': sys.argv[1],
    'severity': sys.argv[2],
    'target': sys.argv[3],
    'detail': sys.argv[4],
    'fix': sys.argv[5],
}))
" "$id" "${sev:-info}" "$target" "$detail" "${fix:-}")"
        findings+=("$json_rec")
    done

    # Build findings array JSON
    local findings_json=""
    local first=1
    local f
    for f in "${findings[@]+"${findings[@]}"}"; do
        if [[ "$first" -eq 1 ]]; then
            findings_json="$f"
            first=0
        else
            findings_json="${findings_json},${f}"
        fi
    done

    # Count by severity for summary
    python3 - "$rc" "$block" "${SECURITY_AUDIT_CHECKS[@]+"${SECURITY_AUDIT_CHECKS[@]}"}" <<'PYEOF'
import json, sys, datetime

rc = int(sys.argv[1])
block = sys.argv[2]
sep = '\x1f'
records = sys.argv[3:]

counts = {'info': 0, 'low': 0, 'medium': 0, 'high': 0, 'critical': 0}
findings = []
for rec in records:
    parts = rec.split(sep)
    if len(parts) < 5:
        continue
    check_id, sev, target, detail, fix = parts[0], parts[1], parts[2], parts[3], parts[4]
    sev = sev if sev in counts else 'info'
    counts[sev] = counts.get(sev, 0) + 1
    findings.append({
        'check': check_id,
        'severity': sev,
        'target': target,
        'detail': detail,
        'fix': fix,
    })

print(json.dumps({
    'generated_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'findings': findings,
    'summary': {
        'counts_by_severity': counts,
        'block_severity': block,
        'exit': rc,
        'info': counts['info'],
        'low': counts['low'],
        'medium': counts['medium'],
        'high': counts['high'],
        'critical': counts['critical'],
    }
}))
PYEOF
}

# security_audit [--json] — main entry point for `agmind security audit`
# Exit codes:
#   0 — no finding with severity >= AGMIND_SECURITY_BLOCK (default high)
#   1 — at least one finding with severity >= AGMIND_SECURITY_BLOCK
#   2 — INSTALL_DIR does not exist (AGmind not installed)
security_audit() {
    local json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true ;;
            -h|--help) echo "Usage: agmind security audit [--json]"; return 0 ;;
            *) ;;
        esac
        shift
    done

    local install_dir="${INSTALL_DIR:-/opt/agmind}"
    if [[ ! -d "$install_dir" ]]; then
        log_error "AGmind not installed at ${install_dir} — nothing to audit"
        return 2
    fi

    # Source doctor.sh for doctor_check_security_exposure reuse (idempotent guard)
    # Try runtime scripts/ path first, then dev lib/ path
    if ! declare -F doctor_check_security_exposure >/dev/null 2>&1; then
        local _sec_script_dir="${SCRIPTS_DIR:-${install_dir}/scripts}"
        local _sec_lib_dir="${AGMIND_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}/lib"
        # shellcheck source=/dev/null
        source "${_sec_script_dir}/doctor.sh" 2>/dev/null \
            || source "${_sec_lib_dir}/doctor.sh" 2>/dev/null \
            || true
    fi

    # Reset registry
    SECURITY_AUDIT_CHECKS=()

    # Run all 5 checks
    _sec_check_exposed_ports
    _sec_check_privileged_containers
    _sec_check_docker_sock_consumers
    _sec_check_weak_env
    _sec_check_file_perms

    # Compute exit code: compare worst severity to block threshold
    local block="${AGMIND_SECURITY_BLOCK:-high}"
    local block_rank
    block_rank="$(_sec_severity_rank "$block")"
    local worst=0
    local rec sev sev_rank
    for rec in "${SECURITY_AUDIT_CHECKS[@]+"${SECURITY_AUDIT_CHECKS[@]}"}"; do
        sev="${rec#*${_SEC_SEP}}"
        sev="${sev%%${_SEC_SEP}*}"
        sev_rank="$(_sec_severity_rank "$sev")"
        (( sev_rank > worst )) && worst=$sev_rank
    done

    local rc=0
    if (( worst > 0 && worst >= block_rank )); then
        rc=1
    fi

    # Render output
    if [[ "$json" == "true" ]]; then
        _sec_render_json "$rc" "$block"
    else
        _sec_render_text "$rc" "$block"
    fi

    return $rc
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
