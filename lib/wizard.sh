#!/usr/bin/env bash
# wizard.sh — Interactive installation wizard. All user questions in one module.
# Dependencies: common.sh (log_*, validate_*, colors), detect.sh (RECOMMENDED_MODEL, DETECTED_GPU)
# Exports all wizard choices as global variables (see §7.3 in SPEC.md):
#   DEPLOY_PROFILE, DOMAIN, CERTBOT_EMAIL, VECTOR_STORE, ENABLE_DOCLING,
#   LLM_PROVIDER, LLM_MODEL, VLLM_MODEL, EMBED_PROVIDER, EMBEDDING_MODEL,
#   HF_TOKEN, TLS_MODE, TLS_CERT_PATH, TLS_KEY_PATH,
#   MONITORING_MODE, MONITORING_ENDPOINT, MONITORING_TOKEN,
#   ALERT_MODE, ALERT_WEBHOOK_URL, ALERT_TELEGRAM_TOKEN, ALERT_TELEGRAM_CHAT_ID,
#   ENABLE_UFW, ENABLE_FAIL2BAN, ENABLE_AUTHELIA,
#   ENABLE_TUNNEL, TUNNEL_VPS_HOST, TUNNEL_VPS_PORT, TUNNEL_REMOTE_PORT,
#   BACKUP_TARGET, BACKUP_SCHEDULE, REMOTE_BACKUP_HOST, REMOTE_BACKUP_PORT,
#   REMOTE_BACKUP_USER, REMOTE_BACKUP_KEY, REMOTE_BACKUP_PATH,
#   ADMIN_UI_OPEN
# Functions: run_wizard()
# Non-interactive: set NON_INTERACTIVE=true + env var overrides
set -euo pipefail

# ============================================================================
# WIZARD DEFAULTS (for --non-interactive)
# ============================================================================

_init_wizard_defaults() {
    DEPLOY_PROFILE="${DEPLOY_PROFILE:-}"
    DOMAIN="${DOMAIN:-}"
    CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
    VECTOR_STORE="${VECTOR_STORE:-weaviate}"
    ENABLE_DOCLING="${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}"
    DOCLING_IMAGE="${DOCLING_IMAGE:-}"
    OCR_LANG="${OCR_LANG:-rus,eng}"
    NVIDIA_VISIBLE_DEVICES="${NVIDIA_VISIBLE_DEVICES:-}"
    LLM_PROVIDER="${LLM_PROVIDER:-}"
    LLM_MODEL="${LLM_MODEL:-}"
    VLLM_MODEL="${VLLM_MODEL:-}"
    VLLM_IMAGE="${VLLM_IMAGE:-}"
    VLLM_CMD_PREFIX="${VLLM_CMD_PREFIX:-}"
    VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"
    VLLM_CUDA_SUFFIX="${VLLM_CUDA_SUFFIX:-}"
    VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-}"
    EMBED_PROVIDER="${EMBED_PROVIDER:-}"
    EMBEDDING_MODEL="${EMBEDDING_MODEL:-}"
    TEI_EMBED_VERSION="${TEI_EMBED_VERSION:-}"
    ENABLE_RERANKER="${ENABLE_RERANKER:-false}"
    RERANK_MODEL="${RERANK_MODEL:-}"
    RERANKER_ON_GPU="${RERANKER_ON_GPU:-false}"
    RERANKER_PROVIDER="${RERANKER_PROVIDER:-tei}"
    TEI_RERANK_VERSION="${TEI_RERANK_VERSION:-}"
    VLLM_EMBED_MODEL="${VLLM_EMBED_MODEL:-}"
    VLLM_RERANK_MODEL="${VLLM_RERANK_MODEL:-}"
    HF_TOKEN="${HF_TOKEN:-}"
    TLS_MODE="${TLS_MODE:-none}"
    TLS_CERT_PATH="${TLS_CERT_PATH:-}"
    TLS_KEY_PATH="${TLS_KEY_PATH:-}"
    MONITORING_MODE="${MONITORING_MODE:-none}"
    MONITORING_ENDPOINT="${MONITORING_ENDPOINT:-}"
    MONITORING_TOKEN="${MONITORING_TOKEN:-}"
    GRAFANA_BIND_ADDR="${GRAFANA_BIND_ADDR:-127.0.0.1}"
    PORTAINER_BIND_ADDR="${PORTAINER_BIND_ADDR:-127.0.0.1}"
    ALERT_MODE="${ALERT_MODE:-none}"
    ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
    ALERT_TELEGRAM_TOKEN="${ALERT_TELEGRAM_TOKEN:-}"
    ALERT_TELEGRAM_CHAT_ID="${ALERT_TELEGRAM_CHAT_ID:-}"
    ENABLE_UFW="${ENABLE_UFW:-false}"
    ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-false}"
    ENABLE_AUTHELIA="${ENABLE_AUTHELIA:-false}"
    ENABLE_TUNNEL="${ENABLE_TUNNEL:-false}"
    TUNNEL_VPS_HOST="${TUNNEL_VPS_HOST:-}"
    TUNNEL_VPS_PORT="${TUNNEL_VPS_PORT:-22}"
    TUNNEL_REMOTE_PORT="${TUNNEL_REMOTE_PORT:-8080}"
    BACKUP_TARGET="${BACKUP_TARGET:-local}"
    BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 3 * * *}"
    REMOTE_BACKUP_HOST="${REMOTE_BACKUP_HOST:-}"
    REMOTE_BACKUP_PORT="${REMOTE_BACKUP_PORT:-22}"
    REMOTE_BACKUP_USER="${REMOTE_BACKUP_USER:-}"
    REMOTE_BACKUP_KEY="${REMOTE_BACKUP_KEY:-}"
    REMOTE_BACKUP_PATH="${REMOTE_BACKUP_PATH:-/var/backups/agmind-remote}"
    ADMIN_UI_OPEN="${ADMIN_UI_OPEN:-false}"
    ENABLE_LITELLM="${ENABLE_LITELLM:-false}"
    ENABLE_SEARXNG="${ENABLE_SEARXNG:-false}"
    ENABLE_NOTEBOOK="${ENABLE_NOTEBOOK:-false}"
    ENABLE_DBGPT="${ENABLE_DBGPT:-false}"
    ENABLE_CRAWL4AI="${ENABLE_CRAWL4AI:-false}"
    ENABLE_DIFY_PREMIUM="${ENABLE_DIFY_PREMIUM:-true}"
    NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
}

# ============================================================================
# HELPERS
# ============================================================================

# Read user choice with default. Usage: _ask "Prompt" default_value
# Returns value in $REPLY. Respects NON_INTERACTIVE.
_ask() {
    local prompt="$1" default="${2:-}"
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        REPLY="$default"
        return 0
    fi
    read -rp "${prompt} " REPLY
    REPLY="${REPLY:-$default}"
}

# Read user choice in a loop until valid. Usage: _ask_choice "Prompt" min max default
_ask_choice() {
    local prompt="$1" min="$2" max="$3" default="$4"
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        REPLY="$default"
        return 0
    fi
    while true; do
        read -rp "${prompt} " REPLY
        REPLY="${REPLY:-$default}"
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [[ "$REPLY" -ge "$min" && "$REPLY" -le "$max" ]]; then
            return 0
        fi
        echo "Введите число от ${min} до ${max}"
    done
}

# ============================================================================
# WIZARD SECTIONS
# ============================================================================

_wizard_profile() {
    if [[ "${NON_INTERACTIVE}" == "true" && -n "${DEPLOY_PROFILE}" ]]; then
        return 0
    fi

    local choice
    choice=$(wt_menu "Профиль развёртывания" \
        "Выберите профиль развёртывания:" \
        "1" "LAN  -- локальная / офисная сеть (по умолчанию)" \
        "2" "VDS/VPS -- публичный сервер (ветка agmind-caddy)")

    case "$choice" in
        2)
            log_info "Переключение на ветку agmind-caddy для VDS/VPS..."
            git fetch origin agmind-caddy && git checkout agmind-caddy && exec bash install.sh --vds
            ;;
        *) DEPLOY_PROFILE="lan";;
    esac
}

_wizard_security_defaults() {
    # LAN profile: optional security
    ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-false}"
}

_wizard_admin_ui() {
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    if wt_yesno "Доступ к Admin UI" \
        "Portainer и Grafana привязаны к localhost (127.0.0.1) по умолчанию.\n\nОткрыть доступ из LAN?" \
        --defaultno; then
        ADMIN_UI_OPEN=true
    else
        ADMIN_UI_OPEN=false
    fi
}

_wizard_domain() {
    # Domain config handled by agmind-caddy branch for VDS/VPS
    return 0
}

_wizard_vector_store() {
    # Respect env override in non-interactive
    if [[ "${NON_INTERACTIVE}" == "true" && "$VECTOR_STORE" != "weaviate" ]]; then
        return 0
    fi

    local choice
    choice=$(wt_menu "Векторное хранилище" \
        "Выберите векторное хранилище:" \
        "1" "Weaviate -- стабильный, проверенный (по умолчанию)" \
        "2" "Qdrant   -- быстрый, REST/gRPC API")

    case "$choice" in
        2) VECTOR_STORE="qdrant";;
        *) VECTOR_STORE="weaviate";;
    esac
}

