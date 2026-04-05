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
    VLLM_CUDA_SUFFIX="${VLLM_CUDA_SUFFIX:-}"
    VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-}"
    EMBED_PROVIDER="${EMBED_PROVIDER:-}"
    EMBEDDING_MODEL="${EMBEDDING_MODEL:-}"
    TEI_EMBED_VERSION="${TEI_EMBED_VERSION:-}"
    ENABLE_RERANKER="${ENABLE_RERANKER:-false}"
    RERANK_MODEL="${RERANK_MODEL:-}"
    HF_TOKEN="${HF_TOKEN:-}"
    TLS_MODE="${TLS_MODE:-none}"
    TLS_CERT_PATH="${TLS_CERT_PATH:-}"
    TLS_KEY_PATH="${TLS_KEY_PATH:-}"
    MONITORING_MODE="${MONITORING_MODE:-none}"
    MONITORING_ENDPOINT="${MONITORING_ENDPOINT:-}"
    MONITORING_TOKEN="${MONITORING_TOKEN:-}"
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
    echo "Выберите профиль развёртывания:"
    echo "  1) LAN     — локальная / офисная сеть (по умолчанию)"
    echo "  2) VDS/VPS — публичный сервер (переключение на ветку agmind-caddy)"
    echo ""

    if [[ "${NON_INTERACTIVE}" == "true" && -n "${DEPLOY_PROFILE}" ]]; then
        return 0
    fi

    _ask_choice "Профиль [1-2, Enter=1]: " 1 2 1
    case "$REPLY" in
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
    echo "Portainer и Grafana привязаны к localhost (127.0.0.1) по умолчанию."
    _ask "Открыть доступ из LAN? [no/yes] (по умолчанию: no):" "no"
    if [[ "$REPLY" == "yes" ]]; then
        ADMIN_UI_OPEN=true
    else
        ADMIN_UI_OPEN=false
    fi
    echo ""
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

    echo "Выберите векторное хранилище:"
    echo "  1) Weaviate  — стабильный, проверенный (по умолчанию)"
    echo "  2) Qdrant    — быстрый, REST/gRPC API"
    echo ""

    _ask_choice "Выбор [1-2, Enter=1]: " 1 2 1
    case "$REPLY" in
        2) VECTOR_STORE="qdrant";;
        *) VECTOR_STORE="weaviate";;
    esac
    echo ""
}

_wizard_etl() {
    # Detect nvidia container runtime availability
    local has_nvidia_runtime="false"
    if [[ "${DETECTED_GPU:-none}" == "nvidia" ]]; then
        if docker info 2>/dev/null | grep -qi "nvidia"; then
            has_nvidia_runtime="true"
        fi
    fi

    echo "Расширенная обработка документов (Docling)?"
    echo "  1) Нет — стандартный Dify ETL (по умолчанию)"
    echo "  2) Да — Docling CPU"
    if [[ "$has_nvidia_runtime" == "true" ]]; then
        echo "  3) Да — Docling GPU (CUDA)"
    fi
    echo ""

    local max_choice=2
    [[ "$has_nvidia_runtime" == "true" ]] && max_choice=3

    _ask_choice "Выбор [1-${max_choice}, Enter=1]: " 1 "$max_choice" 1
    case "$REPLY" in
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
    echo ""
}

_wizard_llm_provider() {
    local default_provider="vllm"
    local default_idx=2
    local gpu_note=""
    if [[ "${DETECTED_GPU:-none}" != "nvidia" ]]; then
        default_provider="ollama"
        default_idx=1
        gpu_note="  (NVIDIA GPU не обнаружен — по умолчанию: Ollama)"
    fi

    # Respect env override only in non-interactive mode
    if [[ "${NON_INTERACTIVE}" == "true" && -n "$LLM_PROVIDER" ]]; then
        _apply_blackwell_cu130
        return 0
    fi

    echo "Выберите LLM-провайдер:${gpu_note}"
    echo "  1) Ollama"
    echo "  2) vLLM"
    echo "  3) Внешний API"
    echo "  4) Пропустить"
    echo ""

    _ask_choice "Выбор [1-4, Enter=${default_idx}]: " 1 4 "$default_idx"
    case "$REPLY" in
        1) LLM_PROVIDER="ollama";;
        2) LLM_PROVIDER="vllm";;
        3) LLM_PROVIDER="external";;
        4) LLM_PROVIDER="skip";;
        *) LLM_PROVIDER="$default_provider";;
    esac

    # Blackwell GPU (sm_120+): auto-apply CUDA 13.0 build for vLLM
    if [[ "$LLM_PROVIDER" == "vllm" ]] && _is_blackwell_gpu; then
        VLLM_CUDA_SUFFIX="-cu130"
        log_info "Blackwell GPU (compute ${DETECTED_GPU_COMPUTE}) → vLLM с CUDA 13.0 (-cu130)"
    fi
    echo ""
}

# Check if GPU is Blackwell architecture (compute capability >= 12.0)
_is_blackwell_gpu() {
    local cc="${DETECTED_GPU_COMPUTE:-}"
    [[ -z "$cc" ]] && return 1
    local major="${cc%%.*}"
    [[ "$major" -ge 12 ]] 2>/dev/null
}

