#!/usr/bin/env bats
# test_compose.bats — Tests for lib/compose.sh
# Run: bats tests/test_compose.bats
#
# Note: compose operations require Docker. Tests verify profile building,
# function contracts, and validation logic. E2E in test_lifecycle.bats.

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test_$$"
    mkdir -p "${INSTALL_DIR}/docker"

    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    # shellcheck source=../lib/compose.sh
    source "${BATS_TEST_DIRNAME}/../lib/compose.sh"
}

teardown() {
    rm -rf "${INSTALL_DIR}"
    unset DEPLOY_PROFILE VECTOR_STORE ETL_ENHANCED MONITORING_MODE
    unset ENABLE_AUTHELIA LLM_PROVIDER EMBED_PROVIDER COMPOSE_PROFILE_STRING
}

# ============================================================================
# BUILD COMPOSE PROFILES
# ============================================================================

@test "build_compose_profiles: LAN + ollama + weaviate" {
    export DEPLOY_PROFILE="lan"
    export VECTOR_STORE="weaviate"
    export ETL_ENHANCED="false"
    export MONITORING_MODE="none"
    export ENABLE_AUTHELIA="false"
    export LLM_PROVIDER="ollama"
    export EMBED_PROVIDER="ollama"

    build_compose_profiles

    [[ "$COMPOSE_PROFILE_STRING" == *"weaviate"* ]]
    [[ "$COMPOSE_PROFILE_STRING" == *"ollama"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"vps"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"monitoring"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"qdrant"* ]]
}

@test "build_compose_profiles: VPS + vllm + qdrant + monitoring + authelia" {
    export DEPLOY_PROFILE="vps"
    export VECTOR_STORE="qdrant"
    export ETL_ENHANCED="false"
    export MONITORING_MODE="local"
    export ENABLE_AUTHELIA="true"
    export LLM_PROVIDER="vllm"
    export EMBED_PROVIDER="tei"

    build_compose_profiles

    [[ "$COMPOSE_PROFILE_STRING" == *"vps"* ]]
    [[ "$COMPOSE_PROFILE_STRING" == *"qdrant"* ]]
    [[ "$COMPOSE_PROFILE_STRING" == *"monitoring"* ]]
    [[ "$COMPOSE_PROFILE_STRING" == *"authelia"* ]]
    [[ "$COMPOSE_PROFILE_STRING" == *"vllm"* ]]
    [[ "$COMPOSE_PROFILE_STRING" == *"tei"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"ollama"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"weaviate"* ]]
}

@test "build_compose_profiles: offline + ollama + weaviate" {
    export DEPLOY_PROFILE="offline"
    export VECTOR_STORE="weaviate"
    export ETL_ENHANCED="false"
    export MONITORING_MODE="none"
    export ENABLE_AUTHELIA="false"
    export LLM_PROVIDER="ollama"
    export EMBED_PROVIDER="ollama"

    build_compose_profiles

    [[ "$COMPOSE_PROFILE_STRING" == *"weaviate"* ]]
    [[ "$COMPOSE_PROFILE_STRING" == *"ollama"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"vps"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"etl"* ]]
}

@test "build_compose_profiles: ETL enhanced adds etl profile" {
    export DEPLOY_PROFILE="lan"
    export VECTOR_STORE="weaviate"
    export ETL_ENHANCED="true"
    export MONITORING_MODE="none"
    export ENABLE_AUTHELIA="false"
    export LLM_PROVIDER="ollama"
    export EMBED_PROVIDER="ollama"

    build_compose_profiles

    [[ "$COMPOSE_PROFILE_STRING" == *"etl"* ]]
}

@test "build_compose_profiles: ollama added when EMBED_PROVIDER=ollama even if LLM=vllm" {
    export DEPLOY_PROFILE="lan"
    export VECTOR_STORE="weaviate"
    export ETL_ENHANCED="false"
    export MONITORING_MODE="none"
    export ENABLE_AUTHELIA="false"
    export LLM_PROVIDER="vllm"
    export EMBED_PROVIDER="ollama"

    build_compose_profiles

    [[ "$COMPOSE_PROFILE_STRING" == *"ollama"* ]]
    [[ "$COMPOSE_PROFILE_STRING" == *"vllm"* ]]
}

@test "build_compose_profiles: skip provider produces minimal profiles" {
    export DEPLOY_PROFILE="lan"
    export VECTOR_STORE="weaviate"
    export ETL_ENHANCED="false"
    export MONITORING_MODE="none"
    export ENABLE_AUTHELIA="false"
    export LLM_PROVIDER="skip"
    export EMBED_PROVIDER="skip"

    build_compose_profiles

    [[ "$COMPOSE_PROFILE_STRING" == *"weaviate"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"ollama"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"vllm"* ]]
    [[ "$COMPOSE_PROFILE_STRING" != *"tei"* ]]
}

# ============================================================================
# SYNC DB PASSWORD — VALIDATION
# ============================================================================

@test "sync_db_password: returns early if no DB_PASSWORD" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_USERNAME=postgres" > "$env_file"
    # No DB_PASSWORD line

    run sync_db_password
    [ "$status" -eq 0 ]
}

@test "sync_db_password: rejects invalid DB_USERNAME" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_PASSWORD=testpass123" > "$env_file"
    echo "DB_USERNAME='; DROP TABLE users; --" >> "$env_file"

    run sync_db_password
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid DB_USERNAME"* ]]
}

@test "sync_db_password: rejects non-alphanumeric DB_PASSWORD" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_PASSWORD=test'pass;--" > "$env_file"
    echo "DB_USERNAME=postgres" >> "$env_file"

    run sync_db_password
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid DB_PASSWORD"* ]]
}

# ============================================================================
# CREATE PLUGIN DB — VALIDATION
# ============================================================================

@test "create_plugin_db: rejects invalid DB_USERNAME" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_USERNAME=bad;user" > "$env_file"
    echo "PLUGIN_DB_DATABASE=dify_plugin" >> "$env_file"

    run create_plugin_db
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid DB_USERNAME"* ]]
}

@test "create_plugin_db: rejects invalid PLUGIN_DB_DATABASE" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_USERNAME=postgres" > "$env_file"
    echo "PLUGIN_DB_DATABASE=db'; DROP TABLE x;--" >> "$env_file"

    run create_plugin_db
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid PLUGIN_DB_DATABASE"* ]]
}

# ============================================================================
# FUNCTIONS EXIST
# ============================================================================

@test "all exported functions are defined" {
    declare -f compose_up >/dev/null
    declare -f compose_down >/dev/null
    declare -f sync_db_password >/dev/null
    declare -f create_plugin_db >/dev/null
    declare -f post_launch_status >/dev/null
    declare -f build_compose_profiles >/dev/null
}

# ============================================================================
# NUCLEAR CLEANUP
# ============================================================================

@test "_nuclear_cleanup_dirs: removes directory artifacts" {
    local docker_dir="${INSTALL_DIR}/docker"
    mkdir -p "${docker_dir}/nginx/nginx.conf"  # dir where file should be
    mkdir -p "${docker_dir}/monitoring/prometheus.yml"  # same

    _nuclear_cleanup_dirs

    [ ! -d "${docker_dir}/nginx/nginx.conf" ]
    [ ! -d "${docker_dir}/monitoring/prometheus.yml" ]
}

# ============================================================================
# COMPOSE DOWN — EDGE CASES
# ============================================================================

@test "compose_down: handles missing docker dir gracefully" {
    export INSTALL_DIR="/tmp/nonexistent_$$"
    run compose_down
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}
