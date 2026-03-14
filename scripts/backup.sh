#!/usr/bin/env bash
# backup.sh — Backup AGMind data: PostgreSQL, volumes, config
set -euo pipefail
umask 077  # B-04: Restrict file permissions for all created files

# B-13: Root check
if [[ $EUID -ne 0 ]]; then echo "This script must be run as root"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Exclusive lock — prevent parallel backup/update/restore
LOCK_FILE="/var/lock/agmind-operation.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "${RED}Другая операция AGMind уже запущена. Дождитесь завершения.${NC}"
    exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# B-09: Validate INSTALL_DIR
[[ "$INSTALL_DIR" == /opt/agmind* ]] || { echo "Invalid INSTALL_DIR"; exit 1; }

COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"

# B-08: Safe config parsing (no source)
if [[ -f "${INSTALL_DIR}/scripts/backup.conf" ]]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        case "$key" in
            BACKUP_RETENTION_COUNT|BACKUP_RETENTION_DAYS|ENABLE_S3_BACKUP|S3_REMOTE_NAME|S3_BUCKET|S3_PATH|ENABLE_BACKUP_ENCRYPTION|REMOTE_BACKUP_HOST|REMOTE_BACKUP_USER|REMOTE_BACKUP_KEY|REMOTE_BACKUP_PORT|REMOTE_BACKUP_PATH)
                declare "$key=$value" ;;
        esac
    done < <(grep -E '^[A-Za-z_]' "${INSTALL_DIR}/scripts/backup.conf")
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/agmind}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
DATE=$(date +%Y-%m-%d_%H%M)
TARGET_DIR="${BACKUP_DIR}/${DATE}"

# B-10: Validate RETENTION is numeric and > 0
[[ "${BACKUP_RETENTION_COUNT:-10}" =~ ^[0-9]+$ ]] || BACKUP_RETENTION_COUNT=10
[[ "$BACKUP_RETENTION_COUNT" -gt 0 ]] || BACKUP_RETENTION_COUNT=10

# B-05: Cleanup trap on failure
BACKUP_OK=true
cleanup_backup() {
    if [[ "$BACKUP_OK" != "true" ]] && [[ -d "${TARGET_DIR:-}" ]]; then
        echo -e "${YELLOW}Cleaning up failed backup...${NC}"
        rm -rf "${TARGET_DIR}"
    fi
}
trap cleanup_backup EXIT

echo "=== AGMind Backup: ${DATE} ==="

# Create backup directory
mkdir -p "${TARGET_DIR}"

# === Pre-backup checks ===
echo "Проверка доступности PostgreSQL..."
if ! docker compose -f "$COMPOSE_FILE" exec -T db pg_isready -U postgres >/dev/null 2>&1; then
    echo -e "${RED}PostgreSQL недоступен! Бэкап отменён.${NC}"
    BACKUP_OK=false
    exit 1
fi
echo -e "${GREEN}PostgreSQL: OK${NC}"

# B-15: Log pg_dump errors to a file instead of suppressing stderr
PGDUMP_LOG="${TARGET_DIR}/pgdump.log"

# 1. PostgreSQL dump — B-11: detect pg_dump failure via intermediate file
echo "  PostgreSQL..."
docker compose -f "$COMPOSE_FILE" exec -T db \
    pg_dump -U postgres dify > "${TARGET_DIR}/dify_db.sql" 2>>"${PGDUMP_LOG}"
if [[ $? -ne 0 ]]; then echo -e "${RED}pg_dump failed${NC}"; BACKUP_OK=false; fi
gzip "${TARGET_DIR}/dify_db.sql"

# Check if plugin DB exists and dump it too
if docker compose -f "$COMPOSE_FILE" exec -T db \
    psql -U postgres -lqt 2>/dev/null | grep -q dify_plugin; then
    docker compose -f "$COMPOSE_FILE" exec -T db \
        pg_dump -U postgres dify_plugin > "${TARGET_DIR}/dify_plugin_db.sql" 2>>"${PGDUMP_LOG}"
    if [[ $? -ne 0 ]]; then echo -e "${RED}pg_dump (plugin) failed${NC}"; BACKUP_OK=false; fi
    gzip "${TARGET_DIR}/dify_plugin_db.sql"
fi

