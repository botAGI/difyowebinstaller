#!/usr/bin/env bash
# models.sh — Download LLM/embedding models (Ollama pull, vLLM/TEI info, Xinference reranker).
# Dependencies: common.sh (log_*, validate_model_name)
# Functions: download_models(), wait_for_ollama(), pull_model(name),
#            check_ollama_models(), load_reranker()
# Expects: INSTALL_DIR, LLM_PROVIDER, LLM_MODEL, EMBED_PROVIDER, EMBEDDING_MODEL,
#          DEPLOY_PROFILE, ETL_ENHANCED
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# Approximate model download sizes for operator feedback
declare -A MODEL_SIZES=(
    ["qwen2.5:14b"]="8.5 GB"
    ["qwen2.5:7b"]="4.7 GB"
    ["qwen2.5:3b"]="1.9 GB"
    ["qwen2.5:32b"]="18 GB"
    ["qwen2.5:72b"]="41 GB"
    ["llama3.1:8b"]="4.7 GB"
    ["llama3.1:70b"]="40 GB"
    ["mistral:7b"]="4.1 GB"
    ["gemma2:9b"]="5.4 GB"
    ["gemma2:27b"]="16 GB"
    ["bge-m3"]="1.2 GB"
    ["nomic-embed-text"]="274 MB"
    ["mxbai-embed-large"]="670 MB"
    # vLLM models (HuggingFace names)
    ["Qwen/Qwen2.5-7B-Instruct-AWQ"]="4 GB"
    ["Qwen/Qwen3-8B-AWQ"]="4.5 GB"
    ["Qwen/Qwen2.5-14B-Instruct-AWQ"]="8 GB"
    ["Qwen/Qwen3-14B-AWQ"]="8 GB"
    ["Qwen/Qwen2.5-32B-Instruct-AWQ"]="18 GB"
    ["Qwen/Qwen2.5-7B-Instruct"]="14 GB"
    ["Qwen/Qwen3-8B"]="16 GB"
    ["mistralai/Mistral-7B-Instruct-v0.3"]="14 GB"
    ["meta-llama/Llama-3.1-8B-Instruct"]="15 GB"
    ["Qwen/Qwen2.5-14B-Instruct"]="28 GB"
    ["Qwen/Qwen3-14B"]="28 GB"
    ["microsoft/phi-4"]="28 GB"
    ["Qwen/Qwen2.5-32B-Instruct"]="60 GB"
    ["meta-llama/Llama-3.3-70B-Instruct"]="131 GB"
    ["bullpoint/Qwen3-Coder-Next-AWQ-4bit"]="8 GB"
    ["stelterlab/NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ"]="2 GB"
)

# ============================================================================
# OLLAMA READINESS
# ============================================================================

# Wait for Ollama API to respond (up to 5 minutes).
wait_for_ollama() {
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    log_info "Waiting for Ollama to be ready..."

    local retries=60 i=0
    while [[ $i -lt $retries ]]; do
        if docker compose -f "$compose_file" exec -T ollama ollama list >/dev/null 2>&1; then
            log_success "Ollama ready"
            return 0
        fi
        sleep 5
        i=$((i + 1))
        echo -n "."
    done
    echo ""
    log_error "Ollama did not respond within 5 minutes"
    return 1
}

# ============================================================================
# PULL MODEL
# ============================================================================

# Pull a single model via docker exec. Validates name before exec.
# Usage: pull_model "qwen2.5:14b" "LLM (qwen2.5:14b)"
pull_model() {
    local model="$1"
    local label="${2:-$model}"

    # Show approximate size if known
    local size="${MODEL_SIZES[$model]:-}"
    if [[ -n "$size" ]]; then
        log_info "Downloading model: ${label} (~${size})..."
    else
        log_info "Downloading model: ${label}..."
    fi

    # Validate model name
    if [[ ! "$model" =~ ^[a-zA-Z0-9.:/_-]+$ ]]; then
        log_error "Invalid model name: ${model}"
        return 1
    fi

    # Try with TTY for progress display, fallback to non-TTY
    if docker exec -t agmind-ollama ollama pull "$model"; then
        log_success "Model ${label} downloaded"
    elif docker exec agmind-ollama ollama pull "$model"; then
        log_success "Model ${label} downloaded (no progress display)"
    else
        log_error "Failed to download model ${label}"
        return 1
    fi
}

# ============================================================================
# CHECK PRE-LOADED MODELS (offline mode)
# ============================================================================