_wizard_etl() {
    # Detect nvidia container runtime availability
    local has_nvidia_runtime="false"
    if [[ "${DETECTED_GPU:-none}" == "nvidia" ]]; then
        if docker info 2>/dev/null | grep -qi "nvidia"; then
            has_nvidia_runtime="true"
        fi
    fi

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    local -a menu_args=(
        "1" "Нет -- стандартный Dify ETL (по умолчанию)"
        "2" "Да  -- Docling CPU"
    )
    if [[ "$has_nvidia_runtime" == "true" ]]; then
        menu_args+=("3" "Да  -- Docling GPU (CUDA)")
    fi

    local choice
    choice=$(wt_menu "Обработка документов (Docling)" \
        "Расширенная обработка документов (Docling)?" \
        "${menu_args[@]}")

    case "$choice" in
        2)
            ENABLE_DOCLING="true"
            DOCLING_IMAGE="${DOCLING_IMAGE_CPU}"
            NVIDIA_VISIBLE_DEVICES=""
            ;;
        3)
            ENABLE_DOCLING="true"
            DOCLING_IMAGE="${DOCLING_IMAGE_CUDA}"
            NVIDIA_VISIBLE_DEVICES="all"
            ;;
        *)
            ENABLE_DOCLING="false"
            DOCLING_IMAGE=""
            NVIDIA_VISIBLE_DEVICES=""
            ;;
    esac
    OCR_LANG="rus,eng"
}

_wizard_llm_provider() {
    local default_provider="vllm"
    local default_tag="2"
    local gpu_note=""
    if [[ "${DETECTED_GPU:-none}" != "nvidia" ]]; then
        default_provider="ollama"
        default_tag="1"
        gpu_note=" (NVIDIA GPU не обнаружен)"
    fi

    # Respect env override only in non-interactive mode
    if [[ "${NON_INTERACTIVE}" == "true" && -n "$LLM_PROVIDER" ]]; then
        _apply_blackwell_cu130
        return 0
    fi

    local choice
    choice=$(wt_menu "LLM-провайдер" \
        "Выберите LLM-провайдер:${gpu_note}" \
        "1" "Ollama" \
        "2" "vLLM" \
        "3" "Внешний API" \
        "4" "Пропустить")

    # Default to detected preference if empty
    choice="${choice:-$default_tag}"

    case "$choice" in
        1) LLM_PROVIDER="ollama";;
        2) LLM_PROVIDER="vllm";;
        3) LLM_PROVIDER="external";;
        4) LLM_PROVIDER="skip";;
        *) LLM_PROVIDER="$default_provider";;
    esac

    # Blackwell GPU (sm_120+): auto-apply CUDA 13.0 build for vLLM
    if [[ "$LLM_PROVIDER" == "vllm" ]] && _is_blackwell_gpu; then
        VLLM_CUDA_SUFFIX="-cu130"
        log_info "Blackwell GPU (compute ${DETECTED_GPU_COMPUTE}) -> vLLM с CUDA 13.0 (-cu130)"
    fi

    # DGX Spark: hardcoded to Gemma 4 on gemma4-cu130 image
    # - Best tested model on Spark (NVIDIA official playbook)
    # - ~40 tok/s, 256K context, 3.8B active params (MoE)
    # - NGC 26.03 lacks transformers 5.5+ needed for Gemma 4
    # - Embed/rerank stay on NGC (different containers)
    if [[ "$LLM_PROVIDER" == "vllm" && "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then
        VLLM_IMAGE="vllm/vllm-openai:gemma4-cu130"
        VLLM_MODEL="google/gemma-4-26B-A4B-it"
        VLLM_CUDA_SUFFIX=""
        VLLM_CMD_PREFIX=""  # gemma4 image has standard vllm entrypoint
        VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-65536}"
        VLLM_EXTRA_ARGS="--kv-cache-dtype fp8 --enable-prefix-caching"
        log_info "DGX Spark → Gemma 4 26B-A4B (${VLLM_IMAGE})"
    fi
}

# Check if GPU is Blackwell architecture (compute capability >= 12.0)
_is_blackwell_gpu() {
    local cc="${DETECTED_GPU_COMPUTE:-}"
    if [[ -z "$cc" ]]; then return 1; fi
    local major="${cc%%.*}"
    [[ "$major" -ge 12 ]] 2>/dev/null
}

# Auto-apply -cu130 suffix for Blackwell in non-interactive mode
_apply_blackwell_cu130() {
    if [[ "$LLM_PROVIDER" == "vllm" ]] && _is_blackwell_gpu; then
        if [[ "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then
            VLLM_IMAGE="vllm/vllm-openai:gemma4-cu130"
            VLLM_MODEL="google/gemma-4-26B-A4B-it"
            VLLM_CUDA_SUFFIX=""
            VLLM_CMD_PREFIX=""
            VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-65536}"
            VLLM_EXTRA_ARGS="--kv-cache-dtype fp8 --enable-prefix-caching"
            log_info "DGX Spark (NI) → Gemma 4 26B-A4B (${VLLM_IMAGE})"
        else
            VLLM_CUDA_SUFFIX="-cu130"
            log_info "Blackwell GPU (compute ${DETECTED_GPU_COMPUTE}) — автоматически выбран vLLM с CUDA 13.0"
        fi
    fi
}

_wizard_ollama_model() {
    # Determine recommended model marker
    local rec_idx=6
    case "${RECOMMENDED_MODEL:-}" in
        *14b*) rec_idx=6;;
        *32b*) rec_idx=10;;
        *72b*) rec_idx=13;;
        *4b*)  rec_idx=1;;
        *7b*)  rec_idx=2;;
    esac

    local ollama_models=(
        ""  # 0 placeholder
        "gemma3:4b"
        "qwen2.5:7b"
        "qwen3:8b"
        "llama3.1:8b"
        "mistral:7b"
        "qwen2.5:14b"
        "phi-4:14b"
        "mistral-nemo:12b"
        "gemma3:12b"
        "qwen2.5:32b"
        "gemma3:27b"
        "command-r:35b"
        "qwen2.5:72b-instruct-q4_K_M"
        "llama3.1:70b-instruct-q4_K_M"
        "qwen3:32b"
        "qwen3.5:35b-a3b"
    )

    # Build menu items with recommended tag
    _ollama_label() {
        local idx="$1" name="$2" extra="${3:-}"
        local label="${name}${extra}"
        if [[ "$idx" -eq "$rec_idx" ]]; then label="${name}${extra}  [*]"; fi
        echo "$label"
    }

    local choice
    choice=$(wt_menu "LLM-модель (Ollama)" \
        "Выберите LLM-модель. [*] = рекомендуется для вашего GPU." \
        "1"  "$(_ollama_label 1  "gemma3:4b"      "  | 8GB+ RAM, 6GB+ VRAM")" \
        "2"  "$(_ollama_label 2  "qwen2.5:7b"     "  | 8GB+ RAM, 6GB+ VRAM")" \
        "3"  "$(_ollama_label 3  "qwen3:8b"       "  | 8GB+ RAM, 6GB+ VRAM")" \
        "4"  "$(_ollama_label 4  "llama3.1:8b"    "  | 8GB+ RAM, 6GB+ VRAM")" \
        "5"  "$(_ollama_label 5  "mistral:7b"     "  | 8GB+ RAM, 6GB+ VRAM")" \
        "6"  "$(_ollama_label 6  "qwen2.5:14b"    "  | 16GB+ RAM, 10GB+ VRAM")" \
        "7"  "$(_ollama_label 7  "phi-4:14b"      "  | 16GB+ RAM, 10GB+ VRAM")" \
        "8"  "$(_ollama_label 8  "mistral-nemo:12b" "  | 16GB+ RAM, 10GB+ VRAM")" \
        "9"  "$(_ollama_label 9  "gemma3:12b"     "  | 16GB+ RAM, 10GB+ VRAM")" \
        "10" "$(_ollama_label 10 "qwen2.5:32b"    "  | 32GB+ RAM, 16GB+ VRAM")" \
        "11" "$(_ollama_label 11 "gemma3:27b"     "  | 32GB+ RAM, 16GB+ VRAM")" \
        "12" "$(_ollama_label 12 "command-r:35b"  "  | 32GB+ RAM, 16GB+ VRAM")" \
        "13" "$(_ollama_label 13 "qwen2.5:72b Q4" "  | 64GB+ RAM, 24GB+ VRAM")" \
        "14" "$(_ollama_label 14 "llama3.1:70b Q4" "  | 64GB+ RAM, 24GB+ VRAM")" \
        "15" "$(_ollama_label 15 "qwen3:32b"      "  | 64GB+ RAM, 24GB+ VRAM")" \
        "16" "$(_ollama_label 16 "qwen3.5:35b-a3b" "  | MoE 35B/3B active")" \
        "17" "Ввести вручную (имя из реестра Ollama)")

    choice="${choice:-6}"

    if [[ "$choice" -ge 1 && "$choice" -le 16 ]]; then
        LLM_MODEL="${ollama_models[$choice]}"
    elif [[ "$choice" -eq 17 ]]; then
        local custom_model
        custom_model=$(wt_input "Своя модель Ollama" "Имя модели:" "qwen2.5:14b")
        LLM_MODEL="${custom_model:-qwen2.5:14b}"
        validate_model_name "$LLM_MODEL" || { LLM_MODEL="qwen2.5:14b"; log_warn "Некорректное имя модели, используется значение по умолчанию"; }
    fi

    unset -f _ollama_label
}

