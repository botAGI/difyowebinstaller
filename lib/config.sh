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
        _configure_peer_monitoring || log_warn "Peer monitoring setup had issues (non-fatal)"
    fi

    generate_redis_config
    generate_sandbox_config
    _generate_squid_config
    if [[ "${ENABLE_LITELLM:-true}" == "true" ]]; then
        _generate_litellm_config
    fi
    _generate_searxng_config "$template_dir"

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
_AUTHELIA_SESSION_SECRET=""
_AUTHELIA_STORAGE_KEY=""
_LITELLM_MASTER_KEY=""
_SEARXNG_SECRET_KEY=""
_SURREALDB_PASSWORD=""
_NOTEBOOK_ENCRYPTION_KEY=""
_MINIO_ROOT_USER=""
_MINIO_ROOT_PASSWORD=""
_S3_ACCESS_KEY=""
_S3_SECRET_KEY=""

# _restore_secrets_from_backup — restore volume-bound secrets when PG data exists (IREL-03)
# Returns 0 if any secrets were restored, 1 if nothing restored.
# Must be called AFTER fresh secrets are generated so they serve as a safe fallback.
_restore_secrets_from_backup() {
    local pg_version_file="${INSTALL_DIR}/docker/volumes/db/data/PG_VERSION"

    # No PG data: fresh install — nothing to restore
    if [[ ! -f "$pg_version_file" ]]; then
        return 1
    fi

    # PG data exists — find the most recent .env backup
    local latest_backup
    latest_backup="$(ls -t "${INSTALL_DIR}/docker/.env.backup."* 2>/dev/null | head -1)"

    if [[ -z "$latest_backup" ]]; then
        log_warn "PG data exists but no .env backup found — generating new password (sync_db_password will fix)"
        return 1
    fi

    local restored=false

    local saved_db_pass
    saved_db_pass="$(grep '^DB_PASSWORD=' "$latest_backup" | cut -d'=' -f2-)"
    if [[ -n "$saved_db_pass" ]]; then
        _DB_PASSWORD="$saved_db_pass"
        restored=true
    fi

    local saved_redis_pass
    saved_redis_pass="$(grep '^REDIS_PASSWORD=' "$latest_backup" | cut -d'=' -f2-)"
    if [[ -n "$saved_redis_pass" ]]; then
        _REDIS_PASSWORD="$saved_redis_pass"
        restored=true
    fi

    local saved_secret_key
    saved_secret_key="$(grep '^SECRET_KEY=' "$latest_backup" | cut -d'=' -f2-)"
    if [[ -n "$saved_secret_key" ]]; then
        _SECRET_KEY="$saved_secret_key"
        restored=true
    fi

    if [[ "$restored" == "true" ]]; then
        return 0
    fi
    return 1
}

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
    _AUTHELIA_SESSION_SECRET="$(generate_random 64)"
    _AUTHELIA_STORAGE_KEY="$(generate_random 64)"
    _LITELLM_MASTER_KEY="sk-$(generate_random 32)"
    _SEARXNG_SECRET_KEY="$(generate_random 32)"
    _SURREALDB_PASSWORD="$(generate_random 24)"
    _NOTEBOOK_ENCRYPTION_KEY="$(generate_random 32)"

    _MINIO_ROOT_USER="agmind-admin"
    _MINIO_ROOT_PASSWORD="$(generate_random 32)"
    _S3_ACCESS_KEY="$(generate_random 20)"
    _S3_SECRET_KEY="$(generate_random 40)"

    _ADMIN_PASSWORD_PLAIN="$(generate_random 16)"
    _ADMIN_PASSWORD_B64="$(echo -n "$_ADMIN_PASSWORD_PLAIN" | base64)"

    # Override volume-bound secrets from backup if PG data exists (IREL-03)
    if _restore_secrets_from_backup; then
        log_info "Restored DB_PASSWORD, REDIS_PASSWORD, SECRET_KEY from previous installation"
    fi

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
    safe_vllm_model="$(escape_sed "${VLLM_MODEL:-QuantTrio/Qwen3.5-27B-AWQ}")"
    safe_hf_token="$(escape_sed "${HF_TOKEN:-}")"
    safe_enable_reranker="$(escape_sed "${ENABLE_RERANKER:-false}")"
    safe_rerank_model="$(escape_sed "${RERANK_MODEL:-}")"
    safe_tei_embed_version="$(escape_sed "${TEI_EMBED_VERSION:-}")"
    safe_monitoring_token="$(escape_sed "${MONITORING_TOKEN:-}")"
    safe_telegram_token="$(escape_sed "${ALERT_TELEGRAM_TOKEN:-}")"
    safe_telegram_chat_id="$(escape_sed "${ALERT_TELEGRAM_CHAT_ID:-}")"

    # ETL type: Dify 1.13+ expects exact string "Unstructured" (case-sensitive)
    local etl_type="dify"
    if [[ "${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}" == "true" ]]; then
        etl_type="Unstructured"
    fi

    # FILES_URL: server IP for LAN profile (VPS path dropped 2026-04-25)
    local files_url=""
    local server_ip
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
    files_url="http://${server_ip}"
    local safe_files_url
    safe_files_url="$(escape_sed "${files_url}")"

    # Storage type: MinIO → s3, otherwise local
    local storage_type="local"
    local s3_endpoint=""
    if [[ "${ENABLE_MINIO:-true}" == "true" ]]; then
        storage_type="s3"
        s3_endpoint="http://minio:9000"
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
        -e "s|__GRAFANA_BIND_ADDR__|${GRAFANA_BIND_ADDR:-127.0.0.1}|g" \
        -e "s|__PORTAINER_BIND_ADDR__|${PORTAINER_BIND_ADDR:-127.0.0.1}|g" \
        -e "s|__ALERT_MODE__|${ALERT_MODE:-none}|g" \
        -e "s|__ALERT_WEBHOOK_URL__|${safe_webhook_url}|g" \
        -e "s|__ALERT_TELEGRAM_TOKEN__|${safe_telegram_token}|g" \
        -e "s|__ALERT_TELEGRAM_CHAT_ID__|${safe_telegram_chat_id}|g" \
        -e "s|__ALERT_EMAIL_TO__|$(escape_sed "${ALERT_EMAIL_TO:-}")|g" \
        -e "s|__ALERT_EMAIL_FROM__|$(escape_sed "${ALERT_EMAIL_FROM:-}")|g" \
        -e "s|__ALERT_EMAIL_SMARTHOST__|$(escape_sed "${ALERT_EMAIL_SMARTHOST:-}")|g" \
        -e "s|__ALERT_EMAIL_AUTH_USER__|$(escape_sed "${ALERT_EMAIL_AUTH_USER:-}")|g" \
        -e "s|__ALERT_EMAIL_AUTH_PASS__|$(escape_sed "${ALERT_EMAIL_AUTH_PASS:-}")|g" \
        -e "s|__LLM_PROVIDER__|${safe_llm_provider}|g" \
        -e "s|__EMBED_PROVIDER__|${safe_embed_provider}|g" \
        -e "s|__VLLM_MODEL__|${safe_vllm_model}|g" \
        -e "s|__HF_TOKEN__|${safe_hf_token}|g" \
        -e "s|__ENABLE_RERANKER__|${safe_enable_reranker}|g" \
        -e "s|__RERANK_MODEL__|${safe_rerank_model}|g" \
        -e "s|__TEI_EMBED_VERSION__|${safe_tei_embed_version}|g" \
        -e "s|__TEI_RERANK_VERSION__|$(escape_sed "${TEI_RERANK_VERSION:-cpu-1.9.3}")|g" \
        -e "s|__AUTHELIA_JWT_SECRET__|${_AUTHELIA_JWT_SECRET}|g" \
        -e "s|__AUTHELIA_SESSION_SECRET__|${_AUTHELIA_SESSION_SECRET}|g" \
        -e "s|__AUTHELIA_STORAGE_KEY__|${_AUTHELIA_STORAGE_KEY}|g" \
        -e "s|__LITELLM_MASTER_KEY__|${_LITELLM_MASTER_KEY}|g" \
        -e "s|__FILES_URL__|${safe_files_url}|g" \
        -e "s|__DOCLING_IMAGE__|${DOCLING_IMAGE:-}|g" \
        -e "s|__OCR_LANG__|${OCR_LANG:-rus,eng}|g" \
        -e "s|__NVIDIA_VISIBLE_DEVICES__|${NVIDIA_VISIBLE_DEVICES:-}|g" \
        -e "s|__ENABLE_LITELLM__|$(escape_sed "${ENABLE_LITELLM:-true}")|g" \
        -e "s|__ENABLE_SEARXNG__|$(escape_sed "${ENABLE_SEARXNG:-false}")|g" \
        -e "s|__ENABLE_NOTEBOOK__|$(escape_sed "${ENABLE_NOTEBOOK:-false}")|g" \
        -e "s|__ENABLE_DBGPT__|$(escape_sed "${ENABLE_DBGPT:-false}")|g" \
        -e "s|__ENABLE_CRAWL4AI__|$(escape_sed "${ENABLE_CRAWL4AI:-false}")|g" \
        -e "s|__ENABLE_OPENWEBUI__|$(escape_sed "${ENABLE_OPENWEBUI:-false}")|g" \
        -e "s|__ENABLE_DIFY_PREMIUM__|$(escape_sed "${ENABLE_DIFY_PREMIUM:-true}")|g" \
        -e "s|__SEARXNG_SECRET_KEY__|$(escape_sed "${_SEARXNG_SECRET_KEY}")|g" \
        -e "s|__SURREALDB_PASSWORD__|$(escape_sed "${_SURREALDB_PASSWORD}")|g" \
        -e "s|__NOTEBOOK_ENCRYPTION_KEY__|$(escape_sed "${_NOTEBOOK_ENCRYPTION_KEY}")|g" \
        -e "s|__ENABLE_MINIO__|$(escape_sed "${ENABLE_MINIO:-true}")|g" \
        -e "s|__MINIO_ROOT_USER__|${_MINIO_ROOT_USER}|g" \
        -e "s|__MINIO_ROOT_PASSWORD__|${_MINIO_ROOT_PASSWORD}|g" \
        -e "s|__S3_ACCESS_KEY__|${_S3_ACCESS_KEY}|g" \
        -e "s|__S3_SECRET_KEY__|${_S3_SECRET_KEY}|g" \
        -e "s|__S3_BUCKET_NAME__|dify-storage|g" \
        -e "s|__STORAGE_TYPE__|${storage_type}|g" \
        -e "s|__S3_ENDPOINT__|${s3_endpoint}|g" \
        "$env_file" > "$env_tmp" || { rm -f "$env_tmp"; return 1; }
    mv "$env_tmp" "$env_file"
    chmod 600 "$env_file"
}