check_ollama_models() {
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    local llm_model="${LLM_MODEL:-qwen2.5:14b}"
    local embedding_model="${EMBEDDING_MODEL:-bge-m3}"

    log_info "Checking pre-loaded models..."
    wait_for_ollama || return 1

    local model_list
    model_list="$(docker compose -f "$compose_file" exec -T ollama ollama list 2>/dev/null || echo "")"

    local missing=0

    if echo "$model_list" | grep -qi "^${llm_model}[[:space:]]"; then
        echo -e "  ${GREEN}[OK]${NC} LLM: ${llm_model}"
    else
        echo -e "  ${RED}[!!]${NC} LLM: ${llm_model} — NOT FOUND"
        echo "       Load manually: docker compose exec ollama ollama pull ${llm_model}"
        missing=$((missing + 1))
    fi

    if echo "$model_list" | grep -qi "^${embedding_model}[[:space:]]"; then
        echo -e "  ${GREEN}[OK]${NC} Embedding: ${embedding_model}"
    else
        echo -e "  ${RED}[!!]${NC} Embedding: ${embedding_model} — NOT FOUND"
        echo "       Load manually: docker compose exec ollama ollama pull ${embedding_model}"
        missing=$((missing + 1))
    fi

    if [[ $missing -gt 0 ]]; then
        echo ""
        log_warn "${missing} model(s) missing. Requests to missing models will fail."
    fi

    return 0
}

# ============================================================================
# XINFERENCE RERANKER
# ============================================================================

# Load bce-reranker-base_v1 in Xinference (only when ETL enhanced is enabled).
load_reranker() {
    if [[ "${ETL_ENHANCED:-false}" != "true" ]]; then
        return 0
    fi

    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    log_info "Loading reranker model in Xinference..."

    # Wait for Xinference to be ready (up to 150s)
    local retries=30 i=0
    while [[ $i -lt $retries ]]; do
        if docker compose -f "$compose_file" exec -T xinference \
            curl -sf http://localhost:9997/v1/models >/dev/null 2>&1; then
            break
        fi
        sleep 5
        i=$((i + 1))
    done

    if [[ $i -ge $retries ]]; then
        log_warn "Xinference not ready, skipping reranker"
        return 0
    fi

    # Register bce-reranker-base_v1
    docker compose -f "$compose_file" exec -T xinference \
        curl -sf -X POST http://localhost:9997/v1/models \
        -H "Content-Type: application/json" \
        -d '{"model_name":"bce-reranker-base_v1","model_type":"rerank","model_engine":"sentence-transformers"}' \
        >/dev/null 2>&1 || true

    log_success "Reranker model registered"
}

# ============================================================================
# MAIN: DOWNLOAD MODELS
# ============================================================================

download_models() {
    local llm_model="${LLM_MODEL:-qwen2.5:14b}"
    local embedding_model="${EMBEDDING_MODEL:-bge-m3}"
    local profile="${DEPLOY_PROFILE:-lan}"
    local llm_provider="${LLM_PROVIDER:-ollama}"
    local embed_provider="${EMBED_PROVIDER:-ollama}"

    # Offline: check only, no download
    if [[ "$profile" == "offline" ]]; then
        log_info "Offline profile: skipping model download"
        if [[ "$llm_provider" == "ollama" || "$embed_provider" == "ollama" ]]; then
            check_ollama_models
        fi
        load_reranker
        return 0
    fi

    # Ollama models
    local need_ollama=false
    [[ "$llm_provider" == "ollama" ]] && need_ollama=true
    [[ "$embed_provider" == "ollama" ]] && need_ollama=true

    if [[ "$need_ollama" == "true" ]]; then
        wait_for_ollama || return 1
        echo ""
        log_info "=== Downloading models ==="
        echo ""
        [[ "$llm_provider" == "ollama" ]] && pull_model "$llm_model" "LLM (${llm_model})"
        [[ "$embed_provider" == "ollama" ]] && pull_model "$embedding_model" "Embedding (${embedding_model})"
    fi

    # vLLM/TEI download at container start
    if [[ "$llm_provider" == "vllm" ]]; then
        log_info "vLLM: model downloads at container startup"
    fi
    if [[ "$embed_provider" == "tei" ]]; then
        log_info "TEI: model downloads at container startup"
    fi
    if [[ "$llm_provider" == "external" || "$llm_provider" == "skip" ]]; then
        [[ "$need_ollama" != "true" ]] && log_info "Provider ${llm_provider}: no model download needed"
    fi

    load_reranker

    echo ""
    log_success "Model phase complete"
}

# ============================================================================
# STANDALONE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    download_models
fi
