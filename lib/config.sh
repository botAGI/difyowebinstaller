#!/usr/bin/env bash
# config.sh — Generate .env, nginx.conf, redis.conf, sandbox config, compose GPU setup.
# Dependencies: common.sh (log_*, generate_random, _atomic_sed, escape_sed,
#               safe_write_file, validate_no_default_secrets, ensure_bind_mount_files)
# Functions: generate_config(profile, template_dir), enable_gpu_compose()
# Expects: wizard exports (DEPLOY_PROFILE, LLM_PROVIDER, DOMAIN, etc.)
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# MAIN CONFIG GENERATION
# ============================================================================

generate_config() {
    local profile="$1"
    local template_dir="$2"

    log_info "Generating configuration (profile: ${profile})..."

    _create_directory_structure
    _copy_compose_file "$template_dir"
    _generate_secrets
    _generate_env_file "$profile" "$template_dir"
    _append_provider_vars
    _copy_versions "$template_dir"
    _copy_release_manifest "$template_dir"

    # Sub-configs
    generate_nginx_config "$profile" "$template_dir"
    handle_tls_config "$profile"

    if [[ "${ENABLE_AUTHELIA:-false}" == "true" ]]; then
        _enable_authelia_nginx
        _copy_authelia_files "$template_dir"
    fi

    if [[ "${MONITORING_MODE:-none}" == "local" ]]; then
        _copy_monitoring_files "$template_dir"
        _configure_alertmanager
    fi

    generate_redis_config
    generate_sandbox_config
    _generate_squid_config

    # Validate secrets
    validate_no_default_secrets "${INSTALL_DIR}/docker/.env"

    # Secure permissions
    chmod 600 "${INSTALL_DIR}/docker/.env"
    if [[ $(id -u) -eq 0 ]]; then
        chown root:root "${INSTALL_DIR}/docker/.env"
    fi

    # Store admin credentials
    _store_admin_credentials

    log_success "Configuration generated: ${INSTALL_DIR}/docker/.env"
}

# ============================================================================
# DIRECTORY STRUCTURE
# ============================================================================

_create_directory_structure() {
    local dirs=(
        "${INSTALL_DIR}/docker/volumes/sandbox/conf"
        "${INSTALL_DIR}/docker/volumes/app/storage"
        "${INSTALL_DIR}/docker/volumes/db/data"
        "${INSTALL_DIR}/docker/volumes/redis/data"
        "${INSTALL_DIR}/docker/volumes/weaviate"
        "${INSTALL_DIR}/docker/volumes/qdrant"
        "${INSTALL_DIR}/docker/volumes/plugin_daemon/storage"
        "${INSTALL_DIR}/docker/volumes/certbot/conf"
        "${INSTALL_DIR}/docker/volumes/certbot/www"
        "${INSTALL_DIR}/docker/volumes/certbot/ssl"
        "${INSTALL_DIR}/docker/volumes/ssrf_proxy"
        "${INSTALL_DIR}/docker/nginx"
        "${INSTALL_DIR}/docker/monitoring/grafana/provisioning/datasources"
        "${INSTALL_DIR}/docker/monitoring/grafana/provisioning/dashboards"
        "${INSTALL_DIR}/docker/monitoring/grafana/dashboards"
        "${INSTALL_DIR}/branding"
        "${INSTALL_DIR}/scripts"
        "${INSTALL_DIR}/workflows"
        "/var/backups/agmind"
    )
    for d in "${dirs[@]}"; do
        mkdir -p "$d" 2>/dev/null || log_warn "Cannot create ${d} (may need root)"
    done
}

_copy_compose_file() {
    local template_dir="$1"
    cp "${template_dir}/docker-compose.yml" "${INSTALL_DIR}/docker/docker-compose.yml"
}

# ============================================================================
# SECRET GENERATION
# ============================================================================

# Module-level variables set by _generate_secrets, consumed by _generate_env_file
_SECRET_KEY=""
_DB_PASSWORD=""
_REDIS_PASSWORD=""
_SANDBOX_API_KEY=""
_PLUGIN_DAEMON_KEY=""
_PLUGIN_INNER_API_KEY=""
_WEAVIATE_API_KEY=""
_QDRANT_API_KEY=""
_GRAFANA_ADMIN_PASSWORD=""
_ADMIN_PASSWORD_PLAIN=""
_ADMIN_PASSWORD_B64=""
_AUTHELIA_JWT_SECRET=""