_append_provider_vars() {
    local env_file="${INSTALL_DIR}/docker/.env"
    local use_litellm="${ENABLE_LITELLM:-true}"
    {
        echo ""
        if [[ "$use_litellm" == "true" ]]; then
            echo "# --- Provider-specific WebUI vars (via LiteLLM) ---"
        else
            echo "# --- Provider-specific WebUI vars (direct, no LiteLLM) ---"
        fi
        case "${LLM_PROVIDER:-ollama}" in
            ollama)
                echo "OLLAMA_BASE_URL=http://ollama:11434"
                echo "ENABLE_OLLAMA_API=true"
                if [[ "$use_litellm" == "true" ]]; then
                    echo "ENABLE_OPENAI_API=true"
                    echo "OPENAI_API_BASE_URL=http://agmind-litellm:4000/v1"
                else
                    echo "ENABLE_OPENAI_API=false"
                    echo "OPENAI_API_BASE_URL="
                fi
                ;;
            vllm)
                echo "OLLAMA_BASE_URL="
                echo "ENABLE_OLLAMA_API=false"
                echo "ENABLE_OPENAI_API=true"
                if [[ "$use_litellm" == "true" ]]; then
                    echo "OPENAI_API_BASE_URL=http://agmind-litellm:4000/v1"
                else
                    echo "OPENAI_API_BASE_URL=http://vllm:8000/v1"
                fi
                if [[ -n "${VLLM_CUDA_SUFFIX:-}" ]]; then echo "VLLM_CUDA_SUFFIX=${VLLM_CUDA_SUFFIX}"; fi
                if [[ -n "${VLLM_MAX_MODEL_LEN:-}" ]]; then echo "VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN}"; fi
                ;;
            external|skip)
                echo "OLLAMA_BASE_URL="
                echo "ENABLE_OLLAMA_API=false"
                echo "ENABLE_OPENAI_API=true"
                if [[ "$use_litellm" == "true" ]]; then
                    echo "OPENAI_API_BASE_URL=http://agmind-litellm:4000/v1"
                else
                    echo "OPENAI_API_BASE_URL="
                fi
                ;;
        esac
        # Canonical cluster placement flags — set by cluster_mode_save (lib/cluster_mode.sh).
        # Single source of truth for "vllm runs on peer" decision in downstream modules.
        echo "LLM_ON_PEER=${LLM_ON_PEER:-false}"
        if [[ -n "${PEER_IP:-}" ]]; then echo "PEER_IP=${PEER_IP}"; fi

        # DGX Spark / vLLM embed/rerank vars (written regardless of LLM provider)
        if [[ -n "${VLLM_IMAGE:-}" ]]; then echo "VLLM_IMAGE=${VLLM_IMAGE}"; fi
        if [[ -n "${VLLM_CMD_PREFIX:-}" ]]; then echo "VLLM_CMD_PREFIX=${VLLM_CMD_PREFIX}"; fi
        if [[ -n "${VLLM_EXTRA_ARGS:-}" ]]; then echo "VLLM_EXTRA_ARGS=\"${VLLM_EXTRA_ARGS}\""; fi
        if [[ "${EMBED_PROVIDER:-}" == "vllm-embed" ]]; then echo "EMBED_PROVIDER=vllm-embed"; fi
        if [[ -n "${VLLM_EMBED_MODEL:-}" && "${EMBED_PROVIDER:-}" == "vllm-embed" ]]; then echo "VLLM_EMBED_MODEL=${VLLM_EMBED_MODEL}"; fi
        if [[ "${RERANKER_PROVIDER:-tei}" == "vllm-rerank" ]]; then echo "RERANKER_PROVIDER=vllm-rerank"; fi
        if [[ -n "${VLLM_RERANK_MODEL:-}" && "${RERANKER_PROVIDER:-tei}" == "vllm-rerank" ]]; then echo "VLLM_RERANK_MODEL=${VLLM_RERANK_MODEL}"; fi
        # DB-GPT API endpoint (used if ENABLE_DBGPT=true)
        if [[ "$use_litellm" == "true" ]]; then
            echo "DBGPT_API_BASE=http://litellm:4000/v1"
            echo "DBGPT_API_KEY=${LITELLM_MASTER_KEY:-}"
        else
            case "${LLM_PROVIDER:-ollama}" in
                ollama) echo "DBGPT_API_BASE=http://ollama:11434/v1"; echo "DBGPT_API_KEY=unused" ;;
                vllm)   echo "DBGPT_API_BASE=http://vllm:8000/v1"; echo "DBGPT_API_KEY=unused" ;;
                *)      echo "DBGPT_API_BASE="; echo "DBGPT_API_KEY=unused" ;;
            esac
        fi
    } >> "$env_file"

    # Auto-detect host docker socket GID for portainer group_add. Without this,
    # portainer (uid=0) cannot read /var/run/docker.sock (mode 660 root:docker)
    # → master endpoint shows "Down" forever. See templates/docker-compose.yml
    # portainer service for context.
    if [[ -S /var/run/docker.sock ]]; then
        local _docker_gid
        _docker_gid="$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 988)"
        echo "DOCKER_GID=${_docker_gid}" >> "$env_file"
        log_info "Detected host docker GID: ${_docker_gid} (portainer needs this)"
    fi

    # Phase 36: collapse duplicate keys, keeping the LAST value (docker compose semantics).
    # _generate_env_file appends conditional overrides after the template was copied in,
    # producing duplicate KEY= lines. Callers (docker compose, dnsmasq generator) rely on
    # last-wins, but scripts using `grep "^KEY=" | head -1` read the wrong value.
    _dedupe_env_file "$env_file"
}

