#!/usr/bin/env bash
# restore.sh — Restore AGMind from backup
set -euo pipefail
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# R-13: Root check
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Exclusive lock — prevent parallel operations
LOCK_FILE="/var/lock/agmind-operation.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "${RED}Другая операция AGMind уже запущена. Дождитесь завершения.${NC}"
    exit 1
fi

AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

# R-08: Validate INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
[[ "$INSTALL_DIR" == /opt/agmind* ]] || { echo "Invalid INSTALL_DIR"; exit 1; }

COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"
BACKUP_BASE="${BACKUP_DIR:-/var/backups/agmind}"

# R-03: Trap to restart services on failure
SERVICES_DOWN=false
cleanup_restore() {
    if [[ "$SERVICES_DOWN" == "true" ]]; then
        echo -e "${YELLOW}Restore interrupted — restarting services...${NC}"
        cd "${INSTALL_DIR}/docker" && docker compose up -d 2>/dev/null || true
    fi
}
trap cleanup_restore EXIT INT TERM

# R-01/R-02: Validate RESTORE_DIR path
if [[ -n "${1:-}" ]]; then
    RESTORE_DIR="$(realpath -m "$1" 2>/dev/null)" || { echo "Invalid path"; exit 1; }
    [[ "$RESTORE_DIR" == "$BACKUP_BASE"/* ]] || { echo -e "${RED}Error: path must be under ${BACKUP_BASE}${NC}"; exit 1; }
else
    echo -e "${YELLOW}Доступные бэкапы:${NC}"
    ls -1d "${BACKUP_BASE}"/*/ 2>/dev/null | while read -r dir; do
        local_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "  $(basename "$dir")  ($local_size)"
    done

    echo ""
    read -rp "Введите дату бэкапа (YYYY-MM-DD_HHMM): " BACKUP_DATE
    RESTORE_DIR="$(realpath -m "${BACKUP_BASE}/${BACKUP_DATE}" 2>/dev/null)"
    [[ "$RESTORE_DIR" == "$BACKUP_BASE"/* ]] || { echo -e "${RED}Invalid backup path${NC}"; exit 1; }
fi

if [[ ! -d "$RESTORE_DIR" ]]; then
    echo -e "${RED}Бэкап не найден: ${RESTORE_DIR}${NC}"
    exit 1
fi

echo -e "${YELLOW}=== Восстановление из бэкапа ===${NC}"
echo "  Источник: ${RESTORE_DIR}"
echo ""

# Confirmation
if [[ "$AUTO_CONFIRM" == "true" ]]; then
    CONFIRM="yes"
else
    read -rp "ВНИМАНИЕ: Текущие данные будут перезаписаны. Продолжить? (yes/no): " CONFIRM
fi
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Отменено."
    exit 0
fi

# Decrypt encrypted backup files if .age files exist
has_age_files=false
for f in "${RESTORE_DIR}"/*.age; do
    [[ -f "$f" ]] && has_age_files=true && break
done

if [[ "$has_age_files" == "true" ]]; then
    echo -e "${YELLOW}Обнаружены зашифрованные файлы (.age)${NC}"
    age_key="${INSTALL_DIR}/.age/agmind.key"
    if [[ -f "$age_key" ]] && command -v age &>/dev/null; then
        echo -e "${YELLOW}Расшифровка бэкапа...${NC}"
        for f in "${RESTORE_DIR}"/*.age; do
            [[ -f "$f" ]] || continue
            local_output="${f%.age}"
            age -d -i "$age_key" -o "$local_output" "$f" 2>/dev/null && rm -f "$f"
        done
        echo -e "${GREEN}Бэкап расшифрован${NC}"
    else
        echo -e "${RED}Ключ дешифрования не найден: ${age_key}${NC}"
        echo "Укажите путь к ключу age или скопируйте его в ${age_key}"
        read -rp "Путь к ключу (Enter для отмены): " custom_key
        if [[ -n "$custom_key" && -f "$custom_key" ]]; then
            for f in "${RESTORE_DIR}"/*.age; do
                [[ -f "$f" ]] || continue
                local_output="${f%.age}"
                age -d -i "$custom_key" -o "$local_output" "$f" 2>/dev/null && rm -f "$f"
            done
            echo -e "${GREEN}Бэкап расшифрован${NC}"
        else
            echo -e "${RED}Отменено — невозможно расшифровать бэкап${NC}"
            exit 1
        fi
    fi
fi

# Verify checksums
if [[ -f "${RESTORE_DIR}/sha256sums.txt" ]]; then
    echo -e "${YELLOW}Проверка контрольных сумм...${NC}"
    cd "${RESTORE_DIR}"
    if sha256sum -c sha256sums.txt >/dev/null 2>&1; then
        echo -e "${GREEN}Контрольные суммы совпадают${NC}"
    else
        echo -e "${RED}ВНИМАНИЕ: Контрольные суммы НЕ совпадают!${NC}"
        if [[ "$AUTO_CONFIRM" == "true" ]]; then
            FORCE_RESTORE="yes"
        else
            read -rp "Продолжить восстановление? (yes/no): " FORCE_RESTORE
        fi
        if [[ "$FORCE_RESTORE" != "yes" ]]; then
            echo "Отменено."
            exit 1
        fi
    fi
    cd - >/dev/null
fi

# Stop services
echo -e "${YELLOW}Остановка контейнеров...${NC}"
SERVICES_DOWN=true
docker compose -f "$COMPOSE_FILE" down

# 1. Restore PostgreSQL
if [[ -f "${RESTORE_DIR}/dify.sql.gz" ]]; then
    echo -e "${YELLOW}Восстановление PostgreSQL...${NC}"
    docker compose -f "$COMPOSE_FILE" up -d db

    # R-05: Wait for PostgreSQL with pg_isready loop
    echo -e "${YELLOW}Waiting for PostgreSQL...${NC}"
    for i in $(seq 1 30); do
        if docker compose -f "$COMPOSE_FILE" exec -T db pg_isready -U postgres >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    # Drop and recreate database
    docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS dify;" 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "CREATE DATABASE dify;" 2>/dev/null || true

    # R-04: Check psql exit codes
    if ! gunzip -c "${RESTORE_DIR}/dify.sql.gz" | \
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -d dify 2>/dev/null; then
        echo -e "${RED}PostgreSQL restore failed for dify DB${NC}"
        exit 1
    fi

    # Restore plugin DB if exists
    if [[ -f "${RESTORE_DIR}/dify_plugin.sql.gz" ]]; then
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS dify_plugin;" 2>/dev/null || true
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "CREATE DATABASE dify_plugin;" 2>/dev/null || true
        if ! gunzip -c "${RESTORE_DIR}/dify_plugin.sql.gz" | \
            docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -d dify_plugin 2>/dev/null; then
            echo -e "${RED}PostgreSQL restore failed for dify_plugin DB${NC}"
            exit 1
        fi
    fi

    docker compose -f "$COMPOSE_FILE" stop db
    echo -e "${GREEN}PostgreSQL восстановлен${NC}"
fi

# 2. Restore vector store
if [[ -f "${RESTORE_DIR}/qdrant.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление Qdrant...${NC}"
    data_dir="${INSTALL_DIR}/docker/volumes/qdrant"
    mkdir -p "${data_dir}"

    # R-06: Safe restore — move old data to temp before replacing
    temp_old=$(mktemp -d "${data_dir}.old.XXXXXX")
    mv "${data_dir}" "${temp_old}/" 2>/dev/null || true
    mkdir -p "${data_dir}"
    if tar xzf "${RESTORE_DIR}/qdrant.tar.gz" -C "${data_dir}/"; then
        rm -rf "${temp_old}"
    else
        rm -rf "${data_dir}"
        mv "${temp_old}/qdrant" "${data_dir}" 2>/dev/null || true
        rm -rf "${temp_old}"
        echo -e "${RED}Qdrant restore failed, old data preserved${NC}"
        exit 1
    fi

    # Restore Qdrant snapshots via API if .snapshot files exist
    has_snapshots=false
    for snap in "${RESTORE_DIR}"/qdrant_*; do
        [[ -f "$snap" ]] && has_snapshots=true && break
    done

    if [[ "$has_snapshots" == "true" ]]; then
        echo -e "${YELLOW}Восстановление Qdrant коллекций из snapshots...${NC}"
        # Start qdrant temporarily
        docker compose -f "$COMPOSE_FILE" up -d qdrant 2>/dev/null || true

        # Wait for Qdrant to be ready
        for i in $(seq 1 30); do
            if curl -sf --max-time 5 "http://localhost:6333/healthz" >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done

        for snap in "${RESTORE_DIR}"/qdrant_*; do
            [[ -f "$snap" ]] || continue
            snap_basename=$(basename "$snap")
            # Extract collection name: qdrant_<collection>_<snapshot_name>
            coll_name=$(echo "$snap_basename" | sed 's/^qdrant_//; s/_[^_]*$//')

            # R-09/R-15: Validate collection name
            [[ "$coll_name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid collection name: $coll_name"; continue; }

            echo "  Восстановление коллекции: ${coll_name}"
            # R-10: Add --max-time 60 to curl
            curl -sf --max-time 60 -X POST "http://localhost:6333/collections/${coll_name}/snapshots/upload" \
                -H "Content-Type: multipart/form-data" \
                -F "snapshot=@${snap}" 2>/dev/null || \
                echo -e "  ${YELLOW}Не удалось восстановить snapshot для ${coll_name}${NC}"
        done
        docker compose -f "$COMPOSE_FILE" stop qdrant 2>/dev/null || true
    fi

    echo -e "${GREEN}Qdrant восстановлен${NC}"
elif [[ -f "${RESTORE_DIR}/weaviate.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление Weaviate...${NC}"
    data_dir="${INSTALL_DIR}/docker/volumes/weaviate"

    # R-06: Safe restore for Weaviate
    temp_old=$(mktemp -d "${data_dir}.old.XXXXXX")
    if [[ -d "${data_dir}" ]]; then
        mv "${data_dir}" "${temp_old}/" 2>/dev/null || true
    fi
    mkdir -p "${data_dir}"
    if tar xzf "${RESTORE_DIR}/weaviate.tar.gz" -C "${data_dir}/"; then
        rm -rf "${temp_old}"
    else
        rm -rf "${data_dir}"
        mv "${temp_old}/weaviate" "${data_dir}" 2>/dev/null || true
        rm -rf "${temp_old}"
        echo -e "${RED}Weaviate restore failed, old data preserved${NC}"
        exit 1
    fi
    echo -e "${GREEN}Weaviate восстановлен${NC}"
fi

# 3. Restore Dify storage
if [[ -f "${RESTORE_DIR}/dify-storage.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление Dify storage...${NC}"
    data_dir="${INSTALL_DIR}/docker/volumes/app/storage"

    # R-06: Safe restore for Dify storage
    temp_old=$(mktemp -d "${data_dir}.old.XXXXXX")
    if [[ -d "${data_dir}" ]]; then
        mv "${data_dir}" "${temp_old}/" 2>/dev/null || true
    fi
    mkdir -p "${data_dir}"
    if tar xzf "${RESTORE_DIR}/dify-storage.tar.gz" -C "${data_dir}/"; then
        rm -rf "${temp_old}"
    else
        rm -rf "${data_dir}"
        mv "${temp_old}/storage" "${data_dir}" 2>/dev/null || true
        rm -rf "${temp_old}"
        echo -e "${RED}Dify storage restore failed, old data preserved${NC}"
        exit 1
    fi
    echo -e "${GREEN}Dify storage восстановлен${NC}"
fi

# 4. Restore Open WebUI
if [[ -f "${RESTORE_DIR}/openwebui.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление Open WebUI...${NC}"
    # R-10: Check if volume exists before restore
    vol_name=$(docker volume ls -q | grep "openwebui" | head -1)
    if [[ -z "$vol_name" ]]; then
        echo -e "${YELLOW}Volume not found, skipping Open WebUI restore${NC}"
    else
        docker run --rm -v "${vol_name}:/data" -v "${RESTORE_DIR}:/backup" \
            alpine sh -c "rm -rf /data/* && tar xzf /backup/openwebui.tar.gz -C /data/"
        echo -e "${GREEN}Open WebUI восстановлен${NC}"
    fi
fi

# 5. Restore Ollama models
if [[ -f "${RESTORE_DIR}/ollama.tar.gz" ]]; then
    echo -e "${YELLOW}Восстановление моделей Ollama...${NC}"
    vol_name=$(docker volume ls -q | grep "ollama_data" | head -1)
    if [[ -z "$vol_name" ]]; then
        echo -e "${YELLOW}Volume not found, skipping Ollama restore${NC}"
    else
        docker run --rm -v "${vol_name}:/data" -v "${RESTORE_DIR}:/backup" \
            alpine sh -c "rm -rf /data/* && tar xzf /backup/ollama.tar.gz -C /data/"
        echo -e "${GREEN}Модели Ollama восстановлены${NC}"
    fi
fi

# 6. Restore config (optional)
if [[ -f "${RESTORE_DIR}/env.backup" ]]; then
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        RESTORE_CONFIG="yes"
    else
        read -rp "Восстановить конфигурацию (.env, nginx)? (yes/no): " RESTORE_CONFIG
    fi
    if [[ "$RESTORE_CONFIG" == "yes" ]]; then
        cp "${RESTORE_DIR}/env.backup" "${INSTALL_DIR}/docker/.env"
        # R-07: Restrict .env permissions after restore
        chmod 600 "${INSTALL_DIR}/docker/.env"
        cp "${RESTORE_DIR}/nginx.conf.backup" "${INSTALL_DIR}/docker/nginx/nginx.conf" 2>/dev/null || true
        # Restore Authelia config if backup exists
        if [[ -f "${RESTORE_DIR}/authelia.tar.gz" ]]; then
            echo -e "${YELLOW}Восстановление Authelia конфигурации...${NC}"
            mkdir -p "${INSTALL_DIR}/docker/authelia"
            tar xzf "${RESTORE_DIR}/authelia.tar.gz" -C "${INSTALL_DIR}/docker/authelia/"
            echo -e "${GREEN}Authelia конфигурация восстановлена${NC}"
        fi
        # Restore age encryption keys if backup exists
        if [[ -d "${RESTORE_DIR}/age_keys" ]]; then
            echo -e "${YELLOW}Восстановление ключей шифрования...${NC}"
            mkdir -p "${INSTALL_DIR}/.age"
            cp -r "${RESTORE_DIR}/age_keys/"* "${INSTALL_DIR}/.age/"
            chmod 700 "${INSTALL_DIR}/.age"
            chmod 600 "${INSTALL_DIR}/.age/"* 2>/dev/null || true
            echo -e "${GREEN}Ключи шифрования восстановлены${NC}"
        fi
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
    authelia=$(grep '^ENABLE_AUTHELIA=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "false")
    [[ "$authelia" == "true" ]] && RESTORE_PROFILES="${RESTORE_PROFILES:+$RESTORE_PROFILES,}authelia"
fi
if [[ -n "$RESTORE_PROFILES" ]]; then
    COMPOSE_PROFILES="$RESTORE_PROFILES" docker compose -f "$COMPOSE_FILE" up -d
else
    docker compose -f "$COMPOSE_FILE" up -d
fi
SERVICES_DOWN=false

echo ""
echo -e "${GREEN}=== Восстановление завершено ===${NC}"
echo "Проверьте состояние: docker compose -f ${COMPOSE_FILE} ps"
