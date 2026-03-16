#!/usr/bin/env bash
# workflow.sh — Import Dify workflow using import.py
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

wait_for_dify_api() {
    echo -e "${YELLOW}Ожидание готовности Dify API...${NC}"
    local retries=60
    local i=0
    local dify_port="${DIFY_PORT:-3000}"
    while [[ $i -lt $retries ]]; do
        # Dify Console served on its own port (default 3000)
        if curl -sf "http://localhost:${dify_port}/console/api/setup" >/dev/null 2>&1; then
            echo -e "${GREEN}Dify API готов${NC}"
            return 0
        fi
        sleep 5
        i=$((i + 1))
        echo -n "."
    done
    echo ""
    echo -e "${RED}Dify API не ответил за 5 минут${NC}"
    return 1
}

setup_dify_account() {
    local admin_email="${ADMIN_EMAIL:-admin@admin.com}"
    local admin_password="${ADMIN_PASSWORD:-}"
    local admin_name="${COMPANY_NAME:-AGMind} Admin"

    echo -e "${YELLOW}Настройка аккаунта Dify...${NC}"

    # Check if setup is needed (init password method)
    local init_password_b64
    init_password_b64=$(grep '^INIT_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "")

    # Dify auto-creates admin from INIT_PASSWORD env var on first boot
    # We just need to wait and verify login works
    sleep 10
}

import_workflow() {
    local admin_email="${ADMIN_EMAIL:-admin@admin.com}"
    local admin_password="${ADMIN_PASSWORD:-}"
    local llm_model="${LLM_MODEL:-qwen2.5:14b}"
    local embedding_model="${EMBEDDING_MODEL:-bge-m3}"
    local company_name="${COMPANY_NAME:-AGMind}"
    local dify_port="${DIFY_PORT:-3000}"
    local dify_url="${DIFY_INTERNAL_URL:-http://localhost:${dify_port}}"

    echo -e "${YELLOW}Импорт workflow в Dify...${NC}"

    # Ensure python3 is available
    if ! command -v python3 &>/dev/null; then
        echo -e "${YELLOW}Установка Python3...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq python3
        elif command -v yum &>/dev/null; then
            yum install -y python3
        fi
    fi

    # Console prefix: Dify Console served on its own port, no prefix needed
    local console_prefix="${DIFY_CONSOLE_PREFIX:-}"

    # Get INIT_PASSWORD from .env for first-boot init validation
    local init_password
    init_password=$(grep '^INIT_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "")

    # Run import script
    python3 "${INSTALL_DIR}/workflows/import.py" \
        --url "$dify_url" \
        --email "$admin_email" \
        --password "$admin_password" \
        --model "$llm_model" \
        --embedding "$embedding_model" \
        --company "$company_name" \
        --workflow "${INSTALL_DIR}/workflows/rag-assistant.json" \
        --console-prefix "$console_prefix" \
        --init-password "$init_password"

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}Workflow импортирован и опубликован${NC}"
    else
        echo -e "${RED}Ошибка импорта workflow (код: ${exit_code})${NC}"
        return 1
    fi
}

setup_workflow() {
    wait_for_dify_api || return 1
    setup_dify_account
    import_workflow
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_workflow
fi