# Keep last occurrence of each KEY= line, preserve comment/blank order.
# Non KEY= lines (comments, blanks, exports) pass through unchanged.
_dedupe_env_file() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0
    local tmp
    tmp=$(mktemp "${env_file}.dedupe.XXXXXX") || return 0
    awk -F= '
        NR==FNR {
            if (/^[A-Za-z_][A-Za-z0-9_]*=/) last[$1] = NR
            next
        }
        /^[A-Za-z_][A-Za-z0-9_]*=/ {
            if (FNR == last[$1]) print
            next
        }
        { print }
    ' "$env_file" "$env_file" > "$tmp" && mv "$tmp" "$env_file"
    chmod 600 "$env_file"
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
        # Allow @ for tag@digest pinning (e.g. PIPELINES_VERSION=main@sha256:...)
        [[ "$value" =~ ^[a-zA-Z0-9._:@-]+$ ]] || continue
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

    # VPS profile с domain server_name был удалён 2026-04-25 — оставляем wildcard.
    local server_name="_"

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
        # Initially use placeholder cert (same path as self-signed)
        # After certbot obtains real cert, _obtain_letsencrypt_cert() switches nginx to LE paths
        cert_path="/etc/nginx/ssl/cert.pem"
        key_path="/etc/nginx/ssl/key.pem"
    fi
    _atomic_sed "$nginx_conf" -e "s|__TLS_CERT_PATH__|${cert_path}|g" -e "s|__TLS_KEY_PATH__|${key_path}|g"

    # LiteLLM markers
    if [[ "${ENABLE_LITELLM:-true}" == "true" ]]; then
        _atomic_sed "$nginx_conf" 's|#__LITELLM__||g'
    else
        _atomic_sed "$nginx_conf" '/#__LITELLM__/d'
    fi

    # DB-GPT markers
    if [[ "${ENABLE_DBGPT:-false}" == "true" ]]; then
        _atomic_sed "$nginx_conf" 's|#__DBGPT__||g'
    else
        _atomic_sed "$nginx_conf" '/#__DBGPT__/d'
    fi

    # Open Notebook markers
    if [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]]; then
        _atomic_sed "$nginx_conf" 's|#__NOTEBOOK__||g'
    else
        _atomic_sed "$nginx_conf" '/#__NOTEBOOK__/d'
    fi

    # SearXNG markers
    if [[ "${ENABLE_SEARXNG:-false}" == "true" ]]; then
        _atomic_sed "$nginx_conf" 's|#__SEARXNG__||g'
    else
        _atomic_sed "$nginx_conf" '/#__SEARXNG__/d'
    fi

    # Crawl4AI markers
    if [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]]; then
        _atomic_sed "$nginx_conf" 's|#__CRAWL4AI__||g'
    else
        _atomic_sed "$nginx_conf" '/#__CRAWL4AI__/d'
    fi

    # Open WebUI markers
    if [[ "${ENABLE_OPENWEBUI:-false}" == "true" ]]; then
        _atomic_sed "$nginx_conf" 's|#__OPENWEBUI__||g'
    else
        _atomic_sed "$nginx_conf" '/#__OPENWEBUI__/d'
    fi

    # Authelia markers (strip when disabled — _enable_authelia_nginx handles enabled case)
    if [[ "${ENABLE_AUTHELIA:-false}" != "true" ]]; then
        _atomic_sed "$nginx_conf" '/#__AUTHELIA__/d'
    fi

    # Register local DNS names in /etc/hosts for vhost routing
    _register_local_dns
}

