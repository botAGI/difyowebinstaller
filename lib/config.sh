#!/usr/bin/env bash
# config.sh — Generate .env and configuration files from templates
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# SAFE FILE OPERATIONS
# ============================================================================

# Prepare a path for writing: remove directory artifact, ensure parent exists.
# Usage: safe_write_file "/path/to/file.yml"
#   then: cat > "/path/to/file.yml" <<EOF ...
#   or:   cp source "/path/to/file.yml"
safe_write_file() {
    local filepath="$1"
    # Docker creates directories when bind mount source files don't exist.
    # On reinstall these stale directories block file creation.
    [[ -d "$filepath" ]] && rm -rf "$filepath"
    mkdir -p "$(dirname "$filepath")"
}

# Ensure all bind-mounted config files exist as FILES (not dirs, not missing).
# Call right before docker compose up as final safety net.
ensure_bind_mount_files() {
    local docker_dir="${INSTALL_DIR}/docker"
    local files=(
        "monitoring/prometheus.yml"
        "monitoring/alert_rules.yml"
        "monitoring/alertmanager.yml"
        "monitoring/loki-config.yml"
        "monitoring/promtail-config.yml"
        "nginx/nginx.conf"
        "volumes/redis/redis.conf"
        "volumes/ssrf_proxy/squid.conf"
        "volumes/sandbox/conf/config.yaml"
    )
    for f in "${files[@]}"; do
        local full="${docker_dir}/${f}"
        if [[ -d "$full" ]]; then
            rm -rf "$full"
            mkdir -p "$(dirname "$full")"
            touch "$full"
            echo -e "${YELLOW}⚠ Fixed directory artifact: ${f}${NC}"
        elif [[ ! -f "$full" ]]; then
            mkdir -p "$(dirname "$full")"
            touch "$full"
            echo -e "${YELLOW}⚠ Created missing bind mount file: ${f}${NC}"
        fi
    done
}

# Pre-flight validation before docker compose up.
# Catches any remaining directory artifacts or missing bind mount sources.
# Aborts with clear error if anything is wrong.
preflight_bind_mount_check() {
    local docker_dir="${INSTALL_DIR}/docker"
    local errors=0

    echo -e "${CYAN}Pre-flight: проверка bind mount файлов...${NC}"

    # 1. Find .yml/.yaml files that are actually directories
    local yml_dirs
    yml_dirs=$(find "$docker_dir" -name "*.yml" -type d 2>/dev/null || true)
    yml_dirs+=$'\n'
    yml_dirs+=$(find "$docker_dir" -name "*.yaml" -type d 2>/dev/null || true)
    yml_dirs=$(echo "$yml_dirs" | sed '/^$/d')
    if [[ -n "$yml_dirs" ]]; then
        echo -e "${RED}✗ ОШИБКА: .yml/.yaml пути являются директориями (а не файлами):${NC}"
        while IFS= read -r d; do
            echo -e "  ${RED}→ ${d}${NC}"
        done <<< "$yml_dirs"
        errors=$((errors + 1))
    fi

    # 2. Find .conf files that are actually directories
    local conf_dirs
    conf_dirs=$(find "$docker_dir" -name "*.conf" -type d 2>/dev/null || true)
    conf_dirs=$(echo "$conf_dirs" | sed '/^$/d')
    if [[ -n "$conf_dirs" ]]; then
        echo -e "${RED}✗ ОШИБКА: .conf пути являются директориями (а не файлами):${NC}"
        while IFS= read -r d; do
            echo -e "  ${RED}→ ${d}${NC}"
        done <<< "$conf_dirs"
        errors=$((errors + 1))
    fi

    # 3. Verify ALL bind-mount source files exist (unconditional — Docker creates
    #    directories for missing sources, which causes OCI mount errors)
    local all_bind_files=(
        "nginx/nginx.conf"
        "volumes/redis/redis.conf"
        "volumes/ssrf_proxy/squid.conf"
        "volumes/sandbox/conf/config.yaml"
        "monitoring/prometheus.yml"
        "monitoring/alert_rules.yml"
        "monitoring/alertmanager.yml"
        "monitoring/loki-config.yml"
        "monitoring/promtail-config.yml"
    )
    for f in "${all_bind_files[@]}"; do
        local full="${docker_dir}/${f}"
        if [[ ! -f "$full" ]]; then
            echo -e "${RED}✗ ОШИБКА: bind mount файл отсутствует: ${f}${NC}"
            errors=$((errors + 1))
        fi
    done

    # Abort if any errors found
    if [[ $errors -gt 0 ]]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  PRE-FLIGHT FAILED: ${errors} ошибка(и) bind mount обнаружено    ║${NC}"
        echo -e "${RED}║  docker compose up отменён для предотвращения OCI ошибок ║${NC}"
        echo -e "${RED}║  Удалите ${INSTALL_DIR} и запустите установку заново     ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Pre-flight: все bind mount файлы в порядке${NC}"
}

