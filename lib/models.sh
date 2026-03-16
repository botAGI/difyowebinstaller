#!/usr/bin/env bash
# models.sh — Download Ollama models after containers are started
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

COMPOSE_DIR="${INSTALL_DIR:-/opt/agmind}/docker"

wait_for_ollama() {
    echo -e "${YELLOW}Ожидание готовности Ollama...${NC}"
    local retries=60
    local i=0
    while [[ $i -lt $retries ]]; do
        if docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T ollama \
            ollama list >/dev/null 2>&1; then
            echo -e "${GREEN}Ollama готов${NC}"
            return 0
        fi
        sleep 5
        i=$((i + 1))
        echo -n "."
    done
    echo ""
    echo -e "${RED}Ollama не ответил за 5 минут${NC}"
    return 1
}

pull_model() {
    local model="$1"
    local label="${2:-$model}"

    echo -e "${YELLOW}Скачивание модели: ${label}...${NC}"
    # Override resolv.conf inside running container to bypass Docker embedded DNS
    # (127.0.0.11) which fails on systemd-resolved hosts
    if docker exec agmind-ollama sh -c \
        "echo 'nameserver 8.8.8.8' > /etc/resolv.conf && ollama pull $model"; then
        echo -e "${GREEN}Модель ${label} загружена${NC}"
    else
        echo -e "${RED}Ошибка загрузки модели ${label}${NC}"
        return 1
    fi
}

check_ollama_models() {
    local llm_model="${LLM_MODEL:-qwen2.5:14b}"
    local embedding_model="${EMBEDDING_MODEL:-bge-m3}"

    echo -e "${YELLOW}Проверка предзагруженных моделей...${NC}"

    wait_for_ollama || return 1

    local model_list
    model_list=$(docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T ollama \
        ollama list 2>/dev/null || echo "")

    local missing=0

    # Match full model name (name:tag) to avoid false positives with different tags
    if echo "$model_list" | grep -qi "^${llm_model}[[:space:]]"; then
        echo -e "  ${GREEN}[OK]${NC} LLM: ${llm_model}"
    else
        echo -e "  ${RED}[!!]${NC} LLM: ${llm_model} — НЕ НАЙДЕНА"
        echo "       Загрузите вручную: docker compose exec ollama ollama pull ${llm_model}"
        missing=$((missing + 1))
    fi

    if echo "$model_list" | grep -qi "^${embedding_model}[[:space:]]"; then
        echo -e "  ${GREEN}[OK]${NC} Embedding: ${embedding_model}"
    else
        echo -e "  ${RED}[!!]${NC} Embedding: ${embedding_model} — НЕ НАЙДЕНА"
        echo "       Загрузите вручную: docker compose exec ollama ollama pull ${embedding_model}"
        missing=$((missing + 1))
    fi

    if [[ $missing -gt 0 ]]; then
        echo ""
        echo -e "${RED}Внимание: ${missing} модель(и) отсутствуют!${NC}"
        echo "Система будет работать, но запросы к отсутствующим моделям не выполнятся."
    fi

    return 0
}

load_reranker() {
    local etl_enhanced="${ETL_ENHANCED:-no}"
    if [[ "$etl_enhanced" != "yes" ]]; then
        return 0
    fi

    echo -e "${YELLOW}Загрузка reranker модели в Xinference...${NC}"

    # Wait for xinference to be ready
    local retries=30
    local i=0
    while [[ $i -lt $retries ]]; do
        if docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T xinference \
            curl -sf http://localhost:9997/v1/models >/dev/null 2>&1; then
            break
        fi
        sleep 5
        i=$((i + 1))
    done

    if [[ $i -ge $retries ]]; then
        echo -e "${YELLOW}Xinference не готов, пропуск загрузки reranker${NC}"
        return 0
    fi

    # Register bce-reranker-base_v1
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T xinference \
        curl -sf -X POST http://localhost:9997/v1/models \
        -H "Content-Type: application/json" \
        -d '{"model_name":"bce-reranker-base_v1","model_type":"rerank","model_engine":"sentence-transformers"}' \
        >/dev/null 2>&1 || true

    echo -e "${GREEN}Reranker модель зарегистрирована${NC}"
}

download_models() {
    local llm_model="${LLM_MODEL:-qwen2.5:14b}"
    local embedding_model="${EMBEDDING_MODEL:-bge-m3}"
    local profile="${DEPLOY_PROFILE:-lan}"

    # Skip for offline profile
    if [[ "$profile" == "offline" ]]; then
        echo -e "${YELLOW}Профиль offline: пропуск загрузки моделей${NC}"
        echo "Проверка предзагруженных моделей..."
        check_ollama_models
        load_reranker
        return 0
    fi

    wait_for_ollama || return 1

    echo ""
    echo -e "${YELLOW}=== Загрузка моделей ===${NC}"
    echo ""

    # Pull LLM model
    pull_model "$llm_model" "LLM ($llm_model)" || return 1

    echo ""

    # Pull embedding model
    pull_model "$embedding_model" "Embedding ($embedding_model)" || return 1

    # Load reranker if ETL enhanced
    load_reranker

    echo ""
    echo -e "${GREEN}Все модели загружены${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    download_models
fi
