#!/usr/bin/env bash
# ============================================================================
# AGMind Installer v2.0
# Full RAG stack: Dify + Open WebUI + Ollama + Weaviate + PostgreSQL + Redis
# Usage: curl -sSL https://install.aillmsystems.com | bash
# ============================================================================
set -euo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# --- Constants ---
VERSION="2.0.0"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${BASH_SOURCE[0]:-}" || ! -f "${INSTALLER_DIR}/lib/detect.sh" ]]; then
    echo -e "\033[0;31mОшибка: запустите инсталлер из директории проекта: bash install.sh\033[0m"
    echo "  git clone https://github.com/... && cd agmind-installer && sudo bash install.sh"
    exit 1
fi
INSTALL_DIR="/opt/agmind"
TEMPLATE_DIR="${INSTALLER_DIR}/templates"

# --- Colors (defined early — used by cleanup trap) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Exclusive lock — prevent parallel install
LOCK_FILE="/var/lock/agmind-install.lock"
if [[ -L "$LOCK_FILE" ]]; then
    echo "ERROR: Lock file is a symlink, aborting for security" >&2
    exit 1
fi
if [[ "$(uname)" == "Darwin" ]]; then
    LOCK_DIR="/tmp/agmind-install.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo -e "${RED}Another install is running${NC}"
        exit 1
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
else
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo -e "${RED}Другой процесс установки уже запущен. Дождитесь завершения.${NC}"
        exit 1
    fi
fi

# Cleanup on failure
cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo -e "${RED}Установка прервана (код: ${exit_code}).${NC}"
        echo -e "${YELLOW}Частично созданные файлы могут остаться в ${INSTALL_DIR}${NC}"
        echo -e "${YELLOW}Для очистки: rm -rf ${INSTALL_DIR}${NC}"
        if [[ -f "${INSTALL_DIR}/.install_phase" ]]; then
            local failed_phase
            failed_phase=$(cat "${INSTALL_DIR}/.install_phase" 2>/dev/null)
            echo -e "${YELLOW}Установка прервана на фазе ${failed_phase}/9. Перезапустите: sudo bash install.sh${NC}"
        fi
    fi
}
if [[ "$(uname)" == "Darwin" ]]; then
    trap 'cleanup_on_failure; rmdir "$LOCK_DIR" 2>/dev/null' EXIT
else
    trap cleanup_on_failure EXIT
fi

# --- Source library modules ---
source "${INSTALLER_DIR}/lib/detect.sh"
source "${INSTALLER_DIR}/lib/docker.sh"
source "${INSTALLER_DIR}/lib/config.sh"
source "${INSTALLER_DIR}/lib/models.sh"
source "${INSTALLER_DIR}/lib/backup.sh"
source "${INSTALLER_DIR}/lib/health.sh"
source "${INSTALLER_DIR}/lib/security.sh"
source "${INSTALLER_DIR}/lib/authelia.sh"

# --- Global state ---
DEPLOY_PROFILE=""
DOMAIN=""
CERTBOT_EMAIL=""
LOGO_PATH=""
LLM_MODEL=""
EMBEDDING_MODEL="bge-m3"
BACKUP_TARGET=""
BACKUP_SCHEDULE=""
REMOTE_BACKUP_HOST=""
REMOTE_BACKUP_PORT="22"
REMOTE_BACKUP_USER=""
REMOTE_BACKUP_KEY=""
REMOTE_BACKUP_PATH="/var/backups/agmind-remote"
VECTOR_STORE="weaviate"
ETL_ENHANCED="no"
TLS_MODE="none"
TLS_CERT_PATH=""
TLS_KEY_PATH=""
MONITORING_MODE="none"
MONITORING_ENDPOINT=""
MONITORING_TOKEN=""
ALERT_MODE="none"
ALERT_WEBHOOK_URL=""
ALERT_TELEGRAM_TOKEN=""
ALERT_TELEGRAM_CHAT_ID=""
NON_INTERACTIVE=false
FORCE_RESTART=false
ADMIN_UI_OPEN=false

# Timeout defaults (seconds) — overridable via env vars
TIMEOUT_START="${TIMEOUT_START:-300}"
TIMEOUT_HEALTH="${TIMEOUT_HEALTH:-300}"
TIMEOUT_MODELS="${TIMEOUT_MODELS:-1200}"
ENABLE_UFW="false"

# --- Input validation functions ---
validate_model_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9._:/-]+$ ]] || { echo -e "${RED}Invalid model name. Allowed: letters, digits, . _ : / -${NC}"; return 1; }
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || { echo -e "${RED}Invalid domain name${NC}"; return 1; }
}