# ============================================================================
# LOCAL DNS — publish agmind-*.local via mDNS (Avahi/Bonjour)
# Works natively on macOS, Linux, Windows 10+ without client config
# ============================================================================

_register_local_dns() {
    # Ensure avahi-daemon + libnss-mdns installed and running.
    # libnss-mdns is what makes `ping foo.local` actually resolve via NSS.
    # Without it /etc/avahi/hosts is published but system resolver can't read it.
    if ! command -v avahi-daemon >/dev/null 2>&1 || ! dpkg -l libnss-mdns 2>/dev/null | grep -q '^ii'; then
        log_info "Installing avahi-daemon + libnss-mdns for mDNS..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y avahi-daemon avahi-utils libnss-mdns >/dev/null 2>&1 || {
            log_warn "Failed to install avahi stack — mDNS disabled, /etc/hosts fallback only"
        }
    fi

    # v3.0 hotfix (2026-04-19): exclude Docker veth interfaces from avahi mDNS publish.
    # On hosts with 30+ containers avahi announces hostname via every veth*/br-*,
    # causing "Local name collision" with its own records. Restrict avahi to the
    # physical uplink interface.
    local avahi_conf="/etc/avahi/avahi-daemon.conf"
    if [[ -f "$avahi_conf" ]] && ! grep -q '^allow-interfaces=' "$avahi_conf"; then
        # Detect primary interface from default route. Multi-homed hosts have
        # multiple defaults — we take all of them (comma-separated for avahi).
        local primary_ifs
        primary_ifs="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | sort -u | paste -sd, -)"
        if [[ -n "$primary_ifs" ]]; then
            sed -i "/^\[server\]/a allow-interfaces=${primary_ifs}" "$avahi_conf"
            log_info "avahi allow-interfaces=${primary_ifs}"
        else
            log_warn "No default route — cannot determine primary interface; avahi will listen on all (may collide with docker bridges)"
        fi
    fi

    if ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
        systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
    fi

    # Build list of names to publish
    local names=("agmind-dify")
    [[ "${ENABLE_OPENWEBUI:-false}" == "true" ]] && names+=("agmind-chat")
    [[ "${ENABLE_MINIO:-false}" == "true" ]] && names+=("agmind-storage")
    [[ "${ENABLE_DBGPT:-false}" == "true" ]] && names+=("agmind-dbgpt")
    [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]] && names+=("agmind-notebook")
    [[ "${ENABLE_SEARXNG:-false}" == "true" ]] && names+=("agmind-search")
    [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]] && names+=("agmind-crawl")

    local server_ip
    server_ip="$(_mdns_get_primary_ip)"
    if [[ -z "$server_ip" ]]; then
        log_warn "Cannot determine primary uplink IP, skipping mDNS publish"
        log_warn "  Check: ip -o -4 route show to default"
        return 0
    fi

    # v3.0 hotfix R4 (2026-04-19): publish names via avahi-publish-address wrapper.
    # Previously used /etc/avahi/hosts — broken when the server IP matches avahi's
    # primary host record (e.g. spark-XXXX.local), because avahi treats alias
    # records on the same IP as "Local name collision" and silently drops them.
    # avahi-publish-address -R advertises each name as an independent A record.
    local wrapper="/usr/local/bin/agmind-mdns-publish"
    local unit="/etc/systemd/system/agmind-mdns.service"

    # Clean stale /etc/avahi/hosts entries from previous installs (pre-R4)
    if [[ -f /etc/avahi/hosts ]] && grep -q 'agmind-' /etc/avahi/hosts 2>/dev/null; then
        sed -i '/agmind-/d' /etc/avahi/hosts
    fi

    # Build wrapper that publishes each name in parallel
    {
        echo '#!/bin/bash'
        echo '# AGmind mDNS .local aliases — autogenerated by install.sh'
        echo 'set -e'
        echo "trap 'kill \$(jobs -p) 2>/dev/null' EXIT TERM INT"
        for name in "${names[@]}"; do
            echo "/usr/bin/avahi-publish-address -R --no-fail \"${name}.local\" \"${server_ip}\" &"
        done
        echo 'wait'
    } > "$wrapper"
    chmod +x "$wrapper"

    cat > "$unit" <<'EOF'
[Unit]
Description=AGmind mDNS .local aliases (avahi-publish-address wrapper)
Documentation=https://github.com/botAGI/AGmind CLAUDE.md#8
After=avahi-daemon.service
Requires=avahi-daemon.service
BindsTo=avahi-daemon.service
PartOf=avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/local/bin/agmind-mdns-publish
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart avahi-daemon 2>/dev/null || true
    # Small delay so avahi is ready to accept D-Bus before wrapper connects
    sleep 1
    systemctl enable --now agmind-mdns.service >/dev/null 2>&1 \
        || log_warn "agmind-mdns.service failed to start — see: journalctl -u agmind-mdns"

    # LEGACY SAFETY NET — this warn-only block is kept as tertiary defence-in-depth.
    # PRIMARY gate is _assert_no_foreign_mdns() called from:
    #   - install.sh phase_diagnostics (normal flow — hard exit 1)
    #   - lib/detect.sh preflight_checks Check 12 (DRY_RUN + resume paths — errors++)
    # Both abort install before this code runs. This block logs if _register_local_dns
    # is ever called outside install.sh flow (standalone tests, custom scripts).
    # Do NOT remove — defence in depth per CLAUDE.md §8 "Second mDNS responder" lesson.

    # Detect foreign mDNS responders on 5353 (NoMachine, iTunes, etc.) that
    # compete with avahi for the multicast socket and trigger Local name collision.
    local mdns_squatters
    mdns_squatters="$(ss -ulnp 2>/dev/null \
        | awk '$5 ~ /:5353$/ && !/avahi-daemon/ {print $7}' \
        | grep -oE 'users:\(\("[^"]+"' | sort -u | tr '\n' ' ' || true)"
    if [[ -n "$mdns_squatters" ]]; then
        log_warn "Foreign mDNS responder on port 5353: ${mdns_squatters}"
        log_warn "  Known conflicts: NoMachine (EnableLocalNetworkBroadcast 0 in /etc/NX/server/localhost/server.cfg)"
        log_warn "  This may cause 'Local name collision' for agmind-*.local."
    fi

    # v3.0 hotfix (2026-04-19): /etc/hosts fallback for local host-side resolution.
    # install.sh healthcheck + agmind CLI + post-install curl all run on the host
    # and benefit from instant resolution independent of avahi/mDNS quirks.
    # LAN clients still use mDNS via avahi (or dnsmasq below) — this entry is
    # host-local only.
    if ! grep -q "agmind-dify.local" /etc/hosts 2>/dev/null; then
        for name in "${names[@]}"; do
            echo "${server_ip} ${name}.local" >> /etc/hosts
        done
    fi

    log_success "mDNS published via avahi-publish wrapper: ${names[*]}"

    # Unicast DNS via dnsmasq — bonus for clients that want stable DNS
    _setup_dnsmasq "$server_ip" "${names[@]}"

    log_info "Accessible from any LAN device: http://agmind-dify.local"
    log_info "For stable DNS: set ${server_ip} as DNS server on client devices"
}

