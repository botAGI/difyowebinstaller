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
    LLM_PROVIDER="${LLM_PROVIDER:-}"
    LLM_MODEL="${LLM_MODEL:-}"
    VLLM_MODEL="${VLLM_MODEL:-}"
    VLLM_CUDA_SUFFIX="${VLLM_CUDA_SUFFIX:-}"
    EMBED_PROVIDER="${EMBED_PROVIDER:-}"
    EMBEDDING_MODEL="${EMBEDDING_MODEL:-}"
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
    echo "  1) VPS     — публичный доступ через домен (нужен интернет + домен)"
    echo "  2) LAN     — локальная офисная сеть (интернет, без домена)"
    echo "  3) VPN     — корпоративный VPN (доступ только через VPN)"
    echo "  4) Offline — изолированная сеть (без интернета)"
    echo ""

    if [[ "${NON_INTERACTIVE}" == "true" && -n "${DEPLOY_PROFILE}" ]]; then
        # Respect env override only in non-interactive mode
        return 0
    fi

    _ask_choice "Профиль [1-4]: " 1 4 2
    case "$REPLY" in
        1) DEPLOY_PROFILE="vps";;
        2) DEPLOY_PROFILE="lan";;
        3) DEPLOY_PROFILE="vpn";;
        4) DEPLOY_PROFILE="offline";;
    esac
}

_wizard_security_defaults() {
    # VPS profile forces security ON unless user explicitly overrode via env
    # before _init_wizard_defaults ran. Since _init_wizard_defaults already set
    # these to "false", we must unconditionally set for vps.
    case "$DEPLOY_PROFILE" in
        vps)
            ENABLE_UFW="true"
            ENABLE_FAIL2BAN="true"
            ;;
        lan|vpn)
            ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-false}"
            ;;
    esac
}

_wizard_admin_ui() {
    if [[ "$DEPLOY_PROFILE" == "vps" ]]; then
        ADMIN_UI_OPEN=false
        return 0
    fi

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
    if [[ "$DEPLOY_PROFILE" != "vps" ]]; then
        return 0
    fi

    if [[ "${NON_INTERACTIVE}" == "true" && -n "$DOMAIN" && -n "$CERTBOT_EMAIL" ]]; then
        # Respect env override only in non-interactive mode
        return 0
    fi

    _ask "Домен для доступа:" ""
    DOMAIN="$REPLY"
    validate_domain "$DOMAIN" || { log_error "Некорректный домен, отмена"; exit 1; }

    _ask "Email для сертификата:" ""
    CERTBOT_EMAIL="$REPLY"
    validate_email "$CERTBOT_EMAIL" || { log_error "Некорректный email, отмена"; exit 1; }
    echo ""
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
    if [[ "$DEPLOY_PROFILE" == "offline" ]]; then
        ENABLE_DOCLING="false"
        return 0
    fi

    echo "Расширенная обработка документов (Docling)?"
    echo "  1) Нет — стандартный Dify ETL (по умолчанию)"
    echo "  2) Да — Docling (улучшенный парсинг документов)"
    echo ""

    _ask_choice "Выбор [1-2, Enter=1]: " 1 2 1
    case "$REPLY" in
        2) ENABLE_DOCLING="true";;
        *) ENABLE_DOCLING="false";;
    esac
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

    # Blackwell GPU warning: sm_120+ needs CUDA 13.0 build
    if [[ "$LLM_PROVIDER" == "vllm" ]] && _is_blackwell_gpu; then
        echo ""
        log_warn "GPU Blackwell (compute ${DETECTED_GPU_COMPUTE}) — требуется vLLM с CUDA 13.0."
        echo "  1) Переключиться на Ollama (рекомендуется)"
        echo "  2) Использовать vLLM с CUDA 13.0 (stable -cu130)"
        echo ""
        _ask_choice "Выбор [1-2, Enter=2]: " 1 2 2
        if [[ "$REPLY" == "1" ]]; then
            LLM_PROVIDER="ollama"
            log_info "Переключено на Ollama"
        else
            VLLM_CUDA_SUFFIX="-cu130"
            log_info "vLLM будет использовать образ с CUDA 13.0"
        fi
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
    echo " -- Своя модель --"
    echo "  16) Ввести вручную (имя из реестра Ollama)"
    echo ""

    _ask_choice "Модель [1-16, Enter=6]: " 1 16 6
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
    )
    if [[ "$REPLY" -ge 1 && "$REPLY" -le 15 ]]; then
        LLM_MODEL="${ollama_models[$REPLY]}"
    elif [[ "$REPLY" -eq 16 ]]; then
        _ask "Имя модели:" "qwen2.5:14b"
        LLM_MODEL="$REPLY"
        validate_model_name "$LLM_MODEL" || { LLM_MODEL="qwen2.5:14b"; log_warn "Некорректное имя модели, используется значение по умолчанию"; }
    fi
    echo ""
}