_generate_secrets() {
    _SECRET_KEY="$(generate_random 64)"
    _DB_PASSWORD="$(generate_random 32)"
    _REDIS_PASSWORD="$(generate_random 32)"
    _SANDBOX_API_KEY="dify-sandbox-$(generate_random 16)"
    _PLUGIN_DAEMON_KEY="$(generate_random 48)"
    _PLUGIN_INNER_API_KEY="$(generate_random 48)"
    _WEAVIATE_API_KEY="$(generate_random 32)"
    _QDRANT_API_KEY="$(generate_random 32)"
    _GRAFANA_ADMIN_PASSWORD="$(generate_random 16)"
    _AUTHELIA_JWT_SECRET="$(generate_random 64)"

    _ADMIN_PASSWORD_PLAIN="$(generate_random 16)"
    _ADMIN_PASSWORD_B64="$(echo -n "$_ADMIN_PASSWORD_PLAIN" | base64)"

    # Fatal check
    if [[ -z "$_SECRET_KEY" || -z "$_DB_PASSWORD" || -z "$_REDIS_PASSWORD" || -z "$_ADMIN_PASSWORD_PLAIN" ]]; then
        log_error "FATAL: failed to generate secrets (/dev/urandom issue)"
        return 1
    fi

    # Export for other modules
    GRAFANA_ADMIN_PASSWORD="$_GRAFANA_ADMIN_PASSWORD"
    export GRAFANA_ADMIN_PASSWORD
}

# ============================================================================
# .ENV GENERATION
# ============================================================================

_generate_env_file() {
    local profile="$1"
    local template_dir="$2"
    local template_file="${template_dir}/env.${profile}.template"
    local env_file="${INSTALL_DIR}/docker/.env"

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: ${template_file}"
        return 1
    fi

    # Backup existing .env
    if [[ -f "$env_file" ]]; then
        log_warn "Existing .env will be overwritten with new secrets"
        cp "$env_file" "${env_file}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    cp "$template_file" "$env_file"
    chmod 600 "$env_file"

    # Escape user-input values for safe sed replacement
    local safe_domain safe_certbot_email safe_monitoring_endpoint safe_webhook_url
    local safe_llm_model safe_embedding_model safe_vllm_model safe_hf_token
    local safe_llm_provider safe_embed_provider
    local safe_monitoring_token safe_telegram_token safe_telegram_chat_id

    safe_domain="$(escape_sed "${DOMAIN:-localhost}")"
    safe_certbot_email="$(escape_sed "${CERTBOT_EMAIL:-}")"
    safe_monitoring_endpoint="$(escape_sed "${MONITORING_ENDPOINT:-}")"
    safe_webhook_url="$(escape_sed "${ALERT_WEBHOOK_URL:-}")"
    safe_llm_model="$(escape_sed "${LLM_MODEL:-qwen2.5:14b}")"
    safe_embedding_model="$(escape_sed "${EMBEDDING_MODEL:-bge-m3}")"
    safe_llm_provider="$(escape_sed "${LLM_PROVIDER:-ollama}")"
    safe_embed_provider="$(escape_sed "${EMBED_PROVIDER:-ollama}")"
    safe_vllm_model="$(escape_sed "${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct}")"
    safe_hf_token="$(escape_sed "${HF_TOKEN:-}")"
    safe_monitoring_token="$(escape_sed "${MONITORING_TOKEN:-}")"
    safe_telegram_token="$(escape_sed "${ALERT_TELEGRAM_TOKEN:-}")"
    safe_telegram_chat_id="$(escape_sed "${ALERT_TELEGRAM_CHAT_ID:-}")"

    # ETL type mapping (v3: true/false → unstructured_api/dify)
    local etl_type="dify"
    if [[ "${ETL_ENHANCED:-false}" == "true" ]]; then
        etl_type="unstructured_api"
    fi

    # Replace all placeholders (atomic: temp + mv)
    local env_tmp="${env_file}.tmp.$$"
    sed \
        -e "s|__SECRET_KEY__|${_SECRET_KEY}|g" \
        -e "s|__DB_PASSWORD__|${_DB_PASSWORD}|g" \
        -e "s|__REDIS_PASSWORD__|${_REDIS_PASSWORD}|g" \
        -e "s|__SANDBOX_API_KEY__|${_SANDBOX_API_KEY}|g" \
        -e "s|__PLUGIN_DAEMON_KEY__|${_PLUGIN_DAEMON_KEY}|g" \
        -e "s|__PLUGIN_INNER_API_KEY__|${_PLUGIN_INNER_API_KEY}|g" \
        -e "s|__ADMIN_PASSWORD_B64__|${_ADMIN_PASSWORD_B64}|g" \
        -e "s|__LLM_MODEL__|${safe_llm_model}|g" \
        -e "s|__EMBEDDING_MODEL__|${safe_embedding_model}|g" \
        -e "s|__DOMAIN__|${safe_domain}|g" \
        -e "s|__CERTBOT_EMAIL__|${safe_certbot_email}|g" \
        -e "s|__VECTOR_STORE__|${VECTOR_STORE:-weaviate}|g" \
        -e "s|__WEAVIATE_API_KEY__|${_WEAVIATE_API_KEY}|g" \
        -e "s|__QDRANT_API_KEY__|${_QDRANT_API_KEY}|g" \
        -e "s|__ETL_TYPE__|${etl_type}|g" \
        -e "s|__TLS_MODE__|${TLS_MODE:-none}|g" \
        -e "s|__MONITORING_MODE__|${MONITORING_MODE:-none}|g" \
        -e "s|__MONITORING_ENDPOINT__|${safe_monitoring_endpoint}|g" \
        -e "s|__MONITORING_TOKEN__|${safe_monitoring_token}|g" \
        -e "s|__GRAFANA_ADMIN_PASSWORD__|${_GRAFANA_ADMIN_PASSWORD}|g" \
        -e "s|__ALERT_MODE__|${ALERT_MODE:-none}|g" \
        -e "s|__ALERT_WEBHOOK_URL__|${safe_webhook_url}|g" \
        -e "s|__ALERT_TELEGRAM_TOKEN__|${safe_telegram_token}|g" \
        -e "s|__ALERT_TELEGRAM_CHAT_ID__|${safe_telegram_chat_id}|g" \
        -e "s|__LLM_PROVIDER__|${safe_llm_provider}|g" \
        -e "s|__EMBED_PROVIDER__|${safe_embed_provider}|g" \
        -e "s|__VLLM_MODEL__|${safe_vllm_model}|g" \
        -e "s|__HF_TOKEN__|${safe_hf_token}|g" \
        -e "s|__AUTHELIA_JWT_SECRET__|${_AUTHELIA_JWT_SECRET}|g" \
        "$env_file" > "$env_tmp" || { rm -f "$env_tmp"; return 1; }
    mv "$env_tmp" "$env_file"
    chmod 600 "$env_file"
}

