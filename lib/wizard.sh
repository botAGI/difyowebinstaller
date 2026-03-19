#!/usr/bin/env bash
# wizard.sh — Interactive installation wizard. All user questions in one module.
# Dependencies: common.sh (log_*, validate_*, colors), detect.sh (RECOMMENDED_MODEL, DETECTED_GPU)
# Exports all wizard choices as global variables (see §7.3 in SPEC.md):
#   DEPLOY_PROFILE, DOMAIN, CERTBOT_EMAIL, VECTOR_STORE, ETL_ENHANCED,
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
    ETL_ENHANCED="${ETL_ENHANCED:-false}"
    LLM_PROVIDER="${LLM_PROVIDER:-}"
    LLM_MODEL="${LLM_MODEL:-}"
    VLLM_MODEL="${VLLM_MODEL:-}"
    EMBED_PROVIDER="${EMBED_PROVIDER:-}"
    EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}"
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
        echo "Enter a number from ${min} to ${max}"
    done
}

# ============================================================================
# WIZARD SECTIONS
# ============================================================================

_wizard_profile() {
    echo "Select deployment profile:"
    echo "  1) VPS     — public access via domain (internet + domain required)"
    echo "  2) LAN     — local office network (internet, no domain)"
    echo "  3) VPN     — corporate VPN (access only through VPN)"
    echo "  4) Offline — air-gapped network (no internet)"
    echo ""

    if [[ -n "${DEPLOY_PROFILE}" ]]; then
        # Already set via env var
        return 0
    fi

    _ask_choice "Profile [1-4]: " 1 4 2
    case "$REPLY" in
        1) DEPLOY_PROFILE="vps";;
        2) DEPLOY_PROFILE="lan";;
        3) DEPLOY_PROFILE="vpn";;
        4) DEPLOY_PROFILE="offline";;
    esac
}

_wizard_security_defaults() {
    # Auto-set security defaults per profile (can be overridden by env)
    case "$DEPLOY_PROFILE" in
        vps)
            ENABLE_UFW="${ENABLE_UFW:-true}"
            ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
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

    echo "Portainer and Grafana are bound to localhost (127.0.0.1) by default."
    _ask "Open access from LAN? [no/yes] (default: no):" "no"
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

    if [[ -n "$DOMAIN" && -n "$CERTBOT_EMAIL" ]]; then
        # Already set via env
        return 0
    fi

    _ask "Domain for access:" ""
    DOMAIN="$REPLY"
    validate_domain "$DOMAIN" || { log_error "Invalid domain, aborting"; exit 1; }

    _ask "Email for certificate:" ""
    CERTBOT_EMAIL="$REPLY"
    validate_email "$CERTBOT_EMAIL" || { log_error "Invalid email, aborting"; exit 1; }
    echo ""
}

_wizard_vector_store() {
    # Respect env override in non-interactive
    if [[ "${NON_INTERACTIVE}" == "true" && "$VECTOR_STORE" != "weaviate" ]]; then
        return 0
    fi

    echo "Select vector store:"
    echo "  1) Weaviate  — stable, battle-tested (default)"
    echo "  2) Qdrant    — fast, REST/gRPC API"
    echo ""

    _ask_choice "Choice [1-2, Enter=1]: " 1 2 1
    case "$REPLY" in
        2) VECTOR_STORE="qdrant";;
        *) VECTOR_STORE="weaviate";;
    esac
    echo ""
}

_wizard_etl() {
    if [[ "$DEPLOY_PROFILE" == "offline" ]]; then
        ETL_ENHANCED="false"
        return 0
    fi

    echo "Enhanced document processing (Docling + Xinference reranker)?"
    echo "  1) No — standard Dify ETL (default)"
    echo "  2) Yes — Docling + bce-reranker-base_v1"
    echo ""

    _ask_choice "Choice [1-2, Enter=1]: " 1 2 1
    case "$REPLY" in
        2) ETL_ENHANCED="true";;
        *) ETL_ENHANCED="false";;
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
        gpu_note="  (NVIDIA GPU not detected — default: Ollama)"
    fi

    # If already set via env
    if [[ -n "$LLM_PROVIDER" ]]; then
        return 0
    fi

    echo "Select LLM provider:${gpu_note}"
    echo "  1) Ollama"
    echo "  2) vLLM"
    echo "  3) External API"
    echo "  4) Skip"
    echo ""

    _ask_choice "Choice [1-4, Enter=${default_idx}]: " 1 4 "$default_idx"
    case "$REPLY" in
        1) LLM_PROVIDER="ollama";;
        2) LLM_PROVIDER="vllm";;
        3) LLM_PROVIDER="external";;
        4) LLM_PROVIDER="skip";;
        *) LLM_PROVIDER="$default_provider";;
    esac
    echo ""
}