# Dynamic VRAM offset: GPU reservation for TEI embedding + reranker.
# Returns offset in GB based on providers and their GPU/CPU mode.
_get_vram_offset() {
    local offset=0
    # TEI embedding on CUDA reserves ~2 GB GPU VRAM
    if [[ "${EMBED_PROVIDER:-tei}" == "tei" && "${TEI_EMBED_VERSION:-cuda}" != cpu-* ]]; then
        offset=$(( offset + 2 ))
    fi
    # vLLM-embed (DGX Spark) reserves ~2 GB GPU VRAM
    if [[ "${EMBED_PROVIDER:-}" == "vllm-embed" ]]; then
        offset=$(( offset + 2 ))
    fi
    # TEI reranker on CUDA reserves ~1 GB GPU VRAM
    if [[ "${RERANKER_ON_GPU:-false}" == "true" ]]; then
        offset=$(( offset + 1 ))
    fi
    # Docling GPU (CUDA OCR + layout) reserves ~3 GB GPU VRAM
    if [[ "${ENABLE_DOCLING:-false}" == "true" && "${NVIDIA_VISIBLE_DEVICES:-}" == "all" ]]; then
        offset=$(( offset + 3 ))
    fi
    echo "$offset"
}

# Returns model weights VRAM in GB (without KV cache).
# Usage: req=$(_get_vllm_weights_gb "Qwen/Qwen2.5-14B-Instruct")
# Outputs "0" for unknown models.
_get_vllm_weights_gb() {
    local model="${1:-}"
    case "$model" in
        "Qwen/Qwen2.5-7B-Instruct-AWQ")                    echo "4"   ;;
        "Qwen/Qwen3-8B-AWQ")                               echo "5"   ;;
        "Qwen/Qwen2.5-14B-Instruct-AWQ")                   echo "8"   ;;
        "Qwen/Qwen3-14B-AWQ")                              echo "8"   ;;
        "QuantTrio/Qwen3.5-27B-AWQ")                       echo "15"  ;;
        "Qwen/Qwen2.5-32B-Instruct-AWQ")                   echo "18"  ;;
        "Qwen/Qwen2.5-7B-Instruct")                        echo "14"  ;;
        "Qwen/Qwen3-8B")                                   echo "16"  ;;
        "mistralai/Mistral-7B-Instruct-v0.3")              echo "14"  ;;
        "meta-llama/Llama-3.1-8B-Instruct")                echo "16"  ;;
        "Qwen/Qwen2.5-14B-Instruct")                       echo "28"  ;;
        "Qwen/Qwen3-14B")                                  echo "28"  ;;
        "microsoft/phi-4")                                  echo "28"  ;;
        "Qwen/Qwen2.5-32B-Instruct")                       echo "64"  ;;
        "meta-llama/Llama-3.3-70B-Instruct")               echo "140" ;;
        "bullpoint/Qwen3-Coder-Next-AWQ-4bit")             echo "12"  ;;
        "stelterlab/NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ")   echo "4"   ;;
        "Qwen/Qwen3.5-35B-A3B")                            echo "72"  ;;
        "google/gemma-4-26B-A4B-it")                       echo "50"  ;;
        "google/gemma-4-31B-it")                           echo "62"  ;;
        "nvidia/Gemma-4-31B-IT-NVFP4")                    echo "20"  ;;
        *)                                                  echo "0"   ;;
    esac
}

# Returns KV cache size in GB per 1K tokens for a model.
# Formula: 2 x layers x kv_heads x head_dim x dtype_bytes / 1024^3 x 1024 tokens
# Outputs "0" for unknown models.
_get_vllm_kv_per_1k() {
    local model="${1:-}"
    # KV cache GB per 1K tokens (fp16=2B, rounded up)
    # 7B  (32L, 8KV, 128d):  2x32x8x128x2 x 1024 / 1073741824 ~ 0.125
    # 8B  (32L, 8KV, 128d):  same ~ 0.125
    # 14B (40L, 8KV, 128d):  2x40x8x128x2 x 1024 / 1073741824 ~ 0.156
    # 27B (28L, 4KV, 128d):  2x28x4x128x2 x 1024 / 1073741824 ~ 0.028 (GQA, few KV heads)
    # 32B (64L, 8KV, 128d):  2x64x8x128x2 x 1024 / 1073741824 ~ 0.250
    # 70B (80L, 8KV, 128d):  2x80x8x128x2 x 1024 / 1073741824 ~ 0.313
    # MoE models share KV across experts — same as base layer count
    case "$model" in
        *7B*|*8B*)       echo "125" ;;   # 0.125 GB/1K tokens (x1000 for int math)
        *14B*|*phi-4*)   echo "156" ;;   # 0.156
        *27B*|*Qwen3.5-27B*)  echo "80"  ;;   # 0.08 (GQA, 4 KV heads)
        *32B*)           echo "250" ;;   # 0.250
        *70B*)           echo "313" ;;   # 0.313
        *35B-A3B*)       echo "20"  ;;   # hybrid: only 10/40 layers have KV (2 heads, dim 256)
        *gemma-4-26B*)   echo "30"  ;;   # 36L, 8KV, 64d, fp8: ~0.03 GB/1K
        *gemma-4-31B*|*Gemma-4-31B*)  echo "30"  ;;   # same KV architecture
        *30B-A3B*)       echo "60"  ;;   # small active params
        *Coder-Next*)    echo "156" ;;   # 14B active ~ 14B KV
        *)               echo "0"   ;;
    esac
}

# Calculate total VRAM: weights + KV cache for given context.
# Usage: total=$(_calc_vllm_total_gb "Qwen/Qwen2.5-14B-Instruct" 32768)
_calc_vllm_total_gb() {
    local model="$1" ctx="${2:-32768}"
    local weights kv_per_1k
    weights=$(_get_vllm_weights_gb "$model")
    kv_per_1k=$(_get_vllm_kv_per_1k "$model")
    if [[ "$weights" -eq 0 || "$kv_per_1k" -eq 0 ]]; then
        echo "$weights"
        return
    fi
    # KV cache GB = kv_per_1k/1000 x (ctx/1024) + ~1 GB CUDA overhead
    local kv_gb=$(( (kv_per_1k * ctx / 1024 + 500) / 1000 + 1 ))
    echo $(( weights + kv_gb ))
}

# Backward-compatible wrapper: returns total VRAM (weights + KV at default 32K).
# Used by config.sh for enforce-eager decision and VRAM summary.
_get_vllm_vram_req() {
    local model="${1:-}"
    _calc_vllm_total_gb "$model" "${VLLM_MAX_MODEL_LEN:-32768}"
}