# ============================================================================
# UNICAST DNS — dnsmasq for reliable agmind-*.local resolution
# mDNS (multicast) is unreliable over WiFi and some switches;
# dnsmasq serves the same names via standard unicast DNS (port 53).
# Clients that add the server IP as DNS get stable name resolution.
# ============================================================================

_setup_dnsmasq() {
    local server_ip="$1"
    shift
    local names=("$@")

    # Install dnsmasq if missing (already present on most Ubuntu/Debian)
    if ! command -v dnsmasq >/dev/null 2>&1; then
        log_info "Installing dnsmasq for unicast DNS..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq >/dev/null 2>&1 || {
            log_warn "Failed to install dnsmasq — unicast DNS disabled, mDNS still works"
            return 0
        }
    fi

    # Ensure conf-dir is enabled in main dnsmasq.conf
    local main_conf="/etc/dnsmasq.conf"
    if [[ -f "$main_conf" ]] && ! grep -q '^conf-dir=/etc/dnsmasq.d/,\*\.conf' "$main_conf" 2>/dev/null; then
        # Uncomment existing line or append
        if grep -q '#conf-dir=/etc/dnsmasq.d/,\*\.conf' "$main_conf" 2>/dev/null; then
            sed -i 's|^#conf-dir=/etc/dnsmasq.d/,\*\.conf|conf-dir=/etc/dnsmasq.d/,*.conf|' "$main_conf"
        else
            echo 'conf-dir=/etc/dnsmasq.d/,*.conf' >> "$main_conf"
        fi
    fi

    # Generate AGMind-specific config
    local conf="/etc/dnsmasq.d/agmind.conf"
    mkdir -p /etc/dnsmasq.d

    cat > "$conf" << EOF
# AGMind forwarding DNS -- .local resolution + upstream forwarding
# Auto-generated by install.sh -- do not edit manually
#
# Clients can set ${server_ip} as their sole DNS server:
# agmind-*.local resolved locally, everything else forwarded upstream.

# Bind only to server IP + loopback -- no conflict with
# systemd-resolved (127.0.0.53) or other DNS services
listen-address=${server_ip},127.0.0.1
bind-interfaces

# Forward non-.local queries to upstream DNS
server=8.8.8.8
server=1.1.1.1

# Authoritative for .local zone
local=/local/

# --- AGMind service records ---
EOF
    for name in "${names[@]}"; do
        echo "address=/${name}.local/${server_ip}" >> "$conf"
    done

    # Validate config before (re)starting
    if ! dnsmasq --test -C "$conf" >/dev/null 2>&1; then
        log_warn "dnsmasq config validation failed — skipping unicast DNS"
        rm -f "$conf"
        return 0
    fi

    # Enable and (re)start — restart picks up new config
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    systemctl restart dnsmasq >/dev/null 2>&1 || {
        log_warn "dnsmasq failed to start — check: systemctl status dnsmasq"
        return 0
    }

    log_success "Unicast DNS active on ${server_ip}:53 (dnsmasq)"
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

# Authentication via ACL (Redis 7+ — explicit blocklist instead of category-based block; allows CONFIG/INFO/KEYS)
user default on >${redis_pass} ~* &* +@all -FLUSHALL -FLUSHDB -SHUTDOWN -BGREWRITEAOF -BGSAVE -DEBUG -MIGRATE -CLUSTER -FAILOVER -REPLICAOF -SLAVEOF -SWAPDB
user agmind on >${redis_pass} ~* &* +@all -FLUSHALL -FLUSHDB -SHUTDOWN -BGREWRITEAOF -BGSAVE -DEBUG -MIGRATE -CLUSTER -FAILOVER -REPLICAOF -SLAVEOF -SWAPDB

maxmemory 512mb
maxmemory-policy allkeys-lru
save 60 1000
save 300 100
appendonly yes
appendfilename "appendonly.aof"

# Connection limits
maxclients 256
timeout 0
tcp-keepalive 30
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

# Generate AGMind service whitelist for Squid from docker-compose.yml.
# Allows Dify API/sandbox to reach internal services (model validation,
# webhooks, vector DB queries) by DNS name, before RFC1918 deny rules.
_squid_agmind_whitelist() {
    local squid_conf="$1"
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"

    # Extract service names from docker-compose (top-level keys under services:)
    local services=""
    if [[ -f "$compose_file" ]]; then
        services=$(docker compose -f "$compose_file" config --services 2>/dev/null || true)
    fi

    # Fallback: hardcoded list if docker compose not available yet
    if [[ -z "$services" ]]; then
        services="api worker web open-webui pipelines ollama vllm tei tei-rerank db redis weaviate qdrant docling sandbox plugin_daemon nginx"
    fi

    {
        echo "# AGMind internal services whitelist (auto-generated from docker-compose)"
        echo "# Allows Dify to reach local model endpoints, vector DBs, and webhooks"
        local acl_line=""
        for svc in $services; do
            # Skip ssrf_proxy itself and utility containers
            # Skip ssrf_proxy itself and utility containers
            case "$svc" in
                ssrf_proxy|redis-lock-cleaner|certbot|promtail|node-exporter|cadvisor) continue ;;
            esac
            acl_line="${acl_line} ${svc}"
        done
        echo "acl agmind_services dstdomain${acl_line}"
        echo "http_access allow agmind_services"
        echo ""
    } >> "$squid_conf"
}