# ============================================================================
# HELPERS
# ============================================================================

generate_random() {
    local length="${1:-32}"
    head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# Escape special characters for sed replacement strings (& | \ /)
escape_sed() {
    printf '%s' "$1" | sed 's/[&/|\]/\\&/g'
}

# Validate that .env contains no known default/weak passwords
validate_no_default_secrets() {
    local env_file="$1"
    local known_defaults=(
        "difyai123456"
        "QaHbTe77"
        "changeme"
        "password"
        "admin123"
        "secret"
        "default"
        "test1234"
    )
    local found=0
    for default in "${known_defaults[@]}"; do
        if grep -qE "^[^#].*=${default}$" "$env_file" 2>/dev/null; then
            local offending
            offending=$(grep -E "^[^#].*=${default}$" "$env_file" | head -5)
            echo -e "${RED}SECURITY FAIL: Default password '${default}' found in .env:${NC}"
            echo "$offending"
            found=1
        fi
    done
    # Also check for unresolved placeholders
    if grep -qE "^[^#].*=__[A-Z_]+__" "$env_file" 2>/dev/null; then
        local unresolved
        unresolved=$(grep -E "^[^#].*=__[A-Z_]+__" "$env_file" | head -5)
        echo -e "${RED}SECURITY FAIL: Unresolved placeholders in .env:${NC}"
        echo "$unresolved"
        found=1
    fi
    if [[ $found -eq 1 ]]; then
        echo -e "${RED}Aborting: fix secrets before proceeding${NC}"
        return 1
    fi
    return 0
}

# ============================================================================
# MAIN CONFIG GENERATION
# ============================================================================

generate_config() {
    local profile="$1"
    local template_dir="$2"

    echo -e "${YELLOW}Генерация конфигурации (профиль: ${profile})...${NC}"

    # Create directory structure (ONLY directories, never file paths)
    mkdir -p "${INSTALL_DIR}/docker/volumes/sandbox/conf"
    mkdir -p "${INSTALL_DIR}/docker/volumes/app/storage"
    mkdir -p "${INSTALL_DIR}/docker/volumes/db/data"
    mkdir -p "${INSTALL_DIR}/docker/volumes/redis/data"
    mkdir -p "${INSTALL_DIR}/docker/volumes/weaviate"
    mkdir -p "${INSTALL_DIR}/docker/volumes/plugin_daemon/storage"
    mkdir -p "${INSTALL_DIR}/docker/volumes/certbot/conf"
    mkdir -p "${INSTALL_DIR}/docker/volumes/certbot/www"
    mkdir -p "${INSTALL_DIR}/docker/volumes/certbot/ssl"
    mkdir -p "${INSTALL_DIR}/docker/nginx"
    mkdir -p "${INSTALL_DIR}/docker/volumes/qdrant"
    mkdir -p "${INSTALL_DIR}/docker/volumes/ssrf_proxy"
    mkdir -p "${INSTALL_DIR}/docker/monitoring/grafana/provisioning/datasources"
    mkdir -p "${INSTALL_DIR}/docker/monitoring/grafana/provisioning/dashboards"
    mkdir -p "${INSTALL_DIR}/docker/monitoring/grafana/dashboards"
    mkdir -p "${INSTALL_DIR}/branding"
    mkdir -p "${INSTALL_DIR}/scripts"
    mkdir -p "${INSTALL_DIR}/workflows"
    mkdir -p /var/backups/agmind

    # Copy docker-compose.yml and pipeline build context
    cp "${template_dir}/docker-compose.yml" "${INSTALL_DIR}/docker/docker-compose.yml"
    local installer_root
    installer_root="$(dirname "$template_dir")"
    if [[ -d "${installer_root}/pipeline" ]]; then
        cp -r "${installer_root}/pipeline" "${INSTALL_DIR}/docker/pipeline"
    fi

    # Generate secrets
    local secret_key
    secret_key=$(generate_random 64)
    local db_password
    db_password=$(generate_random 32)
    local redis_password
    redis_password=$(generate_random 32)
    local sandbox_api_key
    sandbox_api_key="dify-sandbox-$(generate_random 16)"
    local plugin_daemon_key
    plugin_daemon_key=$(generate_random 48)
    local plugin_inner_api_key
    plugin_inner_api_key=$(generate_random 48)

    local qdrant_api_key
    qdrant_api_key=$(generate_random 32)
    local grafana_admin_password
    grafana_admin_password=$(generate_random 16)

    # Admin password (Base64 encoded for Dify)
    local admin_password_plain="${ADMIN_PASSWORD:-}"
    if [[ -z "$admin_password_plain" ]]; then
        admin_password_plain=$(generate_random 16)
    fi
    local admin_password_b64
    admin_password_b64=$(echo -n "$admin_password_plain" | base64)

    # Generate .env from template
    local template_file="${template_dir}/env.${profile}.template"
    if [[ ! -f "$template_file" ]]; then
        echo -e "${RED}Шаблон не найден: ${template_file}${NC}"
        return 1
    fi

    local env_file="${INSTALL_DIR}/docker/.env"
    if [[ -f "$env_file" ]]; then
        echo -e "${YELLOW}⚠ Существующий .env будет перезаписан с новыми секретами${NC}"
        cp "$env_file" "${env_file}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    cp "$template_file" "$env_file"
    chmod 600 "$env_file"

    # Escape user-input values for safe sed replacement (& | / \ chars)
    local safe_admin_email safe_company safe_domain safe_certbot_email
    local safe_monitoring_endpoint safe_webhook_url
    local safe_llm_model safe_embedding_model
    local safe_monitoring_token safe_telegram_token safe_telegram_chat_id
    safe_admin_email=$(escape_sed "${ADMIN_EMAIL:-admin@admin.com}")
    safe_company=$(escape_sed "${COMPANY_NAME:-AGMind}")
    safe_domain=$(escape_sed "${DOMAIN:-localhost}")
    safe_certbot_email=$(escape_sed "${CERTBOT_EMAIL:-}")
    safe_monitoring_endpoint=$(escape_sed "${MONITORING_ENDPOINT:-}")
    safe_webhook_url=$(escape_sed "${ALERT_WEBHOOK_URL:-}")
    safe_llm_model=$(escape_sed "${LLM_MODEL:-qwen2.5:14b}")
    safe_embedding_model=$(escape_sed "${EMBEDDING_MODEL:-bge-m3}")
    safe_monitoring_token=$(escape_sed "${MONITORING_TOKEN:-}")
    safe_telegram_token=$(escape_sed "${ALERT_TELEGRAM_TOKEN:-}")
    safe_telegram_chat_id=$(escape_sed "${ALERT_TELEGRAM_CHAT_ID:-}")

    # Replace placeholders in .env
    sed -i.bak \
        -e "s|__SECRET_KEY__|${secret_key}|g" \
        -e "s|__DB_PASSWORD__|${db_password}|g" \
        -e "s|__REDIS_PASSWORD__|${redis_password}|g" \
        -e "s|__SANDBOX_API_KEY__|${sandbox_api_key}|g" \
        -e "s|__PLUGIN_DAEMON_KEY__|${plugin_daemon_key}|g" \
        -e "s|__PLUGIN_INNER_API_KEY__|${plugin_inner_api_key}|g" \
        -e "s|__ADMIN_EMAIL__|${safe_admin_email}|g" \
        -e "s|__ADMIN_PASSWORD_B64__|${admin_password_b64}|g" \
        -e "s|__COMPANY_NAME__|${safe_company}|g" \
        -e "s|__LLM_MODEL__|${safe_llm_model}|g" \
        -e "s|__EMBEDDING_MODEL__|${safe_embedding_model}|g" \
        -e "s|__DOMAIN__|${safe_domain}|g" \
        -e "s|__CERTBOT_EMAIL__|${safe_certbot_email}|g" \
        -e "s|__VECTOR_STORE__|${VECTOR_STORE:-weaviate}|g" \
        -e "s|__QDRANT_API_KEY__|${qdrant_api_key}|g" \
        -e "s|__ETL_TYPE__|$([ "${ETL_ENHANCED:-no}" = "yes" ] && echo "unstructured_api" || echo "dify")|g" \
        -e "s|__TLS_MODE__|${TLS_MODE:-none}|g" \
        -e "s|__MONITORING_MODE__|${MONITORING_MODE:-none}|g" \
        -e "s|__MONITORING_ENDPOINT__|${safe_monitoring_endpoint}|g" \
        -e "s|__MONITORING_TOKEN__|${safe_monitoring_token}|g" \
        -e "s|__GRAFANA_ADMIN_PASSWORD__|${grafana_admin_password}|g" \
        -e "s|__ALERT_MODE__|${ALERT_MODE:-none}|g" \
        -e "s|__ALERT_WEBHOOK_URL__|${safe_webhook_url}|g" \
        -e "s|__ALERT_TELEGRAM_TOKEN__|${safe_telegram_token}|g" \
        -e "s|__ALERT_TELEGRAM_CHAT_ID__|${safe_telegram_chat_id}|g" \
        "$env_file"
    rm -f "${env_file}.bak"

    # Authelia placeholders
    local authelia_jwt_secret
    authelia_jwt_secret=$(generate_random 64)
    sed -i.bak \
        -e "s|__AUTHELIA_JWT_SECRET__|${authelia_jwt_secret}|g" \
        "$env_file"
    rm -f "${env_file}.bak"

    # Copy release manifest
    local manifest_file="${template_dir}/release-manifest.json"
    if [[ -f "$manifest_file" ]]; then
        cp "$manifest_file" "${INSTALL_DIR}/release-manifest.json"
    fi

    # Copy versions.env and append to .env (single source of truth)
    local versions_file="${template_dir}/versions.env"
    if [[ -f "$versions_file" ]]; then
        cp "$versions_file" "${INSTALL_DIR}/versions.env"
        # Safely parse and append version variables to .env
        echo "" >> "$env_file"
        echo "# === Pinned versions (from versions.env) ===" >> "$env_file"
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*_VERSION$ ]] || continue
            [[ "$value" =~ ^[a-zA-Z0-9._:-]+$ ]] || continue
            declare "$key=$value"
            echo "${key}=${value}" >> "$env_file"
        done < <(grep -E '^[A-Z].*_VERSION=' "$versions_file")
    fi

    GRAFANA_ADMIN_PASSWORD="$grafana_admin_password"

    # Generate nginx.conf from template
    generate_nginx_config "$profile" "$template_dir"

    # Handle TLS mode
    handle_tls_config "$profile"

    # Handle Authelia 2FA
    if [[ "${ENABLE_AUTHELIA:-false}" == "true" ]]; then
        enable_authelia_nginx
        copy_authelia_files "$template_dir"
    fi

    # Copy monitoring provisioning files if local monitoring
    if [[ "${MONITORING_MODE:-none}" == "local" ]]; then
        copy_monitoring_files "$template_dir"
        configure_alertmanager
    fi

    # Generate Redis config (password in file, not command line)
    generate_redis_config

    # Generate sandbox config
    generate_sandbox_config

    # Validate no default/weak secrets remain
    validate_no_default_secrets "$env_file"

    # Secure file permissions
    chmod 600 "$env_file"
    if [[ $(id -u) -eq 0 ]]; then
        chown root:root "$env_file"
    fi

    # Store admin credentials for final output
    echo "$admin_password_plain" > "${INSTALL_DIR}/.admin_password"
    chmod 600 "${INSTALL_DIR}/.admin_password"
    if [[ $(id -u) -eq 0 ]]; then
        chown root:root "${INSTALL_DIR}/.admin_password"
    fi

    echo -e "${GREEN}Конфигурация сгенерирована: ${INSTALL_DIR}/docker/.env${NC}"
}