_wizard_vllm_model() {
    # Model weights in GB (indices 1-18 match menu numbers)
    #                       1   2   3   4   5   6   7   8   9  10  11  12  13  14   15  16  17  18
    local -a weights_gb=(0  4   5   8   8  15  18  14  16  14  16  28  28  28  64  140  12   4  72)
    # KV cache GB per 1K tokens x1000 (for int math)
    local -a kv_per_1k=(0 125 125 156 156  80 250 125 125 125 125 156 156 156 250  313 156  60  20)
    # Default context for display (32K)
    local default_ctx=32768

    # Pre-calc total VRAM (weights + KV@32K + 1GB overhead) for each model
    local -a vram_total=()
    local idx
    for idx in $(seq 0 18); do
        if [[ "$idx" -eq 0 ]]; then
            vram_total+=(0)
        else
            local kv_gb=$(( (kv_per_1k[$idx] * default_ctx / 1024 + 500) / 1000 + 1 ))
            vram_total+=( $(( weights_gb[$idx] + kv_gb )) )
        fi
    done

    local vram_gb=0
    if [[ "${DETECTED_GPU_VRAM:-0}" -gt 0 ]]; then
        vram_gb=$(( DETECTED_GPU_VRAM / 1024 ))
    fi

    # TEI offset for [recommended]
    local effective_vram="$vram_gb"
    if [[ "$vram_gb" -gt 0 ]]; then
        local vram_offset
        vram_offset=$(_get_vram_offset)
        effective_vram=$(( vram_gb - vram_offset ))
        if [[ "$effective_vram" -lt 0 ]]; then effective_vram=0; fi
    fi

    # Find largest fitting model for [*] tag.
    # Check dense models first (14->1), then MoE (16->18) — so dense bf16 > AWQ > MoE.
    # On DGX Spark: skip qwen3.5_moe models (5, 18) — not supported in NGC container.
    local rec_idx=0
    local _spark="${DETECTED_DGX_SPARK:-false}"
    if [[ "$effective_vram" -gt 0 ]]; then
        local i
        for i in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 16 18 17; do
            # Skip unsupported models on Spark
            if [[ "$_spark" == "true" && ( "$i" -eq 5 || "$i" -eq 18 ) ]]; then continue; fi
            if [[ "${vram_total[$i]}" -le "$effective_vram" ]]; then
                rec_idx="$i"
                break
            fi
        done
    fi

    local mem_label="VRAM"
    if [[ "${DETECTED_GPU_UNIFIED_MEMORY:-false}" == "true" ]]; then mem_label="GPU mem"; fi

    # Helper: build label for a vLLM model menu item
    _vllm_label() {
        local idx="$1" name="$2" suffix="${3:-}"
        local rec_mark=""
        if [[ "$idx" -eq "$rec_idx" ]]; then rec_mark="  [*]"; fi
        local w="${weights_gb[$idx]}"
        local kv=$(( vram_total[$idx] - w ))
        echo "${name}  [~${vram_total[$idx]} GB: ${w}+KV${kv}]${suffix}${rec_mark}"
    }

    local vram_note=""
    if [[ "$vram_gb" -eq 0 ]]; then
        vram_note="\n(GPU память не определена -- метка [*] недоступна)"
    fi

    # DGX Spark: qwen3_5_moe architecture not supported in NGC container yet
    local is_spark="${DETECTED_DGX_SPARK:-false}"
    local spark_note=""
    if [[ "$is_spark" == "true" ]]; then
        spark_note="\n(DGX Spark: модели Qwen3.5 MoE пока не поддерживаются NGC)"
    fi

    # Build menu dynamically — skip unsupported models on Spark
    local -a menu_args=()
    menu_args+=("1"  "$(_vllm_label 1  "Qwen2.5-7B-Instruct-AWQ")")
    menu_args+=("2"  "$(_vllm_label 2  "Qwen3-8B-AWQ")")
    menu_args+=("3"  "$(_vllm_label 3  "Qwen2.5-14B-Instruct-AWQ")")
    menu_args+=("4"  "$(_vllm_label 4  "Qwen3-14B-AWQ")")
    if [[ "$is_spark" != "true" ]]; then
        menu_args+=("5"  "$(_vllm_label 5  "Qwen3.5-27B-AWQ")")
    fi
    menu_args+=("6"  "$(_vllm_label 6  "Qwen2.5-32B-Instruct-AWQ")")
    menu_args+=("7"  "$(_vllm_label 7  "Qwen2.5-7B-Instruct bf16")")
    menu_args+=("8"  "$(_vllm_label 8  "Qwen3-8B bf16")")
    menu_args+=("9"  "$(_vllm_label 9  "Mistral-7B-v0.3 bf16")")
    menu_args+=("10" "$(_vllm_label 10 "Llama-3.1-8B bf16" "  (HF_TOKEN)")")
    menu_args+=("11" "$(_vllm_label 11 "Qwen2.5-14B-Instruct bf16")")
    menu_args+=("12" "$(_vllm_label 12 "Qwen3-14B bf16")")
    menu_args+=("13" "$(_vllm_label 13 "microsoft/phi-4 bf16")")
    menu_args+=("14" "$(_vllm_label 14 "Qwen2.5-32B-Instruct bf16")")
    menu_args+=("15" "$(_vllm_label 15 "Llama-3.3-70B bf16" "  (HF_TOKEN)")")
    menu_args+=("16" "$(_vllm_label 16 "Qwen3-Coder-Next AWQ" "  MoE 80B/14B")")
    menu_args+=("17" "$(_vllm_label 17 "Nemotron-Nano-30B-A3B AWQ" "  MoE 30B/3B")")
    if [[ "$is_spark" != "true" ]]; then
        menu_args+=("18" "$(_vllm_label 18 "Qwen3.5-35B-A3B" "  MoE 35B/3B")")
    fi
    menu_args+=("19" "Ввести HuggingFace репозиторий (org/model-name)")

    local choice
    choice=$(wt_menu "Модель vLLM" \
        "Выберите модель. Оценка: веса + KV-кэш при 32K контексте. [*]=рекомендуется.${vram_note}${spark_note}" \
        "${menu_args[@]}")

    local _default_model="5"
    if [[ "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then _default_model="6"; fi
    local model_choice="${choice:-$_default_model}"

    local vllm_models=(
        ""  # 0 placeholder
        "Qwen/Qwen2.5-7B-Instruct-AWQ"
        "Qwen/Qwen3-8B-AWQ"
        "Qwen/Qwen2.5-14B-Instruct-AWQ"
        "Qwen/Qwen3-14B-AWQ"
        "QuantTrio/Qwen3.5-27B-AWQ"
        "Qwen/Qwen2.5-32B-Instruct-AWQ"
        "Qwen/Qwen2.5-7B-Instruct"
        "Qwen/Qwen3-8B"
        "mistralai/Mistral-7B-Instruct-v0.3"
        "meta-llama/Llama-3.1-8B-Instruct"
        "Qwen/Qwen2.5-14B-Instruct"
        "Qwen/Qwen3-14B"
        "microsoft/phi-4"
        "Qwen/Qwen2.5-32B-Instruct"
        "meta-llama/Llama-3.3-70B-Instruct"
        "bullpoint/Qwen3-Coder-Next-AWQ-4bit"
        "stelterlab/NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ"
        "Qwen/Qwen3.5-35B-A3B"
    )

    if [[ "$model_choice" -ge 1 && "$model_choice" -le 18 ]]; then
        VLLM_MODEL="${vllm_models[$model_choice]}"
    elif [[ "$model_choice" -eq 19 ]]; then
        local custom_model
        custom_model=$(wt_input "Своя модель vLLM" "HuggingFace репозиторий (org/model):" "QuantTrio/Qwen3.5-27B-AWQ")
        VLLM_MODEL="${custom_model:-QuantTrio/Qwen3.5-27B-AWQ}"
    fi

    # --- Context length selection ---
    local -a ctx_options=(4096 8192 16384 32768 65536 131072)
    local -a ctx_labels=("4K" "8K" "16K" "32K" "64K" "128K")
    local model_w=0 model_kv=0
    if [[ "$model_choice" -ge 1 && "$model_choice" -le 18 ]]; then
        model_w=${weights_gb[$model_choice]}
        model_kv=${kv_per_1k[$model_choice]}
    fi

    # Build context menu items with VRAM estimation
    local -a ctx_menu_args=()
    local ci
    for ci in $(seq 0 5); do
        local ctx_val=${ctx_options[$ci]}
        local total_est="?"
        if [[ "$model_w" -gt 0 && "$model_kv" -gt 0 ]]; then
            local kv_est=$(( (model_kv * ctx_val / 1024 + 500) / 1000 + 1 ))
            total_est=$(( model_w + kv_est ))
        fi
        local num=$(( ci + 1 ))
        local fit_tag=""
        if [[ "$effective_vram" -gt 0 && "$total_est" != "?" ]]; then
            if [[ "$total_est" -le "$effective_vram" ]]; then
                fit_tag="  [OK]"
            else
                fit_tag="  [!OOM]"
            fi
        fi
        if [[ "$total_est" != "?" ]]; then
            local kv_show=$(( total_est - model_w ))
            ctx_menu_args+=("${num}" "${ctx_labels[$ci]}  [~${total_est} GB: ${model_w}+KV${kv_show}]${fit_tag}")
        else
            ctx_menu_args+=("${num}" "${ctx_labels[$ci]}  [? GB]")
        fi
    done

    local ctx_choice
    ctx_choice=$(wt_menu "Контекст (max-model-len)" \
        "Максимальный контекст. Оценка: веса ${model_w} GB + KV-кэш." \
        "${ctx_menu_args[@]}")

    ctx_choice="${ctx_choice:-4}"
    VLLM_MAX_MODEL_LEN="${ctx_options[$((ctx_choice - 1))]}"

    # Recalculate total VRAM with chosen context
    local total_with_ctx=0
    if [[ "$model_choice" -ge 1 && "$model_choice" -le 18 && "$model_kv" -gt 0 ]]; then
        local kv_chosen=$(( (model_kv * VLLM_MAX_MODEL_LEN / 1024 + 500) / 1000 + 1 ))
        total_with_ctx=$(( model_w + kv_chosen ))
    fi

    # VRAM guard
    if [[ "$model_choice" -ge 1 && "$model_choice" -le 18 && "$total_with_ctx" -gt 0 ]]; then
        local vram_offset_guard
        vram_offset_guard=$(_get_vram_offset)
        local effective_vram_check=$(( vram_gb > 0 ? vram_gb - vram_offset_guard : 0 ))
        if [[ "$effective_vram_check" -lt 0 ]]; then effective_vram_check=0; fi
        if [[ "$vram_gb" -gt 0 && "$total_with_ctx" -gt "$effective_vram_check" ]]; then
            if [[ "${NON_INTERACTIVE}" != "true" ]]; then
                if ! wt_yesno "VRAM предупреждение" \
                    "Модель + KV-кэш (${ctx_labels[$((ctx_choice-1))]}) = ~${total_with_ctx} GB, доступно ${effective_vram_check} GB ${mem_label}.\nВозможен OOM. Продолжить?"\
                    --defaultno; then
                    unset -f _vllm_label
                    _wizard_vllm_model
                    return
                fi
            fi
        fi

        wt_info "vLLM" "Итого: ${VLLM_MODEL} @ ${ctx_labels[$((ctx_choice-1))]} = ~${total_with_ctx} GB (веса ${model_w} + KV ~$((total_with_ctx - model_w)))"
        sleep 1
    fi

    # Clean up nested function
    unset -f _vllm_label
}

_wizard_llm_model() {
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        # Non-vllm providers: no VRAM guard needed, accept env value as-is
        if [[ "$LLM_PROVIDER" != "vllm" ]]; then
            return 0
        fi
        # vllm + NON_INTERACTIVE: skip interactive menu, fall through to
        # default assignment and VRAM guard below (BFIX-41)
    else
        # DGX Spark: model is hardcoded to Gemma 4, offer context choice
        if [[ "$LLM_PROVIDER" == "vllm" && "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then
            local spark_ctx
            spark_ctx=$(wt_menu "DGX Spark — Gemma 4 контекст" \
                "Модель: google/gemma-4-26B-A4B-it (MoE, 3.8B active)\nОбраз: vllm/vllm-openai:gemma4-cu130\n\nВыберите максимальный контекст (fp8 KV-кэш):\n(128 GB unified memory, ~53 GB доступно для KV-кэша)" \
                "1" "32K   — минимум памяти, макс. concurrency" \
                "2" "64K   — баланс (рекомендуется)" \
                "3" "128K  — большие документы, меньше concurrency")
            spark_ctx="${spark_ctx:-2}"
            case "$spark_ctx" in
                1) VLLM_MAX_MODEL_LEN=32768;;
                2) VLLM_MAX_MODEL_LEN=65536;;
                3) VLLM_MAX_MODEL_LEN=131072;;
                *) VLLM_MAX_MODEL_LEN=65536;;
            esac
        else
            # Interactive path
            case "$LLM_PROVIDER" in
                ollama)   _wizard_ollama_model;;
                vllm)     _wizard_vllm_model;;
                # external/skip: no model selection needed
            esac
        fi
    fi

    # Apply non-interactive defaults if still empty
    if [[ "$LLM_PROVIDER" == "ollama" && -z "$LLM_MODEL" ]]; then
        LLM_MODEL="${RECOMMENDED_MODEL:-qwen2.5:14b}"
        validate_model_name "$LLM_MODEL" || LLM_MODEL="qwen2.5:14b"
    fi
    if [[ "$LLM_PROVIDER" == "vllm" && -z "$VLLM_MODEL" ]]; then
        if [[ "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then
            VLLM_MODEL="Qwen/Qwen2.5-32B-Instruct-AWQ"
        else
            VLLM_MODEL="QuantTrio/Qwen3.5-27B-AWQ"
        fi
    fi
    if [[ "$LLM_PROVIDER" == "vllm" && -z "$VLLM_MAX_MODEL_LEN" ]]; then
        VLLM_MAX_MODEL_LEN="32768"
    fi

    # VRAM guard for vllm in NON_INTERACTIVE mode (BFIX-41)
    # Runs for both user-supplied VLLM_MODEL and the default assigned above.
    # Uses total VRAM (weights + KV cache at chosen context).
    if [[ "${NON_INTERACTIVE}" == "true" && "$LLM_PROVIDER" == "vllm" && -n "${VLLM_MODEL:-}" ]]; then
        local ni_vram_req
        ni_vram_req="$(_get_vllm_vram_req "$VLLM_MODEL")"
        if [[ "$ni_vram_req" -gt 0 ]]; then
            local ni_vram_gb=0
            if [[ "${DETECTED_GPU_VRAM:-0}" -gt 0 ]]; then
                ni_vram_gb=$(( DETECTED_GPU_VRAM / 1024 ))
            fi
            local ni_vram_offset
            ni_vram_offset=$(_get_vram_offset)
            local ni_effective_vram=$(( ni_vram_gb > 0 ? ni_vram_gb - ni_vram_offset : 0 ))
            if [[ "$ni_effective_vram" -lt 0 ]]; then ni_effective_vram=0; fi
            if [[ "$ni_vram_gb" -gt 0 && "$ni_vram_req" -gt "$ni_effective_vram" ]]; then
                log_error "Model ${VLLM_MODEL} requires ~${ni_vram_req} GB (weights+KV), effective available: ${ni_effective_vram} GB (${ni_vram_gb} GB - ${ni_vram_offset} GB offset)"
                log_error "Choose a smaller model, reduce VLLM_MAX_MODEL_LEN, or set VLLM_MODEL to a model that fits"
                exit 1
            fi
            if [[ "$ni_vram_gb" -eq 0 ]]; then
                log_warn "GPU memory not detected -- cannot verify model ${VLLM_MODEL} fits (requires ~${ni_vram_req} GB)"
            fi
        fi
    fi
}

_wizard_embed_provider() {
    # Respect env override only in non-interactive mode
    if [[ "${NON_INTERACTIVE}" == "true" && -n "$EMBED_PROVIDER" ]]; then
        # DGX Spark: force vllm-embed even if user specified tei
        if [[ "${DETECTED_DGX_SPARK:-false}" == "true" && "$EMBED_PROVIDER" == "tei" ]]; then
            log_warn "DGX Spark: TEI не поддерживает arm64, переключение на vLLM-embed"
            EMBED_PROVIDER="vllm-embed"
        fi
        return 0
    fi

    local choice
    choice=$(wt_menu "Провайдер эмбеддингов" \
        "Выберите провайдер эмбеддингов:" \
        "1" "Как LLM (Ollama/vLLM -> TEI)" \
        "2" "TEI (Text Embeddings Inference)" \
        "3" "Внешний API" \
        "4" "Пропустить")

    choice="${choice:-1}"

    case "$choice" in
        1) case "$LLM_PROVIDER" in
               ollama)   EMBED_PROVIDER="ollama";;
               vllm)
                   if [[ "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then
                       EMBED_PROVIDER="vllm-embed"
                   else
                       EMBED_PROVIDER="tei"
                   fi;;
               external) EMBED_PROVIDER="external";;
               skip)     EMBED_PROVIDER="skip";;
               *)        EMBED_PROVIDER="ollama";;
           esac;;
        2) EMBED_PROVIDER="tei"
           if [[ "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then
               log_warn "DGX Spark: TEI не поддерживает arm64, переключение на vLLM-embed"
               EMBED_PROVIDER="vllm-embed"
           fi;;
        3) EMBED_PROVIDER="external";;
        4) EMBED_PROVIDER="skip";;
        *) EMBED_PROVIDER="ollama";;
    esac
}

