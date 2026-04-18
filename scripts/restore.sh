#!/usr/bin/env bash
# restore.sh — Restore AGMind from backup
set -euo pipefail
umask 077

export RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

# R-13: Root check
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Exclusive lock — prevent parallel operations
LOCK_FILE="/var/lock/agmind-operation.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "${RED}Another AGMind operation is running. Wait for it to finish.${NC}"
    exit 1
fi

AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

# R-08: Validate INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
[[ "$INSTALL_DIR" == /opt/agmind* ]] || { echo "Invalid INSTALL_DIR"; exit 1; }

COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"
BACKUP_BASE="${BACKUP_DIR:-/var/backups/agmind}"
RESTORE_TMP="${INSTALL_DIR}/.restore_tmp"

# R-03: Trap to restart services on failure and clean up restore tmpdir
SERVICES_DOWN=false
cleanup_restore() {
    if [[ "$SERVICES_DOWN" == "true" ]]; then
        echo -e "${YELLOW}Restore interrupted — restarting services...${NC}"
        cd "${INSTALL_DIR}/docker" && docker compose up -d 2>/dev/null || true
    fi
    # Clean up restore tmpdir
    if [[ -d "${RESTORE_TMP:-}" ]]; then
        rm -rf "$RESTORE_TMP"
    fi
}
trap cleanup_restore EXIT INT TERM

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-confirm) AUTO_CONFIRM=true; shift; continue ;;
        --help|-h)
            echo "Usage: restore.sh [BACKUP_DIR] [--auto-confirm]"
            echo "  BACKUP_DIR     Path to backup directory under ${BACKUP_BASE}"
            echo "  --auto-confirm Skip confirmation prompts"
            exit 0
            ;;
        --*) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
        *) break ;;
    esac
done