# ============================================================================
# CONFIG FILE GENERATORS (all use safe_write_file)
# ============================================================================

generate_nginx_config() {
    local profile="$1"
    local template_dir="$2"
    local nginx_conf="${INSTALL_DIR}/docker/nginx/nginx.conf"

    safe_write_file "$nginx_conf"
    cp "${template_dir}/nginx.conf.template" "$nginx_conf"

    local server_name="_"
    if [[ "$profile" == "vps" && -n "${DOMAIN:-}" ]]; then
        server_name="${DOMAIN}"
    fi

    # Replace all placeholders
    sed -i.bak \
        -e "s|__SERVER_NAME__|${server_name}|g" \
        "$nginx_conf"
    rm -f "${nginx_conf}.bak"

    # Handle TLS markers based on TLS_MODE
    if [[ "${TLS_MODE:-none}" != "none" ]]; then
        # Enable TLS: strip #__TLS__ markers to activate HTTPS block
        sed -i.bak 's|#__TLS__||g' "$nginx_conf"
        rm -f "${nginx_conf}.bak"
        # Enable HTTP→HTTPS redirect: strip #__TLS_REDIRECT__ markers
        sed -i.bak 's|#__TLS_REDIRECT__||g' "$nginx_conf"
        rm -f "${nginx_conf}.bak"
    else
        # No TLS: remove all #__TLS__ lines entirely, and #__TLS_REDIRECT__ lines
        sed -i.bak '/#__TLS__/d' "$nginx_conf"
        rm -f "${nginx_conf}.bak"
        sed -i.bak '/#__TLS_REDIRECT__/d' "$nginx_conf"
        rm -f "${nginx_conf}.bak"
    fi

    # Replace TLS cert/key paths
    local cert_path="/etc/nginx/ssl/cert.pem"
    local key_path="/etc/nginx/ssl/key.pem"
    if [[ "${TLS_MODE:-none}" == "letsencrypt" ]]; then
        cert_path="/etc/letsencrypt/live/${DOMAIN:-localhost}/fullchain.pem"
        key_path="/etc/letsencrypt/live/${DOMAIN:-localhost}/privkey.pem"
    fi
    sed -i.bak \
        -e "s|__TLS_CERT_PATH__|${cert_path}|g" \
        -e "s|__TLS_KEY_PATH__|${key_path}|g" \
        "$nginx_conf"
    rm -f "${nginx_conf}.bak"
}