_wizard_embedding_model() {
    # CPU-only models (no safetensors -> Candle/CUDA fails, ONNX fallback only)
    local -a cpu_only_models=("BAAI/bge-m3")

    _is_cpu_embed_model() {
        local m="${1:-}"
        local c
        for c in "${cpu_only_models[@]}"; do
            if [[ "$m" == "$c" ]]; then return 0; fi
        done
        return 1
    }

    # --- NON_INTERACTIVE: use env or default ---
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        if [[ -n "${EMBEDDING_MODEL:-}" && "$EMBEDDING_MODEL" != "bge-m3" ]]; then
            _is_cpu_embed_model "$EMBEDDING_MODEL" && TEI_EMBED_VERSION="cpu-1.9"
            return 0
        fi
        # Apply provider-aware default
        case "$EMBED_PROVIDER" in
            tei)        EMBEDDING_MODEL="deepvk/USER-bge-m3";;
            vllm-embed) VLLM_EMBED_MODEL="${VLLM_EMBED_MODEL:-deepvk/USER-bge-m3}"
                        EMBEDDING_MODEL="$VLLM_EMBED_MODEL";;
            ollama)     EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}";;
            *)          return 0;;
        esac
        return 0
    fi

    # --- vLLM-embed provider (DGX Spark): show model menu ---
    if [[ "$EMBED_PROVIDER" == "vllm-embed" ]]; then
        # DGX Spark: vLLM serves embeddings instead of TEI
        local choice
        choice=$(wt_menu "Модель эмбеддингов (vLLM)" \
            "DGX Spark: эмбеддинги через vLLM (TEI не поддерживает arm64):" \
            "1" "deepvk/USER-bge-m3     -- русский fine-tune, ~1 GB [*]" \
            "2" "BAAI/bge-m3            -- мультиязычная, ~1 GB" \
            "3" "Ввод вручную")
        choice="${choice:-1}"
        case "$choice" in
            1) VLLM_EMBED_MODEL="deepvk/USER-bge-m3";;
            2) VLLM_EMBED_MODEL="BAAI/bge-m3";;
            3) local custom
               custom=$(wt_input "Своя модель" "HuggingFace model ID:" "deepvk/USER-bge-m3")
               VLLM_EMBED_MODEL="${custom:-deepvk/USER-bge-m3}";;
            *) VLLM_EMBED_MODEL="deepvk/USER-bge-m3";;
        esac
        EMBEDDING_MODEL="$VLLM_EMBED_MODEL"
        return 0
    fi

    # --- TEI provider: show model menu ---
    if [[ "$EMBED_PROVIDER" == "tei" ]]; then
        local choice
        choice=$(wt_menu "Модель эмбеддингов (TEI)" \
            "Выберите модель эмбеддингов TEI:" \
            "1" "deepvk/USER-bge-m3           -- 359M, русский fine-tune [по умолчанию]" \
            "2" "intfloat/multilingual-e5-base -- 278M, мультиязычная" \
            "3" "intfloat/multilingual-e5-large -- 560M, лучшее качество" \
            "4" "intfloat/multilingual-e5-small -- 118M, быстрая" \
            "5" "BAAI/bge-m3                   -- 568M, CPU only" \
            "6" "Ввод вручную (HuggingFace ID)")

        choice="${choice:-1}"

        case "$choice" in
            1) EMBEDDING_MODEL="deepvk/USER-bge-m3";;
            2) EMBEDDING_MODEL="intfloat/multilingual-e5-base";;
            3) EMBEDDING_MODEL="intfloat/multilingual-e5-large";;
            4) EMBEDDING_MODEL="intfloat/multilingual-e5-small";;
            5) EMBEDDING_MODEL="BAAI/bge-m3";;
            6) local custom_embed
               custom_embed=$(wt_input "Своя модель TEI" "HuggingFace model ID:" "deepvk/USER-bge-m3")
               EMBEDDING_MODEL="${custom_embed:-deepvk/USER-bge-m3}"
               validate_model_name "$EMBEDDING_MODEL" || {
                   EMBEDDING_MODEL="deepvk/USER-bge-m3"
                   log_warn "Некорректное имя модели, используется deepvk/USER-bge-m3"
               };;
            *) EMBEDDING_MODEL="deepvk/USER-bge-m3";;
        esac

        # CPU-only models need ONNX backend
        if _is_cpu_embed_model "$EMBEDDING_MODEL"; then
            TEI_EMBED_VERSION="cpu-1.9"
            wt_info "TEI" "${EMBEDDING_MODEL} -- CPU only (ONNX fallback)"
            sleep 1
        fi
        return 0
    fi

    # --- Ollama provider: simple prompt (existing behavior) ---
    if [[ "$EMBED_PROVIDER" == "ollama" ]]; then
        local embed_model
        embed_model=$(wt_input "Модель эмбеддингов (Ollama)" "Модель эмбеддингов:" "bge-m3")
        EMBEDDING_MODEL="${embed_model:-bge-m3}"
        validate_model_name "$EMBEDDING_MODEL" || {
            EMBEDDING_MODEL="bge-m3"
            log_warn "Некорректное имя модели, используется значение по умолчанию"
        }
        return 0
    fi

    # --- external/skip: no model selection needed ---
}