_wizard_ollama_model() {
    # Determine recommended model marker
    local rec_idx=6
    case "${RECOMMENDED_MODEL:-}" in
        *4b*)  rec_idx=1;;
        *7b*)  rec_idx=2;;
        *14b*) rec_idx=6;;
        *32b*) rec_idx=10;;
        *72b*) rec_idx=13;;
    esac

    echo "Select LLM model:"
    echo ""
    echo " -- 4-8B [fast, 8GB+ RAM, 6GB+ VRAM] --"
    echo "  1) gemma3:4b$([ "$rec_idx" -eq 1 ] && echo '  [recommended]')"
    echo "  2) qwen2.5:7b$([ "$rec_idx" -eq 2 ] && echo '  [recommended]')"
    echo "  3) qwen3:8b"
    echo "  4) llama3.1:8b"
    echo "  5) mistral:7b"
    echo ""
    echo " -- 12-14B [balanced, 16GB+ RAM, 10GB+ VRAM] --"
    echo "  6) qwen2.5:14b$([ "$rec_idx" -eq 6 ] && echo '  [recommended]')"
    echo "  7) phi-4:14b"
    echo "  8) mistral-nemo:12b"
    echo "  9) gemma3:12b"
    echo ""
    echo " -- 27-32B [quality, 32GB+ RAM, 16GB+ VRAM] --"
    echo "  10) qwen2.5:32b$([ "$rec_idx" -eq 10 ] && echo '  [recommended]')"
    echo "  11) gemma3:27b"
    echo "  12) command-r:35b"
    echo ""
    echo " -- 60B+ [max quality, 64GB+ RAM, 24GB+ VRAM] --"
    echo "  13) qwen2.5:72b-instruct-q4_K_M$([ "$rec_idx" -eq 13 ] && echo '  [recommended]')"
    echo "  14) llama3.1:70b-instruct-q4_K_M"
    echo "  15) qwen3:32b"
    echo ""
    echo " -- Custom --"
    echo "  16) Enter manually (Ollama registry name)"
    echo ""

    _ask_choice "Model [1-16, Enter=6]: " 1 16 6
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
        _ask "Model name:" "qwen2.5:14b"
        LLM_MODEL="$REPLY"
        validate_model_name "$LLM_MODEL" || { LLM_MODEL="qwen2.5:14b"; log_warn "Invalid model name, using default"; }
    fi
    echo ""
}

_wizard_vllm_model() {
    echo "Select vLLM model:"
    echo ""
    echo " -- 7-8B [14GB+ VRAM] --"
    echo "  1) Qwen/Qwen2.5-7B-Instruct"
    echo "  2) mistralai/Mistral-7B-Instruct-v0.3"
    echo "  3) meta-llama/Llama-3.1-8B-Instruct  (requires HF_TOKEN)"
    echo ""
    echo " -- 14B [24GB+ VRAM] --"
    echo "  4) Qwen/Qwen2.5-14B-Instruct           [recommended]"
    echo "  5) Qwen/Qwen3-14B"
    echo "  6) microsoft/phi-4"
    echo ""
    echo " -- 32B+ [48GB+ VRAM] --"
    echo "  7) Qwen/Qwen2.5-32B-Instruct"
    echo "  8) meta-llama/Llama-3.3-70B-Instruct  (requires HF_TOKEN)"
    echo ""
    echo " -- Custom --"
    echo "  9) Enter HuggingFace repo (org/model-name)"
    echo ""

    _ask_choice "Model [1-9, Enter=4]: " 1 9 4
    local vllm_models=(
        ""  # 0 placeholder
        "Qwen/Qwen2.5-7B-Instruct"
        "mistralai/Mistral-7B-Instruct-v0.3"
        "meta-llama/Llama-3.1-8B-Instruct"
        "Qwen/Qwen2.5-14B-Instruct"
        "Qwen/Qwen3-14B"
        "microsoft/phi-4"
        "Qwen/Qwen2.5-32B-Instruct"
        "meta-llama/Llama-3.3-70B-Instruct"
    )
    if [[ "$REPLY" -ge 1 && "$REPLY" -le 8 ]]; then
        VLLM_MODEL="${vllm_models[$REPLY]}"
    elif [[ "$REPLY" -eq 9 ]]; then
        _ask "HuggingFace repo (org/model):" "Qwen/Qwen2.5-14B-Instruct"
        VLLM_MODEL="${REPLY:-Qwen/Qwen2.5-14B-Instruct}"
    fi
    echo ""
}