_append_provider_vars() {
    local env_file="${INSTALL_DIR}/docker/.env"
    {
        echo ""
        echo "# --- Provider-specific WebUI vars ---"
        case "${LLM_PROVIDER:-ollama}" in
            ollama)
                echo "OLLAMA_BASE_URL=http://ollama:11434"
                echo "ENABLE_OLLAMA_API=true"
                echo "ENABLE_OPENAI_API=false"
                echo "OPENAI_API_BASE_URL="
                ;;
            vllm)
                echo "OLLAMA_BASE_URL="
                echo "ENABLE_OLLAMA_API=false"
                echo "ENABLE_OPENAI_API=true"
                echo "OPENAI_API_BASE_URL=http://vllm:8000/v1"
                [[ -n "${VLLM_CUDA_SUFFIX:-}" ]] && echo "VLLM_CUDA_SUFFIX=${VLLM_CUDA_SUFFIX}"
                ;;
            external|skip)
                echo "OLLAMA_BASE_URL="
                echo "ENABLE_OLLAMA_API=false"
                echo "ENABLE_OPENAI_API=false"
                echo "OPENAI_API_BASE_URL="
                ;;
        esac
    } >> "$env_file"
}

_copy_versions() {
    local template_dir="$1"
    local versions_file="${template_dir}/versions.env"
    local env_file="${INSTALL_DIR}/docker/.env"

    if [[ ! -f "$versions_file" ]]; then
        log_warn "versions.env not found: ${versions_file}"
        return 0
    fi

    cp "$versions_file" "${INSTALL_DIR}/versions.env"

    echo "" >> "$env_file"
    echo "# === Pinned versions (from versions.env) ===" >> "$env_file"
    while IFS='=' read -r key value; do
        # Validate key format and value safety
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*_VERSION$ ]] || continue
        [[ "$value" =~ ^[a-zA-Z0-9._:-]+$ ]] || continue
        echo "${key}=${value}" >> "$env_file"
    done < <(LC_ALL=C grep -E '^[A-Z].*_VERSION=' "$versions_file")
}