generate_redis_config() {
    local redis_conf="${INSTALL_DIR}/docker/volumes/redis/redis.conf"
    safe_write_file "$redis_conf"

    local redis_pass
    redis_pass=$(grep '^REDIS_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "")
    cat > "$redis_conf" << REDISEOF
# AGMind Redis Configuration — Hardened
# bind 0.0.0.0 — container networking requires this; access controlled by Docker network + requirepass
bind 0.0.0.0
protected-mode no
requirepass ${redis_pass}
maxmemory 512mb
maxmemory-policy allkeys-lru
save 60 1000
save 300 100
appendonly yes
appendfilename "appendonly.aof"

# Disable dangerous commands
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG ""
rename-command DEBUG ""
rename-command SHUTDOWN AGMIND_SHUTDOWN_$(head -c 8 /dev/urandom | LC_ALL=C tr -dc 'a-f0-9')

# Connection limits
maxclients 100
timeout 300
tcp-keepalive 60
REDISEOF
    # 644: redis user (UID 999) in container needs read access; password
    # is already protected by Docker network isolation + bind mount :ro
    chmod 644 "$redis_conf"
}

configure_alertmanager() {
    local alertmanager_conf="${INSTALL_DIR}/docker/monitoring/alertmanager.yml"
    safe_write_file "$alertmanager_conf"

    # Create default alertmanager config if not copied from monitoring/
    if [[ ! -f "$alertmanager_conf" ]]; then
        echo -e "${YELLOW}Создание дефолтного alertmanager.yml...${NC}"
        cat > "$alertmanager_conf" << 'DEFAULTAMEOF'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'

receivers:
  - name: 'default'

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname']
DEFAULTAMEOF
    fi

    local alert_mode="${ALERT_MODE:-none}"

    case "$alert_mode" in
        telegram)
            local token="${ALERT_TELEGRAM_TOKEN:-}"
            local chat_id="${ALERT_TELEGRAM_CHAT_ID:-}"
            if [[ -n "$token" && -n "$chat_id" ]]; then
                # Replace default receiver with telegram config
                cat > "$alertmanager_conf" << AMEOF
global:
  resolve_timeout: 5m
  telegram_api_url: 'https://api.telegram.org'

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'telegram'
  routes:
    - match:
        severity: critical
      receiver: 'telegram'
      repeat_interval: 15m

receivers:
  - name: 'telegram'
    telegram_configs:
      - bot_token: '${token}'
        chat_id: ${chat_id}
        parse_mode: 'HTML'
        send_resolved: true
        message: '{{ range .Alerts }}{{ if eq .Status "firing" }}🔴{{ else }}🟢{{ end }} <b>{{ .Labels.alertname }}</b>\n{{ .Annotations.summary }}\n{{ .Annotations.description }}{{ end }}'

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname']
AMEOF
            fi
            ;;
        webhook)
            local webhook_url="${ALERT_WEBHOOK_URL:-}"
            if [[ -n "$webhook_url" ]]; then
                # Enable webhook markers
                sed -i.bak 's|#__WEBHOOK__||g' "$alertmanager_conf"
                rm -f "${alertmanager_conf}.bak"
                local safe_webhook
                safe_webhook=$(escape_sed "$webhook_url")
                sed -i.bak "s|__ALERT_WEBHOOK_URL__|${safe_webhook}|g" "$alertmanager_conf"
                rm -f "${alertmanager_conf}.bak"
            fi
            ;;
    esac
    chmod 600 "$alertmanager_conf"
}