# Auto-apply -cu130 suffix for Blackwell in non-interactive mode
_apply_blackwell_cu130() {
    if [[ "$LLM_PROVIDER" == "vllm" ]] && _is_blackwell_gpu; then
        VLLM_CUDA_SUFFIX="-cu130"
        log_info "Blackwell GPU (compute ${DETECTED_GPU_COMPUTE}) — автоматически выбран vLLM с CUDA 13.0"
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

    echo "Выберите LLM-модель:"
    echo ""
    echo " -- 4-8B [быстрые, 8GB+ RAM, 6GB+ VRAM] --"
    echo "  1) gemma3:4b$([ "$rec_idx" -eq 1 ] && echo '  [рекомендуется]')"
    echo "  2) qwen2.5:7b$([ "$rec_idx" -eq 2 ] && echo '  [рекомендуется]')"
    echo "  3) qwen3:8b"
    echo "  4) llama3.1:8b"
    echo "  5) mistral:7b"
    echo ""
    echo " -- 12-14B [баланс, 16GB+ RAM, 10GB+ VRAM] --"
    echo "  6) qwen2.5:14b$([ "$rec_idx" -eq 6 ] && echo '  [рекомендуется]')"
    echo "  7) phi-4:14b"
    echo "  8) mistral-nemo:12b"
    echo "  9) gemma3:12b"
    echo ""
    echo " -- 27-32B [качество, 32GB+ RAM, 16GB+ VRAM] --"
    echo "  10) qwen2.5:32b$([ "$rec_idx" -eq 10 ] && echo '  [рекомендуется]')"
    echo "  11) gemma3:27b"
    echo "  12) command-r:35b"
    echo ""
    echo " -- 60B+ [макс. качество, 64GB+ RAM, 24GB+ VRAM] --"
    echo "  13) qwen2.5:72b-instruct-q4_K_M$([ "$rec_idx" -eq 13 ] && echo '  [рекомендуется]')"
    echo "  14) llama3.1:70b-instruct-q4_K_M"
    echo "  15) qwen3:32b"
    echo ""
    echo " -- MoE (активных параметров << общих) --"
    echo "  16) qwen3.5:35b-a3b  (35B total, 3B active)"
    echo ""
    echo " -- Своя модель --"
    echo "  17) Ввести вручную (имя из реестра Ollama)"
    echo ""

    _ask_choice "Модель [1-17, Enter=6]: " 1 17 6
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
    if [[ "$REPLY" -ge 1 && "$REPLY" -le 16 ]]; then
        LLM_MODEL="${ollama_models[$REPLY]}"
    elif [[ "$REPLY" -eq 17 ]]; then
        _ask "Имя модели:" "qwen2.5:14b"
        LLM_MODEL="$REPLY"
        validate_model_name "$LLM_MODEL" || { LLM_MODEL="qwen2.5:14b"; log_warn "Некорректное имя модели, используется значение по умолчанию"; }
    fi
    echo ""
}

# Dynamic VRAM offset: GPU reservation for TEI embedding service.
# Returns offset in GB based on EMBED_PROVIDER and TEI_EMBED_VERSION.
# CPU TEI (ONNX) and reranker consume no GPU VRAM.
_get_vram_offset() {
    local offset=0
    # TEI embedding on CUDA reserves ~2 GB GPU VRAM
    # CPU-only models (TEI_EMBED_VERSION=cpu-*) use no GPU VRAM
    if [[ "${EMBED_PROVIDER:-tei}" == "tei" && "${TEI_EMBED_VERSION:-cuda}" != cpu-* ]]; then
        offset=$(( offset + 2 ))
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
        "Qwen/Qwen3.5-35B-A3B")                            echo "6"   ;;
        *)                                                  echo "0"   ;;
    esac
}