_wizard_llm_model() {
    # Already set via env
    if [[ -n "$LLM_MODEL" || -n "$VLLM_MODEL" ]]; then
        return 0
    fi

    case "$LLM_PROVIDER" in
        ollama)   _wizard_ollama_model;;
        vllm)     _wizard_vllm_model;;
        # external/skip: no model selection needed
    esac

    # Apply non-interactive defaults if still empty
    if [[ "$LLM_PROVIDER" == "ollama" && -z "$LLM_MODEL" ]]; then
        LLM_MODEL="${RECOMMENDED_MODEL:-qwen2.5:14b}"
        validate_model_name "$LLM_MODEL" || LLM_MODEL="qwen2.5:14b"
    fi
    if [[ "$LLM_PROVIDER" == "vllm" && -z "$VLLM_MODEL" ]]; then
        VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct"
    fi
}

_wizard_embed_provider() {
    # Already set via env
    if [[ -n "$EMBED_PROVIDER" ]]; then
        return 0
    fi

    echo "Select Embedding provider:"
    echo "  1) Same as LLM"
    echo "  2) TEI (Text Embeddings Inference)"
    echo "  3) External API"
    echo "  4) Skip"
    echo ""

    _ask_choice "Choice [1-4, Enter=1]: " 1 4 1
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

_wizard_embed_model() {
    if [[ "$EMBED_PROVIDER" != "ollama" ]]; then
        return 0
    fi

    _ask "Embedding model [bge-m3]:" "bge-m3"
    EMBEDDING_MODEL="${REPLY:-bge-m3}"
    validate_model_name "$EMBEDDING_MODEL" || { EMBEDDING_MODEL="bge-m3"; log_warn "Invalid embedding model, using default"; }
    echo ""
}

_wizard_hf_token() {
    if [[ "$LLM_PROVIDER" != "vllm" && "$EMBED_PROVIDER" != "tei" ]]; then
        return 0
    fi
    if [[ -n "$HF_TOKEN" ]]; then
        return 0
    fi

    _ask "HuggingFace token (Enter to skip):" ""
    HF_TOKEN="$REPLY"
}

_wizard_offline_warning() {
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        return 0
    fi

    log_warn "Offline profile: models will NOT be downloaded."
    if [[ "$LLM_PROVIDER" == "ollama" || "$EMBED_PROVIDER" == "ollama" ]]; then
        echo "  Ensure models are pre-loaded in ollama_data volume."
    fi
    if [[ "$LLM_PROVIDER" == "vllm" ]]; then
        echo "  Ensure vLLM image and model ${VLLM_MODEL:-} are pre-loaded."
    fi
    if [[ "$EMBED_PROVIDER" == "tei" ]]; then
        echo "  Ensure TEI image and BAAI/bge-m3 model are pre-loaded."
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

    echo "TLS (HTTPS) setup:"
    echo "  1) No TLS (default)"
    echo "  2) Self-signed certificate"
    echo "  3) Custom certificate (provide paths)"
    echo ""

    _ask_choice "TLS [1-3, Enter=1]: " 1 3 1
    case "$REPLY" in
        2) TLS_MODE="self-signed";;
        3)
            TLS_MODE="custom"
            _ask "Certificate path (.pem):" ""
            TLS_CERT_PATH="$(validate_path "$REPLY" 2>/dev/null)" || {
                log_error "Invalid cert path, TLS disabled"
                TLS_MODE="none"; TLS_CERT_PATH=""
            }
            _ask "Key path (.pem):" ""
            TLS_KEY_PATH="$(validate_path "$REPLY" 2>/dev/null)" || {
                log_error "Invalid key path, TLS disabled"
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

    echo "Monitoring:"
    echo "  1) Disabled (default)"
    echo "  2) Local (Grafana + Portainer + Prometheus)"
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        echo "  3) External (endpoint + token)"
    fi
    echo ""

    local max_choice=2
    [[ "$DEPLOY_PROFILE" != "offline" ]] && max_choice=3

    _ask_choice "Monitoring [1-${max_choice}, Enter=1]: " 1 "$max_choice" 1
    case "$REPLY" in
        2) MONITORING_MODE="local";;
        3)
            if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
                MONITORING_MODE="external"
                _ask "Endpoint (URL):" ""
                MONITORING_ENDPOINT="$REPLY"
                validate_url "$MONITORING_ENDPOINT" || {
                    log_error "Invalid URL, monitoring disabled"
                    MONITORING_MODE="none"; MONITORING_ENDPOINT=""
                }
                _ask "Token:" ""
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

    echo "Alerts on failures:"
    echo "  1) Disabled (default)"
    echo "  2) Webhook (URL)"
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        echo "  3) Telegram bot"
    fi
    echo ""

    local max_choice=2
    [[ "$DEPLOY_PROFILE" != "offline" ]] && max_choice=3

    _ask_choice "Alerts [1-${max_choice}, Enter=1]: " 1 "$max_choice" 1
    case "$REPLY" in
        2)
            ALERT_MODE="webhook"
            _ask "Webhook URL:" ""
            ALERT_WEBHOOK_URL="$REPLY"
            validate_url "$ALERT_WEBHOOK_URL" || {
                log_error "Invalid URL, alerts disabled"
                ALERT_MODE="none"; ALERT_WEBHOOK_URL=""
            }
            ;;
        3)
            if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
                ALERT_MODE="telegram"
                _ask "Telegram Bot Token:" ""
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
        echo "  UFW firewall will be configured automatically (VPS)"
        ENABLE_UFW="true"
    else
        echo "Security:"
        echo "  1) Configure UFW firewall"
        echo "  2) Skip (default)"
        echo ""
        _ask_choice "UFW [1-2, Enter=2]: " 1 2 2
        [[ "$REPLY" == "1" ]] && ENABLE_UFW="true" || ENABLE_UFW="${ENABLE_UFW:-false}"
    fi

    # Fail2ban (SSH jail only)
    echo "  Fail2ban (SSH brute-force protection):"
    echo "  1) Enable"
    echo "  2) Skip (default)"
    echo ""
    _ask_choice "Fail2ban [1-2, Enter=2]: " 1 2 2
    [[ "$REPLY" == "1" ]] && ENABLE_FAIL2BAN="true" || ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-false}"
    echo ""

    # Authelia 2FA (VPS only)
    if [[ "$DEPLOY_PROFILE" == "vps" ]]; then
        echo "Enable Authelia 2FA (two-factor authentication)?"
        echo "  1) No (default)"
        echo "  2) Yes"
        _ask_choice "Choice [1-2, Enter=1]: " 1 2 1
        if [[ "$REPLY" == "2" ]]; then
            ENABLE_AUTHELIA="true"
        fi
    fi
}