generate_sandbox_config() {
    local sandbox_conf="${INSTALL_DIR}/docker/volumes/sandbox/conf/config.yaml"
    safe_write_file "$sandbox_conf"

    cat > "$sandbox_conf" << 'SANDBOXEOF'
# Dify Sandbox Configuration
# allowed_syscalls intentionally omitted — sandbox uses its own defaults.
# Specifying syscall names as strings causes panic (expects int syscall numbers).
app:
  port: 8194
  debug: false
  key: __will_be_replaced__

proxy:
  socks5: ""
  http: ""
  https: ""

max_workers: 4
max_requests: 50
worker_timeout: 15
python_path: ""

enable_network: false
SANDBOXEOF

    # Replace sandbox key from .env
    local sandbox_key
    sandbox_key=$(grep '^SANDBOX_API_KEY=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "dify-sandbox")
    sed -i.bak "s|__will_be_replaced__|${sandbox_key}|g" "$sandbox_conf"
    rm -f "${sandbox_conf}.bak"
}

# ============================================================================
# GPU SUPPORT
# ============================================================================

# Enable GPU in docker-compose based on detected GPU type
enable_gpu_compose() {
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"

    case "${DETECTED_GPU:-none}" in
        none)
            echo -e "${YELLOW}GPU не обнаружен — режим CPU${NC}"
            # Remove all GPU-marked lines entirely
            sed -i.bak '/#__GPU__/d' "$compose_file"
            rm -f "${compose_file}.bak"
            ;;
        nvidia)
            echo -e "${YELLOW}Включение GPU поддержки (NVIDIA)...${NC}"
            # Strip markers, keep nvidia deploy block as-is
            sed -i.bak 's|#__GPU__||g' "$compose_file"
            rm -f "${compose_file}.bak"
            echo -e "${GREEN}NVIDIA GPU → deploy.resources.reservations.devices${NC}"
            ;;
        amd)
            echo -e "${YELLOW}Включение GPU поддержки (AMD ROCm)...${NC}"
            # Strip markers first
            sed -i.bak 's|#__GPU__||g' "$compose_file"
            rm -f "${compose_file}.bak"
            # Replace nvidia driver block with AMD ROCm device mounts
            sed -i.bak '/driver: nvidia/,/capabilities: \[gpu\]/c\      # AMD ROCm GPU\n    devices:\n      - /dev/kfd:/dev/kfd\n      - /dev/dri:/dev/dri\n    group_add:\n      - video\n      - render' "$compose_file"
            rm -f "${compose_file}.bak"
            # Add OLLAMA_ROCM env var
            sed -i.bak '/OLLAMA_API_BASE/a\      OLLAMA_ROCM: "1"' "$compose_file" 2>/dev/null || true
            rm -f "${compose_file}.bak"
            echo -e "${GREEN}AMD ROCm GPU → device passthrough${NC}"
            ;;
        intel)
            echo -e "${YELLOW}Включение GPU поддержки (Intel)...${NC}"
            # Strip markers first
            sed -i.bak 's|#__GPU__||g' "$compose_file"
            rm -f "${compose_file}.bak"
            # Replace nvidia driver block with Intel device mounts
            sed -i.bak '/driver: nvidia/,/capabilities: \[gpu\]/c\      # Intel GPU\n    devices:\n      - /dev/dri:/dev/dri\n    group_add:\n      - video\n      - render' "$compose_file"
            rm -f "${compose_file}.bak"
            echo -e "${GREEN}Intel GPU → /dev/dri passthrough${NC}"
            ;;
        apple)
            echo -e "${YELLOW}Apple Silicon — GPU обрабатывается нативно через Metal${NC}"
            # Remove GPU blocks — Metal handled natively by Ollama
            sed -i.bak '/#__GPU__/d' "$compose_file"
            rm -f "${compose_file}.bak"
            echo -e "${GREEN}Apple Silicon — Docker GPU passthrough не требуется${NC}"
            ;;
    esac

    persist_gpu_profile
}