_wizard_reranker_model() {
    # --- NON_INTERACTIVE: use env or default ---
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        if [[ "${ENABLE_RERANKER:-}" == "true" ]]; then
            RERANK_MODEL="${RERANK_MODEL:-BAAI/bge-reranker-base}"
            if [[ "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then
                RERANKER_PROVIDER="vllm-rerank"
                RERANKER_ON_GPU="true"
                TEI_RERANK_VERSION=""
                VLLM_RERANK_MODEL="${RERANK_MODEL}"
            else
                TEI_RERANK_VERSION="${TEI_RERANK_VERSION:-cpu-1.9.3}"
            fi
        fi
        return 0
    fi

    # --- Ask yes/no ---
    if wt_yesno "Реранкер" \
        "Включить реранкер?\nУлучшает качество RAG-поиска (переранжирование top-K результатов)." \
        --defaultno; then
        ENABLE_RERANKER="true"
    else
        ENABLE_RERANKER="false"
        return 0
    fi

    # --- CPU vs GPU ---
    local has_gpu="false"
    if [[ "${DETECTED_GPU:-none}" == "nvidia" ]]; then has_gpu="true"; fi

    if [[ "$has_gpu" == "true" ]]; then
        local hw_choice
        hw_choice=$(wt_menu "Реранкер — CPU или GPU" \
            "Где запускать реранкер?" \
            "gpu"  "GPU (CUDA) — быстрый, ~1 GB VRAM" \
            "cpu"  "CPU (ONNX) — медленнее, ~1-2 GB RAM, GPU не тратится")
        hw_choice="${hw_choice:-gpu}"

        if [[ "$hw_choice" == "gpu" ]]; then
            if [[ "${DETECTED_DGX_SPARK:-false}" == "true" ]]; then
                TEI_RERANK_VERSION=""
                RERANKER_ON_GPU="true"
                RERANKER_PROVIDER="vllm-rerank"
                log_info "DGX Spark → реранкер через vLLM (TEI не поддерживает arm64)"
            else
                TEI_RERANK_VERSION="cuda-1.9.3"
                RERANKER_ON_GPU="true"
                RERANKER_PROVIDER="tei"
            fi
        else
            TEI_RERANK_VERSION="cpu-1.9.3"
            RERANKER_ON_GPU="false"
        fi
    else
        TEI_RERANK_VERSION="cpu-1.9.3"
        RERANKER_ON_GPU="false"
    fi

    # --- Show model menu ---
    local device_label="CPU"
    if [[ "${RERANKER_ON_GPU:-false}" == "true" ]]; then device_label="GPU"; fi

    local choice
    choice=$(wt_menu "Модель реранкера (TEI, ${device_label})" \
        "Реранкер на ${device_label}. Выберите модель:" \
        "1" "BAAI/bge-reranker-v2-m3              -- мультиязычный, ~2.2 GB" \
        "2" "BAAI/bge-reranker-base               -- компактный, ~1.2 GB [*]" \
        "3" "cross-encoder/ms-marco-MiniLM-L-6-v2 -- быстрый, ~0.5 GB" \
        "4" "Ввод вручную (HuggingFace ID)")

    choice="${choice:-2}"

    case "$choice" in
        1) RERANK_MODEL="BAAI/bge-reranker-v2-m3";;
        2) RERANK_MODEL="BAAI/bge-reranker-base";;
        3) RERANK_MODEL="cross-encoder/ms-marco-MiniLM-L-6-v2";;
        4) local custom_rerank
           custom_rerank=$(wt_input "Своя модель реранкера" "HuggingFace model ID:" "BAAI/bge-reranker-base")
           RERANK_MODEL="${custom_rerank:-BAAI/bge-reranker-base}"
           validate_model_name "$RERANK_MODEL" || {
               RERANK_MODEL="BAAI/bge-reranker-base"
               log_warn "Некорректное имя модели, используется BAAI/bge-reranker-base"
           };;
        *) RERANK_MODEL="BAAI/bge-reranker-base";;
    esac

    # DGX Spark: sync VLLM_RERANK_MODEL with RERANK_MODEL
    if [[ "${RERANKER_PROVIDER:-tei}" == "vllm-rerank" ]]; then
        VLLM_RERANK_MODEL="$RERANK_MODEL"
    fi
}

_wizard_hf_token() {
    # Prompt for HF token if any TEI/vLLM service needs HuggingFace models
    if [[ "$LLM_PROVIDER" != "vllm" && "$EMBED_PROVIDER" != "tei" && "$EMBED_PROVIDER" != "vllm-embed" && "${ENABLE_RERANKER:-false}" != "true" ]]; then
        return 0
    fi
    if [[ -n "$HF_TOKEN" ]]; then
        return 0
    fi
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    local token
    token=$(wt_input "HuggingFace Token" "Токен HuggingFace (оставьте пустым для пропуска):" "")
    HF_TOKEN="$token"
}


_wizard_tls() {
    # LAN profile: TLS unnecessary (self-signed = browser warnings, LE needs public DNS)
    if [[ "${DEPLOY_PROFILE:-lan}" == "lan" ]]; then
        TLS_MODE="none"
        return 0
    fi
    # Already set via env
    if [[ "$TLS_MODE" != "none" ]]; then
        return 0
    fi
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    local choice
    choice=$(wt_menu "Настройка TLS (HTTPS)" \
        "Настройка TLS (HTTPS):" \
        "1" "Без TLS (по умолчанию)" \
        "2" "Самоподписанный сертификат" \
        "3" "Свой сертификат (указать пути)")

    choice="${choice:-1}"

    case "$choice" in
        2) TLS_MODE="self-signed";;
        3)
            TLS_MODE="custom"
            local cert_path key_path
            cert_path=$(wt_input "TLS сертификат" "Путь к сертификату (.pem):" "")
            TLS_CERT_PATH="$(validate_path "$cert_path" 2>/dev/null)" || {
                log_error "Некорректный путь к сертификату, TLS отключён"
                TLS_MODE="none"; TLS_CERT_PATH=""
            }
            key_path=$(wt_input "TLS ключ" "Путь к ключу (.pem):" "")
            TLS_KEY_PATH="$(validate_path "$key_path" 2>/dev/null)" || {
                log_error "Некорректный путь к ключу, TLS отключён"
                TLS_MODE="none"; TLS_KEY_PATH=""
            }
            ;;
        *) TLS_MODE="none";;
    esac
}

_wizard_monitoring() {
    # Respect env override in non-interactive
    if [[ "${NON_INTERACTIVE}" == "true" && "$MONITORING_MODE" != "none" ]]; then
        return 0
    fi
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    local choice
    choice=$(wt_menu "Мониторинг" \
        "Мониторинг:" \
        "1" "Отключён (по умолчанию)" \
        "2" "Локальный (Grafana + Portainer + Prometheus)" \
        "3" "Внешний (endpoint + токен)")

    choice="${choice:-1}"

    case "$choice" in
        2) MONITORING_MODE="local";;
        3)
            MONITORING_MODE="external"
            local endpoint token
            endpoint=$(wt_input "Мониторинг (внешний)" "Endpoint (URL):" "")
            MONITORING_ENDPOINT="$endpoint"
            validate_url "$MONITORING_ENDPOINT" || {
                log_error "Некорректный URL, мониторинг отключён"
                MONITORING_MODE="none"; MONITORING_ENDPOINT=""
            }
            token=$(wt_input "Мониторинг (внешний)" "Токен:" "")
            MONITORING_TOKEN="$token"
            ;;
        *) MONITORING_MODE="none";;
    esac

    # Ask whether to expose Grafana/Portainer to LAN
    if [[ "$MONITORING_MODE" == "local" ]]; then
        local expose
        expose=$(wt_menu "Доступ к мониторингу" \
            "Сделать Grafana и Portainer доступными по сети?" \
            "1" "Да — доступ по IP (LAN)" \
            "2" "Нет — только localhost (безопаснее)")
        expose="${expose:-2}"
        if [[ "$expose" == "1" ]]; then
            GRAFANA_BIND_ADDR="0.0.0.0"
            PORTAINER_BIND_ADDR="0.0.0.0"
        else
            GRAFANA_BIND_ADDR="127.0.0.1"
            PORTAINER_BIND_ADDR="127.0.0.1"
        fi
    fi
}

_wizard_alerts() {
    # Respect env override in non-interactive
    if [[ "${NON_INTERACTIVE}" == "true" && "$ALERT_MODE" != "none" ]]; then
        return 0
    fi
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    local choice
    choice=$(wt_menu "Уведомления о сбоях" \
        "Уведомления о сбоях:" \
        "1" "Отключены (по умолчанию)" \
        "2" "Webhook (URL)" \
        "3" "Telegram-бот")

    choice="${choice:-1}"

    case "$choice" in
        2)
            ALERT_MODE="webhook"
            local webhook_url
            webhook_url=$(wt_input "Webhook" "Webhook URL:" "")
            ALERT_WEBHOOK_URL="$webhook_url"
            validate_url "$ALERT_WEBHOOK_URL" || {
                log_error "Некорректный URL, уведомления отключены"
                ALERT_MODE="none"; ALERT_WEBHOOK_URL=""
            }
            ;;
        3)
            ALERT_MODE="telegram"
            local tg_token tg_chat
            tg_token=$(wt_input "Telegram-бот" "Токен Telegram-бота:" "")
            ALERT_TELEGRAM_TOKEN="$tg_token"
            tg_chat=$(wt_input "Telegram-бот" "Telegram Chat ID:" "")
            ALERT_TELEGRAM_CHAT_ID="$tg_chat"
            ;;
        *) ALERT_MODE="none";;
    esac
}