_copy_release_manifest() {
    local template_dir="$1"
    local manifest_file="${template_dir}/release-manifest.json"
    if [[ -f "$manifest_file" ]]; then
        cp "$manifest_file" "${INSTALL_DIR}/release-manifest.json"
    fi
}

_store_admin_credentials() {
    install -m 600 /dev/null "${INSTALL_DIR}/.admin_password"
    echo "$_ADMIN_PASSWORD_PLAIN" > "${INSTALL_DIR}/.admin_password"
    if [[ $(id -u) -eq 0 ]]; then
        chown root:root "${INSTALL_DIR}/.admin_password"
    fi
}

# ============================================================================
# NGINX CONFIG
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

    _atomic_sed "$nginx_conf" -e "s|__SERVER_NAME__|${server_name}|g"

    # TLS markers
    if [[ "${TLS_MODE:-none}" != "none" ]]; then
        _atomic_sed "$nginx_conf" 's|#__TLS__||g'
        _atomic_sed "$nginx_conf" 's|#__TLS_REDIRECT__||g'
    else
        _atomic_sed "$nginx_conf" '/#__TLS__/d'
        _atomic_sed "$nginx_conf" '/#__TLS_REDIRECT__/d'
    fi

    # TLS cert/key paths
    local cert_path="/etc/nginx/ssl/cert.pem"
    local key_path="/etc/nginx/ssl/key.pem"
    if [[ "${TLS_MODE:-none}" == "letsencrypt" ]]; then
        cert_path="/etc/letsencrypt/live/${DOMAIN:-localhost}/fullchain.pem"
        key_path="/etc/letsencrypt/live/${DOMAIN:-localhost}/privkey.pem"
    fi
    _atomic_sed "$nginx_conf" -e "s|__TLS_CERT_PATH__|${cert_path}|g" -e "s|__TLS_KEY_PATH__|${key_path}|g"
}

# ============================================================================
# REDIS CONFIG (ACL instead of rename-command — Redis 7+)
# ============================================================================

generate_redis_config() {
    local redis_conf="${INSTALL_DIR}/docker/volumes/redis/redis.conf"
    safe_write_file "$redis_conf"

    local redis_pass
    redis_pass="$(grep '^REDIS_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "")"
    if [[ -z "$redis_pass" ]]; then
        log_error "FATAL: REDIS_PASSWORD empty in .env"
        return 1
    fi

    cat > "$redis_conf" << REDISEOF
# AGMind Redis Configuration — Hardened (Redis 7+ ACL, no deprecated commands)
bind 0.0.0.0
protected-mode no

# Authentication via ACL (Redis 7+ recommended approach)
user default on >${redis_pass} ~* &* +@all -@dangerous
user agmind on >${redis_pass} ~* &* +@all -@dangerous

maxmemory 512mb
maxmemory-policy allkeys-lru
save 60 1000
save 300 100
appendonly yes
appendfilename "appendonly.aof"

# Connection limits
maxclients 100
timeout 300
tcp-keepalive 60
REDISEOF

    chmod 644 "$redis_conf"
    # Redis image runs as uid 999
    if [[ $(id -u) -eq 0 ]]; then
        chown 999:999 "$redis_conf" 2>/dev/null || true
    fi
}

# ============================================================================
# SANDBOX CONFIG
# ============================================================================

generate_sandbox_config() {
    local sandbox_conf="${INSTALL_DIR}/docker/volumes/sandbox/conf/config.yaml"
    safe_write_file "$sandbox_conf"

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
SANDBOXEOF

    local sandbox_key
    sandbox_key="$(grep '^SANDBOX_API_KEY=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "dify-sandbox")"
    _atomic_sed "$sandbox_conf" "s|__will_be_replaced__|${sandbox_key}|g"
}

# ============================================================================
# SQUID CONFIG (SSRF protection)
# ============================================================================