# ============================================================================
# TLS
# ============================================================================

handle_tls_config() {
    local profile="$1"
    local tls_mode="${TLS_MODE:-none}"
    local ssl_dir="${INSTALL_DIR}/docker/volumes/certbot/ssl"

    case "$tls_mode" in
        self-signed)
            generate_self_signed_cert "$ssl_dir"
            ;;
        custom)
            copy_custom_cert "$ssl_dir"
            ;;
        letsencrypt)
            # Certs will be obtained by certbot container
            echo -e "${YELLOW}TLS: Let's Encrypt (certbot получит сертификат после запуска)${NC}"
            ;;
        none)
            echo -e "${YELLOW}TLS: отключен${NC}"
            ;;
    esac
}

generate_self_signed_cert() {
    local ssl_dir="$1"
    mkdir -p "$ssl_dir"

    if ! command -v openssl &>/dev/null; then
        echo -e "${RED}openssl не найден. Установите: apt install openssl${NC}"
        return 1
    fi

    echo -e "${YELLOW}Генерация self-signed сертификата...${NC}"
    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${ssl_dir}/key.pem" \
        -out "${ssl_dir}/cert.pem" \
        -subj "/CN=${DOMAIN:-localhost}/O=AGMind/C=RU" \
        2>/dev/null

    chmod 600 "${ssl_dir}/key.pem"
    echo -e "${GREEN}Self-signed сертификат создан${NC}"
}