# Returns KV cache size in GB per 1K tokens for a model.
# Formula: 2 × layers × kv_heads × head_dim × dtype_bytes / 1024^3 × 1024 tokens
# Outputs "0" for unknown models.
_get_vllm_kv_per_1k() {
    local model="${1:-}"
    # KV cache GB per 1K tokens (fp16=2B, rounded up)
    # 7B  (32L, 8KV, 128d):  2×32×8×128×2 × 1024 / 1073741824 ≈ 0.125
    # 8B  (32L, 8KV, 128d):  same ≈ 0.125
    # 14B (40L, 8KV, 128d):  2×40×8×128×2 × 1024 / 1073741824 ≈ 0.156
    # 27B (28L, 4KV, 128d):  2×28×4×128×2 × 1024 / 1073741824 ≈ 0.028 (GQA, few KV heads)
    # 32B (64L, 8KV, 128d):  2×64×8×128×2 × 1024 / 1073741824 ≈ 0.250
    # 70B (80L, 8KV, 128d):  2×80×8×128×2 × 1024 / 1073741824 ≈ 0.313
    # MoE models share KV across experts — same as base layer count
    case "$model" in
        *7B*|*8B*)       echo "125" ;;   # 0.125 GB/1K tokens (×1000 for int math)
        *14B*|*phi-4*)   echo "156" ;;   # 0.156
        *27B*|*Qwen3.5-27B*)  echo "80"  ;;   # 0.08 (GQA, 4 KV heads)
        *32B*)           echo "250" ;;   # 0.250
        *70B*)           echo "313" ;;   # 0.313
        *35B-A3B*)       echo "80"  ;;   # MoE, similar to 27B active
        *30B-A3B*)       echo "60"  ;;   # small active params
        *Coder-Next*)    echo "156" ;;   # 14B active ≈ 14B KV
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
    # KV cache GB = kv_per_1k/1000 × (ctx/1024) + ~1 GB CUDA overhead
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
    local -a weights_gb=(0 4 5 8 8 15 18 14 16 14 16 28 28 28 64 140 12 4 6)
    # KV cache GB per 1K tokens ×1000 (for int math)
    local -a kv_per_1k=(0 125 125 156 156 80 250 125 125 125 125 156 156 156 250 313 156 60 80)
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
        [[ "$effective_vram" -lt 0 ]] && effective_vram=0
    fi

    # Find largest fitting model for [recommended] tag.
    # Check dense models first (14→1), then MoE (16→18) — so dense bf16 > AWQ > MoE.
    local rec_idx=0
    if [[ "$effective_vram" -gt 0 ]]; then
        local i
        for i in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 16 18 17; do
            if [[ "${vram_total[$i]}" -le "$effective_vram" ]]; then
                rec_idx="$i"
                break
            fi
        done
    fi

    local mem_label="VRAM"
    [[ "${DETECTED_GPU_UNIFIED_MEMORY:-false}" == "true" ]] && mem_label="GPU mem"

    # Helper: print model line
    _vllm_line() {
        local idx="$1" num="$2" label="$3" suffix="${4:-}"
        local tag=""
        [[ "$idx" -eq "$rec_idx" ]] && tag="  ${GREEN}[рекомендуется]${NC}"
        echo -e "  ${num}) ${label}  [~${vram_total[$idx]} GB: веса ${weights_gb[$idx]}+KV ~$((vram_total[$idx]-weights_gb[$idx]))]${tag}${suffix}"
    }

    echo "Выберите модель vLLM:"
    echo -e "  ${CYAN}(оценка памяти: веса + KV-кэш при 32K контексте)${NC}"
    echo ""
    if [[ "$vram_gb" -eq 0 ]]; then
        echo -e "  ${YELLOW}GPU память не определена — метка [рекомендуется] недоступна${NC}"
        echo ""
    fi
    echo " -- AWQ квантизация (компактный размер) --"
    _vllm_line 1  " 1" "Qwen/Qwen2.5-7B-Instruct-AWQ"
    _vllm_line 2  " 2" "Qwen/Qwen3-8B-AWQ"
    _vllm_line 3  " 3" "Qwen/Qwen2.5-14B-Instruct-AWQ"
    _vllm_line 4  " 4" "Qwen/Qwen3-14B-AWQ"
    _vllm_line 5  " 5" "QuantTrio/Qwen3.5-27B-AWQ"
    _vllm_line 6  " 6" "Qwen/Qwen2.5-32B-Instruct-AWQ"
    echo ""
    echo " -- 7-8B bf16 (полная точность) --"
    _vllm_line 7  " 7" "Qwen/Qwen2.5-7B-Instruct"
    _vllm_line 8  " 8" "Qwen/Qwen3-8B"
    _vllm_line 9  " 9" "mistralai/Mistral-7B-Instruct-v0.3"
    _vllm_line 10 "10" "meta-llama/Llama-3.1-8B-Instruct" "  (HF_TOKEN)"
    echo ""
    echo " -- 14B bf16 --"
    _vllm_line 11 "11" "Qwen/Qwen2.5-14B-Instruct"
    _vllm_line 12 "12" "Qwen/Qwen3-14B"
    _vllm_line 13 "13" "microsoft/phi-4"
    echo ""
    echo " -- 32B+ bf16 --"
    _vllm_line 14 "14" "Qwen/Qwen2.5-32B-Instruct"
    _vllm_line 15 "15" "meta-llama/Llama-3.3-70B-Instruct" "  (HF_TOKEN)"
    echo ""
    echo " -- MoE (активных параметров << общих) --"
    _vllm_line 16 "16" "bullpoint/Qwen3-Coder-Next-AWQ-4bit" "  80B total, 14B active"
    _vllm_line 17 "17" "stelterlab/NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ" "  30B total, 3B active"
    _vllm_line 18 "18" "Qwen/Qwen3.5-35B-A3B" "  35B total, 3B active"
    echo ""
    echo " -- Своя модель --"
    echo " 19) Ввести HuggingFace репозиторий (org/model-name)"
    echo ""

    _ask_choice "Модель [1-19, Enter=5]: " 1 19 5
    local model_choice="$REPLY"

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
        _ask "HuggingFace репозиторий (org/model):" "QuantTrio/Qwen3.5-27B-AWQ"
        VLLM_MODEL="${REPLY:-QuantTrio/Qwen3.5-27B-AWQ}"
    fi

    # --- Context length selection ---
    echo ""
    echo "Максимальный контекст (max-model-len):"
    echo ""

    # Calculate VRAM for each context option
    local -a ctx_options=(4096 8192 16384 32768 65536 131072)
    local -a ctx_labels=("4K" "8K" "16K" "32K" "64K" "128K")
    local model_w=0 model_kv=0
    if [[ "$model_choice" -ge 1 && "$model_choice" -le 18 ]]; then
        model_w=${weights_gb[$model_choice]}
        model_kv=${kv_per_1k[$model_choice]}
    fi

    local ci default_ctx_idx=4  # default = 32K (index 4, 1-based)
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
                fit_tag="  ${GREEN}[OK]${NC}"
            else
                fit_tag="  ${RED}[не влезет]${NC}"
            fi
        fi
        echo -e "  ${num}) ${ctx_labels[$ci]}  (~${total_est} GB: веса ${model_w}+KV ~$((total_est-model_w)))${fit_tag}"
    done
    echo ""

    _ask_choice "Контекст [1-6, Enter=4 (32K)]: " 1 6 4
    local ctx_choice="$REPLY"
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
        [[ "$effective_vram_check" -lt 0 ]] && effective_vram_check=0
        if [[ "$vram_gb" -gt 0 && "$total_with_ctx" -gt "$effective_vram_check" ]]; then
            echo ""
            echo -e "  ${YELLOW}Модель + KV-кэш (${ctx_labels[$((ctx_choice-1))]}) ≈ ${total_with_ctx} GB, доступно ${effective_vram_check} GB ${mem_label}. Возможен OOM.${NC}"
            if [[ "${NON_INTERACTIVE}" != "true" ]]; then
                read -rp "  Продолжить? (y/N): " confirm
                if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
                    unset -f _vllm_line
                    _wizard_vllm_model
                    return
                fi
            fi
        fi

        echo ""
        echo -e "  ${CYAN}Итого: ${VLLM_MODEL} @ ${ctx_labels[$((ctx_choice-1))]} ≈ ${total_with_ctx} GB (веса ${model_w} + KV ~$((total_with_ctx - model_w)))${NC}"
    fi
    echo ""

    # Clean up nested function
    unset -f _vllm_line
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
        # Interactive path
        case "$LLM_PROVIDER" in
            ollama)   _wizard_ollama_model;;
            vllm)     _wizard_vllm_model;;
            # external/skip: no model selection needed
        esac
    fi

    # Apply non-interactive defaults if still empty
    if [[ "$LLM_PROVIDER" == "ollama" && -z "$LLM_MODEL" ]]; then
        LLM_MODEL="${RECOMMENDED_MODEL:-qwen2.5:14b}"
        validate_model_name "$LLM_MODEL" || LLM_MODEL="qwen2.5:14b"
    fi
    if [[ "$LLM_PROVIDER" == "vllm" && -z "$VLLM_MODEL" ]]; then
        VLLM_MODEL="QuantTrio/Qwen3.5-27B-AWQ"
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
            [[ "$ni_effective_vram" -lt 0 ]] && ni_effective_vram=0
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
        return 0
    fi

    echo "Выберите провайдер эмбеддингов:"
    echo "  1) Как LLM"
    echo "  2) TEI (Text Embeddings Inference)"
    echo "  3) Внешний API"
    echo "  4) Пропустить"
    echo ""

    _ask_choice "Выбор [1-4, Enter=1]: " 1 4 1
    case "$REPLY" in
        1) case "$LLM_PROVIDER" in
               ollama)   EMBED_PROVIDER="ollama";;
               vllm)     EMBED_PROVIDER="tei";;
               external) EMBED_PROVIDER="external";;
               skip)     EMBED_PROVIDER="skip";;
               *)        EMBED_PROVIDER="ollama";;
           esac;;
        2) EMBED_PROVIDER="tei";;
        3) EMBED_PROVIDER="external";;
        4) EMBED_PROVIDER="skip";;
        *) EMBED_PROVIDER="ollama";;
    esac
    echo ""
}

