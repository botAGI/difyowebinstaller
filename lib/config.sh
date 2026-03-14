#!/usr/bin/env bash
# config.sh — Generate .env and configuration files from templates
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

generate_random() {
    local length="${1:-32}"
    head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# Escape special characters for sed replacement strings (& | \ /)
escape_sed() {
    printf '%s' "$1" | sed 's/[&/|\]/\\&/g'
}

generate_config() {
    local profile="$1"
    local template_dir="$2"

    echo -e "${YELLOW}Генерация конфигурации (профиль: ${profile})...${NC}"

    # Create directory structure
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

    # Admin token for secret Dify Console access path
    local admin_token
    admin_token=$(generate_random 40)

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
        -e "s|__ADMIN_TOKEN__|${admin_token}|g" \
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

    # Copy and apply versions.env
    local versions_file="${template_dir}/versions.env"
    if [[ -f "$versions_file" ]]; then
        cp "$versions_file" "${INSTALL_DIR}/versions.env"
        # Safely parse version variables (no arbitrary code execution)
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*_VERSION$ ]] || continue
            [[ "$value" =~ ^[a-zA-Z0-9._:-]+$ ]] || continue
            declare "$key=$value"
        done < <(grep -E '^[A-Z].*_VERSION=' "$versions_file")
        sed -i.bak \
            -e "s|DIFY_VERSION=.*|DIFY_VERSION=${DIFY_VERSION}|" \
            -e "s|OLLAMA_VERSION=.*|OLLAMA_VERSION=${OLLAMA_VERSION}|" \
            -e "s|POSTGRES_VERSION=.*|POSTGRES_VERSION=${POSTGRES_VERSION}|" \
            -e "s|REDIS_VERSION=.*|REDIS_VERSION=${REDIS_VERSION}|" \
            -e "s|WEAVIATE_VERSION=.*|WEAVIATE_VERSION=${WEAVIATE_VERSION}|" \
            -e "s|QDRANT_VERSION=.*|QDRANT_VERSION=${QDRANT_VERSION}|" \
            -e "s|SANDBOX_VERSION=.*|SANDBOX_VERSION=${SANDBOX_VERSION}|" \
            -e "s|SQUID_VERSION=.*|SQUID_VERSION=${SQUID_VERSION}|" \
            -e "s|NGINX_VERSION=.*|NGINX_VERSION=${NGINX_VERSION}|" \
            -e "s|CERTBOT_VERSION=.*|CERTBOT_VERSION=${CERTBOT_VERSION}|" \
            -e "s|PLUGIN_DAEMON_VERSION=.*|PLUGIN_DAEMON_VERSION=${PLUGIN_DAEMON_VERSION}|" \
            -e "s|DOCLING_VERSION=.*|DOCLING_VERSION=${DOCLING_VERSION}|" \
            -e "s|XINFERENCE_VERSION=.*|XINFERENCE_VERSION=${XINFERENCE_VERSION}|" \
            -e "s|GRAFANA_VERSION=.*|GRAFANA_VERSION=${GRAFANA_VERSION}|" \
            -e "s|PORTAINER_VERSION=.*|PORTAINER_VERSION=${PORTAINER_VERSION}|" \
            -e "s|CADVISOR_VERSION=.*|CADVISOR_VERSION=${CADVISOR_VERSION}|" \
            -e "s|PROMETHEUS_VERSION=.*|PROMETHEUS_VERSION=${PROMETHEUS_VERSION}|" \
            -e "s|AUTHELIA_VERSION=.*|AUTHELIA_VERSION=${AUTHELIA_VERSION}|" \
            "$env_file"
        rm -f "${env_file}.bak"
    fi

    # Set ADMIN_TOKEN for nginx config generation (not exported to avoid /proc/environ leak)
    ADMIN_TOKEN="$admin_token"
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
    fi

    # Generate Redis config (password in file, not command line)
    generate_redis_config

    # Generate sandbox config
    generate_sandbox_config

    # Store admin credentials for final output
    echo "$admin_password_plain" > "${INSTALL_DIR}/.admin_password"
    chmod 600 "${INSTALL_DIR}/.admin_password"

    echo -e "${GREEN}Конфигурация сгенерирована: ${INSTALL_DIR}/docker/.env${NC}"
}