copy_custom_cert() {
    local ssl_dir="$1"
    mkdir -p "$ssl_dir"

    if [[ -n "${TLS_CERT_PATH:-}" && -f "${TLS_CERT_PATH}" ]]; then
        cp "${TLS_CERT_PATH}" "${ssl_dir}/cert.pem"
        cp "${TLS_KEY_PATH}" "${ssl_dir}/key.pem"
        chmod 600 "${ssl_dir}/key.pem"
        echo -e "${GREEN}Пользовательский сертификат скопирован${NC}"
    else
        echo -e "${RED}Файл сертификата не найден: ${TLS_CERT_PATH:-не указан}${NC}"
        return 1
    fi
}

# ============================================================================
# AUTHELIA
# ============================================================================

enable_authelia_nginx() {
    local nginx_conf="${INSTALL_DIR}/docker/nginx/nginx.conf"

    if [[ ! -f "$nginx_conf" ]]; then
        echo -e "${RED}nginx.conf не найден: ${nginx_conf}${NC}"
        return 1
    fi

    echo -e "${YELLOW}Активация Authelia в nginx...${NC}"
    # Strip #__AUTHELIA__ markers to enable Authelia location blocks
    sed -i.bak 's|#__AUTHELIA__||g' "$nginx_conf"
    rm -f "${nginx_conf}.bak"
    echo -e "${GREEN}Authelia блоки активированы в nginx.conf${NC}"
}

