#!/usr/bin/env bash
# backup.sh — Backup AGMind data: PostgreSQL, volumes, config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"

# Load backup config
if [[ -f "${INSTALL_DIR}/scripts/backup.conf" ]]; then
    source "${INSTALL_DIR}/scripts/backup.conf"
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/agmind}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
DATE=$(date +%Y-%m-%d_%H%M)
TARGET_DIR="${BACKUP_DIR}/${DATE}"

echo "=== AGMind Backup: ${DATE} ==="

# Create backup directory
mkdir -p "${TARGET_DIR}"

# 1. PostgreSQL dump
echo "  PostgreSQL..."
docker compose -f "$COMPOSE_FILE" exec -T db \
    pg_dump -U postgres dify 2>/dev/null | gzip > "${TARGET_DIR}/dify.sql.gz"

# Check if plugin DB exists and dump it too
docker compose -f "$COMPOSE_FILE" exec -T db \
    psql -U postgres -lqt 2>/dev/null | grep -q dify_plugin && \
    docker compose -f "$COMPOSE_FILE" exec -T db \
        pg_dump -U postgres dify_plugin 2>/dev/null | gzip > "${TARGET_DIR}/dify_plugin.sql.gz" || true

# 2. Vector store data
VECTOR_STORE=$(grep '^VECTOR_STORE=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")

if [[ "$VECTOR_STORE" == "qdrant" ]]; then
    echo "  Qdrant..."
    tar czf "${TARGET_DIR}/qdrant.tar.gz" \
        -C "${INSTALL_DIR}/docker/volumes/qdrant" . 2>/dev/null || true
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
cp "${INSTALL_DIR}/docker/docker-compose.yml" "${TARGET_DIR}/docker-compose.yml.backup" 2>/dev/null || true
cp "${INSTALL_DIR}/docker/nginx/nginx.conf" "${TARGET_DIR}/nginx.conf.backup" 2>/dev/null || true

# 7. Checksums
echo "  Checksums..."
cd "${TARGET_DIR}"
sha256sum *.gz *.backup 2>/dev/null > sha256sums.txt || true
cd - >/dev/null

# 8. Rotation — delete backups older than retention period
echo "  Ротация (удаление старше ${RETENTION_DAYS} дней)..."
find "${BACKUP_DIR}" -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -not -name "$(basename "$BACKUP_DIR")" -exec rm -rf {} \; 2>/dev/null || true

# 9. Remote backup (if configured)
if [[ "${REMOTE_BACKUP_ENABLED:-false}" == "true" && -n "${REMOTE_BACKUP_HOST:-}" ]]; then
    echo "  Удалённый бэкап → ${REMOTE_BACKUP_USER}@${REMOTE_BACKUP_HOST}..."
    ssh_opts=""
    if [[ -n "${REMOTE_BACKUP_KEY:-}" ]]; then
        ssh_opts="-e 'ssh -i ${REMOTE_BACKUP_KEY} -p ${REMOTE_BACKUP_PORT:-22}'"
    else
        ssh_opts="-e 'ssh -p ${REMOTE_BACKUP_PORT:-22}'"
    fi
    eval rsync -azP "$ssh_opts" \
        "${TARGET_DIR}/" \
        "${REMOTE_BACKUP_USER}@${REMOTE_BACKUP_HOST}:${REMOTE_BACKUP_PATH:-/var/backups/agmind-remote}/${DATE}/"
fi

# Summary
BACKUP_SIZE=$(du -sh "${TARGET_DIR}" 2>/dev/null | cut -f1)
echo ""
echo "=== Бэкап завершён ==="
echo "  Путь: ${TARGET_DIR}"
echo "  Размер: ${BACKUP_SIZE}"
echo "  Дата: $(date '+%Y-%m-%d %H:%M:%S')"