_wizard_tunnel() {
    if [[ "$DEPLOY_PROFILE" != "lan" && "$DEPLOY_PROFILE" != "vpn" ]]; then
        return 0
    fi

    echo "Reverse SSH tunnel (access LAN node via VPS)?"
    echo "  1) No (default)"
    echo "  2) Yes"
    echo ""
    _ask_choice "Tunnel [1-2, Enter=1]: " 1 2 1
    if [[ "$REPLY" == "2" ]]; then
        ENABLE_TUNNEL="true"
        _ask "VPS host:" ""
        TUNNEL_VPS_HOST="$REPLY"
        validate_hostname "$TUNNEL_VPS_HOST" || { log_warn "Invalid host, tunnel disabled"; ENABLE_TUNNEL="false"; return 0; }
        _ask "VPS SSH port [22]:" "22"
        TUNNEL_VPS_PORT="${REPLY:-22}"
        _ask "Remote port for web [8080]:" "8080"
        TUNNEL_REMOTE_PORT="${REPLY:-8080}"
    fi
    echo ""
}

_wizard_backups() {
    echo "Backup configuration:"
    echo "  1) Local (/var/backups/agmind/)"
    echo "  2) Remote (SCP/rsync)"
    echo "  3) Both"
    echo ""

    _ask_choice "Backup target [1-3, Enter=1]: " 1 3 1
    case "$REPLY" in
        1) BACKUP_TARGET="local";;
        2) BACKUP_TARGET="remote";;
        3) BACKUP_TARGET="both";;
    esac
    echo ""

    echo "Backup schedule:"
    echo "  1) Daily at 03:00 (default)"
    echo "  2) Every 12 hours (03:00 and 15:00)"
    echo "  3) Custom cron expression"
    echo ""

    _ask_choice "Schedule [1-3, Enter=1]: " 1 3 1
    case "$REPLY" in
        2) BACKUP_SCHEDULE="0 3,15 * * *";;
        3)
            _ask "Cron expression:" "0 3 * * *"
            BACKUP_SCHEDULE="$REPLY"
            validate_cron "$BACKUP_SCHEDULE" || {
                log_warn "Invalid cron expression, using default"
                BACKUP_SCHEDULE="0 3 * * *"
            }
            ;;
        *) BACKUP_SCHEDULE="0 3 * * *";;
    esac
    echo ""

    # Remote backup details
    if [[ "$BACKUP_TARGET" != "local" ]]; then
        _ask "SSH host for backups:" ""
        REMOTE_BACKUP_HOST="$REPLY"
        validate_hostname "$REMOTE_BACKUP_HOST" || {
            log_error "Invalid host, falling back to local"
            BACKUP_TARGET="local"
            return 0
        }
        _ask "SSH port [22]:" "22"
        REMOTE_BACKUP_PORT="${REPLY:-22}"
        validate_port "$REMOTE_BACKUP_PORT" || { REMOTE_BACKUP_PORT="22"; log_warn "Using default port 22"; }
        _ask "SSH user:" ""
        REMOTE_BACKUP_USER="$REPLY"
        _ask "SSH key path (Enter to auto-generate):" ""
        REMOTE_BACKUP_KEY="$REPLY"
        echo ""
    fi
}