copy_authelia_files() {
    local template_dir="$1"
    local authelia_dir="${INSTALL_DIR}/docker/authelia"
    mkdir -p "$authelia_dir"

    echo -e "${YELLOW}Копирование файлов Authelia...${NC}"

    if [[ -f "${template_dir}/authelia/configuration.yml.template" ]]; then
        safe_write_file "${authelia_dir}/configuration.yml"
        cp "${template_dir}/authelia/configuration.yml.template" "${authelia_dir}/configuration.yml"
    fi

    if [[ -f "${template_dir}/authelia/users_database.yml.template" ]]; then
        safe_write_file "${authelia_dir}/users_database.yml"
        cp "${template_dir}/authelia/users_database.yml.template" "${authelia_dir}/users_database.yml"
    fi

    echo -e "${GREEN}Файлы Authelia скопированы${NC}"
}

# ============================================================================
# MONITORING
# ============================================================================

copy_monitoring_files() {
    local template_dir="$1"
    local installer_root
    installer_root="$(dirname "$template_dir")"
    local dest="${INSTALL_DIR}/docker/monitoring"

    echo -e "${YELLOW}Копирование файлов мониторинга...${NC}"

    # Ensure destination exists as directory
    mkdir -p "${dest}"

    # Copy individual config files with safe_write_file protection
    local mon_files=("prometheus.yml" "alert_rules.yml" "alertmanager.yml")
    for f in "${mon_files[@]}"; do
        if [[ -f "${installer_root}/monitoring/${f}" ]]; then
            safe_write_file "${dest}/${f}"
            cp "${installer_root}/monitoring/${f}" "${dest}/${f}"
            echo -e "  ${GREEN}✓ ${f} ($(file -b "${dest}/${f}" 2>/dev/null))${NC}"
        else
            echo -e "  ${YELLOW}⚠ source not found: ${installer_root}/monitoring/${f}${NC}"
        fi
    done

    # Loki + Promtail configs
    if [[ "${ENABLE_LOKI:-true}" == "true" ]]; then
        for f in "loki-config.yml" "promtail-config.yml"; do
            if [[ -f "${installer_root}/monitoring/${f}" ]]; then
                safe_write_file "${dest}/${f}"
                cp "${installer_root}/monitoring/${f}" "${dest}/${f}"
                echo -e "  ${GREEN}✓ ${f}${NC}"
            fi
        done
    fi

    # Copy grafana provisioning
    if [[ -d "${installer_root}/monitoring/grafana" ]]; then
        cp -r "${installer_root}/monitoring/grafana/provisioning/"* "${dest}/grafana/provisioning/" 2>/dev/null || true
        cp -r "${installer_root}/monitoring/grafana/dashboards/"* "${dest}/grafana/dashboards/" 2>/dev/null || true
    fi

    # POST-COPY VERIFICATION: catch any corruption immediately
    for f in "${mon_files[@]}"; do
        if [[ -d "${dest}/${f}" ]]; then
            echo -e "  ${RED}✗ BUG: ${f} is a DIRECTORY after copy! Fixing...${NC}"
            rm -rf "${dest:?}/${f}"
            cp "${installer_root}/monitoring/${f}" "${dest}/${f}" 2>/dev/null || touch "${dest}/${f}"
        fi
    done

    echo -e "${GREEN}Файлы мониторинга скопированы${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_config "${1:-lan}" "${2:-.}"
fi