# TEI VRAM offset: reserve 2 GB for TEI embedding container
readonly TEI_VRAM_OFFSET=2

# Returns VRAM requirement in GB for a known vLLM model name.
# Usage: req=$(_get_vllm_vram_req "Qwen/Qwen2.5-14B-Instruct")
# Outputs "0" for unknown models (caller skips the VRAM check).
_get_vllm_vram_req() {
    local model="${1:-}"
    case "$model" in
        "Qwen/Qwen2.5-7B-Instruct-AWQ")                    echo "5"   ;;
        "Qwen/Qwen3-8B-AWQ")                               echo "6"   ;;
        "Qwen/Qwen2.5-14B-Instruct-AWQ")                   echo "10"  ;;
        "Qwen/Qwen3-14B-AWQ")                              echo "10"  ;;
        "Qwen/Qwen2.5-32B-Instruct-AWQ")                   echo "20"  ;;
        "Qwen/Qwen2.5-7B-Instruct")                        echo "16"  ;;
        "Qwen/Qwen3-8B")                                   echo "16"  ;;
        "mistralai/Mistral-7B-Instruct-v0.3")              echo "16"  ;;
        "meta-llama/Llama-3.1-8B-Instruct")                echo "16"  ;;
        "Qwen/Qwen2.5-14B-Instruct")                       echo "28"  ;;
        "Qwen/Qwen3-14B")                                  echo "28"  ;;
        "microsoft/phi-4")                                  echo "28"  ;;
        "Qwen/Qwen2.5-32B-Instruct")                       echo "48"  ;;
        "meta-llama/Llama-3.3-70B-Instruct")               echo "140" ;;
        "bullpoint/Qwen3-Coder-Next-AWQ-4bit")             echo "12"  ;;
        "stelterlab/NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ")   echo "4"   ;;
        *)                                                  echo "0"   ;;
    esac
}

