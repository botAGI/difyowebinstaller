#!/usr/bin/env bash
# models.sh — Download LLM/embedding models (Ollama pull, vLLM/TEI streaming).
# Dependencies: common.sh (log_*, validate_model_name)
# Functions: download_models(), wait_for_ollama(), pull_model(name),
#            check_ollama_models(), _stream_gpu_model_logs()
# Expects: INSTALL_DIR, LLM_PROVIDER, LLM_MODEL, EMBED_PROVIDER, EMBEDDING_MODEL,
#          DEPLOY_PROFILE
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
    ["QuantTrio/Qwen3.5-27B-AWQ"]="16 GB"
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
# GPU MODEL LOG STREAMING
# ============================================================================

# _stream_gpu_model_logs — stream docker logs -f for a GPU service until
# healthy or timeout.
# Usage: _stream_gpu_model_logs "agmind-vllm" "vLLM" 600
# In TTY: streams raw docker logs -f to stdout.
# In non-TTY: polls docker logs --tail=1 every 10s, prints status line.
# Returns 0 when container becomes healthy, 1 on timeout.
_stream_gpu_model_logs() {
    local container="$1"
    local label="$2"
    local timeout="${3:-900}"  # default 15 min; 0 = no limit
    local elapsed=0
    local poll_interval=5

    # Check container exists/running before starting
    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_warn "${label}: container ${container} not found, skipping stream"
        return 1
    fi

    # Direct HTTP health probe — bypasses Docker start_period delay.
    # During start_period Docker reports "starting" even if the service
    # already responds on /health.  This function checks the real endpoint.
    _container_http_ready() {
        local _port=""
        case "$container" in
            *vllm*)          _port=8000 ;;
            *tei-rerank*)    _port=80 ;;
            *tei*)           _port=80 ;;
            *ollama*)        _port=11434 ;;
            *)               return 1 ;;
        esac
        docker exec "$container" curl -sf --max-time 3 "http://localhost:${_port}/health" >/dev/null 2>&1 \
            || docker exec "$container" wget -qO- --timeout=3 "http://localhost:${_port}/health" >/dev/null 2>&1
    }

    if [[ -n "${ORIGINAL_TTY_FD:-}" ]] && { true >&"${ORIGINAL_TTY_FD}"; } 2>/dev/null; then
        # TTY path: stream logs to real terminal (fd 3), filter healthcheck noise
        docker logs -f --since=0s "$container" 2>&1 \
            | grep -v --line-buffered -E '/health|healthcheck' \
            | sed --unbuffered "s/^/  [${label}] /" >&"${ORIGINAL_TTY_FD}" &
        local logs_pid=$!
        local last_log_hash=""
        local inactivity=0

        while [[ "$timeout" -eq 0 || $elapsed -lt $timeout ]]; do
            sleep "$poll_interval"
            elapsed=$((elapsed + poll_interval))

            # Check health — stop immediately when model is loaded
            # Try Docker health status first, then direct HTTP probe
            # (bypasses start_period where Docker reports "starting")
            local health
            health="$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")"
            if [[ "$health" == "healthy" ]] || _container_http_ready; then
                kill "$logs_pid" 2>/dev/null; wait "$logs_pid" 2>/dev/null || true
                return 0
            fi

            # Inactivity guard: check last real log line (not healthcheck)
            local cur_line
            cur_line="$(docker logs --tail=5 "$container" 2>&1 | grep -v -E '/health|healthcheck' | tail -1 | tr -d '\r')"
            local cur_hash
            cur_hash="$(echo "$cur_line" | cksum | cut -d' ' -f1)"
            if [[ "$cur_hash" != "$last_log_hash" ]]; then
                last_log_hash="$cur_hash"
                inactivity=0
            else
                inactivity=$((inactivity + poll_interval))
                if [[ $inactivity -ge 60 ]]; then
                    log_warn "${label}: no log activity for 60s, may be stalled"
                    inactivity=0
                fi
            fi
        done

        kill "$logs_pid" 2>/dev/null; wait "$logs_pid" 2>/dev/null || true
        return 1
    else
        # Non-TTY path: poll last log line every 10s
        poll_interval=10
        while [[ "$timeout" -eq 0 || $elapsed -lt $timeout ]]; do
            sleep "$poll_interval"
            elapsed=$((elapsed + poll_interval))

            # Check health — Docker status or direct HTTP probe
            local health
            health="$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")"
            if [[ "$health" == "healthy" ]] || _container_http_ready; then
                return 0
            fi

            # Show last log line (truncated to 80 chars)
            local last_line
            last_line="$(docker logs --tail=1 --no-log-prefix "$container" 2>/dev/null | tr -d '\r' || echo "")"
            if [[ -n "$last_line" ]]; then
                local summary="${last_line:0:80}"
                log_info "${label}: ${summary}"
            else
                log_info "${label}: waiting... (${elapsed}s)"
            fi
        done

        return 1
    fi
}

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
# CHECK PRE-LOADED MODELS
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
# MAIN: DOWNLOAD MODELS
# ============================================================================