_wizard_embedding_model() {
    # CPU-only models (no safetensors → Candle/CUDA fails, ONNX fallback only)
    local -a cpu_only_models=("BAAI/bge-m3")

    _is_cpu_embed_model() {
        local m="${1:-}"
        local c
        for c in "${cpu_only_models[@]}"; do
            [[ "$m" == "$c" ]] && return 0
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
            tei)    EMBEDDING_MODEL="deepvk/USER-bge-m3";;
            ollama) EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}";;
            *)      return 0;;
        esac
        return 0
    fi

    # --- TEI provider: show model menu ---
    if [[ "$EMBED_PROVIDER" == "tei" ]]; then
        echo "Выберите модель эмбеддингов TEI:"
        echo ""
        echo " -- GPU (CUDA) --"
        echo "  1) deepvk/USER-bge-m3                          — 359M, русский fine-tune  [по умолчанию]"
        echo "  2) intfloat/multilingual-e5-base               — 278M, мультиязычная"
        echo "  3) intfloat/multilingual-e5-large              — 560M, лучшее качество"
        echo "  4) intfloat/multilingual-e5-small              — 118M, быстрая"
        echo ""
        echo " -- CPU only (медленнее) --"
        echo "  5) BAAI/bge-m3                                 — 568M, ⚠ CPU only"
        echo ""
        echo " -- Своя модель --"
        echo "  6) Ввод вручную                                — полный HuggingFace ID"
        echo ""

        _ask_choice "Выбор [1-6, Enter=1]: " 1 6 1
        case "$REPLY" in
            1) EMBEDDING_MODEL="deepvk/USER-bge-m3";;
            2) EMBEDDING_MODEL="intfloat/multilingual-e5-base";;
            3) EMBEDDING_MODEL="intfloat/multilingual-e5-large";;
            4) EMBEDDING_MODEL="intfloat/multilingual-e5-small";;
            5) EMBEDDING_MODEL="BAAI/bge-m3";;
            6) _ask "HuggingFace model ID:" ""
               EMBEDDING_MODEL="${REPLY:-deepvk/USER-bge-m3}"
               validate_model_name "$EMBEDDING_MODEL" || {
                   EMBEDDING_MODEL="deepvk/USER-bge-m3"
                   log_warn "Некорректное имя модели, используется deepvk/USER-bge-m3"
               };;
            *) EMBEDDING_MODEL="deepvk/USER-bge-m3";;
        esac

        # CPU-only models need ONNX backend
        if _is_cpu_embed_model "$EMBEDDING_MODEL"; then
            TEI_EMBED_VERSION="cpu-1.9"
            echo -e "  ${YELLOW}⚠ ${EMBEDDING_MODEL} — CPU only (нет safetensors, ONNX fallback)${NC}"
        fi
        echo ""
        return 0
    fi

    # --- Ollama provider: simple prompt (existing behavior) ---
    if [[ "$EMBED_PROVIDER" == "ollama" ]]; then
        _ask "Модель эмбеддингов [bge-m3]:" "bge-m3"
        EMBEDDING_MODEL="${REPLY:-bge-m3}"
        validate_model_name "$EMBEDDING_MODEL" || {
            EMBEDDING_MODEL="bge-m3"
            log_warn "Некорректное имя модели, используется значение по умолчанию"
        }
        echo ""
        return 0
    fi

    # --- external/skip: no model selection needed ---
}

