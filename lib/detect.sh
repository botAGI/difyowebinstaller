#!/usr/bin/env bash
# detect.sh — System diagnostics: OS, GPU, RAM, disk, ports, Docker, network
set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DETECTED_OS="$ID"
        DETECTED_OS_VERSION="$VERSION_ID"
        DETECTED_OS_NAME="$PRETTY_NAME"
    elif [[ "$(uname)" == "Darwin" ]]; then
        DETECTED_OS="macos"
        DETECTED_OS_VERSION="$(sw_vers -productVersion)"
        DETECTED_OS_NAME="macOS $DETECTED_OS_VERSION"
    else
        DETECTED_OS="unknown"
        DETECTED_OS_VERSION="0"
        DETECTED_OS_NAME="Unknown OS"
    fi
    DETECTED_ARCH="$(uname -m)"
    export DETECTED_OS DETECTED_OS_VERSION DETECTED_OS_NAME DETECTED_ARCH
}

detect_gpu() {
    DETECTED_GPU="none"
    DETECTED_GPU_NAME=""
    DETECTED_GPU_VRAM=""

    if command -v nvidia-smi &>/dev/null; then
        local gpu_info
        gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null || true)
        if [[ -n "$gpu_info" ]]; then
            DETECTED_GPU="nvidia"
            DETECTED_GPU_NAME=$(echo "$gpu_info" | head -1 | cut -d',' -f1 | xargs)
            DETECTED_GPU_VRAM=$(echo "$gpu_info" | head -1 | cut -d',' -f2 | xargs)
        fi
    fi
    export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
}