_generate_squid_config() {
    local squid_conf="${INSTALL_DIR}/docker/volumes/ssrf_proxy/squid.conf"
    safe_write_file "$squid_conf"

    cat > "$squid_conf" << 'SQUIDEOF'
# AGMind SSRF Proxy — Block metadata, optionally block RFC1918
acl localnet src 172.16.0.0/12
acl localnet src 10.0.0.0/8
acl SSL_ports port 443
acl Safe_ports port 80 443 1025-65535
acl CONNECT method CONNECT

# Block cloud metadata endpoints (always)
acl metadata dst 169.254.169.254
acl metadata dst 169.254.0.0/16
http_access deny metadata

SQUIDEOF

    # LAN profile (VPS dropped 2026-04-25): allow RFC1918 for internal webhook
    # calls from Dify sandbox. Metadata endpoints are still blocked above.
    cat >> "$squid_conf" << 'SQUIDEOF'
# LAN profile: allow RFC1918 for internal webhook calls from Dify sandbox
# Metadata endpoints are still blocked above
SQUIDEOF

    cat >> "$squid_conf" << 'SQUIDEOF'

# Allow Docker internal networks (both default 172.x and custom 10.x subnets)
acl docker_nets src 172.16.0.0/12
acl docker_nets src 10.0.0.0/8
http_access allow docker_nets

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localnet
http_access deny all

http_port 3128
coredump_dir /var/spool/squid

# Long-running requests (docling 500+ page PDF extraction can take 10+ min).
# Default squid timeouts (5 min) cause 504 Gateway Timeout → Dify retries →
# docling double-processes same file → 3× slowdown observed 2026-04-22 UAT.
# See CLAUDE.md §8 + BACKLOG 999.3 context.
request_timeout 30 minutes
read_timeout 30 minutes
connect_timeout 2 minutes
SQUIDEOF

    chmod 644 "$squid_conf"
}

# ============================================================================
# LITELLM CONFIG
# ============================================================================

_generate_litellm_config() {
    local config_file="${INSTALL_DIR}/docker/litellm-config.yaml"

    safe_write_file "$config_file"

    log_info "Generating LiteLLM config..."

    local model_list=""

    case "${LLM_PROVIDER:-ollama}" in
        ollama)
            local ollama_model="${LLM_MODEL:-qwen2.5:14b}"
            model_list="  - model_name: ${ollama_model}
    litellm_params:
      model: ollama/${ollama_model}
      api_base: http://ollama:11434"
            ;;
        vllm)
            local vllm_model="${VLLM_MODEL:-QuantTrio/Qwen3.5-27B-AWQ}"
            # LLM_ON_PEER=true → vllm runs on peer Spark, LiteLLM must reach it via PEER_IP.
            local _vllm_host="vllm"
            if [[ "${LLM_ON_PEER:-false}" == "true" && -n "${PEER_IP:-}" ]]; then
                _vllm_host="${PEER_IP}"
            fi
            model_list="  - model_name: ${vllm_model}
    litellm_params:
      model: openai/${vllm_model}
      api_base: http://${_vllm_host}:8000/v1"
            ;;
        external|skip)
            model_list="  # No local LLM provider selected.
  # Add your model configuration here. Example:
  # - model_name: gpt-4o
  #   litellm_params:
  #     model: openai/gpt-4o
  #     api_key: os.environ/OPENAI_API_KEY"
            ;;
    esac

    cat > "$config_file" <<LITELLM_EOF
# AGMind LiteLLM Configuration
# Generated by install.sh -- edit and restart: docker compose restart agmind-litellm
#
# Docs: https://docs.litellm.ai/docs/proxy/configs

model_list:
${model_list}

litellm_settings:
  drop_params: true
  set_verbose: false

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
LITELLM_EOF

    chmod 600 "$config_file"
    log_success "LiteLLM config: ${config_file}"
}

# ============================================================================
# SEARXNG CONFIG
# ============================================================================