_wizard_vllm_model() {
    # VRAM requirements in GB per model (indices 1-16 match menu numbers)
    local -a vram_req=(0 5 6 10 10 20 16 16 16 16 28 28 28 48 140 12 4)

    local vram_gb=0
    if [[ "${DETECTED_GPU_VRAM:-0}" -gt 0 ]]; then
        vram_gb=$(( DETECTED_GPU_VRAM / 1024 ))
    fi

    # TEI offset for [recommended]: vLLM default embed is TEI (~2 GB shared GPU)
    local effective_vram="$vram_gb"
    if [[ "$vram_gb" -gt 0 ]]; then
        effective_vram=$(( vram_gb - TEI_VRAM_OFFSET ))
        [[ "$effective_vram" -lt 0 ]] && effective_vram=0
    fi

    # Find largest fitting model for [recommended] tag
    local rec_idx=0
    if [[ "$effective_vram" -gt 0 ]]; then
        local i
        for i in 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
            if [[ "${vram_req[$i]}" -le "$effective_vram" ]]; then
                rec_idx="$i"
                break
            fi
        done
    fi

    # Helper: print model line with VRAM label + optional [рекомендуется]
    _vllm_line() {
        local idx="$1" num="$2" label="$3" suffix="${4:-}"
        local tag=""
        [[ "$idx" -eq "$rec_idx" ]] && tag="  ${GREEN}[рекомендуется]${NC}"
        echo -e "  ${num}) ${label}  [${vram_req[$idx]} GB VRAM]${tag}${suffix}"
    }

    echo "Выберите модель vLLM:"
    echo ""
    if [[ "$vram_gb" -eq 0 ]]; then
        echo -e "  ${YELLOW}GPU VRAM не определён — метка [рекомендуется] недоступна${NC}"
        echo ""
    fi
    echo " -- AWQ квантизация (компактный VRAM) --"
    _vllm_line 1  " 1" "Qwen/Qwen2.5-7B-Instruct-AWQ"
    _vllm_line 2  " 2" "Qwen/Qwen3-8B-AWQ"
    _vllm_line 3  " 3" "Qwen/Qwen2.5-14B-Instruct-AWQ"
    _vllm_line 4  " 4" "Qwen/Qwen3-14B-AWQ"
    _vllm_line 5  " 5" "Qwen/Qwen2.5-32B-Instruct-AWQ"
    echo ""
    echo " -- 7-8B bf16 (полная точность) --"
    _vllm_line 6  " 6" "Qwen/Qwen2.5-7B-Instruct"
    _vllm_line 7  " 7" "Qwen/Qwen3-8B"
    _vllm_line 8  " 8" "mistralai/Mistral-7B-Instruct-v0.3"
    _vllm_line 9  " 9" "meta-llama/Llama-3.1-8B-Instruct" "  (HF_TOKEN)"
    echo ""
    echo " -- 14B bf16 --"
    _vllm_line 10 "10" "Qwen/Qwen2.5-14B-Instruct"
    _vllm_line 11 "11" "Qwen/Qwen3-14B"
    _vllm_line 12 "12" "microsoft/phi-4"
    echo ""
    echo " -- 32B+ bf16 --"
    _vllm_line 13 "13" "Qwen/Qwen2.5-32B-Instruct"
    _vllm_line 14 "14" "meta-llama/Llama-3.3-70B-Instruct" "  (HF_TOKEN)"
    echo ""
    echo " -- MoE (активных параметров << общих) --"
    _vllm_line 15 "15" "bullpoint/Qwen3-Coder-Next-AWQ-4bit" "  80B total, 14B active"
    _vllm_line 16 "16" "stelterlab/NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ" "  30B total, 3B active"
    echo ""
    echo " -- Своя модель --"
    echo " 17) Ввести HuggingFace репозиторий (org/model-name)"
    echo ""

    _ask_choice "Модель [1-17, Enter=6]: " 1 17 6

    local vllm_models=(
        ""  # 0 placeholder
        "Qwen/Qwen2.5-7B-Instruct-AWQ"
        "Qwen/Qwen3-8B-AWQ"
        "Qwen/Qwen2.5-14B-Instruct-AWQ"
        "Qwen/Qwen3-14B-AWQ"
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
    )

    if [[ "$REPLY" -ge 1 && "$REPLY" -le 16 ]]; then
        VLLM_MODEL="${vllm_models[$REPLY]}"

        # VRAM guard: warn if selected model exceeds effective GPU (raw - TEI offset)
        local effective_vram_check=$(( vram_gb > 0 ? vram_gb - TEI_VRAM_OFFSET : 0 ))
        [[ "$effective_vram_check" -lt 0 ]] && effective_vram_check=0
        if [[ "$vram_gb" -gt 0 && "${vram_req[$REPLY]}" -gt "$effective_vram_check" ]]; then
            echo ""
            echo -e "  ${YELLOW}Модель требует ${vram_req[$REPLY]} GB VRAM, доступно ${effective_vram_check} GB effective (${vram_gb} GB - ${TEI_VRAM_OFFSET} GB TEI). Возможен OOM.${NC}"
            if [[ "${NON_INTERACTIVE}" != "true" ]]; then
                read -rp "  Продолжить? (y/N): " confirm
                if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
                    # Re-show menu
                    unset -f _vllm_line
                    _wizard_vllm_model
                    return
                fi
            fi
        fi
    elif [[ "$REPLY" -eq 17 ]]; then
        _ask "HuggingFace репозиторий (org/model):" "Qwen/Qwen2.5-14B-Instruct"
        VLLM_MODEL="${REPLY:-Qwen/Qwen2.5-14B-Instruct}"
        # No VRAM check for custom models (per decision)
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
        VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct"
    fi

    # VRAM guard for vllm in NON_INTERACTIVE mode (BFIX-41)
    # Runs for both user-supplied VLLM_MODEL and the default assigned above.
    if [[ "${NON_INTERACTIVE}" == "true" && "$LLM_PROVIDER" == "vllm" && -n "${VLLM_MODEL:-}" ]]; then
        local ni_vram_req
        ni_vram_req="$(_get_vllm_vram_req "$VLLM_MODEL")"
        if [[ "$ni_vram_req" -gt 0 ]]; then
            local ni_vram_gb=0
            if [[ "${DETECTED_GPU_VRAM:-0}" -gt 0 ]]; then
                ni_vram_gb=$(( DETECTED_GPU_VRAM / 1024 ))
            fi
            local ni_effective_vram=$(( ni_vram_gb > 0 ? ni_vram_gb - TEI_VRAM_OFFSET : 0 ))
            [[ "$ni_effective_vram" -lt 0 ]] && ni_effective_vram=0
            if [[ "$ni_vram_gb" -gt 0 && "$ni_vram_req" -gt "$ni_effective_vram" ]]; then
                log_error "Model ${VLLM_MODEL} requires ${ni_vram_req} GB VRAM, effective available: ${ni_effective_vram} GB (${ni_vram_gb} GB - ${TEI_VRAM_OFFSET} GB TEI)"
                log_error "Choose a smaller model or set VLLM_MODEL to a model that fits your GPU"
                exit 1
            fi
            if [[ "$ni_vram_gb" -eq 0 ]]; then
                log_warn "GPU VRAM not detected -- cannot verify model ${VLLM_MODEL} fits (requires ${ni_vram_req} GB)"
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
    # --- NON_INTERACTIVE: use env or default ---
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        if [[ -n "${EMBEDDING_MODEL:-}" && "$EMBEDDING_MODEL" != "bge-m3" ]]; then
            return 0
        fi
        # Apply provider-aware default
        case "$EMBED_PROVIDER" in
            tei)    EMBEDDING_MODEL="BAAI/bge-m3";;
            ollama) EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}";;
            *)      return 0;;
        esac
        return 0
    fi

    # --- TEI provider: show model menu ---
    if [[ "$EMBED_PROVIDER" == "tei" ]]; then
        echo "Выберите модель эмбеддингов TEI:"
        echo ""
        echo "  1) BAAI/bge-m3                                — мультиязычная, стабильная  [по умолчанию]"
        echo "  2) Qwen/Qwen3-Embedding-0.6B                  — лёгкая, 0.6B параметров"
        echo "  3) intfloat/multilingual-e5-large-instruct     — instruct-версия, MTEB #7, понимает query:/passage: префиксы"
        echo "  4) Ввод вручную                                — полный HuggingFace ID"
        echo ""

        _ask_choice "Выбор [1-4, Enter=1]: " 1 4 1
        case "$REPLY" in
            1) EMBEDDING_MODEL="BAAI/bge-m3";;
            2) EMBEDDING_MODEL="Qwen/Qwen3-Embedding-0.6B";;
            3) EMBEDDING_MODEL="intfloat/multilingual-e5-large-instruct";;
            4) _ask "HuggingFace model ID:" ""
               EMBEDDING_MODEL="${REPLY:-BAAI/bge-m3}"
               validate_model_name "$EMBEDDING_MODEL" || {
                   EMBEDDING_MODEL="BAAI/bge-m3"
                   log_warn "Некорректное имя модели, используется BAAI/bge-m3"
               };;
            *) EMBEDDING_MODEL="BAAI/bge-m3";;
        esac
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