_generate_squid_config() {
    local squid_conf="${INSTALL_DIR}/docker/volumes/ssrf_proxy/squid.conf"
    safe_write_file "$squid_conf"

    cat > "$squid_conf" << 'SQUIDEOF'
# AGMind SSRF Proxy — Block metadata, RFC1918, link-local
acl localnet src 172.16.0.0/12
acl SSL_ports port 443
acl Safe_ports port 80 443 1025-65535
acl CONNECT method CONNECT

# Block cloud metadata endpoints
acl metadata dst 169.254.169.254
acl metadata dst 169.254.0.0/16
http_access deny metadata

# Block RFC1918 private networks (except Docker)
acl private_nets dst 10.0.0.0/8
acl private_nets dst 192.168.0.0/16
http_access deny private_nets

# Allow Docker internal networks
acl docker_nets src 172.16.0.0/12
http_access allow docker_nets

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localnet
http_access deny all

http_port 3128
coredump_dir /var/spool/squid
SQUIDEOF

    chmod 644 "$squid_conf"
}

# ============================================================================
# GPU COMPOSE SUPPORT
# ============================================================================

enable_gpu_compose() {
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"

    case "${DETECTED_GPU:-none}" in
        none)
            log_info "No GPU detected — CPU mode"
            _atomic_sed "$compose_file" '/#__GPU__/d'
            ;;
        nvidia)
            log_info "Enabling NVIDIA GPU support..."
            _atomic_sed "$compose_file" 's|#__GPU__||g'
            log_success "NVIDIA GPU → deploy.resources.reservations.devices"
            ;;
        amd)
            log_info "Enabling AMD ROCm GPU support..."
            _atomic_sed "$compose_file" 's|#__GPU__||g'
            _atomic_sed "$compose_file" '/driver: nvidia/,/capabilities: \[gpu\]/c\      # AMD ROCm GPU\n    devices:\n      - /dev/kfd:/dev/kfd\n      - /dev/dri:/dev/dri\n    group_add:\n      - video\n      - render'
            _atomic_sed "$compose_file" '/OLLAMA_API_BASE/a\      OLLAMA_ROCM: "1"' 2>/dev/null || true
            log_success "AMD ROCm GPU → device passthrough"
            ;;
        intel)
            log_info "Enabling Intel GPU support..."
            _atomic_sed "$compose_file" 's|#__GPU__||g'
            _atomic_sed "$compose_file" '/driver: nvidia/,/capabilities: \[gpu\]/c\      # Intel GPU\n    devices:\n      - /dev/dri:/dev/dri\n    group_add:\n      - video\n      - render'
            log_success "Intel GPU → /dev/dri passthrough"
            ;;
        apple)
            log_info "Apple Silicon — GPU handled natively via Metal"
            _atomic_sed "$compose_file" '/#__GPU__/d'
            ;;
    esac

    # If vLLM and TEI share the same GPU, reduce vLLM memory utilization
    # to leave room for TEI (~1.5-2 GB VRAM for bge-m3)
    if [[ "${LLM_PROVIDER:-}" == "vllm" && "${EMBED_PROVIDER:-}" == "tei" ]]; then
        log_info "vLLM + TEI on same GPU — setting gpu-memory-utilization=0.75"
        _atomic_sed "$compose_file" \
            's|--gpu-memory-utilization 0\.90|--gpu-memory-utilization 0.75|g'
    fi
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
            _generate_self_signed_cert "$ssl_dir"
            ;;
        custom)
            _copy_custom_cert "$ssl_dir"
            ;;
        letsencrypt)
            log_info "TLS: Let's Encrypt (certbot will obtain cert after launch)"
            ;;
        none)
            log_info "TLS: disabled"
            ;;
    esac
}

_generate_self_signed_cert() {
    local ssl_dir="$1"
    mkdir -p "$ssl_dir"

    if ! command -v openssl &>/dev/null; then
        log_error "openssl not found. Install: apt install openssl"
        return 1
    fi

    log_info "Generating self-signed certificate..."
    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${ssl_dir}/key.pem" \
        -out "${ssl_dir}/cert.pem" \
        -subj "/CN=${DOMAIN:-localhost}/O=AGMind/C=US" \
        2>/dev/null

    chmod 600 "${ssl_dir}/key.pem"
    log_success "Self-signed certificate created"
}