_wizard_reranker_model() {
    # --- NON_INTERACTIVE: use env or default ---
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        if [[ "${ENABLE_RERANKER:-}" == "true" ]]; then
            RERANK_MODEL="${RERANK_MODEL:-BAAI/bge-reranker-base}"
        fi
        return 0
    fi

    # --- Ask yes/no ---
    echo "Включить реранкер? (Улучшает качество RAG, +~1 GB VRAM)"
    echo ""
    _ask "Включить реранкер? [y/N]:" "n"
    if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
        ENABLE_RERANKER="false"
        return 0
    fi
    ENABLE_RERANKER="true"

    # --- Show model menu ---
    echo ""
    echo "Выберите модель реранкера TEI:"
    echo ""
    echo "  1) BAAI/bge-reranker-v2-m3                    — мультиязычный, ~2.2 GB RAM"
    echo "  2) BAAI/bge-reranker-base                     — компактный, ~1.2 GB RAM  [по умолчанию]"
    echo "  3) cross-encoder/ms-marco-MiniLM-L-6-v2       — быстрый, ~0.5 GB RAM"
    echo "  4) Ввод вручную                                — полный HuggingFace ID"
    echo ""

    _ask_choice "Выбор [1-4, Enter=2]: " 1 4 2
    case "$REPLY" in
        1) RERANK_MODEL="BAAI/bge-reranker-v2-m3";;
        2) RERANK_MODEL="BAAI/bge-reranker-base";;
        3) RERANK_MODEL="cross-encoder/ms-marco-MiniLM-L-6-v2";;
        4) _ask "HuggingFace model ID:" ""
           RERANK_MODEL="${REPLY:-BAAI/bge-reranker-base}"
           validate_model_name "$RERANK_MODEL" || {
               RERANK_MODEL="BAAI/bge-reranker-base"
               log_warn "Некорректное имя модели, используется BAAI/bge-reranker-base"
           };;
        *) RERANK_MODEL="BAAI/bge-reranker-base";;
    esac
    echo ""
}

_wizard_hf_token() {
    if [[ "$LLM_PROVIDER" != "vllm" && "$EMBED_PROVIDER" != "tei" ]]; then
        return 0
    fi
    if [[ -n "$HF_TOKEN" ]]; then
        return 0
    fi

    _ask "Токен HuggingFace (Enter — пропустить):" ""
    HF_TOKEN="$REPLY"
}


_wizard_tls() {
    # Already set via env
    if [[ "$TLS_MODE" != "none" ]]; then
        return 0
    fi

    echo "Настройка TLS (HTTPS):"
    echo "  1) Без TLS (по умолчанию)"
    echo "  2) Самоподписанный сертификат"
    echo "  3) Свой сертификат (указать пути)"
    echo ""

    _ask_choice "TLS [1-3, Enter=1]: " 1 3 1
    case "$REPLY" in
        2) TLS_MODE="self-signed";;
        3)
            TLS_MODE="custom"
            _ask "Путь к сертификату (.pem):" ""
            TLS_CERT_PATH="$(validate_path "$REPLY" 2>/dev/null)" || {
                log_error "Некорректный путь к сертификату, TLS отключён"
                TLS_MODE="none"; TLS_CERT_PATH=""
            }
            _ask "Путь к ключу (.pem):" ""
            TLS_KEY_PATH="$(validate_path "$REPLY" 2>/dev/null)" || {
                log_error "Некорректный путь к ключу, TLS отключён"
                TLS_MODE="none"; TLS_KEY_PATH=""
            }
            ;;
        *) TLS_MODE="none";;
    esac
    echo ""
}

_wizard_monitoring() {
    # Respect env override in non-interactive
    if [[ "${NON_INTERACTIVE}" == "true" && "$MONITORING_MODE" != "none" ]]; then
        return 0
    fi

    echo "Мониторинг:"
    echo "  1) Отключён (по умолчанию)"
    echo "  2) Локальный (Grafana + Portainer + Prometheus)"
    echo "  3) Внешний (endpoint + токен)"
    echo ""

    local max_choice=3

    _ask_choice "Мониторинг [1-${max_choice}, Enter=1]: " 1 "$max_choice" 1
    case "$REPLY" in
        2) MONITORING_MODE="local";;
        3)
            MONITORING_MODE="external"
            _ask "Endpoint (URL):" ""
            MONITORING_ENDPOINT="$REPLY"
            validate_url "$MONITORING_ENDPOINT" || {
                log_error "Некорректный URL, мониторинг отключён"
                MONITORING_MODE="none"; MONITORING_ENDPOINT=""
            }
            _ask "Токен:" ""
            MONITORING_TOKEN="$REPLY"
            ;;
        *) MONITORING_MODE="none";;
    esac
    echo ""
}