_wizard_offline_warning() {
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        return 0
    fi

    log_warn "Offline-профиль: модели НЕ будут загружены."
    if [[ "$LLM_PROVIDER" == "ollama" || "$EMBED_PROVIDER" == "ollama" ]]; then
        echo "  Убедитесь, что модели предзагружены в том ollama_data."
    fi
    if [[ "$LLM_PROVIDER" == "vllm" ]]; then
        echo "  Убедитесь, что образ vLLM и модель ${VLLM_MODEL:-} предзагружены."
    fi
    if [[ "$EMBED_PROVIDER" == "tei" ]]; then
        echo "  Убедитесь, что образ TEI и модель BAAI/bge-m3 предзагружены."
    fi
    echo ""
}

_wizard_tls() {
    if [[ "$DEPLOY_PROFILE" == "vps" ]]; then
        TLS_MODE="letsencrypt"
        return 0
    fi
    if [[ "$DEPLOY_PROFILE" == "offline" ]]; then
        TLS_MODE="none"
        return 0
    fi

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
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        echo "  3) Внешний (endpoint + токен)"
    fi
    echo ""

    local max_choice=2
    [[ "$DEPLOY_PROFILE" != "offline" ]] && max_choice=3

    _ask_choice "Мониторинг [1-${max_choice}, Enter=1]: " 1 "$max_choice" 1
    case "$REPLY" in
        2) MONITORING_MODE="local";;
        3)
            if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
                MONITORING_MODE="external"
                _ask "Endpoint (URL):" ""
                MONITORING_ENDPOINT="$REPLY"
                validate_url "$MONITORING_ENDPOINT" || {
                    log_error "Некорректный URL, мониторинг отключён"
                    MONITORING_MODE="none"; MONITORING_ENDPOINT=""
                }
                _ask "Токен:" ""
                MONITORING_TOKEN="$REPLY"
            fi
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
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        echo "  3) Telegram-бот"
    fi
    echo ""

    local max_choice=2
    [[ "$DEPLOY_PROFILE" != "offline" ]] && max_choice=3

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
            if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
                ALERT_MODE="telegram"
                _ask "Токен Telegram-бота:" ""
                ALERT_TELEGRAM_TOKEN="$REPLY"
                _ask "Telegram Chat ID:" ""
                ALERT_TELEGRAM_CHAT_ID="$REPLY"
            fi
            ;;
        *) ALERT_MODE="none";;
    esac
    echo ""
}