_generate_searxng_config() {
    local template_dir="$1"
    if [[ "${ENABLE_SEARXNG:-false}" != "true" ]]; then
        return 0
    fi
    local src="${template_dir}/searxng-settings.yml"
    local dst="${INSTALL_DIR}/docker/searxng-settings.yml"
    if [[ ! -f "$src" ]]; then
        log_warn "SearXNG settings template not found: ${src}"
        return 0
    fi
    sed "s|__SEARXNG_SECRET_KEY__|${_SEARXNG_SECRET_KEY}|g" "$src" > "$dst"
    chmod 600 "$dst"
    log_success "SearXNG config: ${dst}"
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

    # TEI reranker GPU: enable if user chose GPU reranker
    if [[ "${RERANKER_ON_GPU:-false}" == "true" && "${DETECTED_GPU:-none}" == "nvidia" ]]; then
        _atomic_sed "$compose_file" 's|#__GPU_RERANK__||g'
        log_info "TEI reranker → GPU (CUDA)"
    else
        _atomic_sed "$compose_file" '/#__GPU_RERANK__/d'
    fi

    # If vLLM and TEI share the same GPU, calculate VRAM split dynamically:
    # Reserve 4 GB for TEI (~1.3 GB) + CUDA driver/context (~0.5 GB) + system (~1.5 GB) + headroom.
    # Note: nvidia-smi reports ~500 MiB more than CUDA-visible total,
    # so we over-reserve to compensate for this gap.
    # Formula: (total_vram_mb - 4000) / total_vram_mb
    #   12 GB → 0.67   16 GB → 0.75   24 GB → 0.83   32 GB → 0.88
    if [[ "${LLM_PROVIDER:-}" == "vllm" && ( "${EMBED_PROVIDER:-}" == "tei" || "${EMBED_PROVIDER:-}" == "vllm-embed" ) ]]; then
        local env_file="${INSTALL_DIR}/docker/.env"
        local tei_reserve_mb=4000
        # Add reranker GPU overhead if enabled
        if [[ "${RERANKER_ON_GPU:-false}" == "true" ]]; then
            tei_reserve_mb=$(( tei_reserve_mb + 1024 ))
        fi
        # Add Docling GPU overhead if enabled
        if [[ "${ENABLE_DOCLING:-false}" == "true" && "${NVIDIA_VISIBLE_DEVICES:-}" == "all" ]]; then
            tei_reserve_mb=$(( tei_reserve_mb + 3072 ))
        fi
        # Use DETECTED_GPU_VRAM (set by detect.sh, handles unified memory)
        # instead of re-querying nvidia-smi (which returns N/A on unified memory GPUs)
        local total_vram_mb="${DETECTED_GPU_VRAM:-0}"

        if [[ "$total_vram_mb" -gt 0 ]] 2>/dev/null; then
            local vllm_util

            if [[ "${DETECTED_GPU_UNIFIED_MEMORY:-false}" == "true" ]]; then
                # Unified memory (GB10, Grace Hopper): GPU shares system RAM.
                # cudaMemGetInfo reports only ~56 GB of 128 GB as "free" because
                # it cannot account for reclaimable page cache. vLLM checks:
                #   free_gpu >= gpu_memory_utilization * total_gpu
                # With total≈121 GB and free≈102 GB, 0.90 requests 109 GB → fails.
                # 0.70 keeps ~19 GiB free for OS/Docker/swap relief while still
                # giving 35 GiB KV cache (312K tokens, ~38x concurrency @65K).
                vllm_util="0.60"
                log_info "Unified memory GPU (${total_vram_mb} MB) — VLLM_GPU_MEM_UTIL=${vllm_util}"
                # Unified memory: CUDA allocations ARE system RAM and count toward
                # Docker cgroup mem_limit. Budget for 128g total:
                #   main: 0.60*121=73g + embed: 0.05*121=6g + rerank: 0.03*121=4g
                #   + docling ~4g + non-GPU ~28g = ~115g (13g headroom for OS)
                echo "VLLM_MEM_LIMIT=80g" >> "$env_file"
                echo "VLLM_EMBED_GPU_MEM_UTIL=0.05" >> "$env_file"
                echo "VLLM_EMBED_MEM_LIMIT=10g" >> "$env_file"
                echo "VLLM_RERANK_GPU_MEM_UTIL=0.03" >> "$env_file"
                echo "VLLM_RERANK_MEM_LIMIT=8g" >> "$env_file"
                echo "DOCLING_MEM_LIMIT=16g" >> "$env_file"

                # Cluster mode=master: vLLM main runs on peer, master GPU is free
                # for embed/rerank/docling. Benchmarked 2026-04-22 on spark-3eac:
                # 4 PDF (181+530+680+руководство) parallel → 5m36s total
                # (~5 pages/sec throughput, 7-10× faster than conservative defaults).
                # Safe because master has no ~73 GiB vllm main hogging the GPU.
                if [[ "${AGMIND_MODE:-single}" == "master" ]]; then
                    log_info "Cluster master mode — applying aggressive embed/rerank/docling limits (peer hosts LLM)"
                    echo "# cluster mode=master overrides — vLLM main on peer, master GPU free" >> "$env_file"
                    echo "VLLM_EMBED_GPU_MEM_UTIL=0.10" >> "$env_file"
                    echo "VLLM_EMBED_MEM_LIMIT=12g" >> "$env_file"
                    echo "VLLM_RERANK_GPU_MEM_UTIL=0.08" >> "$env_file"
                    echo "VLLM_RERANK_MEM_LIMIT=10g" >> "$env_file"
                    echo "DOCLING_MEM_LIMIT=32g" >> "$env_file"
                    echo "DOCLING_SERVE_LAYOUT_BATCH_SIZE=256" >> "$env_file"
                    echo "DOCLING_SERVE_OCR_BATCH_SIZE=256" >> "$env_file"
                    echo "DOCLING_SERVE_TABLE_BATCH_SIZE=32" >> "$env_file"
                    # 1 uvicorn process keeps models loaded once (no duplicate VRAM),
                    # 4 async local workers serve concurrent requests efficiently.
                    echo "DOCLING_UVICORN_WORKERS=1" >> "$env_file"
                    echo "DOCLING_SERVE_WORKERS=4" >> "$env_file"
                    # Docling VLM picture description calls main LLM. Master has no
                    # local vllm (it's on peer) — redirect via PEER_IP or VLM breaks.
                    if [[ -n "${PEER_IP:-}" ]]; then
                        echo "DOCLING_VLM_URL=http://${PEER_IP}:8000/v1/chat/completions" >> "$env_file"
                    fi
                fi
            else
                vllm_util=$(LC_NUMERIC=C awk "BEGIN { printf \"%.2f\", ($total_vram_mb - $tei_reserve_mb) / $total_vram_mb }")
                # Clamp to [0.40, 0.92] — never starve vLLM or oversubscribe
                if LC_NUMERIC=C awk "BEGIN { exit ($vllm_util < 0.40) ? 0 : 1 }"; then vllm_util="0.40"; fi
                if LC_NUMERIC=C awk "BEGIN { exit ($vllm_util > 0.92) ? 0 : 1 }"; then vllm_util="0.92"; fi
                log_info "GPU VRAM ${total_vram_mb} MB — reserving ${tei_reserve_mb} MB for TEI → VLLM_GPU_MEM_UTIL=${vllm_util}"
            fi
        else
            # Fallback: can't query VRAM (e.g. CI), use conservative default
            local vllm_util="0.70"
            log_warn "Could not query GPU VRAM — using conservative VLLM_GPU_MEM_UTIL=${vllm_util}"
        fi
        echo "VLLM_GPU_MEM_UTIL=${vllm_util}" >> "$env_file"

        # Auto-enable --enforce-eager when model weights leave <25% VRAM for
        # KV cache + CUDA graphs.  CUDA graph profiling can allocate 3-5 GiB
        # temporarily, causing OOM on tight configs (e.g. 27B-AWQ on 32 GB).
        # Skip for unified memory — plenty of headroom, CUDA graphs are beneficial.
        if [[ "$total_vram_mb" -gt 0 && "${DETECTED_GPU_UNIFIED_MEMORY:-false}" != "true" ]] 2>/dev/null; then
            local model_vram_gb=0
            # source wizard.sh helper if available
            if type -t _get_vllm_vram_req &>/dev/null; then
                model_vram_gb="$(_get_vllm_vram_req "${VLLM_MODEL:-}")"
            fi
            if [[ "$model_vram_gb" -gt 0 ]]; then
                local model_vram_mb=$((model_vram_gb * 1024))
                local avail_for_kv=$((total_vram_mb - tei_reserve_mb - model_vram_mb))
                # If less than 25% of total VRAM left for KV cache — disable CUDA graphs
                local threshold=$((total_vram_mb / 4))
                if [[ $avail_for_kv -lt $threshold ]]; then
                    log_info "Tight VRAM: ${model_vram_gb} GB model + TEI on ${total_vram_mb} MB → enabling --enforce-eager"
                    echo "VLLM_EXTRA_ARGS=--enforce-eager" >> "$env_file"
                fi
            fi
        fi
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
            log_info "TLS: Let's Encrypt — generating placeholder cert for initial startup..."
            _generate_self_signed_cert "$ssl_dir"
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

# ============================================================================
# PEER MONITORING (Plan 02-05, PEER-05) — uncomment scrape targets and
# substitute PEER_IP in rendered prometheus.yml when AGMIND_MODE=master.
# Called after _copy_monitoring_files from generate_config.
# ============================================================================

_configure_peer_monitoring() {
    local mode="${AGMIND_MODE:-single}"
    if [[ "$mode" != "master" ]]; then
        log_info "Cluster mode=${mode} — peer monitoring scrape skipped"
        return 0
    fi

    local prom_conf="${INSTALL_DIR}/docker/monitoring/prometheus.yml"

    # MAJOR 3 FIX — defensive checks on dependencies before use
    command -v _atomic_sed >/dev/null 2>&1 || {
        # _atomic_sed defined in lib/common.sh — if absent, this is a structural bug
        log_error "_atomic_sed helper missing (required from lib/common.sh) — peer monitoring not configured"
        return 1
    }
    if [[ ! -f "$prom_conf" ]]; then
        log_error "${prom_conf} not found — run config phase first (generate_config → _copy_monitoring_files)"
        return 1
    fi

    local peer_ip="${PEER_IP:-}"
    local state_file="${AGMIND_CLUSTER_STATE_FILE:-/var/lib/agmind/state/cluster.json}"
    if [[ -z "$peer_ip" ]] && [[ -f "$state_file" ]] && command -v jq >/dev/null 2>&1; then
        peer_ip="$(jq -r '.peer_ip // empty' "$state_file" 2>/dev/null || true)"
    fi
    if [[ -z "$peer_ip" ]]; then
        log_warn "PEER_IP unknown — peer monitoring scrape not configured"
        return 0
    fi

    # Idempotency: if PEER_SCRAPE block already uncommented — skip or rewrite if IP changed.
    # Uncommented state = '- job_name: peer-node-exporter' (no leading # in rendered jobs).
    if grep -qE "^  - job_name: 'peer-node-exporter'" "$prom_conf"; then
        log_info "Peer scrape jobs already configured — checking PEER_IP consistency"
        if grep -qF "targets: ['${peer_ip}:9100']" "$prom_conf"; then
            return 0
        fi
        # IP changed — fall through to rewrite
    fi

    # Substitute __PEER_IP__ placeholder with actual IP
    _atomic_sed "$prom_conf" -e "s|__PEER_IP__|${peer_ip}|g" || {
        log_error "Failed to substitute __PEER_IP__ in ${prom_conf}"
        return 1
    }

    # Uncomment the PEER_SCRAPE block (remove leading '  # ' on lines between markers,
    # EXCEPT the marker lines themselves). Sed range: from BEGIN to END marker.
    # shellcheck disable=SC2016  # single-quotes are intentional in sed expression (not shell var)
    _atomic_sed "$prom_conf" \
        -e '/__PEER_SCRAPE_BEGIN__/,/__PEER_SCRAPE_END__/{ /__PEER_SCRAPE_/!s/^  # /  /; }' || {
        log_error "Failed to uncomment peer scrape jobs in ${prom_conf}"
        return 1
    }

    # Mask local-vllm scrape target: main LLM lives on peer in master mode, so
    # agmind-vllm:8000 is permanently down. Embed/rerank stay on master untouched.
    # Regex [^# ] ensures idempotency — already-commented lines are skipped.
    # shellcheck disable=SC2016  # single-quotes are intentional in sed expression (not shell var)
    _atomic_sed "$prom_conf" \
        -e '/__LLM_LOCAL_BEGIN__/,/__LLM_LOCAL_END__/{ /__LLM_LOCAL_/!s/^\(  *\)\([^# ]\)/\1# \2/; }' || {
        log_error "Failed to mask local vllm scrape in ${prom_conf}"
        return 1
    }

    log_success "Peer monitoring configured: scrape targets ${peer_ip}:9100 + ${peer_ip}:8000 (local vllm scrape masked)"
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

    # Phase 37: source of truth is monitoring/alertmanager.yml template (copied earlier).
    # We only uncomment the matching receiver block via sed — no inline heredoc duplication.
    # Template holds both #__ALERT_TELEGRAM__ and #__WEBHOOK__ blocks; unused ones stay commented.
    case "${ALERT_MODE:-none}" in
        telegram)
            local token="${ALERT_TELEGRAM_TOKEN:-}"
            local chat_id="${ALERT_TELEGRAM_CHAT_ID:-}"
            if [[ -n "$token" && -n "$chat_id" ]]; then
                _atomic_sed "$alertmanager_conf" 's|#__ALERT_TELEGRAM__||g'
                local safe_token safe_chat_id
                safe_token="$(escape_sed "$token")"
                safe_chat_id="$(escape_sed "$chat_id")"
                _atomic_sed "$alertmanager_conf" "s|__ALERT_TELEGRAM_TOKEN__|${safe_token}|g"
                _atomic_sed "$alertmanager_conf" "s|__ALERT_TELEGRAM_CHAT_ID__|${safe_chat_id}|g"
            fi
            ;;
        email)
            # Phase 37 extension: SMTP via Alertmanager native email_configs.
            # Customer supplies their SMTP (corporate relay or provider).
            local email_to="${ALERT_EMAIL_TO:-}"
            local smarthost="${ALERT_EMAIL_SMARTHOST:-}"
            if [[ -n "$email_to" && -n "$smarthost" ]]; then
                _atomic_sed "$alertmanager_conf" 's|#__ALERT_EMAIL__||g'
                _atomic_sed "$alertmanager_conf" "s|__ALERT_EMAIL_TO__|$(escape_sed "$email_to")|g"
                _atomic_sed "$alertmanager_conf" "s|__ALERT_EMAIL_FROM__|$(escape_sed "${ALERT_EMAIL_FROM:-alerts@agmind.local}")|g"
                _atomic_sed "$alertmanager_conf" "s|__ALERT_EMAIL_SMARTHOST__|$(escape_sed "$smarthost")|g"
                _atomic_sed "$alertmanager_conf" "s|__ALERT_EMAIL_AUTH_USER__|$(escape_sed "${ALERT_EMAIL_AUTH_USER:-}")|g"
                _atomic_sed "$alertmanager_conf" "s|__ALERT_EMAIL_AUTH_PASS__|$(escape_sed "${ALERT_EMAIL_AUTH_PASS:-}")|g"
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