_wizard_alerts() {
    # Respect env override in non-interactive
    if [[ "${NON_INTERACTIVE}" == "true" && "$ALERT_MODE" != "none" ]]; then
        return 0
    fi

    echo "Уведомления о сбоях:"
    echo "  1) Отключены (по умолчанию)"
    echo "  2) Webhook (URL)"
    echo "  3) Telegram-бот"
    echo ""

    local max_choice=3

    _ask_choice "Уведомления [1-${max_choice}, Enter=1]: " 1 "$max_choice" 1
    case "$REPLY" in
        2)
            ALERT_MODE="webhook"
            _ask "Webhook URL:" ""
            ALERT_WEBHOOK_URL="$REPLY"
            validate_url "$ALERT_WEBHOOK_URL" || {
                log_error "Некорректный URL, уведомления отключены"
                ALERT_MODE="none"; ALERT_WEBHOOK_URL=""
            }
            ;;
        3)
            ALERT_MODE="telegram"
            _ask "Токен Telegram-бота:" ""
            ALERT_TELEGRAM_TOKEN="$REPLY"
            _ask "Telegram Chat ID:" ""
            ALERT_TELEGRAM_CHAT_ID="$REPLY"
            ;;
        *) ALERT_MODE="none";;
    esac
    echo ""
}

_wizard_security() {
    # UFW
    echo "Безопасность:"
    echo "  1) Настроить UFW файрвол"
    echo "  2) Пропустить (по умолчанию)"
    echo ""
    _ask_choice "UFW [1-2, Enter=2]: " 1 2 2
    [[ "$REPLY" == "1" ]] && ENABLE_UFW="true" || ENABLE_UFW="${ENABLE_UFW:-false}"

    # Fail2ban (SSH jail only)
    echo "  Fail2ban (защита от перебора SSH):"
    echo "  1) Включить"
    echo "  2) Пропустить (по умолчанию)"
    echo ""
    _ask_choice "Fail2ban [1-2, Enter=2]: " 1 2 2
    [[ "$REPLY" == "1" ]] && ENABLE_FAIL2BAN="true" || ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-false}"
    echo ""
}

_wizard_tunnel() {
    if [[ "$DEPLOY_PROFILE" != "lan" ]]; then
        return 0
    fi

    echo "Обратный SSH-туннель (доступ к LAN через VPS)?"
    echo "  1) Нет (по умолчанию)"
    echo "  2) Да"
    echo ""
    _ask_choice "Туннель [1-2, Enter=1]: " 1 2 1
    if [[ "$REPLY" == "2" ]]; then
        ENABLE_TUNNEL="true"
        _ask "Хост VPS:" ""
        TUNNEL_VPS_HOST="$REPLY"
        validate_hostname "$TUNNEL_VPS_HOST" || { log_warn "Некорректный хост, туннель отключён"; ENABLE_TUNNEL="false"; return 0; }
        _ask "SSH-порт VPS [22]:" "22"
        TUNNEL_VPS_PORT="${REPLY:-22}"
        _ask "Удалённый порт для веб [8080]:" "8080"
        TUNNEL_REMOTE_PORT="${REPLY:-8080}"
    fi
    echo ""
}

_wizard_backups() {
    echo "Настройка бэкапов:"
    echo "  1) Локальные (/var/backups/agmind/)"
    echo "  2) Удалённые (SCP/rsync)"
    echo "  3) Оба варианта"
    echo ""

    _ask_choice "Бэкапы [1-3, Enter=1]: " 1 3 1
    case "$REPLY" in
        1) BACKUP_TARGET="local";;
        2) BACKUP_TARGET="remote";;
        3) BACKUP_TARGET="both";;
    esac
    echo ""

    echo "Расписание бэкапов:"
    echo "  1) Ежедневно в 03:00 (по умолчанию)"
    echo "  2) Каждые 12 часов (03:00 и 15:00)"
    echo "  3) Своё cron-выражение"
    echo ""

    _ask_choice "Расписание [1-3, Enter=1]: " 1 3 1
    case "$REPLY" in
        2) BACKUP_SCHEDULE="0 3,15 * * *";;
        3)
            _ask "Cron-выражение:" "0 3 * * *"
            BACKUP_SCHEDULE="$REPLY"
            validate_cron "$BACKUP_SCHEDULE" || {
                log_warn "Некорректное cron-выражение, используется значение по умолчанию"
                BACKUP_SCHEDULE="0 3 * * *"
            }
            ;;
        *) BACKUP_SCHEDULE="0 3 * * *";;
    esac
    echo ""

    # Remote backup details
    if [[ "$BACKUP_TARGET" != "local" ]]; then
        _ask "SSH-хост для бэкапов:" ""
        REMOTE_BACKUP_HOST="$REPLY"
        validate_hostname "$REMOTE_BACKUP_HOST" || {
            log_error "Некорректный хост, переключение на локальные бэкапы"
            BACKUP_TARGET="local"
            return 0
        }
        _ask "SSH-порт [22]:" "22"
        REMOTE_BACKUP_PORT="${REPLY:-22}"
        validate_port "$REMOTE_BACKUP_PORT" || { REMOTE_BACKUP_PORT="22"; log_warn "Используется порт по умолчанию 22"; }
        _ask "SSH-пользователь:" ""
        REMOTE_BACKUP_USER="$REPLY"
        _ask "Путь к SSH-ключу (Enter — сгенерировать):" ""
        REMOTE_BACKUP_KEY="$REPLY"
        echo ""
    fi
}