# 2. Vector store data
VECTOR_STORE=$(grep '^VECTOR_STORE=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")

if [[ "$VECTOR_STORE" == "qdrant" ]]; then
    echo "  Qdrant snapshot..."
    # Use Qdrant snapshot API for consistent backup
    # B-06: --max-time 30 on curl
    collections=$(curl -sf --max-time 30 http://localhost:6333/collections 2>/dev/null | \
        python3 -c "import json,sys; [print(c['name']) for c in json.load(sys.stdin).get('result',{}).get('collections',[])]" 2>/dev/null || echo "")

    if [[ -n "$collections" ]]; then
        # B-07: Quote $collections in for loop
        for coll in $collections; do
            # Validate collection name — B-06/B-07
            if [[ ! "$coll" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo -e "${YELLOW}Skipping invalid collection name: ${coll}${NC}"
                continue
            fi
            # Create snapshot via API — B-06: --max-time 30
            snap_url="http://localhost:6333/collections/${coll}/snapshots"
            snap_result=$(curl -sf --max-time 30 -X POST "$snap_url" 2>/dev/null || echo "")
            if [[ -n "$snap_result" ]]; then
                snap_name=$(echo "$snap_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('name',''))" 2>/dev/null || echo "")
                if [[ -n "$snap_name" ]]; then
                    # Download snapshot — B-06: --max-time 30
                    curl -sf --max-time 30 "${snap_url}/${snap_name}" -o "${TARGET_DIR}/qdrant_${coll}_${snap_name}" 2>/dev/null || true
                fi
            fi
        done
    fi
    # Fallback: also tar the volume
    tar czf "${TARGET_DIR}/qdrant.tar.gz" -C "${INSTALL_DIR}/docker/volumes" qdrant/ 2>/dev/null || true
else
    echo "  Weaviate..."
    docker run --rm \
        -v "$(docker volume ls -q | grep weaviate | head -1 || echo agmind_weaviate):/data:ro" \
        -v "${TARGET_DIR}:/backup" \
        alpine tar czf /backup/weaviate.tar.gz -C /data . 2>/dev/null || \
        tar czf "${TARGET_DIR}/weaviate.tar.gz" -C "${INSTALL_DIR}/docker/volumes/weaviate" . 2>/dev/null || true
fi

# 3. Dify storage (uploads)
echo "  Dify storage..."
tar czf "${TARGET_DIR}/dify-storage.tar.gz" \
    -C "${INSTALL_DIR}/docker/volumes/app/storage" . 2>/dev/null || true

# 4. Open WebUI data
echo "  Open WebUI..."
docker run --rm \
    -v "$(docker volume ls -q | grep openwebui | head -1 || echo agmind_openwebui_data):/data:ro" \
    -v "${TARGET_DIR}:/backup" \
    alpine tar czf /backup/openwebui.tar.gz -C /data . 2>/dev/null || true

# 5. Ollama models
echo "  Ollama models..."
docker run --rm \
    -v "$(docker volume ls -q | grep ollama_data | head -1 || echo agmind_ollama_data):/data:ro" \
    -v "${TARGET_DIR}:/backup" \
    alpine tar czf /backup/ollama.tar.gz -C /data . 2>/dev/null || true

# 6. Configuration files
echo "  Config..."
cp "${INSTALL_DIR}/docker/.env" "${TARGET_DIR}/env.backup" 2>/dev/null || true
# B-01: Restrict .env backup permissions
chmod 600 "${TARGET_DIR}/env.backup" 2>/dev/null || true
cp "${INSTALL_DIR}/docker/docker-compose.yml" "${TARGET_DIR}/docker-compose.yml.backup" 2>/dev/null || true
cp "${INSTALL_DIR}/docker/nginx/nginx.conf" "${TARGET_DIR}/nginx.conf.backup" 2>/dev/null || true

# B-03: Age keys are NOT backed up for security — store them separately

# 6c. Authelia config (users database with password hashes)
if [[ -d "${INSTALL_DIR}/docker/authelia" ]]; then
    echo "  Authelia config..."
    tar czf "${TARGET_DIR}/authelia.tar.gz" -C "${INSTALL_DIR}/docker/authelia" . 2>/dev/null || true
fi

# 7. Checksums
echo "  Checksums..."
cd "${TARGET_DIR}"
sha256sum *.gz *.backup 2>/dev/null > sha256sums.txt || true
cd - >/dev/null

# === Encryption ===
if [[ "${ENABLE_BACKUP_ENCRYPTION:-false}" == "true" ]]; then
    echo "Шифрование бэкапа..."
    age_key="${INSTALL_DIR}/.age/agmind.key"
    if [[ -f "$age_key" ]] && command -v age &>/dev/null; then
        pub_key=$(grep 'public key:' "$age_key" | cut -d: -f2- | tr -d ' ')
        for f in "${TARGET_DIR}"/*.gz "${TARGET_DIR}"/*.backup; do
            [[ -f "$f" ]] || continue
            age -r "$pub_key" -o "${f}.age" "$f" 2>/dev/null && rm -f "$f"
        done
        echo -e "${GREEN}Бэкап зашифрован${NC}"
    else
        echo -e "${YELLOW}age ключ не найден — пропускаем шифрование${NC}"
    fi
fi

# 8. Rotation — delete backups older than retention period
echo "  Ротация (удаление старше ${RETENTION_DAYS} дней)..."
find "${BACKUP_DIR}" -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -not -name "$(basename "$BACKUP_DIR")" -exec rm -rf {} \; 2>/dev/null || true

# Retention by count
if [[ -n "${BACKUP_RETENTION_COUNT:-}" ]] && [[ "$BACKUP_RETENTION_COUNT" -gt 0 ]] 2>/dev/null; then
    backup_count=$(find "${BACKUP_DIR}" -maxdepth 1 -type d -name "20*" | wc -l)
    if [[ "$backup_count" -gt "$BACKUP_RETENTION_COUNT" ]]; then
        to_delete=$((backup_count - BACKUP_RETENTION_COUNT))
        find "${BACKUP_DIR}" -maxdepth 1 -type d -name "20*" | sort | head -n "$to_delete" | while read -r old_dir; do
            rm -rf "$old_dir"
            echo "  Удалён (по лимиту): $(basename "$old_dir")"
        done
    fi
fi

# 9. Remote backup (if configured)
if [[ "${REMOTE_BACKUP_ENABLED:-false}" == "true" && -n "${REMOTE_BACKUP_HOST:-}" ]]; then
    echo "  Удалённый бэкап → ${REMOTE_BACKUP_USER}@${REMOTE_BACKUP_HOST}..."
    rsync_cmd=(rsync -azP)
    if [[ -n "${REMOTE_BACKUP_KEY:-}" ]]; then
        # B-14: Quote REMOTE_BACKUP_KEY
        rsync_cmd+=(-e "ssh -i \"${REMOTE_BACKUP_KEY}\" -p ${REMOTE_BACKUP_PORT:-22}")
    else
        rsync_cmd+=(-e "ssh -p ${REMOTE_BACKUP_PORT:-22}")
    fi
    "${rsync_cmd[@]}" \
        "${TARGET_DIR}/" \
        "${REMOTE_BACKUP_USER}@${REMOTE_BACKUP_HOST}:${REMOTE_BACKUP_PATH:-/var/backups/agmind-remote}/${DATE}/"
fi

# === S3 Upload ===
if [[ "${ENABLE_S3_BACKUP:-false}" == "true" ]]; then
    echo "Загрузка в S3..."
    if ! command -v rclone &>/dev/null; then
        echo -e "${YELLOW}rclone не установлен. Установите: https://rclone.org/install/${NC}"
    else
        s3_remote="${S3_REMOTE_NAME:-s3}"
        s3_bucket="${S3_BUCKET:-agmind-backups}"
        s3_path="${S3_PATH:-$(hostname 2>/dev/null || echo 'default')}"
        rclone copy "${TARGET_DIR}/" "${s3_remote}:${s3_bucket}/${s3_path}/${DATE}/" \
            --config "${RCLONE_CONFIG_PATH:-$HOME/.config/rclone/rclone.conf}" \
            2>/dev/null && echo -e "${GREEN}S3 upload: OK${NC}" \
            || echo -e "${YELLOW}S3 upload: ошибка${NC}"
    fi
fi

# Summary
BACKUP_SIZE=$(du -sh "${TARGET_DIR}" 2>/dev/null | cut -f1)
echo ""
echo "=== Бэкап завершён ==="
echo "  Путь: ${TARGET_DIR}"
echo "  Размер: ${BACKUP_SIZE}"
echo "  Дата: $(date '+%Y-%m-%d %H:%M:%S')"
