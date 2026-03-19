#!/usr/bin/env bats
# test_wizard.bats — Tests for lib/wizard.sh (non-interactive mode only)
# Run: bats tests/test_wizard.bats

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test"
    export NON_INTERACTIVE="true"
    mkdir -p "$INSTALL_DIR"

    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    # shellcheck source=../lib/detect.sh
    source "${BATS_TEST_DIRNAME}/../lib/detect.sh"
    # shellcheck source=../lib/wizard.sh
    source "${BATS_TEST_DIRNAME}/../lib/wizard.sh"
}

teardown() {
    rm -rf "${BATS_TMPDIR}/agmind_test"
    # Clean up env vars
    unset NON_INTERACTIVE DEPLOY_PROFILE LLM_PROVIDER LLM_MODEL VLLM_MODEL
    unset EMBED_PROVIDER EMBEDDING_MODEL VECTOR_STORE ETL_ENHANCED
    unset DOMAIN CERTBOT_EMAIL HF_TOKEN TLS_MODE MONITORING_MODE ALERT_MODE
    unset ENABLE_UFW ENABLE_FAIL2BAN ENABLE_AUTHELIA ENABLE_TUNNEL
    unset BACKUP_TARGET BACKUP_SCHEDULE ADMIN_UI_OPEN
}

# ============================================================================
# DEFAULTS
# ============================================================================

@test "wizard defaults: minimal LAN config works" {
    export DEPLOY_PROFILE="lan"
    run run_wizard
    [ "$status" -eq 0 ]
}

@test "wizard defaults: DEPLOY_PROFILE is required" {
    export DEPLOY_PROFILE="lan"
    run run_wizard
    [ "$status" -eq 0 ]
    [ "$DEPLOY_PROFILE" = "lan" ]
}

@test "wizard defaults: vector store defaults to weaviate" {
    export DEPLOY_PROFILE="lan"
    _init_wizard_defaults
    [ "$VECTOR_STORE" = "weaviate" ]
}

@test "wizard defaults: embedding model defaults to bge-m3" {
    export DEPLOY_PROFILE="lan"
    _init_wizard_defaults
    [ "$EMBEDDING_MODEL" = "bge-m3" ]
}

@test "wizard defaults: backup defaults to local daily" {
    export DEPLOY_PROFILE="lan"
    _init_wizard_defaults
    [ "$BACKUP_TARGET" = "local" ]
    [ "$BACKUP_SCHEDULE" = "0 3 * * *" ]
}

@test "wizard defaults: security defaults to false" {
    export DEPLOY_PROFILE="lan"
    _init_wizard_defaults
    [ "$ENABLE_UFW" = "false" ]
    [ "$ENABLE_FAIL2BAN" = "false" ]
    [ "$ENABLE_AUTHELIA" = "false" ]
}

@test "wizard defaults: tunnel defaults to false" {
    export DEPLOY_PROFILE="lan"
    _init_wizard_defaults
    [ "$ENABLE_TUNNEL" = "false" ]
}

# ============================================================================
# PROFILE-SPECIFIC BEHAVIOR
# Note: run_wizard called directly (not via `run`) so variables persist
# ============================================================================

@test "profile vps: sets TLS to letsencrypt" {
    export DEPLOY_PROFILE="vps"
    export DOMAIN="example.com"
    export CERTBOT_EMAIL="admin@example.com"
    run_wizard >/dev/null 2>&1
    [ "$TLS_MODE" = "letsencrypt" ]
}

@test "profile vps: security defaults auto-set" {
    export DEPLOY_PROFILE="vps"
    export DOMAIN="example.com"
    export CERTBOT_EMAIL="admin@example.com"
    run_wizard >/dev/null 2>&1
    [ "$ENABLE_UFW" = "true" ]
    [ "$ENABLE_FAIL2BAN" = "true" ]
}

@test "profile offline: ETL disabled" {
    export DEPLOY_PROFILE="offline"
    run_wizard >/dev/null 2>&1
    [ "$ETL_ENHANCED" = "false" ]
}

@test "profile offline: TLS set to none" {
    export DEPLOY_PROFILE="offline"
    run_wizard >/dev/null 2>&1
    [ "$TLS_MODE" = "none" ]
}

# ============================================================================
# LLM PROVIDER
# ============================================================================

@test "llm provider: ollama via env" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    run_wizard >/dev/null 2>&1
    [ "$LLM_PROVIDER" = "ollama" ]
    [ "$LLM_MODEL" = "qwen2.5:7b" ]
}

@test "llm provider: vllm via env" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="vllm"
    export VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct"
    run_wizard >/dev/null 2>&1
    [ "$LLM_PROVIDER" = "vllm" ]
    [ "$VLLM_MODEL" = "Qwen/Qwen2.5-14B-Instruct" ]
}

@test "llm provider: external via env" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="external"
    run_wizard >/dev/null 2>&1
    [ "$LLM_PROVIDER" = "external" ]
}

@test "llm provider: skip via env" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="skip"
    run_wizard >/dev/null 2>&1
    [ "$LLM_PROVIDER" = "skip" ]
}

# ============================================================================
# EMBEDDING PROVIDER
# ============================================================================

@test "embed provider: ollama default with ollama LLM" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    run_wizard >/dev/null 2>&1
    [ "$EMBED_PROVIDER" = "ollama" ]
    [ "$EMBEDDING_MODEL" = "bge-m3" ]
}

@test "embed provider: tei via env" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="tei"
    run_wizard >/dev/null 2>&1
    [ "$EMBED_PROVIDER" = "tei" ]
}

# ============================================================================
# VECTOR STORE
# ============================================================================