_wizard_litellm() {
    # LAN — локальные модели, прокси не нужен; VPS — multi-user, прокси полезен
    local default_litellm="false"
    [[ "${DEPLOY_PROFILE:-lan}" == "vps" ]] && default_litellm="true"

    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_LITELLM="${ENABLE_LITELLM:-$default_litellm}"
        return
    fi
    echo ""
    echo -e "${CYAN}--- LiteLLM (AI Gateway) ---${NC}"
    echo "  Универсальный прокси для LLM (логирование, rate-limit, fallback)."
    echo "  Если нет — Open WebUI и Dify подключатся к Ollama/vLLM напрямую."
    echo "  ~1 GB RAM + PostgreSQL таблица."
    if [[ "$default_litellm" == "true" ]]; then
        _ask "Включить LiteLLM? [Y/n]:" "y"
        [[ "${REPLY,,}" =~ ^n ]] && ENABLE_LITELLM=false || ENABLE_LITELLM=true
    else
        _ask "Включить LiteLLM? [y/N]:" "n"
        [[ "${REPLY,,}" =~ ^y ]] && ENABLE_LITELLM=true || ENABLE_LITELLM=false
    fi
}

_wizard_searxng() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_SEARXNG="${ENABLE_SEARXNG:-false}"
        return
    fi
    echo ""
    echo -e "${CYAN}--- SearXNG (поисковый движок) ---${NC}"
    echo "  Мета-поисковик (Google, Bing, DuckDuckGo, Wikipedia)."
    echo "  JSON API для интеграции с Dify/агентами. ~256 MB RAM."
    _ask "Включить SearXNG? [y/N]:" "n"
    [[ "${REPLY,,}" =~ ^y ]] && ENABLE_SEARXNG=true || ENABLE_SEARXNG=false
}

_wizard_notebook() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_NOTEBOOK="${ENABLE_NOTEBOOK:-false}"
        return
    fi
    echo ""
    echo -e "${CYAN}--- Open Notebook (исследовательский ассистент) ---${NC}"
    echo "  Альтернатива Google NotebookLM. PDF, видео, аудио, веб."
    echo "  ~512 MB RAM + SurrealDB (~256 MB)."
    _ask "Включить Open Notebook? [y/N]:" "n"
    [[ "${REPLY,,}" =~ ^y ]] && ENABLE_NOTEBOOK=true || ENABLE_NOTEBOOK=false
}

_wizard_dbgpt() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_DBGPT="${ENABLE_DBGPT:-false}"
        return
    fi
    echo ""
    echo -e "${CYAN}--- DB-GPT (аналитика данных) ---${NC}"
    echo "  AI-агент для анализа данных и SQL."
    echo "  ~1 GB RAM."
    _ask "Включить DB-GPT? [y/N]:" "n"
    [[ "${REPLY,,}" =~ ^y ]] && ENABLE_DBGPT=true || ENABLE_DBGPT=false
}

_wizard_crawl4ai() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_CRAWL4AI="${ENABLE_CRAWL4AI:-false}"
        return
    fi
    echo ""
    echo -e "${CYAN}--- Crawl4AI (веб-краулер) ---${NC}"
    echo "  REST API для извлечения данных из веб-страниц (Chromium)."
    echo "  Playground + мониторинг. ~2 GB RAM."
    _ask "Включить Crawl4AI? [y/N]:" "n"
    [[ "${REPLY,,}" =~ ^y ]] && ENABLE_CRAWL4AI=true || ENABLE_CRAWL4AI=false
}

_wizard_dify_premium() {
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        ENABLE_DIFY_PREMIUM="${ENABLE_DIFY_PREMIUM:-true}"
        return
    fi
    echo ""
    echo -e "${CYAN}--- Dify Premium Features ---${NC}"
    echo "  Разблокирует: замена лого, балансировка моделей,"
    echo "  безлимит участников/приложений/документов, приоритетная обработка."
    echo "  Не требует лицензию, не включает биллинг."
    echo ""
    echo "  1) Да  — разблокировать (рекомендуется)"
    echo "  2) Нет — оставить Community Edition"
    _ask_choice "Premium [1-2, Enter=1]: " 1 2 1
    case "$REPLY" in
        1) ENABLE_DIFY_PREMIUM="true" ;;
        2) ENABLE_DIFY_PREMIUM="false" ;;
    esac
}

