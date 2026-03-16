#!/usr/bin/env bash
# detect.sh — System diagnostics: OS, GPU, RAM, disk, ports, Docker, network
set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

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
    DETECTED_GPU_VRAM="0"

    # ENV override: force a specific GPU type
    if [[ -n "${FORCE_GPU_TYPE:-}" ]]; then
        case "$FORCE_GPU_TYPE" in
            nvidia|amd|intel|apple|none)
                DETECTED_GPU="$FORCE_GPU_TYPE"
                ;;
            *)
                echo -e "${YELLOW}Unknown FORCE_GPU_TYPE '${FORCE_GPU_TYPE}', ignoring (valid: nvidia, amd, intel, apple, none)${NC}"
                ;;
        esac
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
        return 0
    fi

    # ENV override: skip detection entirely
    if [[ "${SKIP_GPU_DETECT:-false}" == "true" ]]; then
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
        return 0
    fi

    # 1. NVIDIA — nvidia-smi
    if command -v nvidia-smi &>/dev/null; then
        local gpu_info
        gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null || true)
        if [[ -n "$gpu_info" ]]; then
            DETECTED_GPU="nvidia"
            DETECTED_GPU_NAME=$(echo "$gpu_info" | head -1 | cut -d',' -f1 | xargs)
            DETECTED_GPU_VRAM=$(echo "$gpu_info" | head -1 | cut -d',' -f2 | xargs)
            [[ "$DETECTED_GPU_VRAM" =~ ^[0-9]+$ ]] || DETECTED_GPU_VRAM="0"
            export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
            return 0
        fi
    fi

    # 2. AMD ROCm — /dev/kfd or rocminfo
    if [[ -e /dev/kfd ]] || command -v rocminfo &>/dev/null; then
        DETECTED_GPU="amd"
        DETECTED_GPU_NAME=$(rocminfo 2>/dev/null | grep 'Marketing Name' | head -1 | cut -d: -f2- | xargs 2>/dev/null || echo "")
        DETECTED_GPU_VRAM=$(rocm-smi --showmeminfo vram 2>/dev/null | grep 'Total' | awk '{print $NF}' || echo "0")
        [[ "$DETECTED_GPU_VRAM" =~ ^[0-9]+$ ]] || DETECTED_GPU_VRAM="0"
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
        return 0
    fi

    # 3. Intel Arc — /dev/dri/renderD128 + lspci VGA Intel
    if [[ -e /dev/dri/renderD128 ]]; then
        if lspci 2>/dev/null | grep -qi 'vga.*intel'; then
            DETECTED_GPU="intel"
            DETECTED_GPU_NAME=$(lspci 2>/dev/null | grep -i 'vga.*intel' | head -1 | sed 's/.*: //' || echo "")
            export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
            return 0
        fi
    fi

    # 4. Apple Silicon — arm64 Darwin
    if [[ "$(uname -m)" == "arm64" && "$(uname -s)" == "Darwin" ]]; then
        DETECTED_GPU="apple"
        DETECTED_GPU_NAME="Apple Silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'M-series'))"
        echo -e "${YELLOW}Apple Silicon использует Metal нативно, Docker GPU passthrough не поддерживается${NC}"
        export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
        return 0
    fi

    # 5. CPU fallback
    export DETECTED_GPU DETECTED_GPU_NAME DETECTED_GPU_VRAM
}

persist_gpu_profile() {
    local profile_file="${INSTALL_DIR:-.}/.agmind_gpu_profile"
    cat > "$profile_file" <<EOF
GPU_TYPE="${DETECTED_GPU}"
GPU_NAME="${DETECTED_GPU_NAME:-unknown}"
GPU_VRAM="${DETECTED_GPU_VRAM:-0}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
EOF
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) DOCKER_PLATFORM="linux/amd64" ;;
        aarch64|arm64) DOCKER_PLATFORM="linux/arm64" ;;
        armv7l) DOCKER_PLATFORM="linux/arm/v7" ;;
        *) DOCKER_PLATFORM="linux/amd64" ;;
    esac
    export DOCKER_PLATFORM
    DETECTED_ARCH="$arch"
    export DETECTED_ARCH
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
        if curl -sf --connect-timeout 5 https://hub.docker.com >/dev/null 2>&1; then
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
    elif [[ "$gpu" == "amd" && "${vram:-0}" -gt 0 ]]; then
        # VRAM in MB from rocm-smi, convert to GB
        effective_mem=$(( vram / 1024 ))
    fi
    # Apple Silicon / Intel / CPU fallback: use total RAM (already set above)

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
    detect_arch
    echo -e "  Система:      ${GREEN}${DETECTED_OS_NAME}, ${DETECTED_ARCH}${NC}"
    echo -e "  Платформа:    ${GREEN}${DOCKER_PLATFORM}${NC}"

    detect_gpu
    case "$DETECTED_GPU" in
        nvidia)
            echo -e "  GPU:          ${GREEN}NVIDIA ${DETECTED_GPU_NAME} (${DETECTED_GPU_VRAM} MB VRAM)${NC}" ;;
        amd)
            echo -e "  GPU:          ${GREEN}AMD ${DETECTED_GPU_NAME:-ROCm} ${DETECTED_GPU_VRAM:+(${DETECTED_GPU_VRAM} MB VRAM)}${NC}" ;;
        intel)
            echo -e "  GPU:          ${GREEN}Intel ${DETECTED_GPU_NAME:-Arc}${NC}" ;;
        apple)
            echo -e "  GPU:          ${GREEN}${DETECTED_GPU_NAME:-Apple Silicon} (Metal)${NC}" ;;
        *)
            echo -e "  GPU:          ${YELLOW}Не обнаружен (CPU only)${NC}" ;;
    esac

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