_wizard_security() {
    # LAN profile: UFW useless (Docker bypasses iptables), Fail2ban unnecessary (behind NAT)
    if [[ "${DEPLOY_PROFILE:-lan}" == "lan" ]]; then
        ENABLE_UFW="false"
        ENABLE_FAIL2BAN="false"
        return 0
    fi
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    local result
    result=$(wt_checklist "Безопасность" \
        "Выберите компоненты безопасности:" \
        "ufw"      "UFW файрвол"                    "OFF" \
        "fail2ban" "Fail2ban (защита от перебора SSH)" "OFF")

    local parsed
    parsed=$(wt_parse "$result")

    ENABLE_UFW="${ENABLE_UFW:-false}"
    ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-false}"

    local item
    for item in $parsed; do
        case "$item" in
            ufw)      ENABLE_UFW="true";;
            fail2ban) ENABLE_FAIL2BAN="true";;
        esac
    done
}

_wizard_tunnel() {
    if [[ "$DEPLOY_PROFILE" != "lan" ]]; then
        return 0
    fi
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    if wt_yesno "SSH-туннель" \
        "Обратный SSH-туннель (доступ к LAN через VPS)?\nВыберите Да, если хотите пробросить доступ через внешний сервер." \
        --defaultno; then
        ENABLE_TUNNEL="true"

        local vps_host vps_port remote_port
        vps_host=$(wt_input "SSH-туннель" "Хост VPS:" "")
        TUNNEL_VPS_HOST="$vps_host"
        validate_hostname "$TUNNEL_VPS_HOST" || { log_warn "Некорректный хост, туннель отключён"; ENABLE_TUNNEL="false"; return 0; }

        vps_port=$(wt_input "SSH-туннель" "SSH-порт VPS:" "22")
        TUNNEL_VPS_PORT="${vps_port:-22}"

        remote_port=$(wt_input "SSH-туннель" "Удалённый порт для веб:" "8080")
        TUNNEL_REMOTE_PORT="${remote_port:-8080}"
    fi
}

_wizard_backups() {
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    local choice
    choice=$(wt_menu "Настройка бэкапов" \
        "Настройка бэкапов:" \
        "1" "Локальные (/var/backups/agmind/)" \
        "2" "Удалённые (SCP/rsync)" \
        "3" "Оба варианта")

    choice="${choice:-1}"

    case "$choice" in
        1) BACKUP_TARGET="local";;
        2) BACKUP_TARGET="remote";;
        3) BACKUP_TARGET="both";;
    esac

    local sched_choice
    sched_choice=$(wt_menu "Расписание бэкапов" \
        "Расписание бэкапов:" \
        "1" "Ежедневно в 03:00 (по умолчанию)" \
        "2" "Каждые 12 часов (03:00 и 15:00)" \
        "3" "Своё cron-выражение")

    sched_choice="${sched_choice:-1}"

    case "$sched_choice" in
        2) BACKUP_SCHEDULE="0 3,15 * * *";;
        3)
            local cron_expr
            cron_expr=$(wt_input "Cron-расписание" "Cron-выражение:" "0 3 * * *")
            BACKUP_SCHEDULE="${cron_expr:-0 3 * * *}"
            validate_cron "$BACKUP_SCHEDULE" || {
                log_warn "Некорректное cron-выражение, используется значение по умолчанию"
                BACKUP_SCHEDULE="0 3 * * *"
            }
            ;;
        *) BACKUP_SCHEDULE="0 3 * * *";;
    esac

    # Remote backup details
    if [[ "$BACKUP_TARGET" != "local" ]]; then
        local r_host r_port r_user r_key
        r_host=$(wt_input "Удалённый бэкап" "SSH-хост для бэкапов:" "")
        REMOTE_BACKUP_HOST="$r_host"
        validate_hostname "$REMOTE_BACKUP_HOST" || {
            log_error "Некорректный хост, переключение на локальные бэкапы"
            BACKUP_TARGET="local"
            return 0
        }
        r_port=$(wt_input "Удалённый бэкап" "SSH-порт:" "22")
        REMOTE_BACKUP_PORT="${r_port:-22}"
        validate_port "$REMOTE_BACKUP_PORT" || { REMOTE_BACKUP_PORT="22"; log_warn "Используется порт по умолчанию 22"; }
        r_user=$(wt_input "Удалённый бэкап" "SSH-пользователь:" "")
        REMOTE_BACKUP_USER="$r_user"
        r_key=$(wt_input "Удалённый бэкап" "Путь к SSH-ключу (пусто -- сгенерировать):" "")
        REMOTE_BACKUP_KEY="$r_key"
    fi
}

# Individual optional service functions kept for backward compatibility and NI mode
_wizard_litellm() {
    # LAN — локальные модели, прокси не нужен; VPS — multi-user, прокси полезен
    local default_litellm="false"
    if [[ "${DEPLOY_PROFILE:-lan}" == "vps" ]]; then default_litellm="true"; fi

    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_LITELLM="${ENABLE_LITELLM:-$default_litellm}"
        return
    fi
    # Interactive handled by _wizard_optional_services
}

_wizard_searxng() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_SEARXNG="${ENABLE_SEARXNG:-false}"
        return
    fi
    # Interactive handled by _wizard_optional_services
}

_wizard_notebook() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_NOTEBOOK="${ENABLE_NOTEBOOK:-false}"
        return
    fi
    # Interactive handled by _wizard_optional_services
}

_wizard_dbgpt() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_DBGPT="${ENABLE_DBGPT:-false}"
        return
    fi
    # Interactive handled by _wizard_optional_services
}

_wizard_crawl4ai() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_CRAWL4AI="${ENABLE_CRAWL4AI:-false}"
        return
    fi
    # Interactive handled by _wizard_optional_services
}

_wizard_optional_services() {
    # Handle NI mode via individual functions
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        _wizard_litellm
        _wizard_searxng
        _wizard_notebook
        _wizard_dbgpt
        _wizard_crawl4ai
        return 0
    fi

    # Determine LiteLLM default state
    local litellm_default="OFF"
    if [[ "${DEPLOY_PROFILE:-lan}" == "vps" ]]; then litellm_default="ON"; fi

    local result
    result=$(wt_checklist "Дополнительные сервисы" \
        "Выберите дополнительные сервисы для установки:" \
        "litellm"  "LiteLLM  -- AI Gateway, прокси для LLM (~1 GB RAM)"            "$litellm_default" \
        "searxng"  "SearXNG  -- мета-поисковик для агентов (~256 MB RAM)"           "OFF" \
        "notebook" "Open Notebook -- исследовательский ассистент (~512 MB RAM)"     "OFF" \
        "dbgpt"    "DB-GPT   -- AI-агент для анализа данных и SQL (~1 GB RAM)"      "OFF" \
        "crawl4ai" "Crawl4AI -- веб-краулер с REST API (~2 GB RAM)"                 "OFF")

    local parsed
    parsed=$(wt_parse "$result")

    # Default everything to false, then enable selected
    ENABLE_LITELLM="false"
    ENABLE_SEARXNG="false"
    ENABLE_NOTEBOOK="false"
    ENABLE_DBGPT="false"
    ENABLE_CRAWL4AI="false"

    local item
    for item in $parsed; do
        case "$item" in
            litellm)  ENABLE_LITELLM="true";;
            searxng)  ENABLE_SEARXNG="true";;
            notebook) ENABLE_NOTEBOOK="true";;
            dbgpt)    ENABLE_DBGPT="true";;
            crawl4ai) ENABLE_CRAWL4AI="true";;
        esac
    done
}

_wizard_dify_premium() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_DIFY_PREMIUM="${ENABLE_DIFY_PREMIUM:-true}"
        return
    fi

    if wt_yesno "Dify Premium Features" \
        "Разблокировать Dify Premium?\n\nВключает: замену лого, балансировку моделей, безлимит участников/приложений/документов, приоритетную обработку.\nНе требует лицензию, не включает биллинг." ; then
        ENABLE_DIFY_PREMIUM="true"
    else
        ENABLE_DIFY_PREMIUM="false"
    fi
}