detect_ram() {
    if [[ "$(uname)" == "Darwin" ]]; then
        DETECTED_RAM_TOTAL_MB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
        # macOS doesn't have a simple "available" memory metric
        local pages_free pages_inactive page_size
        page_size=$(sysctl -n hw.pagesize)
        pages_free=$(vm_stat | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
        pages_inactive=$(vm_stat | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
        DETECTED_RAM_AVAILABLE_MB=$(( (pages_free + pages_inactive) * page_size / 1024 / 1024 ))
    else
        DETECTED_RAM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
        DETECTED_RAM_AVAILABLE_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    fi
    DETECTED_RAM_TOTAL_GB=$(( DETECTED_RAM_TOTAL_MB / 1024 ))
    DETECTED_RAM_AVAILABLE_GB=$(( DETECTED_RAM_AVAILABLE_MB / 1024 ))
    export DETECTED_RAM_TOTAL_MB DETECTED_RAM_AVAILABLE_MB DETECTED_RAM_TOTAL_GB DETECTED_RAM_AVAILABLE_GB
}

detect_disk() {
    if [[ "$(uname)" == "Darwin" ]]; then
        DETECTED_DISK_FREE_GB=$(df -g / | awk 'NR==2 {print $4}')
    else
        DETECTED_DISK_FREE_GB=$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
    fi
    export DETECTED_DISK_FREE_GB
}

detect_ports() {
    PORTS_IN_USE=""
    local check_ports=(80 443 3000 5001 8080 11434)
    for port in "${check_ports[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           lsof -i ":${port}" -sTCP:LISTEN &>/dev/null; then
            PORTS_IN_USE="${PORTS_IN_USE}${port} "
        fi
    done
    export PORTS_IN_USE
}

detect_docker() {
    DETECTED_DOCKER_INSTALLED="false"
    DETECTED_DOCKER_VERSION=""
    DETECTED_DOCKER_COMPOSE="false"

    if command -v docker &>/dev/null; then
        DETECTED_DOCKER_INSTALLED="true"
        DETECTED_DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")

        if docker compose version &>/dev/null 2>&1; then
            DETECTED_DOCKER_COMPOSE="true"
        fi
    fi
    export DETECTED_DOCKER_INSTALLED DETECTED_DOCKER_VERSION DETECTED_DOCKER_COMPOSE
}

detect_network() {
    DETECTED_NETWORK="false"
    if command -v curl &>/dev/null; then
        if curl -s --connect-timeout 5 https://hub.docker.com >/dev/null 2>&1; then
            DETECTED_NETWORK="true"
        fi
    elif command -v wget &>/dev/null; then
        if wget -q --timeout=5 --spider https://hub.docker.com 2>/dev/null; then
            DETECTED_NETWORK="true"
        fi
    fi
    export DETECTED_NETWORK
}

recommend_model() {
    local ram_gb="${DETECTED_RAM_TOTAL_GB:-0}"
    local gpu="${DETECTED_GPU:-none}"
    local vram="${DETECTED_GPU_VRAM:-0}"

    # Use VRAM if GPU available, otherwise fallback to RAM-based recommendation
    local effective_mem="$ram_gb"
    if [[ "$gpu" == "nvidia" && "${vram:-0}" -gt 0 ]]; then
        # VRAM in MB from nvidia-smi, convert to GB
        effective_mem=$(( vram / 1024 ))
    fi

    if [[ "$effective_mem" -ge 48 ]]; then
        RECOMMENDED_MODEL="qwen2.5:72b-instruct-q4_K_M"
        RECOMMENDED_REASON="48GB+ VRAM/RAM — максимальное качество"
    elif [[ "$effective_mem" -ge 24 ]]; then
        RECOMMENDED_MODEL="qwen2.5:32b"
        RECOMMENDED_REASON="24GB+ VRAM/RAM — высокое качество"
    elif [[ "$effective_mem" -ge 12 ]]; then
        RECOMMENDED_MODEL="qwen2.5:14b"
        RECOMMENDED_REASON="12GB+ VRAM/RAM — баланс скорости и качества"
    elif [[ "$effective_mem" -ge 6 ]]; then
        RECOMMENDED_MODEL="qwen2.5:7b"
        RECOMMENDED_REASON="6GB+ VRAM/RAM — быстрая работа"
    else
        RECOMMENDED_MODEL="gemma3:4b"
        RECOMMENDED_REASON="4GB+ RAM — компактная модель"
    fi
    export RECOMMENDED_MODEL RECOMMENDED_REASON
}

run_diagnostics() {
    echo -e "${CYAN}=== Диагностика системы ===${NC}"
    echo ""

    detect_os
    echo -e "  Система:      ${GREEN}${DETECTED_OS_NAME}, ${DETECTED_ARCH}${NC}"

    detect_gpu
    if [[ "$DETECTED_GPU" == "nvidia" ]]; then
        echo -e "  GPU:          ${GREEN}NVIDIA ${DETECTED_GPU_NAME} (${DETECTED_GPU_VRAM} MB VRAM)${NC}"
    else
        echo -e "  GPU:          ${YELLOW}Не обнаружен (CPU only)${NC}"
    fi

    detect_ram
    echo -e "  RAM:          ${GREEN}${DETECTED_RAM_TOTAL_GB}GB (${DETECTED_RAM_AVAILABLE_GB}GB доступно)${NC}"
    if [[ "$DETECTED_RAM_TOTAL_GB" -lt 4 ]]; then
        echo -e "                ${RED}ВНИМАНИЕ: минимум 4GB RAM, рекомендуется 16GB+${NC}"
    elif [[ "$DETECTED_RAM_TOTAL_GB" -lt 16 ]]; then
        echo -e "                ${YELLOW}Рекомендуется 16GB+ для оптимальной работы${NC}"
    fi

    detect_disk
    echo -e "  Диск:         ${GREEN}${DETECTED_DISK_FREE_GB}GB свободно${NC}"
    if [[ "$DETECTED_DISK_FREE_GB" -lt 30 ]]; then
        echo -e "                ${RED}ВНИМАНИЕ: минимум 30GB, рекомендуется 50GB+${NC}"
    fi

    detect_ports
    if [[ -n "$PORTS_IN_USE" ]]; then
        echo -e "  Порты:        ${YELLOW}Заняты: ${PORTS_IN_USE}${NC}"
    else
        echo -e "  Порты:        ${GREEN}80, 443, 3000, 5001, 8080 свободны${NC}"
    fi

    detect_docker
    if [[ "$DETECTED_DOCKER_INSTALLED" == "true" ]]; then
        echo -e "  Docker:       ${GREEN}${DETECTED_DOCKER_VERSION}${NC}"
        if [[ "$DETECTED_DOCKER_COMPOSE" == "true" ]]; then
            echo -e "  Compose:      ${GREEN}установлен${NC}"
        else
            echo -e "  Compose:      ${YELLOW}не установлен${NC}"
        fi
    else
        echo -e "  Docker:       ${YELLOW}не установлен${NC}"
    fi

    detect_network
    if [[ "$DETECTED_NETWORK" == "true" ]]; then
        echo -e "  Сеть:         ${GREEN}доступна${NC}"
    else
        echo -e "  Сеть:         ${YELLOW}недоступна${NC}"
    fi

    recommend_model
    echo ""

    # Validate minimum requirements
    local errors=0
    if [[ "$DETECTED_RAM_TOTAL_GB" -lt 4 ]]; then
        echo -e "${RED}ОШИБКА: Недостаточно RAM (минимум 4GB)${NC}"
        errors=$((errors + 1))
    fi
    if [[ "$DETECTED_DISK_FREE_GB" -lt 30 ]]; then
        echo -e "${RED}ОШИБКА: Недостаточно места на диске (минимум 30GB)${NC}"
        errors=$((errors + 1))
    fi

    return $errors
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_diagnostics
fi