_wizard_summary() {
    echo -e "${CYAN}=== Сводка установки ===${NC}"
    echo "  Профиль:      ${DEPLOY_PROFILE}"
    [[ -n "$DOMAIN" ]] && echo "  Домен:        ${DOMAIN}"
    echo "  Вектор. БД:   ${VECTOR_STORE}"
    [[ "$ENABLE_DOCLING" == "true" ]] && echo "  ETL:          Docling (${DOCLING_IMAGE##*/})"
    if [[ "${LLM_PROVIDER:-}" == "vllm" && -n "${VLLM_MAX_MODEL_LEN:-}" ]]; then
        local ctx_k=$(( VLLM_MAX_MODEL_LEN / 1024 ))
        echo "  LLM:          ${LLM_PROVIDER} (${VLLM_MODEL}) ctx=${ctx_k}K"
    else
        echo "  LLM:          ${LLM_PROVIDER} ${LLM_MODEL}${VLLM_MODEL:+ (${VLLM_MODEL})}"
    fi
    echo "  Эмбеддинги:   ${EMBED_PROVIDER} ${EMBEDDING_MODEL}"
    [[ "${ENABLE_RERANKER:-}" == "true" ]] && echo "  Реранкер:     ${RERANK_MODEL} (~1 GB)"
    [[ "$TLS_MODE" != "none" ]] && echo "  TLS:          ${TLS_MODE}"
    [[ "$MONITORING_MODE" != "none" ]] && echo "  Мониторинг:   ${MONITORING_MODE}"
    [[ "$ALERT_MODE" != "none" ]] && echo "  Уведомления:  ${ALERT_MODE}"
    [[ "$ENABLE_UFW" == "true" ]] && echo "  UFW:          включён"
    [[ "$ENABLE_FAIL2BAN" == "true" ]] && echo "  Fail2ban:     SSH jail"
    [[ "$ENABLE_AUTHELIA" == "true" ]] && echo "  Authelia:     2FA включена"
    [[ "${ENABLE_LITELLM:-true}" == "true" ]] && echo "  LiteLLM:      включён (AI Gateway)"
    [[ "${ENABLE_SEARXNG:-false}" == "true" ]] && echo "  SearXNG:      включён (порт 8888)"
    [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]] && echo "  Open Notebook: включён (порт 8502)"
    [[ "${ENABLE_DBGPT:-false}" == "true" ]] && echo "  DB-GPT:       включён (порт 5670)"
    [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]] && echo "  Crawl4AI:     включён (порт 11235)"
    [[ "${ENABLE_DIFY_PREMIUM:-true}" == "true" ]] && echo "  Dify Premium: включён (патч после запуска)"
    [[ "$ENABLE_TUNNEL" == "true" ]] && echo "  Туннель:      ${TUNNEL_VPS_HOST}:${TUNNEL_REMOTE_PORT}"
    echo "  Бэкапы:       ${BACKUP_TARGET} (${BACKUP_SCHEDULE})"

    # VRAM plan (only for vLLM — Ollama manages VRAM internally)
    if [[ "${LLM_PROVIDER:-}" == "vllm" ]]; then
        echo ""
        echo -e "${CYAN}--- GPU память ---${NC}"
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
        [[ "$vllm_total" == "0" ]] && vllm_total="?"
        if [[ "$vllm_total" != "?" && "$vllm_weights" -gt 0 ]]; then
            local kv_est=$(( vllm_total - vllm_weights ))
            echo "  vLLM:         ~${vllm_total} GB   (веса ${vllm_weights} + KV ~${kv_est} @ ${vllm_ctx_label})   ${VLLM_MODEL:-unknown}"
        else
            echo "  vLLM:         ${vllm_total} GB   (${VLLM_MODEL:-unknown})"
        fi

        local embed_vram=0
        if [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then
            if [[ "${TEI_EMBED_VERSION:-cuda}" == cpu-* ]]; then
                echo "  TEI-embed:    CPU (8 GB RAM)   (${EMBEDDING_MODEL:-unknown})"
            else
                embed_vram=2
                echo "  TEI-embed:    ${embed_vram} GB   (${EMBEDDING_MODEL:-unknown})"
            fi
        fi

        if [[ "${ENABLE_RERANKER:-}" == "true" ]]; then
            echo "  TEI-rerank:   CPU (4 GB RAM)   (${RERANK_MODEL:-unknown})"
        fi

        echo "  ─────────────────"

        if [[ "$vllm_total" == "?" ]]; then
            echo "  Итого:        ? GB (неизвестная модель)"
        else
            local total_vram=$(( vllm_total + embed_vram ))
            local gpu_vram_mb="${DETECTED_GPU_VRAM:-0}"
            if [[ "$gpu_vram_mb" -gt 0 ]] 2>/dev/null; then
                local gpu_vram_gb=$(( gpu_vram_mb / 1024 ))
                local mem_type="VRAM"
                [[ "${DETECTED_GPU_UNIFIED_MEMORY:-false}" == "true" ]] && mem_type="unified memory"
                echo "  Итого:        ~${total_vram} GB / ${gpu_vram_gb} GB ${mem_type} доступно"
                if [[ "$total_vram" -gt "$gpu_vram_gb" ]]; then
                    echo -e "  ${YELLOW}⚠ ${mem_type} бюджет превышен! Возможен OOM.${NC}"
                fi
            else
                echo "  Итого:        ~${total_vram} GB"
                echo -e "  ${YELLOW}GPU память не определена — проверьте вручную${NC}"
            fi
        fi
    fi

    echo ""
}

_wizard_confirm() {
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi
    _ask "Начать установку? (yes/no):" "no"
    if [[ "$REPLY" != "yes" ]]; then
        echo "Отменено."
        exit 0
    fi
    echo ""
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

run_wizard() {
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
    _wizard_litellm
    _wizard_searxng
    _wizard_notebook
    _wizard_dbgpt
    _wizard_crawl4ai
    _wizard_dify_premium
    _wizard_summary
    _wizard_confirm

    # Export all choices
    export DEPLOY_PROFILE DOMAIN CERTBOT_EMAIL VECTOR_STORE ENABLE_DOCLING
    export DOCLING_IMAGE OCR_LANG NVIDIA_VISIBLE_DEVICES
    export LLM_PROVIDER LLM_MODEL VLLM_MODEL VLLM_CUDA_SUFFIX EMBED_PROVIDER EMBEDDING_MODEL TEI_EMBED_VERSION
    export ENABLE_RERANKER RERANK_MODEL
    export HF_TOKEN TLS_MODE TLS_CERT_PATH TLS_KEY_PATH
    export MONITORING_MODE MONITORING_ENDPOINT MONITORING_TOKEN
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
    run_wizard
fi