download_models() {
    local llm_model="${LLM_MODEL:-qwen2.5:14b}"
    local embedding_model="${EMBEDDING_MODEL:-bge-m3}"
    local profile="${DEPLOY_PROFILE:-lan}"
    local llm_provider="${LLM_PROVIDER:-ollama}"
    local embed_provider="${EMBED_PROVIDER:-ollama}"

    # Ollama models
    local need_ollama=false
    if [[ "$llm_provider" == "ollama" ]]; then need_ollama=true; fi
    if [[ "$embed_provider" == "ollama" ]]; then need_ollama=true; fi

    if [[ "$need_ollama" == "true" ]]; then
        wait_for_ollama || return 1
        echo ""
        log_info "=== Downloading models ==="
        echo ""
        if [[ "$llm_provider" == "ollama" ]]; then pull_model "$llm_model" "LLM (${llm_model})"; fi
        if [[ "$embed_provider" == "ollama" ]]; then pull_model "$embedding_model" "Embedding (${embedding_model})"; fi
    fi

    # vLLM/TEI: models download at container startup (Phase 6).
    # Only stream logs if container is NOT yet healthy — skip if already loaded.
    if [[ "$llm_provider" == "vllm" ]]; then
        local vllm_health
        vllm_health="$(docker inspect --format='{{.State.Health.Status}}' agmind-vllm 2>/dev/null || echo "none")"
        if [[ "$vllm_health" != "healthy" ]] \
            && docker exec agmind-vllm curl -sf --max-time 3 http://localhost:8000/health >/dev/null 2>&1; then
            vllm_health="healthy"
        fi
        if [[ "$vllm_health" == "healthy" ]]; then
            log_success "vLLM model already loaded"
        else
            local vllm_size=""
            local _vllm_name="${VLLM_MODEL:-${LLM_MODEL:-unknown}}"
            if [[ -n "$_vllm_name" && "$_vllm_name" != "unknown" ]]; then vllm_size="${MODEL_SIZES[$_vllm_name]:-}"; fi
            local vllm_label="vLLM model: ${_vllm_name}"
            if [[ -n "$vllm_size" ]]; then vllm_label="${vllm_label} (~${vllm_size})"; fi
            log_info "Waiting for ${vllm_label}..."
            if ! _stream_gpu_model_logs "agmind-vllm" "vLLM" "${TIMEOUT_GPU_HEALTH:-0}"; then
                log_warn "vLLM model not fully loaded yet"
                log_warn "Container continues in background"
                log_warn "Monitor: docker logs -f agmind-vllm"
            fi
        fi
    fi
    if [[ "$embed_provider" == "tei" ]]; then
        local tei_health
        tei_health="$(docker inspect --format='{{.State.Health.Status}}' agmind-tei 2>/dev/null || echo "none")"
        # Docker reports "starting" during start_period even if TEI already serves /health
        if [[ "$tei_health" != "healthy" ]] \
            && docker exec agmind-tei curl -sf --max-time 3 http://localhost:80/health >/dev/null 2>&1; then
            tei_health="healthy"
        fi
        if [[ "$tei_health" == "healthy" ]]; then
            log_success "TEI model already loaded"
        else
            local tei_size=""
            if [[ -n "${EMBEDDING_MODEL:-}" ]]; then tei_size="${MODEL_SIZES[${EMBEDDING_MODEL}]:-}"; fi
            local tei_label="TEI model: ${EMBEDDING_MODEL:-unknown}"
            if [[ -n "$tei_size" ]]; then tei_label="${tei_label} (~${tei_size})"; fi
            log_info "Waiting for ${tei_label}..."
            if ! _stream_gpu_model_logs "agmind-tei" "TEI" "${TIMEOUT_GPU_HEALTH:-0}"; then
                log_warn "TEI model not fully loaded yet"
                log_warn "Container continues in background"
                log_warn "Monitor: docker logs -f agmind-tei"
            fi
        fi
    fi
    if [[ "$llm_provider" == "external" || "$llm_provider" == "skip" ]]; then
        if [[ "$need_ollama" != "true" ]]; then log_info "Provider ${llm_provider}: no model download needed"; fi
    fi

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