# R-01/R-02: Validate RESTORE_DIR path
if [[ -n "${1:-}" ]]; then
    RESTORE_DIR="$(realpath -m "$1" 2>/dev/null || readlink -f "$1" 2>/dev/null || echo "$1")"
    [[ "$RESTORE_DIR" == "$BACKUP_BASE"/* ]] || { echo -e "${RED}Error: path must be under ${BACKUP_BASE}${NC}"; exit 1; }
else
    echo -e "${YELLOW}Available backups:${NC}"
    ls -1d "${BACKUP_BASE}"/*/ 2>/dev/null | while read -r dir; do
        local_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "  $(basename "$dir")  ($local_size)"
    done

    echo ""
    read -rp "Enter backup date (YYYY-MM-DD_HHMM): " BACKUP_DATE
    RESTORE_DIR="$(realpath -m "${BACKUP_BASE}/${BACKUP_DATE}" 2>/dev/null)"
    [[ "$RESTORE_DIR" == "$BACKUP_BASE"/* ]] || { echo -e "${RED}Invalid backup path${NC}"; exit 1; }
fi

if [[ ! -d "$RESTORE_DIR" ]]; then
    echo -e "${RED}Backup not found: ${RESTORE_DIR}${NC}"
    exit 1
fi

echo -e "${YELLOW}=== Restoring from backup ===${NC}"
echo "  Source: ${RESTORE_DIR}"
echo ""

# Confirmation
if [[ "$AUTO_CONFIRM" == "true" ]]; then
    CONFIRM="yes"
else
    read -rp "WARNING: Current data will be overwritten. Continue? (yes/no): " CONFIRM
fi
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Cancelled."
    exit 0
fi

# Decrypt encrypted backup files if .age files exist
has_age_files=false
for f in "${RESTORE_DIR}"/*.age; do
    [[ -f "$f" ]] && has_age_files=true && break
done

if [[ "$has_age_files" == "true" ]]; then
    echo -e "${YELLOW}Encrypted files detected (.age)${NC}"
    age_key="${INSTALL_DIR}/.age/agmind.key"
    if [[ -f "$age_key" ]] && command -v age &>/dev/null; then
        echo -e "${YELLOW}Decrypting backup...${NC}"
        for f in "${RESTORE_DIR}"/*.age; do
            [[ -f "$f" ]] || continue
            local_output="${f%.age}"
            age -d -i "$age_key" -o "$local_output" "$f" 2>/dev/null && rm -f "$f"
        done
        echo -e "${GREEN}Backup decrypted${NC}"
    else
        echo -e "${RED}Decryption key not found: ${age_key}${NC}"
        echo "Provide path to age key or copy it to ${age_key}"
        read -rp "Path to key (Enter to cancel): " custom_key
        if [[ -n "$custom_key" && -f "$custom_key" ]]; then
            for f in "${RESTORE_DIR}"/*.age; do
                [[ -f "$f" ]] || continue
                local_output="${f%.age}"
                age -d -i "$custom_key" -o "$local_output" "$f" 2>/dev/null && rm -f "$f"
            done
            echo -e "${GREEN}Backup decrypted${NC}"
        else
            echo -e "${RED}Cancelled — cannot decrypt backup${NC}"
            exit 1
        fi
    fi
fi

# Verify checksums
if [[ -f "${RESTORE_DIR}/sha256sums.txt" ]]; then
    echo -e "${YELLOW}Verifying checksums...${NC}"
    cd "${RESTORE_DIR}"
    if sha256sum -c sha256sums.txt >/dev/null 2>&1; then
        echo -e "${GREEN}Checksums match${NC}"
    else
        echo -e "${RED}WARNING: Checksums DO NOT match!${NC}"
        if [[ "$AUTO_CONFIRM" == "true" ]]; then
            FORCE_RESTORE="yes"
        else
            read -rp "Continue restore? (yes/no): " FORCE_RESTORE
        fi
        if [[ "$FORCE_RESTORE" != "yes" ]]; then
            echo "Cancelled."
            exit 1
        fi
    fi
    cd - >/dev/null
fi

# Create restore tmpdir on same filesystem as data volumes (no cross-device issues)
mkdir -p "$RESTORE_TMP"

# Stop services
echo -e "${YELLOW}Stopping containers...${NC}"
SERVICES_DOWN=true
docker compose -f "$COMPOSE_FILE" down

# 1. Restore PostgreSQL
if [[ -f "${RESTORE_DIR}/dify_db.sql.gz" ]]; then
    echo -e "${YELLOW}Restoring PostgreSQL...${NC}"
    docker compose -f "$COMPOSE_FILE" up -d db

    # R-05: Wait for PostgreSQL with pg_isready loop
    echo -e "${YELLOW}Waiting for PostgreSQL...${NC}"
    for _ in $(seq 1 30); do
        if docker compose -f "$COMPOSE_FILE" exec -T db pg_isready -U postgres >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    if ! docker compose -f "$COMPOSE_FILE" exec -T db pg_isready -U "${DB_USER:-postgres}" >/dev/null 2>&1; then
        echo -e "${RED}✗ PostgreSQL not ready within timeout${NC}"
        exit 1
    fi

    # Drop and recreate database
    docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS dify;" 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "CREATE DATABASE dify;" 2>/dev/null || true

    # R-04: Check psql exit codes
    # set -o pipefail ensures gunzip|psql pipe failures are caught
    if ! gunzip -c "${RESTORE_DIR}/dify_db.sql.gz" | \
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -d dify 2>/dev/null; then
        echo -e "${RED}PostgreSQL restore failed for dify DB${NC}"
        exit 1
    fi

    # Restore plugin DB if exists
    if [[ -f "${RESTORE_DIR}/dify_plugin_db.sql.gz" ]]; then
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS dify_plugin;" 2>/dev/null || true
        docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -c "CREATE DATABASE dify_plugin;" 2>/dev/null || true
        if ! gunzip -c "${RESTORE_DIR}/dify_plugin_db.sql.gz" | \
            docker compose -f "$COMPOSE_FILE" exec -T db psql -U postgres -d dify_plugin 2>/dev/null; then
            echo -e "${RED}PostgreSQL restore failed for dify_plugin DB${NC}"
            exit 1
        fi
    fi

    docker compose -f "$COMPOSE_FILE" stop db
    echo -e "${GREEN}PostgreSQL restored${NC}"
fi

# 2. Restore vector store
if [[ -f "${RESTORE_DIR}/qdrant.tar.gz" ]]; then
    echo -e "${YELLOW}Restoring Qdrant...${NC}"
    data_dir="${INSTALL_DIR}/docker/volumes/qdrant"
    mkdir -p "${data_dir}"

    # R-06: Safe restore — move old data to temp before replacing
    temp_old="${RESTORE_TMP}/$(basename "$data_dir").old"
    mkdir -p "$temp_old"
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

    # Qdrant: volume tar restore only (API not exposed to host — no ports: in compose)
    echo -e "${GREEN}Qdrant restored${NC}"
elif [[ -f "${RESTORE_DIR}/weaviate.tar.gz" ]]; then
    echo -e "${YELLOW}Restoring Weaviate...${NC}"
    data_dir="${INSTALL_DIR}/docker/volumes/weaviate"

    # R-06: Safe restore for Weaviate
    temp_old="${RESTORE_TMP}/$(basename "$data_dir").old"
    mkdir -p "$temp_old"
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
    echo -e "${GREEN}Weaviate restored${NC}"
fi

# 3. Restore Dify storage
if [[ -f "${RESTORE_DIR}/dify-storage.tar.gz" ]]; then
    echo -e "${YELLOW}Restoring Dify storage...${NC}"
    data_dir="${INSTALL_DIR}/docker/volumes/app/storage"

    # R-06: Safe restore for Dify storage
    temp_old="${RESTORE_TMP}/$(basename "$data_dir").old"
    mkdir -p "$temp_old"
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
    echo -e "${GREEN}Dify storage restored${NC}"
fi

# 4. Restore Open WebUI
if [[ -f "${RESTORE_DIR}/openwebui.tar.gz" ]]; then
    echo -e "${YELLOW}Restoring Open WebUI...${NC}"
    # R-10: Check if volume exists before restore
    vol_name=$(docker volume ls -q | grep "openwebui" | head -1)
    if [[ -z "$vol_name" ]]; then
        echo -e "${YELLOW}Volume not found, skipping Open WebUI restore${NC}"
    else
        docker run --rm -v "${vol_name}:/data" -v "${RESTORE_DIR}:/backup" \
            alpine sh -c "rm -rf /data/* && tar xzf /backup/openwebui.tar.gz -C /data/"
        echo -e "${GREEN}Open WebUI restored${NC}"
    fi
fi

# 5. Restore Ollama models
if [[ -f "${RESTORE_DIR}/ollama.tar.gz" ]]; then
    echo -e "${YELLOW}Restoring Ollama models...${NC}"
    vol_name=$(docker volume ls -q | grep "ollama_data" | head -1)
    if [[ -z "$vol_name" ]]; then
        echo -e "${YELLOW}Volume not found, skipping Ollama restore${NC}"
    else
        docker run --rm -v "${vol_name}:/data" -v "${RESTORE_DIR}:/backup" \
            alpine sh -c "rm -rf /data/* && tar xzf /backup/ollama.tar.gz -C /data/"
        echo -e "${GREEN}Ollama models restored${NC}"
    fi
fi

# 6. Restore config (optional)
if [[ -f "${RESTORE_DIR}/env.backup" ]]; then
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        RESTORE_CONFIG="yes"
    else
        read -rp "Restore configuration (.env, nginx)? (yes/no): " RESTORE_CONFIG
    fi
    if [[ "$RESTORE_CONFIG" == "yes" ]]; then
        cp "${RESTORE_DIR}/env.backup" "${INSTALL_DIR}/docker/.env"
        # R-07: Restrict .env permissions after restore
        chmod 600 "${INSTALL_DIR}/docker/.env"
        cp "${RESTORE_DIR}/nginx.conf.backup" "${INSTALL_DIR}/docker/nginx/nginx.conf" 2>/dev/null || true
        # Restore Authelia config if backup exists
        if [[ -f "${RESTORE_DIR}/authelia.tar.gz" ]]; then
            echo -e "${YELLOW}Restoring Authelia configuration...${NC}"
            mkdir -p "${INSTALL_DIR}/docker/authelia"
            tar xzf "${RESTORE_DIR}/authelia.tar.gz" -C "${INSTALL_DIR}/docker/authelia/"
            echo -e "${GREEN}Authelia configuration restored${NC}"
        fi
        # Restore age encryption keys if backup exists
        if [[ -d "${RESTORE_DIR}/age_keys" ]]; then
            echo -e "${YELLOW}Restoring encryption keys...${NC}"
            mkdir -p "${INSTALL_DIR}/.age"
            cp -r "${RESTORE_DIR}/age_keys/"* "${INSTALL_DIR}/.age/"
            chmod 700 "${INSTALL_DIR}/.age"
            chmod 600 "${INSTALL_DIR}/.age/"* 2>/dev/null || true
            echo -e "${GREEN}Encryption keys restored${NC}"
        fi
        echo -e "${GREEN}Configuration restored${NC}"
    fi
fi

# Clean up restore tmpdir after successful restore
rm -rf "$RESTORE_TMP" 2>/dev/null || true

# Start all services (read COMPOSE_PROFILES from restored .env — install.sh already writes full profile list)
echo -e "${YELLOW}Starting containers...${NC}"
RESTORE_PROFILES=""
ENV_FILE="${INSTALL_DIR}/docker/.env"
if [[ -f "$ENV_FILE" ]]; then
    RESTORE_PROFILES=$(grep '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "")
fi
if [[ -n "$RESTORE_PROFILES" ]]; then
    COMPOSE_PROFILES="$RESTORE_PROFILES" docker compose -f "$COMPOSE_FILE" up -d
else
    docker compose -f "$COMPOSE_FILE" up -d
fi
SERVICES_DOWN=false

echo ""
echo -e "${GREEN}=== Restore complete ===${NC}"
echo "Check status: docker compose -f ${COMPOSE_FILE} ps"