_wizard_summary() {
    echo -e "${CYAN}=== Installation Summary ===${NC}"
    echo "  Profile:      ${DEPLOY_PROFILE}"
    [[ -n "$DOMAIN" ]] && echo "  Domain:       ${DOMAIN}"
    echo "  Vector DB:    ${VECTOR_STORE}"
    [[ "$ETL_ENHANCED" == "true" ]] && echo "  ETL:          Docling + Xinference"
    echo "  LLM:          ${LLM_PROVIDER} ${LLM_MODEL}${VLLM_MODEL:+ (${VLLM_MODEL})}"
    echo "  Embedding:    ${EMBED_PROVIDER} ${EMBEDDING_MODEL}"
    [[ "$TLS_MODE" != "none" ]] && echo "  TLS:          ${TLS_MODE}"
    [[ "$MONITORING_MODE" != "none" ]] && echo "  Monitoring:   ${MONITORING_MODE}"
    [[ "$ALERT_MODE" != "none" ]] && echo "  Alerts:       ${ALERT_MODE}"
    [[ "$ENABLE_UFW" == "true" ]] && echo "  UFW:          enabled"
    [[ "$ENABLE_FAIL2BAN" == "true" ]] && echo "  Fail2ban:     SSH jail"
    [[ "$ENABLE_AUTHELIA" == "true" ]] && echo "  Authelia:     2FA enabled"
    [[ "$ENABLE_TUNNEL" == "true" ]] && echo "  Tunnel:       ${TUNNEL_VPS_HOST}:${TUNNEL_REMOTE_PORT}"
    echo "  Backup:       ${BACKUP_TARGET} (${BACKUP_SCHEDULE})"
    echo ""
}

_wizard_confirm() {
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return 0
    fi
    _ask "Start installation? (yes/no):" "no"
    if [[ "$REPLY" != "yes" ]]; then
        echo "Cancelled."
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
    _wizard_embed_model
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
    export DEPLOY_PROFILE DOMAIN CERTBOT_EMAIL VECTOR_STORE ETL_ENHANCED
    export LLM_PROVIDER LLM_MODEL VLLM_MODEL EMBED_PROVIDER EMBEDDING_MODEL
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