_wizard_security() {
    # UFW
    if [[ "$DEPLOY_PROFILE" == "vps" ]]; then
        echo "  UFW файрвол будет настроен автоматически (VPS)"
        ENABLE_UFW="true"
    else
        echo "Безопасность:"
        echo "  1) Настроить UFW файрвол"
        echo "  2) Пропустить (по умолчанию)"
        echo ""
        _ask_choice "UFW [1-2, Enter=2]: " 1 2 2
        [[ "$REPLY" == "1" ]] && ENABLE_UFW="true" || ENABLE_UFW="${ENABLE_UFW:-false}"
    fi

    # Fail2ban (SSH jail only)
    echo "  Fail2ban (защита от перебора SSH):"
    echo "  1) Включить"
    echo "  2) Пропустить (по умолчанию)"
    echo ""
    _ask_choice "Fail2ban [1-2, Enter=2]: " 1 2 2
    [[ "$REPLY" == "1" ]] && ENABLE_FAIL2BAN="true" || ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-false}"
    echo ""

    # Authelia 2FA (VPS only)
    if [[ "$DEPLOY_PROFILE" == "vps" ]]; then
        echo "Включить Authelia 2FA (двухфакторная аутентификация)?"
        echo "  1) Нет (по умолчанию)"
        echo "  2) Да"
        _ask_choice "Выбор [1-2, Enter=1]: " 1 2 1
        if [[ "$REPLY" == "2" ]]; then
            ENABLE_AUTHELIA="true"
        fi
    fi
}