preflight_checks() {
    if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then
        echo -e "${YELLOW}Pre-flight проверки пропущены (SKIP_PREFLIGHT=true)${NC}"
        return 0
    fi

    echo -e "${BOLD}Pre-flight проверки:${NC}"
    echo ""

    local errors=0
    local warnings=0

    # 1. OS detection and version
    local os_name os_ver
    if [[ -f /etc/os-release ]]; then
        os_name=$(. /etc/os-release && echo "$ID")
        os_ver=$(. /etc/os-release && echo "$VERSION_ID")
        case "$os_name" in
            ubuntu)
                local os_major="${os_ver%%.*}"
                local os_minor="${os_ver#*.}"
                os_minor="${os_minor%%.*}"
                if [[ "$os_major" -gt 20 ]] 2>/dev/null || [[ "$os_major" -eq 20 && "${os_minor:-0}" -ge 4 ]] 2>/dev/null; then
                    echo -e "  ${GREEN}[PASS]${NC} OS: Ubuntu $os_ver"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} OS: Ubuntu $os_ver (рекомендуется 20.04+)"
                    warnings=$((warnings + 1))
                fi ;;
            debian)
                if [[ "${os_ver%%.*}" -ge 11 ]] 2>/dev/null; then
                    echo -e "  ${GREEN}[PASS]${NC} OS: Debian $os_ver"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} OS: Debian $os_ver (рекомендуется 11+)"
                    warnings=$((warnings + 1))
                fi ;;
            centos|rhel|rocky|almalinux)
                if [[ "${os_ver%%.*}" -ge 8 ]] 2>/dev/null; then
                    echo -e "  ${GREEN}[PASS]${NC} OS: $os_name $os_ver"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} OS: $os_name $os_ver (рекомендуется 8+)"
                    warnings=$((warnings + 1))
                fi ;;
            fedora)
                if [[ "${os_ver%%.*}" -ge 38 ]] 2>/dev/null; then
                    echo -e "  ${GREEN}[PASS]${NC} OS: Fedora $os_ver"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} OS: Fedora $os_ver (рекомендуется 38+)"
                    warnings=$((warnings + 1))
                fi ;;
            *) echo -e "  ${YELLOW}[WARN]${NC} OS: $os_name $os_ver (не тестировалось)"
               warnings=$((warnings + 1)) ;;
        esac
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        echo -e "  ${YELLOW}[WARN]${NC} OS: macOS (только для разработки)"
        warnings=$((warnings + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} OS: неизвестная система"
        warnings=$((warnings + 1))
    fi

    # 2. Docker version >= 24.0
    if command -v docker &>/dev/null; then
        local docker_ver
        docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")
        local docker_major="${docker_ver%%.*}"
        if [[ "$docker_major" -ge 24 ]] 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} Docker: v${docker_ver}"
        elif [[ "$docker_major" -ge 20 ]] 2>/dev/null; then
            echo -e "  ${YELLOW}[WARN]${NC} Docker: v${docker_ver} (рекомендуется 24.0+)"
            warnings=$((warnings + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} Docker: v${docker_ver} (требуется 24.0+)"
            errors=$((errors + 1))
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} Docker: не установлен (будет установлен автоматически)"
        warnings=$((warnings + 1))
    fi

    # 3. Docker Compose version >= 2.20
    if docker compose version &>/dev/null; then
        local compose_ver
        compose_ver=$(docker compose version --short 2>/dev/null | sed 's/^v//')
        local compose_major="${compose_ver%%.*}"
        local compose_minor="${compose_ver#*.}"
        compose_minor="${compose_minor%%.*}"
        if [[ "$compose_major" -gt 2 ]] 2>/dev/null || \
           [[ "$compose_major" -eq 2 && "$compose_minor" -ge 20 ]] 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} Docker Compose: v${compose_ver}"
        else
            echo -e "  ${YELLOW}[WARN]${NC} Docker Compose: v${compose_ver} (рекомендуется 2.20+)"
            warnings=$((warnings + 1))
        fi
    elif command -v docker &>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} Docker Compose: не найден"
        warnings=$((warnings + 1))
    fi

    # 4. Disk space
    local disk_gb
    disk_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}' || echo "0")
    if [[ "$disk_gb" -ge 30 ]] 2>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} Диск: ${disk_gb}GB свободно"
    elif [[ "$disk_gb" -ge 20 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} Диск: ${disk_gb}GB свободно (рекомендуется 30GB+)"
        warnings=$((warnings + 1))
    elif [[ "$disk_gb" -ge 10 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} Диск: ${disk_gb}GB свободно (минимум 20GB)"
        warnings=$((warnings + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Диск: ${disk_gb}GB свободно (требуется минимум 10GB)"
        errors=$((errors + 1))
    fi

    # 5. RAM >= 4GB
    local ram_gb
    ram_gb="${DETECTED_RAM_TOTAL_GB:-0}"
    if [[ "$ram_gb" -ge 8 ]] 2>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} RAM: ${ram_gb}GB"
    elif [[ "$ram_gb" -ge 4 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} RAM: ${ram_gb}GB (рекомендуется 8GB+ для полного стека)"
        warnings=$((warnings + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} RAM: ${ram_gb}GB (требуется минимум 4GB)"
        errors=$((errors + 1))
    fi

    # 6. CPU cores >= 2
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "1")
    if [[ "$cpu_cores" -ge 4 ]] 2>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} CPU: ${cpu_cores} ядер"
    elif [[ "$cpu_cores" -ge 2 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} CPU: ${cpu_cores} ядер (рекомендуется 4+)"
        warnings=$((warnings + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} CPU: ${cpu_cores} ядро (требуется минимум 2)"
        errors=$((errors + 1))
    fi

    # 7. Ports 80/443 not in use
    for port in 80 443; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           lsof -i ":${port}" -sTCP:LISTEN &>/dev/null; then
            echo -e "  ${YELLOW}[WARN]${NC} Порт ${port}: занят"
            warnings=$((warnings + 1))
        else
            echo -e "  ${GREEN}[PASS]${NC} Порт ${port}: свободен"
        fi
    done

    # 8. Docker daemon running
    if command -v docker &>/dev/null; then
        if docker info &>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} Docker daemon: работает"
        else
            echo -e "  ${YELLOW}[WARN]${NC} Docker daemon: не запущен"
            warnings=$((warnings + 1))
        fi
    fi

    # 9. docker.sock accessible
    if [[ -S /var/run/docker.sock ]]; then
        if [[ -r /var/run/docker.sock ]]; then
            echo -e "  ${GREEN}[PASS]${NC} Docker socket: доступен"
        else
            echo -e "  ${YELLOW}[WARN]${NC} Docker socket: нет прав чтения"
            warnings=$((warnings + 1))
        fi
    elif command -v docker &>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${NC} Docker socket: /var/run/docker.sock не найден"
        warnings=$((warnings + 1))
    fi

    # 10. Internet connectivity (skip if offline)
    if [[ "${DEPLOY_PROFILE:-}" != "offline" ]]; then
        if curl -sf --connect-timeout 5 https://hub.docker.com >/dev/null 2>&1 || \
           wget -q --spider --timeout=5 https://hub.docker.com 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} Интернет: доступен"
        else
            echo -e "  ${YELLOW}[WARN]${NC} Интернет: недоступен (потребуется для скачивания образов)"
            warnings=$((warnings + 1))
        fi
    else
        echo -e "  ${CYAN}[SKIP]${NC} Интернет: пропущено (offline профиль)"
    fi

    # Summary
    echo ""
    if [[ $errors -gt 0 ]]; then
        echo -e "  ${RED}Ошибок: ${errors}, Предупреждений: ${warnings}${NC}"
        echo -e "  ${RED}Исправьте ошибки перед продолжением.${NC}"
    elif [[ $warnings -gt 0 ]]; then
        echo -e "  ${YELLOW}Предупреждений: ${warnings} (установка возможна)${NC}"
    else
        echo -e "  ${GREEN}Все проверки пройдены!${NC}"
    fi
    echo ""

    return $errors
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_diagnostics
fi