_wizard_summary() {
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    local summary=""
    summary+="Профиль:      ${DEPLOY_PROFILE}\n"
    if [[ -n "$DOMAIN" ]]; then summary+="Домен:        ${DOMAIN}\n"; fi
    summary+="Вектор. БД:   ${VECTOR_STORE}\n"
    if [[ "$ENABLE_DOCLING" == "true" ]]; then summary+="ETL:          Docling (${DOCLING_IMAGE##*/})\n"; fi
    if [[ "${LLM_PROVIDER:-}" == "vllm" && -n "${VLLM_MAX_MODEL_LEN:-}" ]]; then
        local ctx_k=$(( VLLM_MAX_MODEL_LEN / 1024 ))
        summary+="LLM:          ${LLM_PROVIDER} (${VLLM_MODEL}) ctx=${ctx_k}K\n"
    else
        summary+="LLM:          ${LLM_PROVIDER} ${LLM_MODEL}${VLLM_MODEL:+ (${VLLM_MODEL})}\n"
    fi
    summary+="Эмбеддинги:   ${EMBED_PROVIDER} ${EMBEDDING_MODEL}\n"
    if [[ "${ENABLE_RERANKER:-}" == "true" ]]; then
        local _rr_dev="CPU"
        if [[ "${RERANKER_ON_GPU:-false}" == "true" ]]; then _rr_dev="GPU"; fi
        summary+="Реранкер:     ${RERANK_MODEL} (${_rr_dev})\n"
    fi
    if [[ "$TLS_MODE" != "none" ]]; then summary+="TLS:          ${TLS_MODE}\n"; fi
    if [[ "$MONITORING_MODE" != "none" ]]; then summary+="Мониторинг:   ${MONITORING_MODE}\n"; fi
    if [[ "$ALERT_MODE" != "none" ]]; then summary+="Уведомления:  ${ALERT_MODE}\n"; fi
    if [[ "$ENABLE_UFW" == "true" ]]; then summary+="UFW:          включён\n"; fi
    if [[ "$ENABLE_FAIL2BAN" == "true" ]]; then summary+="Fail2ban:     SSH jail\n"; fi
    if [[ "$ENABLE_AUTHELIA" == "true" ]]; then summary+="Authelia:     2FA включена\n"; fi
    if [[ "${ENABLE_LITELLM:-true}" == "true" ]]; then summary+="LiteLLM:      включён (AI Gateway)\n"; fi
    if [[ "${ENABLE_SEARXNG:-false}" == "true" ]]; then summary+="SearXNG:      включён (порт 8888)\n"; fi
    if [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]]; then summary+="Open Notebook: включён (порт 8502)\n"; fi
    if [[ "${ENABLE_DBGPT:-false}" == "true" ]]; then summary+="DB-GPT:       включён (порт 5670)\n"; fi
    if [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]]; then summary+="Crawl4AI:     включён (порт 11235)\n"; fi
    if [[ "${ENABLE_DIFY_PREMIUM:-true}" == "true" ]]; then summary+="Dify Premium: включён (патч после запуска)\n"; fi
    if [[ "$ENABLE_TUNNEL" == "true" ]]; then summary+="Туннель:      ${TUNNEL_VPS_HOST}:${TUNNEL_REMOTE_PORT}\n"; fi
    summary+="Бэкапы:       ${BACKUP_TARGET} (${BACKUP_SCHEDULE})\n"

    # VRAM plan (only for vLLM — Ollama manages VRAM internally)
    if [[ "${LLM_PROVIDER:-}" == "vllm" ]]; then
        summary+="\n--- GPU память ---\n"
        local vllm_weights vllm_total vllm_ctx_label
        vllm_weights=$(_get_vllm_weights_gb "${VLLM_MODEL:-}")
        vllm_total=$(_get_vllm_vram_req "${VLLM_MODEL:-}")
        local ctx_len="${VLLM_MAX_MODEL_LEN:-32768}"
        # Human-readable context label
        if [[ "$ctx_len" -ge 1024 ]]; then
            vllm_ctx_label="$((ctx_len / 1024))K"
        else
            vllm_ctx_label="${ctx_len}"
        fi
        if [[ "$vllm_total" == "0" ]]; then vllm_total="?"; fi
        if [[ "$vllm_total" != "?" && "$vllm_weights" -gt 0 ]]; then
            local kv_est=$(( vllm_total - vllm_weights ))
            summary+="vLLM:         ~${vllm_total} GB   (веса ${vllm_weights} + KV ~${kv_est} @ ${vllm_ctx_label})   ${VLLM_MODEL:-unknown}\n"
        else
            summary+="vLLM:         ${vllm_total} GB   (${VLLM_MODEL:-unknown})\n"
        fi

        local embed_vram=0
        if [[ "${EMBED_PROVIDER:-}" == "vllm-embed" ]]; then
            embed_vram=2
            summary+="vLLM-embed:   ${embed_vram} GB   (${VLLM_EMBED_MODEL:-${EMBEDDING_MODEL:-unknown}})\n"
        elif [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then
            if [[ "${TEI_EMBED_VERSION:-cuda}" == cpu-* ]]; then
                summary+="TEI-embed:    CPU (8 GB RAM)   (${EMBEDDING_MODEL:-unknown})\n"
            else
                embed_vram=2
                summary+="TEI-embed:    ${embed_vram} GB   (${EMBEDDING_MODEL:-unknown})\n"
            fi
        fi

        local rerank_vram=0
        if [[ "${ENABLE_RERANKER:-}" == "true" ]]; then
            if [[ "${RERANKER_PROVIDER:-tei}" == "vllm-rerank" ]]; then
                rerank_vram=1
                summary+="vLLM-rerank:  ${rerank_vram} GB GPU   (${VLLM_RERANK_MODEL:-${RERANK_MODEL:-unknown}})\n"
            elif [[ "${RERANKER_ON_GPU:-false}" == "true" ]]; then
                rerank_vram=1
                summary+="TEI-rerank:   ${rerank_vram} GB GPU   (${RERANK_MODEL:-unknown})\n"
            else
                summary+="TEI-rerank:   CPU (~2 GB RAM)   (${RERANK_MODEL:-unknown})\n"
            fi
        fi

        local docling_vram=0
        if [[ "${ENABLE_DOCLING:-false}" == "true" && "${NVIDIA_VISIBLE_DEVICES:-}" == "all" ]]; then
            docling_vram=3
            summary+="Docling:      ~${docling_vram} GB GPU   (OCR + layout)\n"
        fi

        summary+="---------------------\n"

        if [[ "$vllm_total" == "?" ]]; then
            summary+="Итого:        ? GB (неизвестная модель)\n"
        else
            local total_vram=$(( vllm_total + embed_vram + rerank_vram + docling_vram ))
            local gpu_vram_mb="${DETECTED_GPU_VRAM:-0}"
            if [[ "$gpu_vram_mb" -gt 0 ]] 2>/dev/null; then
                local gpu_vram_gb=$(( gpu_vram_mb / 1024 ))
                local mem_type="VRAM"
                if [[ "${DETECTED_GPU_UNIFIED_MEMORY:-false}" == "true" ]]; then mem_type="unified memory"; fi
                summary+="Итого:        ~${total_vram} GB / ${gpu_vram_gb} GB ${mem_type} доступно\n"
                if [[ "$total_vram" -gt "$gpu_vram_gb" ]]; then
                    summary+="!! ${mem_type} бюджет превышен! Возможен OOM.\n"
                fi
            else
                summary+="Итого:        ~${total_vram} GB\n"
                summary+="GPU память не определена -- проверьте вручную\n"
            fi
        fi
    fi

    wt_msg "Сводка установки" "$(echo -e "$summary")"
}

_wizard_confirm() {
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi

    if ! wt_yesno "Подтверждение" "Начать установку?"; then
        echo "Отменено."
        exit 0
    fi
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

run_wizard() {
    # Load version defaults (DOCLING_IMAGE_CPU, DOCLING_IMAGE_CUDA, etc.)
    local _versions_file="${INSTALLER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/templates/versions.env"
    if [[ -f "$_versions_file" ]]; then
        set +u; source "$_versions_file"; set -u
    fi

    _init_wizard_defaults

    _wizard_profile
    _wizard_security_defaults
    _wizard_admin_ui
    _wizard_domain
    _wizard_llm_provider
    _wizard_llm_model
    _wizard_embed_provider
    _wizard_embedding_model
    _wizard_reranker_model
    _wizard_vector_store
    _wizard_etl
    _wizard_hf_token
    _wizard_tls
    _wizard_monitoring
    _wizard_alerts
    _wizard_security
    _wizard_tunnel
    _wizard_backups
    _wizard_optional_services
    _wizard_dify_premium
    _wizard_summary
    _wizard_confirm

    # Export all choices
    export DEPLOY_PROFILE DOMAIN CERTBOT_EMAIL VECTOR_STORE ENABLE_DOCLING
    export DOCLING_IMAGE OCR_LANG NVIDIA_VISIBLE_DEVICES
    export LLM_PROVIDER LLM_MODEL VLLM_MODEL VLLM_CUDA_SUFFIX VLLM_MAX_MODEL_LEN EMBED_PROVIDER EMBEDDING_MODEL TEI_EMBED_VERSION
    export VLLM_IMAGE VLLM_CMD_PREFIX VLLM_EXTRA_ARGS VLLM_EMBED_MODEL VLLM_RERANK_MODEL RERANKER_PROVIDER
    export ENABLE_RERANKER RERANK_MODEL RERANKER_ON_GPU TEI_RERANK_VERSION
    export HF_TOKEN TLS_MODE TLS_CERT_PATH TLS_KEY_PATH
    export MONITORING_MODE MONITORING_ENDPOINT MONITORING_TOKEN GRAFANA_BIND_ADDR PORTAINER_BIND_ADDR
    export ALERT_MODE ALERT_WEBHOOK_URL ALERT_TELEGRAM_TOKEN ALERT_TELEGRAM_CHAT_ID
    export ENABLE_UFW ENABLE_FAIL2BAN ENABLE_AUTHELIA
    export ENABLE_TUNNEL TUNNEL_VPS_HOST TUNNEL_VPS_PORT TUNNEL_REMOTE_PORT
    export BACKUP_TARGET BACKUP_SCHEDULE
    export REMOTE_BACKUP_HOST REMOTE_BACKUP_PORT REMOTE_BACKUP_USER REMOTE_BACKUP_KEY REMOTE_BACKUP_PATH
    export ADMIN_UI_OPEN
    export ENABLE_LITELLM ENABLE_SEARXNG ENABLE_NOTEBOOK ENABLE_DBGPT ENABLE_CRAWL4AI
    export ENABLE_DIFY_PREMIUM
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    # shellcheck source=detect.sh
    source "${SCRIPT_DIR}/detect.sh"
    # shellcheck source=tui.sh
    source "${SCRIPT_DIR}/tui.sh"
    run_wizard
fi