generate_nginx_config() {
    local profile="$1"
    local template_dir="$2"
    local nginx_conf="${INSTALL_DIR}/docker/nginx/nginx.conf"

    cp "${template_dir}/nginx.conf.template" "$nginx_conf"

    local server_name="_"
    if [[ "$profile" == "vps" && -n "${DOMAIN:-}" ]]; then
        server_name="${DOMAIN}"
    fi

    # Replace all placeholders
    sed -i.bak \
        -e "s|__SERVER_NAME__|${server_name}|g" \
        -e "s|__ADMIN_TOKEN__|${ADMIN_TOKEN}|g" \
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
    local redis_pass
    redis_pass=$(grep '^REDIS_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "")
    cat > "$redis_conf" << REDISEOF
# AGMind Redis Configuration
requirepass ${redis_pass}
maxmemory 256mb
maxmemory-policy allkeys-lru
save 60 1000
save 300 100
appendonly yes
appendfilename "appendonly.aof"
REDISEOF
    chmod 600 "$redis_conf"
}

generate_sandbox_config() {
    local sandbox_conf="${INSTALL_DIR}/docker/volumes/sandbox/conf/config.yaml"
    cat > "$sandbox_conf" << 'SANDBOXEOF'
# Dify Sandbox Configuration
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

allowed_syscalls:
  - "read"
  - "write"
  - "readv"
  - "writev"
  - "open"
  - "close"
  - "stat"
  - "fstat"
  - "lstat"
  - "poll"
  - "lseek"
  - "mmap"
  - "mprotect"
  - "munmap"
  - "brk"
  - "rt_sigaction"
  - "rt_sigprocmask"
  - "ioctl"
  - "access"
  - "pipe"
  - "select"
  - "sched_yield"
  - "mremap"
  - "dup"
  - "dup2"
  - "getpid"
  - "clone"
  - "fork"
  - "vfork"
  - "execve"
  - "exit"
  - "wait4"
  - "uname"
  - "fcntl"
  - "flock"
  - "fsync"
  - "fdatasync"
  - "getcwd"
  - "chdir"
  - "openat"
  - "newfstatat"
  - "set_tid_address"
  - "set_robust_list"
  - "futex"
  - "sched_getaffinity"
  - "clock_gettime"
  - "exit_group"
  - "epoll_ctl"
  - "epoll_wait"
  - "getrandom"
  - "pread64"
  - "pwrite64"
  - "arch_prctl"
  - "prlimit64"
  - "getdents64"
  - "clock_nanosleep"
SANDBOXEOF

    # Replace sandbox key from .env
    local sandbox_key
    sandbox_key=$(grep '^SANDBOX_API_KEY=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "dify-sandbox")
    sed -i.bak "s|__will_be_replaced__|${sandbox_key}|g" "$sandbox_conf"
    rm -f "${sandbox_conf}.bak"
}

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
        cp "${template_dir}/authelia/configuration.yml.template" "${authelia_dir}/configuration.yml"
    fi

    if [[ -f "${template_dir}/authelia/users_database.yml.template" ]]; then
        cp "${template_dir}/authelia/users_database.yml.template" "${authelia_dir}/users_database.yml"
    fi

    echo -e "${GREEN}Файлы Authelia скопированы${NC}"
}

copy_monitoring_files() {
    local template_dir="$1"
    local installer_root
    installer_root="$(dirname "$template_dir")"
    local dest="${INSTALL_DIR}/docker/monitoring"

    echo -e "${YELLOW}Копирование файлов мониторинга...${NC}"

    # Copy prometheus config
    if [[ -f "${installer_root}/monitoring/prometheus.yml" ]]; then
        cp "${installer_root}/monitoring/prometheus.yml" "${dest}/prometheus.yml"
    fi

    # Loki + Promtail configs
    if [[ "${ENABLE_LOKI:-true}" == "true" ]]; then
        cp "${installer_root}/monitoring/loki-config.yml" "${INSTALL_DIR}/docker/monitoring/" 2>/dev/null || true
        cp "${installer_root}/monitoring/promtail-config.yml" "${INSTALL_DIR}/docker/monitoring/" 2>/dev/null || true
    fi

    # Copy grafana provisioning
    if [[ -d "${installer_root}/monitoring/grafana" ]]; then
        cp -r "${installer_root}/monitoring/grafana/provisioning/"* "${dest}/grafana/provisioning/"
        cp -r "${installer_root}/monitoring/grafana/dashboards/"* "${dest}/grafana/dashboards/"
        cp "${installer_root}/monitoring/grafana/dashboards/logs.json" "${INSTALL_DIR}/docker/monitoring/grafana/dashboards/" 2>/dev/null || true
    fi

    echo -e "${GREEN}Файлы мониторинга скопированы${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_config "${1:-lan}" "${2:-.}"
fi
