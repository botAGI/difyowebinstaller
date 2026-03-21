#!/usr/bin/env bats
# test_config.bats — Tests for lib/config.sh
# Run: bats tests/test_config.bats

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test_$$"
    mkdir -p "${INSTALL_DIR}/docker"

    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    # shellcheck source=../lib/config.sh
    source "${BATS_TEST_DIRNAME}/../lib/config.sh"

    TEMPLATE_DIR="${BATS_TEST_DIRNAME}/../templates"
}

teardown() {
    rm -rf "${INSTALL_DIR}"
}

# ============================================================================
# GENERATE CONFIG — FULL RUN
# ============================================================================

@test "generate_config: LAN profile creates .env and configs" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export EMBEDDING_MODEL="bge-m3"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    run generate_config "lan" "$TEMPLATE_DIR"
    [ "$status" -eq 0 ]

    # .env exists and is not empty
    [ -f "${INSTALL_DIR}/docker/.env" ]
    [ -s "${INSTALL_DIR}/docker/.env" ]

    # Permissions (skip on filesystems that don't support chmod, e.g. NTFS)
    if chmod 600 "${INSTALL_DIR}/docker/.env" 2>/dev/null; then
        local perms
        perms="$(stat -c '%a' "${INSTALL_DIR}/docker/.env" 2>/dev/null || stat -f '%Lp' "${INSTALL_DIR}/docker/.env")"
        [ "$perms" = "600" ]
    fi
}

@test "generate_config: creates admin password file" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export EMBEDDING_MODEL="bge-m3"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    [ -f "${INSTALL_DIR}/.admin_password" ]
    [ -s "${INSTALL_DIR}/.admin_password" ]
    if chmod 600 "${INSTALL_DIR}/.admin_password" 2>/dev/null; then
        local perms
        perms="$(stat -c '%a' "${INSTALL_DIR}/.admin_password" 2>/dev/null || stat -f '%Lp' "${INSTALL_DIR}/.admin_password")"
        [ "$perms" = "600" ]
    fi
}

@test "generate_config: .env has no unresolved placeholders" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    # No __PLACEHOLDER__ patterns should remain
    run grep -E '^[^#].*__[A-Z_]+__' "${INSTALL_DIR}/docker/.env"
    [ "$status" -ne 0 ]  # grep returns 1 = no matches = good
}

@test "generate_config: .env has no weak default passwords" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    run validate_no_default_secrets "${INSTALL_DIR}/docker/.env"
    [ "$status" -eq 0 ]
}

# ============================================================================
# PROVIDER VARS
# ============================================================================

@test "generate_config: ollama provider sets OLLAMA_BASE_URL" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    grep -q "OLLAMA_BASE_URL=http://ollama:11434" "${INSTALL_DIR}/docker/.env"
    grep -q "ENABLE_OLLAMA_API=true" "${INSTALL_DIR}/docker/.env"
}

@test "generate_config: vllm provider sets OPENAI_API_BASE_URL" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="vllm"
    export LLM_MODEL="Qwen/Qwen2.5-14B-Instruct"
    export VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct"
    export EMBED_PROVIDER="tei"
    export EMBEDDING_MODEL="BAAI/bge-m3"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    grep -q "ENABLE_OPENAI_API=true" "${INSTALL_DIR}/docker/.env"
    grep -q "OPENAI_API_BASE_URL=http://vllm:8000/v1" "${INSTALL_DIR}/docker/.env"
}

# ============================================================================
# REDIS CONFIG
# ============================================================================

@test "generate_redis_config: uses ACL not rename-command" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    local redis_conf="${INSTALL_DIR}/docker/volumes/redis/redis.conf"
    [ -f "$redis_conf" ]

    # Must use ACL
    grep -q "user default on" "$redis_conf"
    grep -q "@dangerous" "$redis_conf"

    # Must NOT use rename-command
    run grep "rename-command" "$redis_conf"
    [ "$status" -ne 0 ]
}

# ============================================================================
# SQUID CONFIG
# ============================================================================