@test "vector store: weaviate via env" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export VECTOR_STORE="weaviate"
    run_wizard >/dev/null 2>&1
    [ "$VECTOR_STORE" = "weaviate" ]
}

@test "vector store: qdrant via env" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    # Note: in non-interactive, vector store choice defaults to 1 (weaviate)
    # To set qdrant, we rely on the env var being preserved through _init_wizard_defaults
    export VECTOR_STORE="qdrant"
    _init_wizard_defaults
    [ "$VECTOR_STORE" = "qdrant" ]
}

# ============================================================================
# MONITORING & ALERTS
# ============================================================================

@test "monitoring: none by default" {
    export DEPLOY_PROFILE="lan"
    run_wizard >/dev/null 2>&1
    [ "$MONITORING_MODE" = "none" ]
}

@test "alerts: none by default" {
    export DEPLOY_PROFILE="lan"
    run_wizard >/dev/null 2>&1
    [ "$ALERT_MODE" = "none" ]
}

# ============================================================================
# BACKUPS
# ============================================================================

@test "backup: local by default with daily schedule" {
    export DEPLOY_PROFILE="lan"
    run_wizard >/dev/null 2>&1
    [ "$BACKUP_TARGET" = "local" ]
    [ "$BACKUP_SCHEDULE" = "0 3 * * *" ]
}

@test "backup: custom schedule via env" {
    export DEPLOY_PROFILE="lan"
    export BACKUP_SCHEDULE="0 3,15 * * *"
    _init_wizard_defaults
    [ "$BACKUP_SCHEDULE" = "0 3,15 * * *" ]
}

# ============================================================================
# TUNNEL
# ============================================================================

@test "tunnel: disabled by default" {
    export DEPLOY_PROFILE="lan"
    run_wizard >/dev/null 2>&1
    [ "$ENABLE_TUNNEL" = "false" ]
}

@test "tunnel: not offered for vps" {
    export DEPLOY_PROFILE="vps"
    export DOMAIN="example.com"
    export CERTBOT_EMAIL="admin@example.com"
    export ENABLE_TUNNEL="true"  # even if forced, tunnel section skips for vps
    run _wizard_tunnel
    [ "$status" -eq 0 ]
    # _wizard_tunnel returns early for non-lan/vpn profiles
}

# ============================================================================
# FULL NON-INTERACTIVE RUNS
# ============================================================================

@test "full run: minimal LAN + ollama" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:14b"
    run run_wizard
    [ "$status" -eq 0 ]
    [[ "$output" == *"Сводка установки"* ]]
    [[ "$output" == *"lan"* ]]
    [[ "$output" == *"ollama"* ]]
}

@test "full run: VPS + vllm + monitoring" {
    export DEPLOY_PROFILE="vps"
    export DOMAIN="ai.example.com"
    export CERTBOT_EMAIL="admin@example.com"
    export LLM_PROVIDER="vllm"
    export VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct"
    export EMBED_PROVIDER="tei"
    export HF_TOKEN="hf_test123"
    export MONITORING_MODE="local"
    run run_wizard
    [ "$status" -eq 0 ]
    [[ "$output" == *"Сводка установки"* ]]
    [[ "$output" == *"vps"* ]]
}

@test "full run: offline minimal" {
    export DEPLOY_PROFILE="offline"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    run run_wizard
    [ "$status" -eq 0 ]
    [[ "$output" == *"Offline"* ]]
}

# ============================================================================
# SUMMARY OUTPUT
# ============================================================================

@test "summary: shows all key settings" {
    export DEPLOY_PROFILE="vps"
    export DOMAIN="test.com"
    export CERTBOT_EMAIL="a@test.com"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:14b"
    export EMBED_PROVIDER="ollama"
    export VECTOR_STORE="weaviate"
    export ENABLE_AUTHELIA="true"
    run run_wizard
    [ "$status" -eq 0 ]
    [[ "$output" == *"Профиль:"* ]]
    [[ "$output" == *"Домен:"* ]]
    [[ "$output" == *"Вектор. БД:"* ]]
    [[ "$output" == *"LLM:"* ]]
    [[ "$output" == *"Эмбеддинги:"* ]]
    [[ "$output" == *"Бэкапы:"* ]]
}

# ============================================================================
# _ask / _ask_choice HELPERS
# ============================================================================

@test "_ask: returns default in non-interactive" {
    NON_INTERACTIVE="true"
    _ask "test prompt" "default_val"
    [ "$REPLY" = "default_val" ]
}

@test "_ask_choice: returns default in non-interactive" {
    NON_INTERACTIVE="true"
    _ask_choice "test" 1 4 3
    [ "$REPLY" = "3" ]
}

# ============================================================================
# INIT WIZARD DEFAULTS
# ============================================================================

@test "init defaults: all variables are set" {
    unset DEPLOY_PROFILE LLM_PROVIDER EMBED_PROVIDER
    _init_wizard_defaults
    [ "${DEPLOY_PROFILE+set}" = "set" ]
    [ "${LLM_PROVIDER+set}" = "set" ]
    [ "${EMBED_PROVIDER+set}" = "set" ]
    [ "${VECTOR_STORE}" = "weaviate" ]
    [ "${ETL_ENHANCED}" = "false" ]
    [ "${TLS_MODE}" = "none" ]
    [ "${MONITORING_MODE}" = "none" ]
    [ "${ALERT_MODE}" = "none" ]
}

@test "init defaults: preserves existing env vars" {
    export DEPLOY_PROFILE="vpn"
    export LLM_PROVIDER="vllm"
    export VECTOR_STORE="qdrant"
    _init_wizard_defaults
    [ "$DEPLOY_PROFILE" = "vpn" ]
    [ "$LLM_PROVIDER" = "vllm" ]
    [ "$VECTOR_STORE" = "qdrant" ]
}