_copy_custom_cert() {
    local ssl_dir="$1"
    mkdir -p "$ssl_dir"

    if [[ -n "${TLS_CERT_PATH:-}" && -f "${TLS_CERT_PATH}" ]]; then
        cp "${TLS_CERT_PATH}" "${ssl_dir}/cert.pem"
        cp "${TLS_KEY_PATH}" "${ssl_dir}/key.pem"
        chmod 600 "${ssl_dir}/key.pem"
        log_success "Custom certificate copied"
    else
        log_error "Certificate file not found: ${TLS_CERT_PATH:-not specified}"
        return 1
    fi
}

# ============================================================================
# AUTHELIA
# ============================================================================

_enable_authelia_nginx() {
    local nginx_conf="${INSTALL_DIR}/docker/nginx/nginx.conf"
    if [[ ! -f "$nginx_conf" ]]; then
        log_error "nginx.conf not found: ${nginx_conf}"
        return 1
    fi

    log_info "Enabling Authelia in nginx..."
    _atomic_sed "$nginx_conf" 's|#__AUTHELIA__||g'
    log_success "Authelia blocks activated in nginx.conf"
}

_copy_authelia_files() {
    local template_dir="$1"
    local authelia_dir="${INSTALL_DIR}/docker/authelia"
    mkdir -p "$authelia_dir"

    log_info "Copying Authelia files..."
    for f in "configuration.yml.template" "users_database.yml.template"; do
        local src="${template_dir}/authelia/${f}"
        local dest="${authelia_dir}/${f%.template}"
        if [[ -f "$src" ]]; then
            safe_write_file "$dest"
            cp "$src" "$dest"
        fi
    done
    log_success "Authelia files copied"
}

# ============================================================================
# MONITORING
# ============================================================================

_copy_monitoring_files() {
    local template_dir="$1"
    local installer_root
    installer_root="$(dirname "$template_dir")"
    local dest="${INSTALL_DIR}/docker/monitoring"

    log_info "Copying monitoring files..."
    mkdir -p "$dest"

    # Core config files
    local mon_files=("prometheus.yml" "alert_rules.yml" "alertmanager.yml" "loki-config.yml" "promtail-config.yml")
    for f in "${mon_files[@]}"; do
        if [[ -f "${installer_root}/monitoring/${f}" ]]; then
            safe_write_file "${dest}/${f}"
            cp "${installer_root}/monitoring/${f}" "${dest}/${f}"
            chmod 644 "${dest}/${f}"
        else
            log_warn "Monitoring source not found: monitoring/${f}"
        fi
    done

    # Grafana provisioning
    if [[ -d "${installer_root}/monitoring/grafana" ]]; then
        cp -r "${installer_root}/monitoring/grafana/provisioning/"* "${dest}/grafana/provisioning/" 2>/dev/null || true
        cp -r "${installer_root}/monitoring/grafana/dashboards/"* "${dest}/grafana/dashboards/" 2>/dev/null || true
    fi

    # Post-copy verification
    for f in "${mon_files[@]}"; do
        if [[ -d "${dest}/${f}" ]]; then
            log_warn "BUG: ${f} is a directory after copy — fixing"
            rm -rf "${dest:?}/${f}"
            cp "${installer_root}/monitoring/${f}" "${dest}/${f}" 2>/dev/null || touch "${dest}/${f}"
        fi
    done

    log_success "Monitoring files copied"
}

_configure_alertmanager() {
    local alertmanager_conf="${INSTALL_DIR}/docker/monitoring/alertmanager.yml"
    safe_write_file "$alertmanager_conf"

    # Create default config if empty
    if [[ ! -s "$alertmanager_conf" ]]; then
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

    case "${ALERT_MODE:-none}" in
        telegram)
            local token="${ALERT_TELEGRAM_TOKEN:-}"
            local chat_id="${ALERT_TELEGRAM_CHAT_ID:-}"
            if [[ -n "$token" && -n "$chat_id" ]]; then
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
                _atomic_sed "$alertmanager_conf" 's|#__WEBHOOK__||g'
                local safe_webhook
                safe_webhook="$(escape_sed "$webhook_url")"
                _atomic_sed "$alertmanager_conf" "s|__ALERT_WEBHOOK_URL__|${safe_webhook}|g"
            fi
            ;;
    esac
    chmod 644 "$alertmanager_conf"
}

# ============================================================================
# STANDALONE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    generate_config "${1:-lan}" "${2:-.}"
fi