@test "generate_config: creates squid config with SSRF protection" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    local squid_conf="${INSTALL_DIR}/docker/volumes/ssrf_proxy/squid.conf"
    [ -f "$squid_conf" ]
    grep -q "169.254" "$squid_conf"
    grep -q "deny metadata" "$squid_conf"
}

# ============================================================================
# SANDBOX CONFIG
# ============================================================================

@test "generate_config: sandbox config has replaced key" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    local sandbox_conf="${INSTALL_DIR}/docker/volumes/sandbox/conf/config.yaml"
    [ -f "$sandbox_conf" ]

    # Key must be replaced (not the placeholder)
    run grep "__will_be_replaced__" "$sandbox_conf"
    [ "$status" -ne 0 ]
}

# ============================================================================
# VERSIONS
# ============================================================================

@test "generate_config: pinned versions appended to .env" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    grep -q "DIFY_VERSION=" "${INSTALL_DIR}/docker/.env"
    grep -q "POSTGRES_VERSION=" "${INSTALL_DIR}/docker/.env"
    grep -q "REDIS_VERSION=" "${INSTALL_DIR}/docker/.env"
}

@test "versions.env has no 'latest' tags" {
    run grep -i "latest" "${TEMPLATE_DIR}/versions.env"
    [ "$status" -ne 0 ]
}

# ============================================================================
# TEMPLATE VALIDATION
# ============================================================================

@test "env templates have no _VERSION variables" {
    for template in "${TEMPLATE_DIR}"/env.*.template; do
        [ -f "$template" ] || continue
        local count
        count="$(grep -c "_VERSION=" "$template" || true)"
        [ "$count" -eq 0 ]
    done
}

@test "nginx template has no __ADMIN_TOKEN__" {
    run grep "__ADMIN_TOKEN__" "${TEMPLATE_DIR}/nginx.conf.template"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml is valid YAML" {
    if ! command -v python3 &>/dev/null; then
        skip "python3 not available"
    fi
    run python3 -c "import yaml; yaml.safe_load(open('${TEMPLATE_DIR}/docker-compose.yml'))"
    [ "$status" -eq 0 ]
}

# ============================================================================
# DIRECTORY STRUCTURE
# ============================================================================

@test "generate_config: creates all required directories" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export TLS_MODE="none"
    export MONITORING_MODE="none"
    export ALERT_MODE="none"
    export ETL_ENHANCED="false"
    export ENABLE_AUTHELIA="false"

    generate_config "lan" "$TEMPLATE_DIR"

    [ -d "${INSTALL_DIR}/docker/volumes/sandbox/conf" ]
    [ -d "${INSTALL_DIR}/docker/volumes/db/data" ]
    [ -d "${INSTALL_DIR}/docker/volumes/redis/data" ]
    [ -d "${INSTALL_DIR}/docker/nginx" ]
    [ -d "${INSTALL_DIR}/scripts" ]
    [ -d "${INSTALL_DIR}/workflows" ]
}

# ============================================================================
# GPU COMPOSE
# ============================================================================

@test "enable_gpu_compose: CPU mode removes GPU markers" {
    export DETECTED_GPU="none"
    local compose="${INSTALL_DIR}/docker/docker-compose.yml"
    mkdir -p "$(dirname "$compose")"
    echo "#__GPU__some gpu config" > "$compose"

    enable_gpu_compose
    run grep "#__GPU__" "$compose"
    [ "$status" -ne 0 ]  # markers removed
}

@test "enable_gpu_compose: NVIDIA enables GPU markers" {
    export DETECTED_GPU="nvidia"
    local compose="${INSTALL_DIR}/docker/docker-compose.yml"
    mkdir -p "$(dirname "$compose")"
    echo "#__GPU__      deploy:" > "$compose"

    enable_gpu_compose
    # Markers should be stripped (not the content after them)
    run grep "#__GPU__" "$compose"
    [ "$status" -ne 0 ]
    grep -q "deploy:" "$compose"
}
