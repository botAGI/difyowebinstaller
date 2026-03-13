#!/usr/bin/env bash
# restore.sh — Restore AGMind from backup
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"
BACKUP_BASE="${BACKUP_DIR:-/var/backups/agmind}"

# Select backup
if [[ -n "${1:-}" ]]; then
    RESTORE_DIR="$1"
else
    echo -e "${YELLOW}Доступные бэкапы:${NC}"
    ls -1d "${BACKUP_BASE}"/*/ 2>/dev/null | while read -r dir; do
        local_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "  $(basename "$dir")  ($local_size)"
    done

    echo ""
    read -rp "Введите дату бэкапа (YYYY-MM-DD_HHMM): " BACKUP_DATE
    RESTORE_DIR="${BACKUP_BASE}/${BACKUP_DATE}"
fi

if [[ ! -d "$RESTORE_DIR" ]]; then
    echo -e "${RED}Бэкап не найден: ${RESTORE_DIR}${NC}"
    exit 1
fi

echo -e "${YELLOW}=== Восстановление из бэкапа ===${NC}"
echo "  Источник: ${RESTORE_DIR}"
echo ""

# Confirmation
read -rp "ВНИМАНИЕ: Текущие данные будут перезаписаны. Продолжить? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Отменено."
    exit 0
fi

# Verify checksums
if [[ -f "${RESTORE_DIR}/sha256sums.txt" ]]; then
    echo -e "${YELLOW}Проверка контрольных сумм...${NC}"
    cd "${RESTORE_DIR}"
    if sha256sum -c sha256sums.txt >/dev/null 2>&1; then
        echo -e "${GREEN}Контрольные суммы совпадают${NC}"
    else
        echo -e "${RED}ВНИМАНИЕ: Контрольные суммы НЕ совпадают!${NC}"
        read -rp "Продолжить восстановление? (yes/no): " FORCE_RESTORE
        if [[ "$FORCE_RESTORE" != "yes" ]]; then
            echo "Отменено."
            exit 1
        fi
    fi
    cd - >/dev/null
fi

# Stop services
echo -e "${YELLOW}Остановка контейнеров...${NC}"
docker compose -f "$COMPOSE_FILE" down

# 1. Restore PostgreSQL
if [[ -f "${RESTORE_DIR}/dify.sql.gz" ]]; then
    echo -e "${YELLOW}Восстановление PostgreSQL...${NC}"
    docker compose -f "$COMPOSE_FILE" up -d db
    sleep 10

    # Drop and recreate database
    docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS dify;" 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "CREATE DATABASE dify;" 2>/dev/null || true

    gunzip -c "${RESTORE_DIR}/dify.sql.gz" | \
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -d dify

    # Restore plugin DB if exists
    if [[ -f "${RESTORE_DIR}/dify_plugin.sql.gz" ]]; then
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS dify_plugin;" 2>/dev/null || true
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "CREATE DATABASE dify_plugin;" 2>/dev/null || true
        gunzip -c "${RESTORE_DIR}/dify_plugin.sql.gz" | \
            docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -d dify_plugin
    fi

    docker compose -f "$COMPOSE_FILE" stop db
    echo -e "${GREEN}PostgreSQL восстановлен${NC}"
fi

# 2. Restore vector store
if [[ -f "${RESTORE_DIR}/qdrant.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление Qdrant...${NC}"
    mkdir -p "${INSTALL_DIR}/docker/volumes/qdrant"
    rm -rf "${INSTALL_DIR}/docker/volumes/qdrant/"*
    tar xzf "${RESTORE_DIR}/qdrant.tar.gz" -C "${INSTALL_DIR}/docker/volumes/qdrant/"
    echo -e "${GREEN}Qdrant восстановлен${NC}"
elif [[ -f "${RESTORE_DIR}/weaviate.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление Weaviate...${NC}"
    rm -rf "${INSTALL_DIR}/docker/volumes/weaviate/"*
    tar xzf "${RESTORE_DIR}/weaviate.tar.gz" -C "${INSTALL_DIR}/docker/volumes/weaviate/"
    echo -e "${GREEN}Weaviate восстановлен${NC}"
fi

# 3. Restore Dify storage
if [[ -f "${RESTORE_DIR}/dify-storage.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление Dify storage...${NC}"
    rm -rf "${INSTALL_DIR}/docker/volumes/app/storage/"*
    tar xzf "${RESTORE_DIR}/dify-storage.tar.gz" -C "${INSTALL_DIR}/docker/volumes/app/storage/"
    echo -e "${GREEN}Dify storage восстановлен${NC}"
fi

# 4. Restore Open WebUI
if [[ -f "${RESTORE_DIR}/openwebui.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление Open WebUI...${NC}"
    vol_name=$(docker volume ls -q | grep openwebui | head -1 || echo "")
    if [[ -n "$vol_name" ]]; then
        docker run --rm -v "${vol_name}:/data" -v "${RESTORE_DIR}:/backup" \
            alpine sh -c "rm -rf /data/* && tar xzf /backup/openwebui.tar.gz -C /data/"
    fi
    echo -e "${GREEN}Open WebUI восстановлен${NC}"
fi

# 5. Restore Ollama models
if [[ -f "${RESTORE_DIR}/ollama.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление моделей Ollama...${NC}"
    vol_name=$(docker volume ls -q | grep ollama_data | head -1 || echo "")
    if [[ -n "$vol_name" ]]; then
        docker run --rm -v "${vol_name}:/data" -v "${RESTORE_DIR}:/backup" \
            alpine sh -c "rm -rf /data/* && tar xzf /backup/ollama.tar.gz -C /data/"
    fi
    echo -e "${GREEN}Модели Ollama восстановлены${NC}"
fi

# 6. Restore config (optional)
if [[ -f "${RESTORE_DIR}/env.backup" ]]; then
    read -rp "Восстановить конфигурацию (.env, nginx)? (yes/no): " RESTORE_CONFIG
    if [[ "$RESTORE_CONFIG" == "yes" ]]; then
        cp "${RESTORE_DIR}/env.backup" "${INSTALL_DIR}/docker/.env"
        cp "${RESTORE_DIR}/nginx.conf.backup" "${INSTALL_DIR}/docker/nginx/nginx.conf" 2>/dev/null || true
        echo -e "${GREEN}Конфигурация восстановлена${NC}"
    fi
fi

# Start all services (rebuild COMPOSE_PROFILES from .env settings)
echo -e "${YELLOW}Запуск контейнеров...${NC}"
RESTORE_PROFILES=""
ENV_FILE="${INSTALL_DIR}/docker/.env"
if [[ -f "$ENV_FILE" ]]; then
    vs=$(grep '^VECTOR_STORE=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")
    [[ "$vs" == "qdrant" ]] && RESTORE_PROFILES="qdrant"
    [[ "$vs" == "weaviate" ]] && RESTORE_PROFILES="weaviate"
    etl=$(grep '^ETL_TYPE=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "dify")
    [[ "$etl" == "unstructured_api" ]] && RESTORE_PROFILES="${RESTORE_PROFILES:+$RESTORE_PROFILES,}etl"
    mon=$(grep '^MONITORING_MODE=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "none")
    [[ "$mon" == "local" ]] && RESTORE_PROFILES="${RESTORE_PROFILES:+$RESTORE_PROFILES,}monitoring"
fi
if [[ -n "$RESTORE_PROFILES" ]]; then
    COMPOSE_PROFILES="$RESTORE_PROFILES" docker compose -f "$COMPOSE_FILE" up -d
else
    docker compose -f "$COMPOSE_FILE" up -d
fi

echo ""
echo -e "${GREEN}=== Восстановление завершено ===${NC}"
echo "Проверьте состояние: docker compose -f ${COMPOSE_FILE} ps"