_wizard_tunnel() {
    if [[ "$DEPLOY_PROFILE" != "lan" && "$DEPLOY_PROFILE" != "vpn" ]]; then
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

_wizard_summary() {
    echo -e "${CYAN}=== Сводка установки ===${NC}"
    echo "  Профиль:      ${DEPLOY_PROFILE}"
    [[ -n "$DOMAIN" ]] && echo "  Домен:        ${DOMAIN}"
    echo "  Вектор. БД:   ${VECTOR_STORE}"
    [[ "$ENABLE_DOCLING" == "true" ]] && echo "  ETL:          Docling"
    echo "  LLM:          ${LLM_PROVIDER} ${LLM_MODEL}${VLLM_MODEL:+ (${VLLM_MODEL})}"
    echo "  Эмбеддинги:   ${EMBED_PROVIDER} ${EMBEDDING_MODEL}"
    [[ "$TLS_MODE" != "none" ]] && echo "  TLS:          ${TLS_MODE}"
    [[ "$MONITORING_MODE" != "none" ]] && echo "  Мониторинг:   ${MONITORING_MODE}"
    [[ "$ALERT_MODE" != "none" ]] && echo "  Уведомления:  ${ALERT_MODE}"
    [[ "$ENABLE_UFW" == "true" ]] && echo "  UFW:          включён"
    [[ "$ENABLE_FAIL2BAN" == "true" ]] && echo "  Fail2ban:     SSH jail"
    [[ "$ENABLE_AUTHELIA" == "true" ]] && echo "  Authelia:     2FA включена"
    [[ "$ENABLE_TUNNEL" == "true" ]] && echo "  Туннель:      ${TUNNEL_VPS_HOST}:${TUNNEL_REMOTE_PORT}"
    echo "  Бэкапы:       ${BACKUP_TARGET} (${BACKUP_SCHEDULE})"
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
    _wizard_vector_store
    _wizard_etl
    _wizard_llm_provider
    _wizard_llm_model
    _wizard_embed_provider
    _wizard_embedding_model
    _wizard_hf_token
    _wizard_offline_warning
    _wizard_tls
    _wizard_monitoring
    _wizard_alerts
    _wizard_security
    _wizard_tunnel
    _wizard_backups
    _wizard_summary
    _wizard_confirm

    # Export all choices
    export DEPLOY_PROFILE DOMAIN CERTBOT_EMAIL VECTOR_STORE ENABLE_DOCLING
    export LLM_PROVIDER LLM_MODEL VLLM_MODEL VLLM_CUDA_SUFFIX EMBED_PROVIDER EMBEDDING_MODEL
    export HF_TOKEN TLS_MODE TLS_CERT_PATH TLS_KEY_PATH
    export MONITORING_MODE MONITORING_ENDPOINT MONITORING_TOKEN
    export ALERT_MODE ALERT_WEBHOOK_URL ALERT_TELEGRAM_TOKEN ALERT_TELEGRAM_CHAT_ID
    export ENABLE_UFW ENABLE_FAIL2BAN ENABLE_AUTHELIA
    export ENABLE_TUNNEL TUNNEL_VPS_HOST TUNNEL_VPS_PORT TUNNEL_REMOTE_PORT
    export BACKUP_TARGET BACKUP_SCHEDULE
    export REMOTE_BACKUP_HOST REMOTE_BACKUP_PORT REMOTE_BACKUP_USER REMOTE_BACKUP_KEY REMOTE_BACKUP_PATH
    export ADMIN_UI_OPEN
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
