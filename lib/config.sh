#!/usr/bin/env bash
# config.sh — Generate .env and configuration files from templates
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

generate_random() {
    local length="${1:-32}"
    head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c "$length"
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
    cp "$template_file" "$env_file"

    # Replace placeholders in .env
    sed -i.bak \
        -e "s|__SECRET_KEY__|${secret_key}|g" \
        -e "s|__DB_PASSWORD__|${db_password}|g" \
        -e "s|__REDIS_PASSWORD__|${redis_password}|g" \
        -e "s|__SANDBOX_API_KEY__|${sandbox_api_key}|g" \
        -e "s|__PLUGIN_DAEMON_KEY__|${plugin_daemon_key}|g" \
        -e "s|__PLUGIN_INNER_API_KEY__|${plugin_inner_api_key}|g" \
        -e "s|__ADMIN_EMAIL__|${ADMIN_EMAIL:-admin@admin.com}|g" \
        -e "s|__ADMIN_PASSWORD_B64__|${admin_password_b64}|g" \
        -e "s|__COMPANY_NAME__|${COMPANY_NAME:-AGMind}|g" \
        -e "s|__LLM_MODEL__|${LLM_MODEL:-qwen2.5:14b}|g" \
        -e "s|__EMBEDDING_MODEL__|${EMBEDDING_MODEL:-bge-m3}|g" \
        -e "s|__DOMAIN__|${DOMAIN:-localhost}|g" \
        -e "s|__CERTBOT_EMAIL__|${CERTBOT_EMAIL:-}|g" \
        -e "s|__ADMIN_TOKEN__|${admin_token}|g" \
        -e "s|__VECTOR_STORE__|${VECTOR_STORE:-weaviate}|g" \
        -e "s|__QDRANT_API_KEY__|${qdrant_api_key}|g" \
        -e "s|__ETL_TYPE__|$([ "${ETL_ENHANCED:-no}" = "yes" ] && echo "unstructured_api" || echo "dify")|g" \
        -e "s|__TLS_MODE__|${TLS_MODE:-none}|g" \
        -e "s|__MONITORING_MODE__|${MONITORING_MODE:-none}|g" \
        -e "s|__MONITORING_ENDPOINT__|${MONITORING_ENDPOINT:-}|g" \
        -e "s|__MONITORING_TOKEN__|${MONITORING_TOKEN:-}|g" \
        -e "s|__GRAFANA_ADMIN_PASSWORD__|${grafana_admin_password}|g" \
        -e "s|__ALERT_MODE__|${ALERT_MODE:-none}|g" \
        -e "s|__ALERT_WEBHOOK_URL__|${ALERT_WEBHOOK_URL:-}|g" \
        -e "s|__ALERT_TELEGRAM_TOKEN__|${ALERT_TELEGRAM_TOKEN:-}|g" \
        -e "s|__ALERT_TELEGRAM_CHAT_ID__|${ALERT_TELEGRAM_CHAT_ID:-}|g" \
        "$env_file"
    rm -f "${env_file}.bak"

    # Export ADMIN_TOKEN for nginx config generation
    export ADMIN_TOKEN="$admin_token"
    export GRAFANA_ADMIN_PASSWORD="$grafana_admin_password"

    # Generate nginx.conf from template
    generate_nginx_config "$profile" "$template_dir"

    # Handle TLS mode
    handle_tls_config "$profile"

    # Copy monitoring provisioning files if local monitoring
    if [[ "${MONITORING_MODE:-none}" == "local" ]]; then
        copy_monitoring_files "$template_dir"
    fi

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

# Enable GPU in docker-compose if NVIDIA detected
enable_gpu_compose() {
    if [[ "${DETECTED_GPU:-none}" == "nvidia" ]]; then
        echo -e "${YELLOW}Включение GPU поддержки в docker-compose...${NC}"
        local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"

        # Uncomment GPU section in ollama service
        sed -i.bak 's|#__GPU__||g' "$compose_file"
        rm -f "${compose_file}.bak"

        echo -e "${GREEN}GPU поддержка включена${NC}"
    fi
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

    # Copy grafana provisioning
    if [[ -d "${installer_root}/monitoring/grafana" ]]; then
        cp -r "${installer_root}/monitoring/grafana/provisioning/"* "${dest}/grafana/provisioning/"
        cp -r "${installer_root}/monitoring/grafana/dashboards/"* "${dest}/grafana/dashboards/"
    fi

    echo -e "${GREEN}Файлы мониторинга скопированы${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_config "${1:-lan}" "${2:-.}"
fi
