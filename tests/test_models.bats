#!/usr/bin/env bats
# test_models.bats — Tests for lib/models.sh
# Run: bats tests/test_models.bats
#
# Note: model download requires running Docker + Ollama.
# Tests verify validation, routing logic, and offline behavior.

setup() {
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test_$$"
    mkdir -p "${INSTALL_DIR}/docker"

    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
    # shellcheck source=../lib/models.sh
    source "${BATS_TEST_DIRNAME}/../lib/models.sh"
}

teardown() {
    rm -rf "${INSTALL_DIR}"
    unset LLM_PROVIDER LLM_MODEL EMBED_PROVIDER EMBEDDING_MODEL
    unset DEPLOY_PROFILE ETL_ENHANCED
}

# ============================================================================
# PULL MODEL — VALIDATION
# ============================================================================

@test "pull_model: rejects invalid model name with spaces" {
    run pull_model "model name with spaces"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid model name"* ]]
}

@test "pull_model: rejects model name with semicolons" {
    run pull_model "model;rm -rf /"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid model name"* ]]
}

@test "pull_model: rejects empty model name" {
    run pull_model ""
    [ "$status" -eq 1 ]
}

@test "pull_model: accepts valid Ollama model names" {
    # These will fail at docker exec (no container), but should pass validation
    # We check they DON'T produce "Invalid model name"
    for name in "qwen2.5:14b" "bge-m3" "llama3.1:8b" "library/model:tag" "Qwen/model_v2"; do
        run pull_model "$name"
        [[ "$output" != *"Invalid model name"* ]]
    done
}

# ============================================================================
# LOAD RERANKER — ETL FLAG
# ============================================================================

@test "load_reranker: skips when ETL_ENHANCED=false" {
    export ETL_ENHANCED="false"
    run load_reranker
    [ "$status" -eq 0 ]
    [ -z "$output" ]  # No output = early return
}

@test "load_reranker: skips when ETL_ENHANCED not set" {
    unset ETL_ENHANCED
    run load_reranker
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ============================================================================
# DOWNLOAD MODELS — ROUTING
# ============================================================================

@test "download_models: offline mode skips download" {
    export DEPLOY_PROFILE="offline"
    export LLM_PROVIDER="ollama"
    export LLM_MODEL="qwen2.5:7b"
    export EMBED_PROVIDER="ollama"
    export EMBEDDING_MODEL="bge-m3"
    export ETL_ENHANCED="false"

    run download_models
    # Will fail at wait_for_ollama (no Docker), but should say "Offline"
    [[ "$output" == *"Offline"* ]] || [[ "$output" == *"offline"* ]]
}

@test "download_models: vllm provider logs info message" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="vllm"
    export EMBED_PROVIDER="tei"
    export ETL_ENHANCED="false"

    run download_models
    [[ "$output" == *"vLLM"* ]]
    [[ "$output" == *"TEI"* ]]
}

@test "download_models: skip provider logs no download needed" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="skip"
    export EMBED_PROVIDER="skip"
    export ETL_ENHANCED="false"

    run download_models
    [[ "$output" == *"no model download"* ]]
}

@test "download_models: external provider logs no download needed" {
    export DEPLOY_PROFILE="lan"
    export LLM_PROVIDER="external"
    export EMBED_PROVIDER="external"
    export ETL_ENHANCED="false"

    run download_models
    [[ "$output" == *"no model download"* ]]
}