validate_email() {
    [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { echo -e "${RED}Invalid email format${NC}"; return 1; }
}

validate_cron() {
    [[ "$1" =~ ^[0-9*,/-]+\ [0-9*,/-]+\ [0-9*,/-]+\ [0-9*,/-]+\ [0-9*,/-]+$ ]] || return 1
}

validate_url() {
    [[ "$1" =~ ^https?://[a-zA-Z0-9._:/-]+$ ]] || { echo -e "${RED}Invalid URL format${NC}"; return 1; }
}

validate_path() {
    local p
    p="$(realpath "$1" 2>/dev/null)" || { echo -e "${RED}Invalid path${NC}"; return 1; }
    [[ "$p" == /tmp/* || "$p" == /home/* || "$p" == /root/* || "$p" == /etc/ssl/* || "$p" == /opt/* ]] || { echo -e "${RED}Path must be in /tmp, /home, /root, /etc/ssl, or /opt${NC}"; return 1; }
    echo "$p"
}

validate_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || { echo -e "${RED}Invalid hostname${NC}"; return 1; }
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]] || { echo -e "${RED}Invalid port number${NC}"; return 1; }
}
ENABLE_FAIL2BAN="false"
ENABLE_SOPS="false"
ENABLE_SECRET_ROTATION="false"
ENABLE_AUTHELIA="false"

# ============================================================================
# BANNER
# ============================================================================
show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "    _    ____ __  __ _           _ "
    echo "   / \  / ___|  \/  (_)_ __   __| |"
    echo "  / _ \| |  _| |\/| | | '_ \ / _\` |"
    echo " / ___ \ |_| | |  | | | | | | (_| |"
    echo "/_/   \_\____|_|  |_|_|_| |_|\__,_|"
    echo ""
    echo -e "${NC}${BOLD}  RAG Stack Installer v${VERSION}${NC}"
    echo "  Dify + Open WebUI + Ollama"
    echo ""
}

# ============================================================================
# PHASE 1: Diagnostics
# ============================================================================
phase_diagnostics() {
    echo ""
    run_diagnostics || {
        echo ""
        echo -e "${RED}Система не соответствует минимальным требованиям.${NC}"
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Продолжить всё равно? (yes/no): " FORCE
            if [[ "$FORCE" != "yes" ]]; then
                exit 1
            fi
        else
            echo -e "${YELLOW}Non-interactive: продолжаем несмотря на предупреждения${NC}"
        fi
    }
    echo ""

    # Pre-flight checks (Section 6)
    preflight_checks || {
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Есть критические ошибки. Продолжить? (yes/no): " FORCE
            if [[ "$FORCE" != "yes" ]]; then
                exit 1
            fi
        else
            echo -e "${YELLOW}Non-interactive: продолжаем несмотря на ошибки pre-flight${NC}"
        fi
    }
}

# ============================================================================
# PHASE 2: Interactive Wizard
# ============================================================================
phase_wizard() {
    echo ""

    # --- Profile ---
    echo "Выберите режим деплоя:"
    echo "  1) VPS     — публичный доступ через домен (есть интернет, есть домен)"
    echo "  2) LAN     — локальная сеть офиса (есть интернет, нет домена)"
    echo "  3) VPN     — корпоративный VPN (доступ только через VPN)"
    echo "  4) Offline — замкнутая сеть (без интернета)"
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        while true; do
            read -rp "Профиль [1-4]: " choice
            case "$choice" in
                1) DEPLOY_PROFILE="vps"; break;;
                2) DEPLOY_PROFILE="lan"; break;;
                3) DEPLOY_PROFILE="vpn"; break;;
                4) DEPLOY_PROFILE="offline"; break;;
                *) echo "Введите число от 1 до 4";;
            esac
        done
    else
        DEPLOY_PROFILE="${DEPLOY_PROFILE:-lan}"
    fi

    # --- Security defaults per profile (override with DISABLE_SECURITY_DEFAULTS=true) ---
    if [[ "${DISABLE_SECURITY_DEFAULTS:-false}" != "true" ]]; then
        case "$DEPLOY_PROFILE" in
            vps)
                ENABLE_UFW="${ENABLE_UFW:-true}"
                ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
                ENABLE_SOPS="${ENABLE_SOPS:-true}"
                ;;
            lan|vpn)
                ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
                ;;
        esac
    fi
    echo ""

    # --- Admin UI access (Portainer/Grafana) ---
    if [[ "$DEPLOY_PROFILE" != "vps" ]]; then
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            echo "Portainer и Grafana доступны только с localhost (127.0.0.1)."
            read -rp "Открыть доступ из локальной сети? [no/yes] (default: no): " admin_ui_choice
            admin_ui_choice="${admin_ui_choice:-no}"
        else
            admin_ui_choice="${ADMIN_UI_BIND_ADDR:+yes}"
            admin_ui_choice="${admin_ui_choice:-no}"
        fi
        if [[ "$admin_ui_choice" == "yes" ]]; then
            ADMIN_UI_OPEN=true
        else
            ADMIN_UI_OPEN=false
        fi
        echo ""
    else
        ADMIN_UI_OPEN=false
    fi

    # --- Domain (VPS only) ---
    if [[ "$DEPLOY_PROFILE" == "vps" ]]; then
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Домен для доступа: " DOMAIN
            validate_domain "$DOMAIN" || { echo -e "${RED}Некорректный домен, установка прервана${NC}"; exit 1; }
            read -rp "Email для сертификата: " CERTBOT_EMAIL
            validate_email "$CERTBOT_EMAIL" || { echo -e "${RED}Некорректный email, установка прервана${NC}"; exit 1; }
        fi
        echo ""
    fi

    # --- Vector Store ---
    echo "Выберите векторное хранилище:"
    echo "  1) Weaviate  — стабильный, проверенный (по умолчанию)"
    echo "  2) Qdrant    — быстрый, REST/gRPC API"
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Выбор [1-2, Enter=1]: " choice
        choice="${choice:-1}"
    else
        choice="${VECTOR_STORE_CHOICE:-1}"
    fi
    case "$choice" in
        2) VECTOR_STORE="qdrant";;
        *) VECTOR_STORE="weaviate";;
    esac
    echo ""

    # --- ETL Enhancement (not for offline) ---
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        echo "Расширенная обработка документов (Docling + Xinference reranker)?"
        echo "  1) Нет — стандартный ETL Dify (по умолчанию)"
        echo "  2) Да — Docling + bce-reranker-base_v1"
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Выбор [1-2, Enter=1]: " choice
            choice="${choice:-1}"
        else
            choice="${ETL_ENHANCED_CHOICE:-1}"
        fi
        case "$choice" in
            2) ETL_ENHANCED="yes";;
            *) ETL_ENHANCED="no";;
        esac
        echo ""
    fi

    # --- LLM Provider ---
    local default_llm_provider="vllm"
    local default_llm_idx=2
    local gpu_warning=""
    if [[ "${DETECTED_GPU:-none}" != "nvidia" ]]; then
        default_llm_provider="ollama"
        default_llm_idx=1
        gpu_warning="  (GPU NVIDIA не обнаружен — умолчание: Ollama)"
    fi

    echo "Выберите LLM провайдер:${gpu_warning}"
    echo "  1) Ollama"
    echo "  2) vLLM"
    echo "  3) External API"
    echo "  4) Skip"
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Выбор [1-4, Enter=${default_llm_idx}]: " choice
        choice="${choice:-${default_llm_idx}}"
    else
        case "${LLM_PROVIDER:-$default_llm_provider}" in
            ollama)   choice=1;; vllm) choice=2;; external) choice=3;; skip) choice=4;; *) choice="${default_llm_idx}";;
        esac
    fi
    case "$choice" in
        1) LLM_PROVIDER="ollama";;
        2) LLM_PROVIDER="vllm";;
        3) LLM_PROVIDER="external";;
        4) LLM_PROVIDER="skip";;
        *) LLM_PROVIDER="$default_llm_provider";;
    esac
    echo ""

    # --- LLM Model (provider-dependent) ---
    if [[ "$LLM_PROVIDER" == "ollama" ]]; then
        # Determine recommended model marker (rec_idx = menu item number)
        local rec_idx=6  # default: qwen2.5:14b (item 6)
        if [[ "${RECOMMENDED_MODEL:-}" == "gemma3:4b" ]]; then
            rec_idx=1
        elif [[ "${RECOMMENDED_MODEL:-}" == "qwen2.5:7b" ]]; then
            rec_idx=2
        elif [[ "${RECOMMENDED_MODEL:-}" == "qwen2.5:32b" ]]; then
            rec_idx=10
        elif [[ "${RECOMMENDED_MODEL:-}" == "qwen2.5:72b-instruct-q4_K_M" ]]; then
            rec_idx=13
        fi

        echo "Выберите LLM модель:"
        echo ""
        echo " ── 4-8B [быстро, 8GB+ RAM, 6GB+ VRAM] ──"
        echo "  1) gemma3:4b            — компактная, Google$([ $rec_idx -eq 1 ] && echo '  [рекомендуется]')"
        echo "  2) qwen2.5:7b           — быстрая, Alibaba$([ $rec_idx -eq 2 ] && echo '  [рекомендуется]')"
        echo "  3) qwen3:8b             — нов. поколение, Alibaba"
        echo "  4) llama3.1:8b          — универсальная, Meta"
        echo "  5) mistral:7b           — европейская, Mistral"
        echo ""
        echo " ── 12-14B [баланс, 16GB+ RAM, 10GB+ VRAM] ──"
        echo "  6) qwen2.5:14b          — сбалансированная, Alibaba$([ $rec_idx -eq 6 ] && echo '  [рекомендуется]')"
        echo "  7) phi-4:14b            — Microsoft"
        echo "  8) mistral-nemo:12b     — компактная, Mistral"
        echo "  9) gemma3:12b           — средняя, Google"
        echo ""
        echo " ── 27-32B [качество, 32GB+ RAM, 16GB+ VRAM] ──"
        echo "  10) qwen2.5:32b         — качественная, Alibaba$([ $rec_idx -eq 10 ] && echo '  [рекомендуется]')"
        echo "  11) gemma3:27b          — большая, Google"
        echo "  12) command-r:35b       — RAG-оптимизированная, Cohere"
        echo ""
        echo " ── 60B+ [макс. качество, 64GB+ RAM, 24GB+ VRAM] ──"
        echo "  13) qwen2.5:72b-instruct-q4_K_M  — топ, квантизация$([ $rec_idx -eq 13 ] && echo '  [рекомендуется]')"
        echo "  14) llama3.1:70b-instruct-q4_K_M  — Meta, квантизация"
        echo "  15) qwen3:32b           — нов. поколение, Alibaba"
        echo ""
        echo " ── Своя модель ──"
        echo "  16) Указать вручную (название из Ollama registry)"
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            while true; do
                read -rp "Модель [1-16, Enter=6]: " choice
                choice="${choice:-6}"
                case "$choice" in
                    1)  LLM_MODEL="gemma3:4b"; break;;
                    2)  LLM_MODEL="qwen2.5:7b"; break;;
                    3)  LLM_MODEL="qwen3:8b"; break;;
                    4)  LLM_MODEL="llama3.1:8b"; break;;
                    5)  LLM_MODEL="mistral:7b"; break;;
                    6)  LLM_MODEL="qwen2.5:14b"; break;;
                    7)  LLM_MODEL="phi-4:14b"; break;;
                    8)  LLM_MODEL="mistral-nemo:12b"; break;;
                    9)  LLM_MODEL="gemma3:12b"; break;;
                    10) LLM_MODEL="qwen2.5:32b"; break;;
                    11) LLM_MODEL="gemma3:27b"; break;;
                    12) LLM_MODEL="command-r:35b"; break;;
                    13) LLM_MODEL="qwen2.5:72b-instruct-q4_K_M"; break;;
                    14) LLM_MODEL="llama3.1:70b-instruct-q4_K_M"; break;;
                    15) LLM_MODEL="qwen3:32b"; break;;
                    16) read -rp "Название модели: " LLM_MODEL
                        validate_model_name "$LLM_MODEL" || { LLM_MODEL="qwen2.5:14b"; echo "Using default model"; }
                        break;;
                    *)  echo "Введите число от 1 до 16";;
                esac
            done
        else
            LLM_MODEL="${LLM_MODEL:-qwen2.5:14b}"
            validate_model_name "$LLM_MODEL" || { LLM_MODEL="qwen2.5:14b"; echo "Invalid LLM_MODEL, using default"; }
        fi
        echo ""
    elif [[ "$LLM_PROVIDER" == "vllm" ]]; then
        echo "Выберите модель для vLLM:"
        echo ""
        echo " ── 7-8B [14GB+ VRAM] ──"
        echo "  1) Qwen/Qwen2.5-7B-Instruct"
        echo "  2) mistralai/Mistral-7B-Instruct-v0.3"
        echo "  3) meta-llama/Llama-3.1-8B-Instruct  (требует HF_TOKEN)"
        echo ""
        echo " ── 14B [24GB+ VRAM] ──"
        echo "  4) Qwen/Qwen2.5-14B-Instruct           [рекомендуется]"
        echo "  5) Qwen/Qwen3-14B"
        echo "  6) microsoft/phi-4"
        echo ""
        echo " ── 32B+ [48GB+ VRAM] ──"
        echo "  7) Qwen/Qwen2.5-32B-Instruct"
        echo "  8) meta-llama/Llama-3.3-70B-Instruct  (требует HF_TOKEN)"
        echo ""
        echo " ── Своя модель ──"
        echo "  9) Указать HuggingFace repo (org/model-name)"
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Модель [1-9, Enter=4]: " choice
            choice="${choice:-4}"
            case "$choice" in
                1) VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct";;
                2) VLLM_MODEL="mistralai/Mistral-7B-Instruct-v0.3";;
                3) VLLM_MODEL="meta-llama/Llama-3.1-8B-Instruct";;
                4) VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct";;
                5) VLLM_MODEL="Qwen/Qwen3-14B";;
                6) VLLM_MODEL="microsoft/phi-4";;
                7) VLLM_MODEL="Qwen/Qwen2.5-32B-Instruct";;
                8) VLLM_MODEL="meta-llama/Llama-3.3-70B-Instruct";;
                9) read -rp "HuggingFace repo (org/model): " VLLM_MODEL
                   [[ -z "$VLLM_MODEL" ]] && VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct";;
                *) VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct";;
            esac
        else
            VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct}"
        fi
        echo ""
    fi
    # external/skip: no model selection needed

    # --- Embedding Provider ---
    echo "Выберите Embedding провайдер:"
    echo "  1) Тот же, что LLM"
    echo "  2) TEI (Text Embeddings Inference)"
    echo "  3) External API"
    echo "  4) Skip"
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Выбор [1-4, Enter=1]: " choice
        choice="${choice:-1}"
    else
        case "${EMBED_PROVIDER:-same}" in
            same|"") choice=1;; tei) choice=2;; external) choice=3;; skip) choice=4;;
            ollama) choice=1;; # backwards compat
            *) choice=1;;
        esac
    fi
    case "$choice" in
        1) # "Same as LLM" mapping
           case "$LLM_PROVIDER" in
               ollama)   EMBED_PROVIDER="ollama";;
               vllm)     EMBED_PROVIDER="tei";;
               external) EMBED_PROVIDER="external";;
               skip)     EMBED_PROVIDER="skip";;
           esac
           ;;
        2) EMBED_PROVIDER="tei";;
        3) EMBED_PROVIDER="external";;
        4) EMBED_PROVIDER="skip";;
        *) EMBED_PROVIDER="ollama";;  # fallback
    esac
    echo ""

    # --- Embedding Model (only for Ollama provider) ---
    if [[ "$EMBED_PROVIDER" == "ollama" ]]; then
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Embedding модель [bge-m3]: " EMBEDDING_MODEL
            EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}"
            validate_model_name "$EMBEDDING_MODEL" || { EMBEDDING_MODEL="bge-m3"; echo "Using default embedding model"; }
        else
            EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}"
        fi
        echo ""
    fi

    # --- HuggingFace Token (optional, only for vLLM/TEI) ---
    HF_TOKEN="${HF_TOKEN:-}"
    if [[ "$LLM_PROVIDER" == "vllm" || "$EMBED_PROVIDER" == "tei" ]]; then
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "HuggingFace token (Enter для пропуска): " HF_TOKEN
            HF_TOKEN="${HF_TOKEN:-}"
        fi
    fi

    # --- Offline model warning ---
    if [[ "$DEPLOY_PROFILE" == "offline" ]]; then
        echo -e "${YELLOW}⚠ Профиль Offline: модели не будут скачиваться.${NC}"
        if [[ "$LLM_PROVIDER" == "ollama" || "$EMBED_PROVIDER" == "ollama" ]]; then
            echo "  Убедитесь, что модели предзагружены в ollama_data volume."
        fi
        if [[ "$LLM_PROVIDER" == "vllm" ]]; then
            echo "  Убедитесь, что образ vLLM и модель ${VLLM_MODEL:-} предзагружены."
        fi
        if [[ "$EMBED_PROVIDER" == "tei" ]]; then
            echo "  Убедитесь, что образ TEI и модель BAAI/bge-m3 предзагружены."
        fi
        echo ""
    fi

    # --- TLS (for lan/vpn only; vps=letsencrypt auto, offline=none) ---
    if [[ "$DEPLOY_PROFILE" == "lan" || "$DEPLOY_PROFILE" == "vpn" ]]; then
        echo "Настройка TLS (HTTPS):"
        echo "  1) Без TLS (по умолчанию)"
        echo "  2) Self-signed сертификат"
        echo "  3) Свой сертификат (указать путь)"
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "TLS [1-3, Enter=1]: " choice
            choice="${choice:-1}"
        else
            choice="${TLS_MODE_CHOICE:-1}"
        fi
        case "$choice" in
            2) TLS_MODE="self-signed";;
            3)
                TLS_MODE="custom"
                if [[ "$NON_INTERACTIVE" != "true" ]]; then
                    read -rp "Путь к сертификату (.pem): " TLS_CERT_PATH
                    read -rp "Путь к ключу (.pem): " TLS_KEY_PATH
                    if [[ -n "$TLS_CERT_PATH" ]]; then
                        TLS_CERT_PATH="$(realpath "$TLS_CERT_PATH" 2>/dev/null)" || { echo -e "${RED}Invalid cert path${NC}"; TLS_CERT_PATH=""; }
                        if [[ -n "$TLS_CERT_PATH" ]]; then
                            [[ "$TLS_CERT_PATH" == /tmp/* || "$TLS_CERT_PATH" == /home/* || "$TLS_CERT_PATH" == /root/* || "$TLS_CERT_PATH" == /etc/ssl/* || "$TLS_CERT_PATH" == /opt/* ]] || { echo -e "${RED}Cert must be in /tmp, /home, /root, /etc/ssl, or /opt${NC}"; TLS_CERT_PATH=""; }
                        fi
                    fi
                    if [[ -n "$TLS_KEY_PATH" ]]; then
                        TLS_KEY_PATH="$(realpath "$TLS_KEY_PATH" 2>/dev/null)" || { echo -e "${RED}Invalid key path${NC}"; TLS_KEY_PATH=""; }
                        if [[ -n "$TLS_KEY_PATH" ]]; then
                            [[ "$TLS_KEY_PATH" == /tmp/* || "$TLS_KEY_PATH" == /home/* || "$TLS_KEY_PATH" == /root/* || "$TLS_KEY_PATH" == /etc/ssl/* || "$TLS_KEY_PATH" == /opt/* ]] || { echo -e "${RED}Key must be in /tmp, /home, /root, /etc/ssl, or /opt${NC}"; TLS_KEY_PATH=""; }
                        fi
                    fi
                fi
                ;;
            *) TLS_MODE="none";;
        esac
        echo ""
    elif [[ "$DEPLOY_PROFILE" == "vps" ]]; then
        TLS_MODE="letsencrypt"
    fi

    # --- Monitoring ---
    echo "Мониторинг:"
    echo "  1) Отключен (по умолчанию)"
    echo "  2) Локальный (Grafana + Portainer + Prometheus)"
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        echo "  3) Внешний (endpoint + token)"
    fi
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Мониторинг [1-$([ "$DEPLOY_PROFILE" != "offline" ] && echo "3" || echo "2"), Enter=1]: " choice
        choice="${choice:-1}"
    else
        choice="${MONITORING_CHOICE:-1}"
    fi
    case "$choice" in
        2) MONITORING_MODE="local";;
        3)
            if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
                MONITORING_MODE="external"
                if [[ "$NON_INTERACTIVE" != "true" ]]; then
                    read -rp "Endpoint (URL): " MONITORING_ENDPOINT
                    validate_url "$MONITORING_ENDPOINT" || { echo -e "${RED}Некорректный URL, мониторинг отключён${NC}"; MONITORING_MODE="none"; MONITORING_ENDPOINT=""; }
                    read -rp "Token: " MONITORING_TOKEN
                fi
            fi
            ;;
        *) MONITORING_MODE="none";;
    esac
    echo ""

    # --- Alerts ---
    echo "Алерты при сбоях:"
    echo "  1) Отключены (по умолчанию)"
    echo "  2) Webhook (URL)"
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        echo "  3) Telegram бот"
    fi
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Алерты [1-$([ "$DEPLOY_PROFILE" != "offline" ] && echo "3" || echo "2"), Enter=1]: " choice
        choice="${choice:-1}"
    else
        choice="${ALERT_CHOICE:-1}"
    fi
    case "$choice" in
        2)
            ALERT_MODE="webhook"
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                read -rp "Webhook URL: " ALERT_WEBHOOK_URL
                validate_url "$ALERT_WEBHOOK_URL" || { echo -e "${RED}Некорректный URL, алерты отключены${NC}"; ALERT_MODE="none"; ALERT_WEBHOOK_URL=""; }
            fi
            ;;
        3)
            if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
                ALERT_MODE="telegram"
                if [[ "$NON_INTERACTIVE" != "true" ]]; then
                    read -rp "Telegram Bot Token: " ALERT_TELEGRAM_TOKEN
                    read -rp "Telegram Chat ID: " ALERT_TELEGRAM_CHAT_ID
                fi
            fi
            ;;
        *) ALERT_MODE="none";;
    esac
    echo ""

    # --- Security (not for offline) ---
    if [[ "$DEPLOY_PROFILE" != "offline" ]]; then
        echo "Безопасность:"
        if [[ "$DEPLOY_PROFILE" == "vps" ]]; then
            echo "  UFW файрвол будет настроен автоматически (VPS)"
            ENABLE_UFW="true"
        else
            echo "  1) Настроить UFW файрвол"
            echo "  2) Пропустить (по умолчанию)"
            echo ""
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                read -rp "UFW [1-2, Enter=2]: " choice
                choice="${choice:-2}"
            else
                choice="${ENABLE_UFW_CHOICE:-2}"
            fi
            [[ "$choice" == "1" ]] && ENABLE_UFW="true" || ENABLE_UFW="false"
        fi

        echo "  Fail2ban (защита от bruteforce):"
        echo "  1) Включить"
        echo "  2) Пропустить (по умолчанию)"
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Fail2ban [1-2, Enter=2]: " choice
            choice="${choice:-2}"
        else
            choice="${ENABLE_FAIL2BAN_CHOICE:-2}"
        fi
        [[ "$choice" == "1" ]] && ENABLE_FAIL2BAN="true" || ENABLE_FAIL2BAN="false"
        echo ""

        # --- Authelia 2FA ---
        if [[ "$DEPLOY_PROFILE" == "vps" ]]; then
            echo ""
            echo -e "${CYAN}Включить Authelia 2FA? (двухфакторная аутентификация)${NC}"
            echo "  1) Нет (по умолчанию)"
            echo "  2) Да"
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                read -rp "Выбор [1]: " auth_choice
                [[ "$auth_choice" == "2" ]] && ENABLE_AUTHELIA="true"
            else
                [[ "${ENABLE_AUTHELIA_CHOICE:-1}" == "2" ]] && ENABLE_AUTHELIA="true"
            fi
        fi
    fi

    # --- Backups ---
    echo "Настройка бэкапов:"
    echo "  1) Локально (/var/backups/agmind/)"
    echo "  2) Удалённо (SCP/rsync)"
    echo "  3) Оба варианта"
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        while true; do
            read -rp "Куда сохранять [1-3, Enter=1]: " choice
            choice="${choice:-1}"
            case "$choice" in
                1) BACKUP_TARGET="local"; break;;
                2) BACKUP_TARGET="remote"; break;;
                3) BACKUP_TARGET="both"; break;;
                *) echo "Введите число от 1 до 3";;
            esac
        done
    else
        BACKUP_TARGET="${BACKUP_TARGET:-local}"
    fi
    echo ""

    echo "Расписание бэкапов:"
    echo "  1) Ежедневно в 03:00 (по умолчанию)"
    echo "  2) Каждые 12 часов (03:00 и 15:00)"
    echo "  3) Своё (cron expression)"
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Расписание [1-3, Enter=1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            2) BACKUP_SCHEDULE="0 3,15 * * *";;
            3) read -rp "Cron expression: " BACKUP_SCHEDULE
               validate_cron "$BACKUP_SCHEDULE" || { echo -e "${YELLOW}Некорректный cron, используется значение по умолчанию${NC}"; BACKUP_SCHEDULE="0 3 * * *"; };;
            *) BACKUP_SCHEDULE="0 3 * * *";;
        esac
    else
        BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 3 * * *}"
    fi
    echo ""

    # Remote backup details
    if [[ "$BACKUP_TARGET" != "local" ]]; then
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "SSH хост для бэкапов: " REMOTE_BACKUP_HOST
            validate_hostname "$REMOTE_BACKUP_HOST" || { echo -e "${RED}Некорректный хост${NC}"; BACKUP_TARGET="local"; }
            read -rp "SSH порт [22]: " REMOTE_BACKUP_PORT
            REMOTE_BACKUP_PORT="${REMOTE_BACKUP_PORT:-22}"
            validate_port "$REMOTE_BACKUP_PORT" || { REMOTE_BACKUP_PORT="22"; echo "Using default port 22"; }
            read -rp "SSH пользователь: " REMOTE_BACKUP_USER
            read -rp "SSH ключ (путь, Enter для генерации): " REMOTE_BACKUP_KEY
        fi
        echo ""
    fi

    # --- Summary ---
    echo -e "${CYAN}=== Параметры установки ===${NC}"
    echo "  Профиль:      ${DEPLOY_PROFILE}"
    [[ -n "$DOMAIN" ]] && echo "  Домен:        ${DOMAIN}"
    echo "  Векторное БД: ${VECTOR_STORE}"
    [[ "$ETL_ENHANCED" == "yes" ]] && echo "  ETL:          Docling + Xinference"
    echo "  LLM:          ${LLM_MODEL}"
    echo "  Embedding:    ${EMBEDDING_MODEL}"
    [[ "$TLS_MODE" != "none" ]] && echo "  TLS:          ${TLS_MODE}"
    [[ "$MONITORING_MODE" != "none" ]] && echo "  Мониторинг:   ${MONITORING_MODE}"
    [[ "$ALERT_MODE" != "none" ]] && echo "  Алерты:       ${ALERT_MODE}"
    echo "  Бэкап:        ${BACKUP_TARGET} (${BACKUP_SCHEDULE})"
    echo ""

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Начать установку? (yes/no): " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]; then
            echo "Отменено."
            exit 0
        fi
    fi
    echo ""
}

# ============================================================================
# PHASE 3: Install Docker
# ============================================================================
phase_docker() {
    setup_docker
    echo ""
}

# ============================================================================
# PHASE 4: Generate Configuration
# ============================================================================
phase_config() {

    # FIRST: clean directory artifacts left by previous failed installs.
    # Must run BEFORE generate_config — otherwise cat/cp into a directory path fails.
    ensure_bind_mount_files

    # v1 → v2 migration: auto-inject provider variables if missing from existing .env
    if [[ -f "${INSTALL_DIR}/docker/.env" ]]; then
        local existing_env="${INSTALL_DIR}/docker/.env"
        if ! grep -q '^LLM_PROVIDER=' "$existing_env" 2>/dev/null; then
            echo -e "${YELLOW}v1 миграция: добавляю LLM_PROVIDER=ollama в .env${NC}"
            echo "LLM_PROVIDER=ollama" >> "$existing_env"
            LLM_PROVIDER="ollama"
        fi
        if ! grep -q '^EMBED_PROVIDER=' "$existing_env" 2>/dev/null; then
            echo -e "${YELLOW}v1 миграция: добавляю EMBED_PROVIDER=ollama в .env${NC}"
            echo "EMBED_PROVIDER=ollama" >> "$existing_env"
            EMBED_PROVIDER="ollama"
        fi
    fi

    # Export variables for config.sh
    export INSTALL_DIR
    export LLM_MODEL EMBEDDING_MODEL DOMAIN CERTBOT_EMAIL
    export DEPLOY_PROFILE VECTOR_STORE ETL_ENHANCED
    export TLS_MODE TLS_CERT_PATH TLS_KEY_PATH
    export MONITORING_MODE MONITORING_ENDPOINT
    MONITORING_TOKEN="${MONITORING_TOKEN:-}"
    export ALERT_MODE
    ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
    ALERT_TELEGRAM_TOKEN="${ALERT_TELEGRAM_TOKEN:-}"
    ALERT_TELEGRAM_CHAT_ID="${ALERT_TELEGRAM_CHAT_ID:-}"
    export ENABLE_UFW ENABLE_FAIL2BAN ENABLE_SOPS ENABLE_SECRET_ROTATION ENABLE_AUTHELIA

    generate_config "$DEPLOY_PROFILE" "$TEMPLATE_DIR"

    # Override admin UI bind address if user opted in
    if [[ "${ADMIN_UI_OPEN:-false}" == "true" ]]; then
        local env_file="${INSTALL_DIR}/docker/.env"
        local env_tmp="${env_file}.tmp.$$"
        sed \
            -e "s|GRAFANA_BIND_ADDR=127.0.0.1|GRAFANA_BIND_ADDR=0.0.0.0|g" \
            -e "s|PORTAINER_BIND_ADDR=127.0.0.1|PORTAINER_BIND_ADDR=0.0.0.0|g" \
            "$env_file" > "$env_tmp" && mv "$env_tmp" "$env_file" || rm -f "$env_tmp"
        chmod 600 "$env_file"
    fi

    # Ensure .admin_password has restrictive permissions
    if [[ -f "${INSTALL_DIR}/.admin_password" ]]; then
        chmod 600 "${INSTALL_DIR}/.admin_password"
    fi

    # SECOND: clean up after generate_config — copy_monitoring_files or other
    # functions inside generate_config may recreate directory artifacts.
    ensure_bind_mount_files

    enable_gpu_compose

    # Security hardening
    setup_security

    # Authelia 2FA
    [[ "$ENABLE_AUTHELIA" == "true" ]] && configure_authelia "$TEMPLATE_DIR"

    # Copy workflow files
    cp "${INSTALLER_DIR}/workflows/rag-assistant.json" "${INSTALL_DIR}/workflows/" 2>/dev/null || \
        cp "${INSTALLER_DIR}/references/rag-assistant-mvp-workflow.json" "${INSTALL_DIR}/workflows/rag-assistant.json"

    # Copy scripts
    cp "${INSTALLER_DIR}/scripts/backup.sh" "${INSTALL_DIR}/scripts/"
    cp "${INSTALLER_DIR}/scripts/restore.sh" "${INSTALL_DIR}/scripts/"
    cp "${INSTALLER_DIR}/scripts/uninstall.sh" "${INSTALL_DIR}/scripts/"
    cp "${INSTALLER_DIR}/scripts/update.sh" "${INSTALL_DIR}/scripts/"
    cp "${INSTALLER_DIR}/lib/health.sh" "${INSTALL_DIR}/scripts/health.sh"
    cp "${INSTALLER_DIR}/scripts/rotate_secrets.sh" "${INSTALL_DIR}/scripts/"
    cp "${INSTALLER_DIR}/scripts/multi-instance.sh" "${INSTALL_DIR}/scripts/"
    cp "${INSTALLER_DIR}/scripts/agmind.sh" "${INSTALL_DIR}/scripts/"
    cp "${INSTALLER_DIR}/scripts/health-gen.sh" "${INSTALL_DIR}/scripts/"
    cp "${INSTALLER_DIR}/lib/detect.sh" "${INSTALL_DIR}/scripts/detect.sh"
    chmod +x "${INSTALL_DIR}/scripts/"*.sh

    # Create initial health.json for nginx (prevents 404 before first cron tick)
    mkdir -p "${INSTALL_DIR}/docker/nginx"
    cat > "${INSTALL_DIR}/docker/nginx/health.json" <<ENDJSON
{
  "status": "starting",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "services": {"total": 0, "running": 0, "details": {}}
}
ENDJSON

    # Copy branding
    if [[ -n "$LOGO_PATH" && -f "$LOGO_PATH" ]]; then
        cp "$LOGO_PATH" "${INSTALL_DIR}/branding/logo.svg"
    else
        cp "${INSTALLER_DIR}/branding/logo.svg" "${INSTALL_DIR}/branding/"
    fi
    cp "${INSTALLER_DIR}/branding/theme.json" "${INSTALL_DIR}/branding/"

    # Create squid config for SSRF proxy
    create_squid_config

    echo ""
}

create_squid_config() {
    local squid_conf="${INSTALL_DIR}/docker/volumes/ssrf_proxy/squid.conf"
    safe_write_file "$squid_conf"
    cat > "$squid_conf" << 'SQUIDEOF'
# Restrict to Docker bridge networks only (not all RFC1918)
acl localnet src 172.16.0.0/12
acl localnet src 10.0.0.0/8

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 21
acl Safe_ports port 443
acl Safe_ports port 70
acl Safe_ports port 210
acl Safe_ports port 1025-65535
acl Safe_ports port 280
acl Safe_ports port 488
acl Safe_ports port 591
acl Safe_ports port 777

acl CONNECT method CONNECT

# SSRF protection: block cloud metadata and private networks
acl metadata dst 169.254.169.254
acl link_local dst 169.254.0.0/16
acl rfc1918_192 dst 192.168.0.0/16

http_access deny metadata
http_access deny link_local
http_access deny rfc1918_192

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost manager
http_access deny manager
http_access allow localhost
http_access allow localnet
http_access deny all

http_port 3128

coredump_dir /var/spool/squid

refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320

dns_nameservers 8.8.8.8 8.8.4.4
SQUIDEOF
}

# ============================================================================
# PHASE 5: Start Stack
# ============================================================================
phase_start() {
    cd "${INSTALL_DIR}/docker"

    # Build compose profiles dynamically
    local profiles=""
    [[ "$DEPLOY_PROFILE" == "vps" ]] && profiles="vps"
    [[ "$VECTOR_STORE" == "qdrant" ]] && profiles="${profiles:+$profiles,}qdrant"
    [[ "$VECTOR_STORE" == "weaviate" ]] && profiles="${profiles:+$profiles,}weaviate"
    [[ "$ETL_ENHANCED" == "yes" ]] && profiles="${profiles:+$profiles,}etl"
    [[ "$MONITORING_MODE" == "local" ]] && profiles="${profiles:+$profiles,}monitoring"
    [[ "$ENABLE_AUTHELIA" == "true" ]] && profiles="${profiles:+$profiles,}authelia"
    [[ "$LLM_PROVIDER" == "ollama" || "$EMBED_PROVIDER" == "ollama" ]] && \
        profiles="${profiles:+$profiles,}ollama"
    [[ "$LLM_PROVIDER" == "vllm" ]] && profiles="${profiles:+$profiles,}vllm"
    [[ "$EMBED_PROVIDER" == "tei" ]] && profiles="${profiles:+$profiles,}tei"

    # Stop and remove ALL stale containers from previous failed installs.
    # Must use ALL profiles — docker compose down without profiles won't touch
    # services that have profiles: [monitoring], etc. Without this, Docker
    # reuses old containers whose bind mounts were cached as directories.
    COMPOSE_PROFILES=vps,monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei \
        docker compose down --remove-orphans 2>/dev/null || true
    # Belt-and-suspenders: force-remove any agmind containers docker compose missed
    docker ps -a --filter "name=agmind-" -q | while read -r id; do docker rm -f "$id" 2>/dev/null; done

    # Final safety net: fix any remaining directory artifacts before compose up
    ensure_bind_mount_files

    # NOTE: ENABLE_SIGNUP stays false in .env — admin is created via docker exec
    # to avoid exposing signup endpoint through nginx (race condition fix)

    # Nuclear cleanup: find and remove ANY .yml/.conf that is a directory
    find "${INSTALL_DIR}/docker" -maxdepth 3 -name "*.yml" -type d -exec rm -rf {} + 2>/dev/null || true
    find "${INSTALL_DIR}/docker" -maxdepth 3 -name "*.yaml" -type d -exec rm -rf {} + 2>/dev/null || true
    find "${INSTALL_DIR}/docker" -maxdepth 3 -name "*.conf" -type d -exec rm -rf {} + 2>/dev/null || true

    # Pre-flight validation: abort if any .yml/.conf are still directories
    preflight_bind_mount_check

    if [[ "$DEPLOY_PROFILE" == "offline" ]]; then
        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="${profiles}" docker compose up -d --pull never
        else
            docker compose up -d --pull never
        fi
    elif [[ -n "$profiles" ]]; then
        COMPOSE_PROFILES="${profiles}" docker compose up -d --pull missing
    else
        docker compose up -d --pull missing
    fi

    # Sync PostgreSQL password: if db volume existed from a previous attempt,
    # the password in the DB won't match the newly generated .env password.
    # Wait for db healthy, then ALTER USER to match.
    sync_db_password

    # Create plugin database if it doesn't exist (plugin-daemon needs it)
    create_plugin_db

    # BUG-015 fix: docker compose up -d returns before the full dependency chain
    # resolves — containers with condition: service_healthy deps stay in "Created".
    # Re-run compose up to kick any containers whose dependencies are now healthy.
    echo -e "${YELLOW}Ожидание каскада зависимостей...${NC}"
    local retry created=0
    for retry in 1 2 3; do
        created=$(docker ps -a --filter "name=agmind-" --filter "status=created" --format '{{.ID}}' 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${created:-0}" -eq 0 ]]; then
            break
        fi
        echo "  Попытка ${retry}/3: ${created} контейнеров в Created, перезапуск..."
        sleep 10
        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="${profiles}" docker compose up -d 2>&1 | tail -5
        else
            docker compose up -d 2>&1 | tail -5
        fi
    done
    # Fail loudly if containers still stuck after all retries
    if [[ "${created:-0}" -gt 0 ]]; then
        local stuck_names
        stuck_names=$(docker ps -a --filter "name=agmind-" --filter "status=created" --format '{{.Names}}' 2>/dev/null | tr '\n' ', ')
        echo -e "${RED}ОШИБКА: ${created} контейнеров не запустились после 3 попыток: ${stuck_names}${NC}"
        echo -e "${YELLOW}Проверьте логи: docker compose logs <service>${NC}"
    fi

    # Fix Dify API storage permissions (container runs as user "dify")
    docker exec -u root agmind-api chown -R dify:dify /app/api/storage 2>/dev/null || true

    # Post-launch status: wait briefly and report unhealthy/restarting containers
    post_launch_status

    # Create Open WebUI admin account, then lock down signups
    create_openwebui_admin

    # Final safety: ensure ALL containers are started after admin creation
    # (create_openwebui_admin restarts open-webui and nginx individually)
    local final_created
    final_created=$(docker ps -a --filter "name=agmind-" --filter "status=created" -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${final_created:-0}" -gt 0 ]]; then
        echo -e "${YELLOW}Запуск ${final_created} оставшихся контейнеров...${NC}"
        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="${profiles}" docker compose up -d 2>&1 | tail -5
        else
            docker compose up -d 2>&1 | tail -5
        fi
    fi

    echo ""
}

# Create admin user in Open WebUI via internal API (no public exposure)
# Eliminates race condition: nginx is stopped during signup window,
# and admin is created via docker exec (container-internal), not through
# the public nginx port.
create_openwebui_admin() {
    local admin_email="admin@localhost"
    local admin_password
    admin_password=$(grep '^INIT_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- | base64 -d 2>/dev/null || head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 16)
    local admin_name="AGMind Admin"

    echo -e "${YELLOW}Создание администратора Open WebUI...${NC}"

    cd "${INSTALL_DIR}/docker"

    # Step 1: Stop nginx to prevent external access during signup window
    docker compose stop nginx >/dev/null 2>&1 || true

    # Step 2: Temporarily restart open-webui with signup enabled
    # Shell env overrides .env file (ENABLE_SIGNUP=false stays in .env)
    ENABLE_SIGNUP=true docker compose up -d open-webui >/dev/null 2>&1 || true

    # Step 3: Wait for Open WebUI to be healthy (up to 120 sec)
    local attempts=0
    while [[ $attempts -lt 24 ]]; do
        if docker exec agmind-openwebui curl -sf http://localhost:8080/health >/dev/null 2>&1; then
            break
        fi
        sleep 5
        attempts=$((attempts + 1))
    done
    if [[ $attempts -ge 24 ]]; then
        echo -e "${RED}Open WebUI не ответил за 120 сек, пропускаем создание админа${NC}"
        # Restore nginx even on failure
        docker compose up -d nginx >/dev/null 2>&1 || true
        return 0
    fi

    # Step 4: Create admin via container-internal API (NOT through nginx)
    # Sanitize inputs: escape double quotes in JSON values
    # Construct JSON payload safely using printf with proper escaping
    local json_payload
    json_payload=$(printf '{"name":"%s","email":"%s","password":"%s"}' \
        "$(printf '%s' "$admin_name" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')" \
        "$(printf '%s' "$admin_email" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')" \
        "$(printf '%s' "$admin_password" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g')")

    local resp
    resp=$(docker exec agmind-openwebui curl -sf \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        http://localhost:8080/api/v1/auths/signup 2>&1) || true

    if echo "$resp" | grep -q '"token"'; then
        echo -e "${GREEN}✓ Админ Open WebUI создан (${admin_email})${NC}"
    elif echo "$resp" | grep -qi "already"; then
        echo -e "${YELLOW}Админ Open WebUI уже существует${NC}"
    else
        echo -e "${YELLOW}Open WebUI signup: $(echo "$resp" | head -c 200)${NC}"
    fi

    # Step 5: Restart open-webui with signup locked (reads .env: ENABLE_SIGNUP=false)
    docker compose up -d open-webui >/dev/null 2>&1 || true

    # Step 6: Start nginx (public access begins AFTER signup is locked)
    docker compose up -d nginx >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ Регистрация закрыта (ENABLE_SIGNUP=false)${NC}"
}

sync_db_password() {
    local db_pass
    db_pass=$(grep '^DB_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2-)
    [[ -z "$db_pass" ]] && return 0

    local db_user
    db_user=$(grep '^DB_USERNAME=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "postgres")
    db_user="${db_user:-postgres}"

    # Validate inputs to prevent SQL injection
    if [[ ! "$db_user" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo -e "${RED}✗ Invalid DB_USERNAME: contains disallowed characters${NC}"
        return 1
    fi
    if [[ ! "$db_pass" =~ ^[a-zA-Z0-9]+$ ]]; then
        echo -e "${RED}✗ Invalid DB_PASSWORD: contains disallowed characters${NC}"
        return 1
    fi

    echo -e "${YELLOW}Синхронизация пароля PostgreSQL...${NC}"
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if docker exec agmind-db pg_isready -U "$db_user" &>/dev/null; then
            docker exec agmind-db psql -U "$db_user" -c \
                "ALTER USER ${db_user} WITH PASSWORD '${db_pass}';" &>/dev/null && \
                echo -e "${GREEN}✓ Пароль PostgreSQL синхронизирован${NC}" && return 0
            echo -e "${RED}✗ Не удалось обновить пароль PostgreSQL${NC}"
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    echo -e "${RED}✗ PostgreSQL не готов за 60 сек, пропускаем sync${NC}"
}

create_plugin_db() {
    local db_user
    db_user=$(grep '^DB_USERNAME=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "postgres")
    db_user="${db_user:-postgres}"
    local plugin_db
    plugin_db=$(grep '^PLUGIN_DB_DATABASE=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "dify_plugin")
    plugin_db="${plugin_db:-dify_plugin}"

    # Validate inputs to prevent SQL injection
    if [[ ! "$db_user" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo -e "${RED}✗ Invalid DB_USERNAME: contains disallowed characters${NC}"
        return 1
    fi
    if [[ ! "$plugin_db" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo -e "${RED}✗ Invalid PLUGIN_DB_DATABASE: contains disallowed characters${NC}"
        return 1
    fi

    # Wait for db to be ready
    local attempts=0
    while [[ $attempts -lt 15 ]]; do
        if docker exec agmind-db pg_isready -U "$db_user" &>/dev/null; then
            # Create database if not exists
            docker exec agmind-db psql -U "$db_user" -tc \
                "SELECT 1 FROM pg_database WHERE datname = '${plugin_db}';" 2>/dev/null | grep -q 1 || {
                docker exec agmind-db psql -U "$db_user" -c \
                    "CREATE DATABASE ${plugin_db};" &>/dev/null && \
                    echo -e "${GREEN}✓ БД ${plugin_db} создана${NC}"
            }
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
}

post_launch_status() {
    echo -e "${YELLOW}Ожидание запуска контейнеров...${NC}"
    local elapsed=0
    while [[ $elapsed -lt 120 ]]; do
        local starting
        starting=$(docker ps --filter "name=agmind-" --filter "health=starting" -q 2>/dev/null | wc -l || echo "0")
        [[ "$starting" -eq 0 ]] && break
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done
    echo ""

    local bad
    bad=$(docker ps --filter "name=agmind-" --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -iE "unhealthy|restarting" || true)
    if [[ -n "$bad" ]]; then
        echo -e "${YELLOW}⚠ Контейнеры с проблемами:${NC}"
        while IFS=$'\t' read -r name status; do
            echo -e "  ${RED}✗ ${name}: ${status}${NC}"
            # Show last 3 log lines for diagnosis
            local logs
            logs=$(docker logs --tail 3 "$name" 2>&1 || true)
            if [[ -n "$logs" ]]; then
                echo "    $(echo "$logs" | head -3 | sed 's/^/    /')"
            fi
        done <<< "$bad"
        echo ""
        echo -e "${YELLOW}Используйте 'docker logs <container>' для деталей${NC}"
    else
        echo -e "${GREEN}✓ Все контейнеры работают${NC}"
    fi
}

# ============================================================================
# PHASE 6: Wait for healthy
# ============================================================================
phase_health() {
    export INSTALL_DIR
    wait_healthy 300 || true

    # Check critical services — halt if any core service is unhealthy
    local critical_services=(db redis api worker web nginx)
    local critical_failed=0
    for svc in "${critical_services[@]}"; do
        local status
        status=$(docker ps --filter "name=agmind-${svc}" --format "{{.Status}}" 2>/dev/null | head -1)
        if echo "$status" | grep -qi "unhealthy\|restarting\|exited"; then
            echo -e "${RED}✗ Критический сервис ${svc} не работает: ${status}${NC}"
            docker logs --tail 5 "agmind-${svc}" 2>&1 | sed 's/^/    /'
            critical_failed=$((critical_failed + 1))
        fi
    done

    if [[ $critical_failed -gt 0 ]]; then
        echo ""
        echo -e "${RED}${critical_failed} критических сервисов не запустились.${NC}"
        echo -e "${RED}Установка не может продолжиться. Проверьте логи: docker logs <container>${NC}"
        exit 1
    fi

    echo ""
}

# ============================================================================
# PHASE 7: Download Models
# ============================================================================
phase_models() {
    export INSTALL_DIR LLM_MODEL EMBEDDING_MODEL DEPLOY_PROFILE LLM_PROVIDER EMBED_PROVIDER
    download_models
    echo ""
}

# ============================================================================
# PHASE 8: Setup Backups
# ============================================================================
phase_backups() {
    export INSTALL_DIR BACKUP_TARGET BACKUP_SCHEDULE
    export REMOTE_BACKUP_HOST REMOTE_BACKUP_PORT REMOTE_BACKUP_USER
    export REMOTE_BACKUP_KEY REMOTE_BACKUP_PATH
    setup_backups
    echo ""
}

# Portable helper: get local IP on both Linux and macOS
get_local_ip() {
    if [[ "$(uname)" == "Darwin" ]]; then
        ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1"
    else
        hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
    fi
}

# ============================================================================
# PHASE 9: Final Output
# ============================================================================
phase_complete() {
    echo ""

    # Provider-aware display labels
    local llm_display
    case "${LLM_PROVIDER:-ollama}" in
        ollama)   llm_display="${LLM_MODEL:-qwen2.5:14b} (Ollama)";;
        vllm)     llm_display="${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct} (vLLM)";;
        external) llm_display="External API";;
        skip)     llm_display="Не настроен";;
    esac

    local embed_display
    case "${EMBED_PROVIDER:-ollama}" in
        ollama)   embed_display="${EMBEDDING_MODEL:-bge-m3} (Ollama)";;
        tei)      embed_display="BAAI/bge-m3 (TEI)";;
        external) embed_display="External API";;
        skip)     embed_display="Не настроен";;
    esac

    # Determine access URL
    local access_url=""
    case "$DEPLOY_PROFILE" in
        vps)
            if [[ -n "$DOMAIN" ]]; then
                access_url="https://${DOMAIN}"
            else
                access_url="http://$(curl -sf --max-time 10 ifconfig.me 2>/dev/null || echo 'YOUR_IP')"
            fi
            ;;
        lan|vpn)
            local lan_ip
            lan_ip=$(get_local_ip)
            access_url="http://${lan_ip}"
            ;;
        offline)
            local lan_ip
            lan_ip=$(get_local_ip)
            access_url="http://${lan_ip}"
            ;;
    esac

    # Dify Console on port 3000
    local dify_url
    case "$DEPLOY_PROFILE" in
        vps)
            if [[ -n "$DOMAIN" ]]; then
                dify_url="http://${DOMAIN}:3000"
            else
                dify_url="http://$(curl -sf --max-time 10 ifconfig.me 2>/dev/null || echo 'YOUR_IP'):3000"
            fi
            ;;
        *)
            local dify_ip
            dify_ip=$(get_local_ip)
            dify_url="http://${dify_ip}:3000"
            ;;
    esac

    # Gather credentials
    local init_password=""
    if [[ -f "${INSTALL_DIR}/docker/.env" ]]; then
        init_password=$(grep '^INIT_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2-)
    fi
    local owui_pass=""
    if [[ -f "${INSTALL_DIR}/.admin_password" ]]; then
        owui_pass=$(cat "${INSTALL_DIR}/.admin_password" 2>/dev/null)
    fi
    local grafana_pass=""
    if [[ -f "${INSTALL_DIR}/docker/.env" ]]; then
        grafana_pass=$(grep '^GRAFANA_ADMIN_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d= -f2-)
    fi

    # Container status
    local total_containers healthy_containers
    total_containers=$(docker ps -a --filter "name=agmind-" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
    healthy_containers=$(docker ps --filter "name=agmind-" --filter "health=healthy" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')

    # Reranker info
    local rerank_info=""
    if [[ "$ETL_ENHANCED" == "yes" ]]; then
        rerank_info="${RERANK_MODEL:-bce-reranker-base_v1} (Xinference)"
    fi

    # Build the summary block (plain text for both terminal and file)
    local W=54  # inner width
    local summary=""
    summary+="$(printf '╔%s╗\n' "$(printf '═%.0s' $(seq 1 $W))")"
    summary+="$(printf '║%*s%-*s║\n' 16 '' $((W-16)) 'URLS & STATUS')"
    summary+="$(printf '╠%s╣\n' "$(printf '═%.0s' $(seq 1 $W))")"
    summary+="$(printf '║%*s║\n' $W '')"
    summary+="$(printf '║  Open WebUI:    %-*s║\n' $((W-18)) "$access_url")"
    summary+="$(printf '║  Dify Console:  %-*s║\n' $((W-18)) "$dify_url")"
    if [[ "$MONITORING_MODE" == "local" ]]; then
        local mon_ip; mon_ip=$(get_local_ip)
        summary+="$(printf '║  Grafana:       %-*s║\n' $((W-18)) "http://${mon_ip}:3001")"
        summary+="$(printf '║  Portainer:     %-*s║\n' $((W-18)) "https://${mon_ip}:9443")"
    fi
    summary+="$(printf '║%*s║\n' $W '')"
    summary+="$(printf '║  LLM:           %-*s║\n' $((W-18)) "$llm_display")"
    summary+="$(printf '║  Embedding:     %-*s║\n' $((W-18)) "$embed_display")"
    if [[ -n "$rerank_info" ]]; then
        summary+="$(printf '║  Reranker:      %-*s║\n' $((W-18)) "$rerank_info")"
    fi
    summary+="$(printf '║  Vector DB:     %-*s║\n' $((W-18)) "${VECTOR_STORE}")"
    summary+="$(printf '║%*s║\n' $W '')"
    summary+="$(printf '║  Containers:    %-*s║\n' $((W-18)) "${healthy_containers}/${total_containers} healthy")"
    summary+="$(printf '║  Backup:        %-*s║\n' $((W-18)) "${BACKUP_SCHEDULE}")"
    [[ "$ENABLE_UFW" == "true" ]] && summary+="$(printf '║  UFW:           %-*s║\n' $((W-18)) "enabled")"
    [[ "$ENABLE_FAIL2BAN" == "true" ]] && summary+="$(printf '║  Fail2ban:      %-*s║\n' $((W-18)) "enabled")"
    [[ "$ENABLE_AUTHELIA" == "true" ]] && summary+="$(printf '║  Authelia:      %-*s║\n' $((W-18)) "2FA enabled")"
    summary+="$(printf '║%*s║\n' $W '')"
    summary+="$(printf '║  Логи:   agmind logs -f                      ║\n')"
    summary+="$(printf '║  Бэкап:  %s/scripts/backup.sh  ║\n' "${INSTALL_DIR}")"
    summary+="$(printf '║  Статус: agmind status                       ║\n')"
    summary+="$(printf '║%*s║\n' $W '')"
    summary+="$(printf '╚%s╝\n' "$(printf '═%.0s' $(seq 1 $W))")"

    echo ""
    echo -e "${GREEN}${summary}${NC}"
    echo ""
    echo -e "${YELLOW}Credentials saved to: ${INSTALL_DIR}/credentials.txt (chmod 600)${NC}"
    echo -e "${CYAN}View: cat ${INSTALL_DIR}/credentials.txt${NC}"

    # Provider-specific plugin hint
    echo ""
    local plugin_hint
    case "${LLM_PROVIDER:-ollama}" in
        ollama)
            plugin_hint="Установите плагин langgenius/ollama в Dify -> Plugins"
            ;;
        vllm)
            plugin_hint="Установите плагин langgenius/openai_api_compatible в Dify -> Plugins"
            echo -e "${CYAN}${plugin_hint}${NC}"
            echo -e "${CYAN}  Endpoint: http://vllm:8000/v1${NC}"
            plugin_hint=""  # already printed
            ;;
        external)
            plugin_hint="Установите плагин langgenius/openai_api_compatible в Dify -> Plugins"
            ;;
        skip)
            plugin_hint="Настройте модель в Dify -> Settings -> Model Providers"
            ;;
    esac
    if [[ -n "$plugin_hint" ]]; then
        echo -e "${CYAN}${plugin_hint}${NC}"
    fi
    echo -e "${CYAN}Подробно: ${INSTALL_DIR}/workflows/README.md${NC}"

    # Save credentials to file (root-only)
    {
        echo "# AGMind Credentials — $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "# chmod 600 — only root can read"
        echo ""
        echo "Open WebUI:    $access_url"
        echo "WebUI pass:    ${owui_pass:-N/A}"
        echo "Dify Console:  $dify_url"
        echo "Dify init pwd: ${init_password:-N/A}"
        [[ "$MONITORING_MODE" == "local" ]] && echo "Grafana:       http://$(get_local_ip):3001"
        [[ "$MONITORING_MODE" == "local" ]] && echo "Portainer:     https://$(get_local_ip):9443"
        [[ -n "$grafana_pass" ]] && echo "Grafana pass:  $grafana_pass"
        echo ""
        echo "LLM:           $llm_display"
        echo "Embedding:     $embed_display"
        [[ -n "$rerank_info" ]] && echo "Reranker:      $rerank_info"
        echo "Vector DB:     $VECTOR_STORE"
        echo "Containers:    ${healthy_containers}/${total_containers} healthy"
    } > "${INSTALL_DIR}/credentials.txt"
    chmod 600 "${INSTALL_DIR}/credentials.txt"

    # Mark as installed
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${INSTALL_DIR}/.agmind_installed"

    # Create agmind CLI symlink (idempotent)
    if [[ -d /usr/local/bin ]]; then
        ln -sf "${INSTALL_DIR}/scripts/agmind.sh" /usr/local/bin/agmind
        echo -e "${GREEN}Команда 'agmind' доступна глобально${NC}"
    fi

    # Install health-gen cron (every minute, as root)
    cat > /etc/cron.d/agmind-health <<CRON_EOF
# AGMind health.json generator — runs every minute
* * * * * root ${INSTALL_DIR}/scripts/health-gen.sh >> ${INSTALL_DIR}/health-gen.log 2>&1
CRON_EOF
    chmod 644 /etc/cron.d/agmind-health

    # Install logrotate config for AGMind logs (prevents /var partition fill)
    if [[ -d /etc/logrotate.d ]]; then
        sed "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
            "${INSTALLER_DIR}/templates/logrotate-agmind.conf" \
            > /etc/logrotate.d/agmind
        chmod 644 /etc/logrotate.d/agmind
    fi

    # Generate initial health.json with real data (replaces placeholder from phase_config)
    "${INSTALL_DIR}/scripts/health-gen.sh" 2>/dev/null || true
}

# ============================================================================
# PHASE RUNNER: checkpoint tracking + timestamp logging
# ============================================================================
# Run a single installation phase with checkpoint tracking and timestamp logging.
# Usage: run_phase <phase_number> <total_phases> <phase_name> <phase_function>
run_phase() {
    local phase_num="$1"
    local total="$2"
    local phase_name="$3"
    local phase_func="$4"

    # Write checkpoint BEFORE phase starts — crash mid-phase retries this phase
    echo "$phase_num" > "${INSTALL_DIR}/.install_phase"

    local start_ts
    start_ts=$(date +%H:%M:%S)
    echo ""
    echo -e "${BOLD}[${start_ts}] === PHASE ${phase_num}/${total}: ${phase_name} ===${NC}"

    "$phase_func"

    local end_ts
    end_ts=$(date +%H:%M:%S)
    echo -e "${GREEN}[${end_ts}] === PHASE ${phase_num}/${total}: ${phase_name} DONE ===${NC}"
}

# Run a single installation phase with timeout and one retry (doubled timeout on retry).
# Returns 1 after retry exhaustion with diagnostic; returns function exit code on non-timeout failure.
# Usage: run_phase_with_timeout <phase_num> <total> <phase_name> <phase_func> <timeout_sec>
run_phase_with_timeout() {
    local phase_num="$1"
    local total="$2"
    local phase_name="$3"
    local phase_func="$4"
    local timeout_sec="$5"

    # Write checkpoint BEFORE phase starts
    echo "$phase_num" > "${INSTALL_DIR}/.install_phase"

    local start_ts
    start_ts=$(date +%H:%M:%S)
    echo ""
    echo -e "${BOLD}[${start_ts}] === PHASE ${phase_num}/${total}: ${phase_name} (таймаут: ${timeout_sec}с) ===${NC}"

    # First attempt
    if _run_with_timeout "$phase_func" "$timeout_sec"; then
        local end_ts
        end_ts=$(date +%H:%M:%S)
        echo -e "${GREEN}[${end_ts}] === PHASE ${phase_num}/${total}: ${phase_name} DONE ===${NC}"
        return 0
    fi

    local result=$?
    if [[ $result -eq 124 ]]; then
        # Timeout — retry with doubled value
        local retry_timeout=$((timeout_sec * 2))
        echo ""
        echo -e "${YELLOW}Фаза ${phase_name} не завершилась за ${timeout_sec}с. Повтор (таймаут: ${retry_timeout}с)...${NC}"

        if _run_with_timeout "$phase_func" "$retry_timeout"; then
            local end_ts
            end_ts=$(date +%H:%M:%S)
            echo -e "${GREEN}[${end_ts}] === PHASE ${phase_num}/${total}: ${phase_name} DONE (повтор) ===${NC}"
            return 0
        fi
        result=$?
        if [[ $result -eq 124 ]]; then
            echo ""
            echo -e "${RED}Фаза ${phase_name} не завершилась за ${retry_timeout}с.${NC}"
            _show_timeout_diagnostic "$phase_num" "$timeout_sec"
            return 1
        fi
    fi

    # Non-timeout failure
    echo -e "${RED}Фаза ${phase_name} завершилась с ошибкой (код: ${result})${NC}"
    return "$result"
}

# Internal: run a shell function in background with a timer.
# Returns 124 on timeout, otherwise returns the function's exit code.
_run_with_timeout() {
    local func="$1"
    local secs="$2"

    "$func" &
    local pid=$!
    local elapsed=0

    while kill -0 "$pid" 2>/dev/null; do
        if [[ $elapsed -ge $secs ]]; then
            kill -TERM "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait "$pid"
    return $?
}

# Internal: print diagnostic after timeout exhaustion.
# Usage: _show_timeout_diagnostic <phase_num> <base_timeout_sec>
_show_timeout_diagnostic() {
    local phase_num="$1"
    local base_timeout="$2"
    local timeout_var=""

    case "$phase_num" in
        5)
            timeout_var="TIMEOUT_START"
            echo -e "${RED}Контейнеры не запустились вовремя.${NC}"
            echo -e "${CYAN}Проверьте: docker compose -f ${INSTALL_DIR}/docker/docker-compose.yml ps${NC}"
            echo -e "${CYAN}Логи: docker compose -f ${INSTALL_DIR}/docker/docker-compose.yml logs --tail 50${NC}"
            ;;
        6)
            timeout_var="TIMEOUT_HEALTH"
            echo -e "${RED}Контейнеры не прошли проверку здоровья.${NC}"
            echo -e "${CYAN}Проверьте: docker ps --filter 'name=agmind-' --format '{{.Names}}\t{{.Status}}'${NC}"
            echo -e "${CYAN}Логи проблемного сервиса: docker logs agmind-<service>${NC}"
            ;;
        7)
            timeout_var="TIMEOUT_MODELS"
            echo -e "${RED}Загрузка моделей не завершилась за отведённое время.${NC}"
            echo -e "${CYAN}Проверьте сеть: curl -s https://registry.ollama.ai >/dev/null && echo OK${NC}"
            echo -e "${CYAN}Статус загрузки: docker exec agmind-ollama ollama list${NC}"
            ;;
    esac

    echo ""
    echo -e "${YELLOW}Перезапустите: sudo bash install.sh${NC}"
    if [[ -n "$timeout_var" ]]; then
        echo -e "${YELLOW}Увеличить таймаут: ${timeout_var}=$((base_timeout * 4)) sudo bash install.sh${NC}"
    fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    # Parse arguments (CLI args set defaults; env vars still override)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE=true ;;
            --force-restart) FORCE_RESTART=true ;;
            --profile) DEPLOY_PROFILE="${DEPLOY_PROFILE:-$2}"; shift ;;
            --profile=*) DEPLOY_PROFILE="${DEPLOY_PROFILE:-${1#*=}}" ;;
            --llm) LLM_MODEL="${LLM_MODEL:-$2}"; shift ;;
            --llm=*) LLM_MODEL="${LLM_MODEL:-${1#*=}}" ;;
            --embedding) EMBEDDING_MODEL="${EMBEDDING_MODEL:-$2}"; shift ;;
            --embedding=*) EMBEDDING_MODEL="${EMBEDDING_MODEL:-${1#*=}}" ;;
            --monitoring) MONITORING_MODE="${MONITORING_MODE:-$2}"; shift ;;
            --monitoring=*) MONITORING_MODE="${MONITORING_MODE:-${1#*=}}" ;;
            --etl) ETL_TYPE="${ETL_TYPE:-$2}"; shift ;;
            --etl=*) ETL_TYPE="${ETL_TYPE:-${1#*=}}" ;;
            --vector-store) VECTOR_STORE="${VECTOR_STORE:-$2}"; shift ;;
            --vector-store=*) VECTOR_STORE="${VECTOR_STORE:-${1#*=}}" ;;
            --domain) DOMAIN="${DOMAIN:-$2}"; shift ;;
            --domain=*) DOMAIN="${DOMAIN:-${1#*=}}" ;;
            --help|-h)
                echo "Usage: sudo bash install.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --non-interactive    Run without prompts (use env vars or CLI args)"
                echo "  --force-restart      Delete checkpoint, start from phase 1"
                echo "  --profile PROFILE    Deploy profile: vps, lan, vpn, offline"
                echo "  --llm MODEL          LLM model (e.g. qwen2.5:7b)"
                echo "  --embedding MODEL    Embedding model (e.g. bge-m3)"
                echo "  --monitoring MODE    Monitoring: local, none"
                echo "  --etl TYPE           ETL: dify, unstructured_api"
                echo "  --vector-store TYPE  Vector store: weaviate, qdrant"
                echo "  --domain DOMAIN      Domain for TLS"
                echo ""
                echo "Env vars take precedence over CLI args."
                exit 0
                ;;
        esac
        shift
    done

    # Check root
    if [[ "$(id -u)" -ne 0 && "$(uname)" != "Darwin" ]]; then
        echo -e "${RED}Запустите от root: sudo bash install.sh${NC}"
        exit 1
    fi

    # Ensure INSTALL_DIR exists for logging and checkpoint
    mkdir -p "${INSTALL_DIR}"

    # Setup logging: all stdout+stderr goes to screen AND install.log
    local LOG_FILE="${INSTALL_DIR}/install.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    chmod 600 "$LOG_FILE"

    show_banner

    # Handle --force-restart: delete checkpoint, proceed as fresh install
    if [[ "$FORCE_RESTART" == "true" ]]; then
        rm -f "${INSTALL_DIR}/.install_phase"
        echo -e "${YELLOW}--force-restart: checkpoint removed, starting from phase 1${NC}"
    fi

    # Determine start phase (checkpoint resume)
    local start_phase=1
    local checkpoint_file="${INSTALL_DIR}/.install_phase"

    if [[ -f "$checkpoint_file" ]]; then
        local saved_phase
        saved_phase=$(cat "$checkpoint_file" 2>/dev/null)
        # Validate: must be integer 1-9
        if [[ "$saved_phase" =~ ^[1-9]$ ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                # Non-interactive: auto-resume
                echo -e "${YELLOW}Checkpoint found: resuming from phase ${saved_phase}/9${NC}"
                start_phase="$saved_phase"
            else
                echo ""
                echo -e "${YELLOW}Найдена незавершённая установка (фаза ${saved_phase}/9).${NC}"
                echo -e "${YELLOW}Продолжить? [yes/no/restart]${NC}"
                local resume_choice
                read -rp "> " resume_choice
                case "$resume_choice" in
                    yes|y)
                        start_phase="$saved_phase"
                        echo -e "${GREEN}Продолжение с фазы ${start_phase}...${NC}"
                        ;;
                    restart)
                        rm -f "$checkpoint_file"
                        echo -e "${YELLOW}Checkpoint удалён, начинаем с фазы 1${NC}"
                        start_phase=1
                        ;;
                    *)
                        echo "Выход."
                        exit 0
                        ;;
                esac
            fi
        fi
    fi

    # Check if already installed (only on fresh install, not resume)
    if [[ "$start_phase" -eq 1 && -f "${INSTALL_DIR}/.agmind_installed" ]]; then
        echo -e "${YELLOW}AGMind уже установлен в ${INSTALL_DIR}${NC}"
        echo "  Для обновления: ${INSTALL_DIR}/scripts/update.sh"
        echo "  Для переустановки: ${INSTALL_DIR}/scripts/uninstall.sh && bash install.sh"
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Переустановить? (yes/no): " REINSTALL
            if [[ "$REINSTALL" != "yes" ]]; then
                exit 0
            fi
        else
            echo -e "${RED}Non-interactive: отказ от переустановки. Используйте FORCE_REINSTALL=true.${NC}"
            if [[ "${FORCE_REINSTALL:-false}" != "true" ]]; then
                exit 1
            fi
        fi
    fi

    # On resume: skip wizard, source existing .env for variables
    if [[ "$start_phase" -gt 2 && -f "${INSTALL_DIR}/docker/.env" ]]; then
        echo -e "${CYAN}Загрузка переменных из существующего .env...${NC}"
        # shellcheck disable=SC1091
        set +u  # .env may have empty values
        source "${INSTALL_DIR}/docker/.env"
        set -u
    fi

    # Phase table: number, name, function
    local total=9
    [[ "$start_phase" -le 1 ]] && run_phase 1 $total "Diagnostika sistemy"        phase_diagnostics
    [[ "$start_phase" -le 2 ]] && run_phase 2 $total "Nastroika ustanovki"        phase_wizard
    [[ "$start_phase" -le 3 ]] && run_phase 3 $total "Docker"                     phase_docker
    [[ "$start_phase" -le 4 ]] && run_phase 4 $total "Generatsiya konfiguratsii"  phase_config
    [[ "$start_phase" -le 5 ]] && run_phase_with_timeout 5 $total "Zapusk konteinerov"         phase_start  "$TIMEOUT_START"
    [[ "$start_phase" -le 6 ]] && run_phase_with_timeout 6 $total "Proverka zdorovya"          phase_health "$TIMEOUT_HEALTH"
    [[ "$start_phase" -le 7 ]] && run_phase_with_timeout 7 $total "Zagruzka modelej"           phase_models "$TIMEOUT_MODELS"
    [[ "$start_phase" -le 8 ]] && run_phase 8 $total "Nastroika bekapov"          phase_backups
    [[ "$start_phase" -le 9 ]] && run_phase 9 $total "Zavershenie"                phase_complete

    # Installation complete — remove checkpoint
    rm -f "${INSTALL_DIR}/.install_phase"
}

main "$@"
