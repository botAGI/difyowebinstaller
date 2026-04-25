#!/usr/bin/env bash
# uninstall.sh — Remove AGMind containers, volumes, and configuration
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# --- Validate INSTALL_DIR ---
INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
[[ "$INSTALL_DIR" == /opt/agmind* ]] || { echo -e "${RED}Invalid INSTALL_DIR: must start with /opt/agmind${NC}"; exit 1; }

COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"

# --- Trap for partial cleanup tracking ---
CLEANUP_STAGE=""
cleanup_status() {
    if [[ -n "$CLEANUP_STAGE" ]]; then
        echo -e "${YELLOW}Uninstall interrupted at stage: ${CLEANUP_STAGE}${NC}"
        echo -e "${YELLOW}Run again with --force to continue cleanup${NC}"
    fi
}
trap cleanup_status EXIT

# Parse flags
FORCE=false
DRY_RUN=false
KEEP_MODELS=false
for arg in "$@"; do
    case "$arg" in
        --force|-f)    FORCE=true ;;
        --dry-run)     DRY_RUN=true ;;
        --keep-models) KEEP_MODELS=true ;;
    esac
done

# Model cache volume names — preserved when --keep-models is set.
# Сохраняет gemma-4 (vllm), bge-m3 (embed), bge-reranker-v2-m3 (rerank), Ollama models, docling.
# Полезно при rerun install.sh без re-download (gemma-4 ~52GB на pretty slow link).
MODEL_VOLUMES_REGEX='^(agmind_ollama_data|docker_agmind_vllm_cache|docker_agmind_vllm_embed_cache|docker_agmind_vllm_rerank_cache|docker_agmind_docling_cache|docker_agmind_huggingface_cache)$'

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}=== DRY RUN — nothing will be deleted ===${NC}"
    echo ""
    echo "Will be removed:"
    if [[ "$KEEP_MODELS" == "true" ]]; then
        echo "  - Docker containers + volumes (EXCEPT model caches per --keep-models)"
        echo "      preserved: $(docker volume ls -q 2>/dev/null | grep -E "$MODEL_VOLUMES_REGEX" | tr '\n' ' ')"
    else
        echo "  - Docker containers and volumes for AGMind (including model caches — use --keep-models to preserve)"
    fi
    [[ -f /etc/systemd/system/agmind-tunnel.service ]] && echo "  - Systemd service agmind-tunnel"
    echo "  - AGMind cron jobs"
    [[ -f /etc/fail2ban/filter.d/agmind-nginx.conf ]] && echo "  - Fail2ban configuration"
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'AGMind' && echo "  - AGMind UFW rules"
    [[ -d "${INSTALL_DIR}/.age" ]] && echo "  - Age encryption keys"
    [[ -d "/opt/agmind-instances" ]] && echo "  - Multi-instance directories"
    echo "  - ${INSTALL_DIR}/"
    echo ""
    echo "Will NOT be removed:"
    echo "  - /var/backups/agmind/ (backups)"
    echo "  - Docker Engine"
    echo "  - Installed packages (age, sops, fail2ban)"
    exit 0
fi

echo -e "${RED}=== AGMind Uninstaller ===${NC}"
echo ""
echo "This will:"
echo "  1. Stop all AGMind containers"
echo "  2. Remove Docker volumes (databases, models, files)"
echo "  3. Remove configuration (/opt/agmind/)"
echo ""
echo -e "${RED}WARNING: All data will be PERMANENTLY DELETED!${NC}"
echo ""

if [[ "$FORCE" == "true" ]]; then
    DO_BACKUP="no"
else
    read -rp "Create backup before removal? (yes/no): " DO_BACKUP
fi
if [[ "$DO_BACKUP" == "yes" ]]; then
    echo -e "${YELLOW}Creating backup...${NC}"
    "${INSTALL_DIR}/scripts/backup.sh" || true
    echo ""
fi

if [[ "$FORCE" != "true" ]]; then
    read -rp "Are you sure? Type 'DELETE' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "DELETE" ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

echo ""

# 1. Stop and remove containers (ALL profiles must be active for compose down to catch everything)
CLEANUP_STAGE="docker-compose-down"
if [[ -f "$COMPOSE_FILE" ]]; then
    echo -e "${YELLOW}Stopping containers...${NC}"
    # Source ALL_COMPOSE_PROFILES if service-map.sh exists, otherwise use hardcoded superset
    ALL_PROFILES="monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei,reranker,vllm-embed,vllm-rerank,docling,litellm,searxng,notebook,dbgpt,crawl4ai,openwebui"
    if [[ -f "${INSTALL_DIR}/lib/service-map.sh" ]]; then
        ALL_PROFILES="$(grep '^ALL_COMPOSE_PROFILES=' "${INSTALL_DIR}/lib/service-map.sh" 2>/dev/null | cut -d'"' -f2 || echo "$ALL_PROFILES")"
    fi
    COMPOSE_PROFILES="$ALL_PROFILES" docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
fi

# Also stop any orphan agmind containers not managed by compose
docker ps -aq --filter "name=agmind-" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true

# 2. Remove Docker volumes (match both agmind_ and docker_agmind_ prefixes).
# When --keep-models is set, skip volumes matching MODEL_VOLUMES_REGEX so
# previously downloaded models (gemma-4 / bge-m3 / docling) survive uninstall
# and are reused on the next install.sh.
CLEANUP_STAGE="docker-volumes"
if [[ "$KEEP_MODELS" == "true" ]]; then
    echo -e "${YELLOW}Removing Docker volumes (preserving models — --keep-models)...${NC}"
else
    echo -e "${YELLOW}Removing Docker volumes...${NC}"
fi
docker volume ls -q 2>/dev/null | grep -E "^agmind_|^docker_agmind_" | while read -r vol; do
    if [[ "$KEEP_MODELS" == "true" ]] && [[ "$vol" =~ $MODEL_VOLUMES_REGEX ]]; then
        echo "  Preserved volume: $vol"
        continue
    fi
    docker volume rm "$vol" 2>/dev/null || true
    echo "  Removed volume: $vol"
done

# 3. Remove systemd services
CLEANUP_STAGE="systemd-services"
echo -e "${YELLOW}Removing systemd services...${NC}"
for svc in agmind-stack agmind-tunnel; do
    if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        echo "  Removed ${svc}.service"
    fi
done
systemctl daemon-reload 2>/dev/null || true

# 4. Remove cron entries (backup + secret rotation)
CLEANUP_STAGE="cron-entries"
echo -e "${YELLOW}Removing cron jobs...${NC}"
crontab -l 2>/dev/null | grep -v 'agmind\|rotate_secrets' | crontab - 2>/dev/null || true

# 5. Remove Fail2ban filter and jail
CLEANUP_STAGE="fail2ban"
if [[ -f /etc/fail2ban/filter.d/agmind-nginx.conf ]]; then
    echo -e "${YELLOW}Removing Fail2ban configuration...${NC}"
    rm -f /etc/fail2ban/filter.d/agmind-nginx.conf
    rm -f /etc/fail2ban/jail.d/agmind.conf
    systemctl restart fail2ban 2>/dev/null || true
fi

# 6. Remove UFW rules
CLEANUP_STAGE="ufw-rules"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'AGMind'; then
    echo -e "${YELLOW}Removing AGMind UFW rules...${NC}"
    ufw status numbered 2>/dev/null | grep -i 'agmind\|Grafana\|Portainer' | \
        awk -F'[][]' '{print $2}' | sort -rn | while read -r num; do
        ufw --force delete "$num" 2>/dev/null || true
    done
fi

# 7. Remove age encryption keys
CLEANUP_STAGE="age-keys"
if [[ -d "${INSTALL_DIR}/.age" ]]; then
    echo -e "${YELLOW}Removing encryption keys (.age)...${NC}"
    rm -rf "${INSTALL_DIR}/.age"
fi

# 8. Remove GPU profile file
CLEANUP_STAGE="gpu-profile"
rm -f "${INSTALL_DIR}/.agmind_gpu_profile" 2>/dev/null || true

# 9. Remove multi-instance directories
CLEANUP_STAGE="multi-instance"
if [[ -d "/opt/agmind-instances" ]]; then
    echo -e "${YELLOW}Multi-instance directories found in /opt/agmind-instances/${NC}"
    if [[ "$FORCE" == "true" ]]; then
        DEL_MULTI="yes"
    else
        read -rp "Remove multi-instance directories? (yes/no): " DEL_MULTI
    fi
    if [[ "$DEL_MULTI" == "yes" ]]; then
        # Stop all instances first
        for inst_dir in /opt/agmind-instances/*/; do
            [[ -f "${inst_dir}docker-compose.yml" ]] && \
                docker compose -f "${inst_dir}docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
        done
        rm -rf /opt/agmind-instances
        echo -e "${GREEN}Multi-instance directories removed${NC}"
    fi
fi

# 10. Remove CLI symlink
CLEANUP_STAGE="cli-symlink"
if [[ -L /usr/local/bin/agmind ]]; then
    echo -e "${YELLOW}Removing CLI symlink...${NC}"
    rm -f /usr/local/bin/agmind
fi

# 11. Remove installation directory
# When --keep-models is set, persist .secrets/surrealdb_password to
# /var/lib/agmind/state/ before INSTALL_DIR wipe — это обязательно потому что
# SurrealDB volume preserved (model cache) и пароль ДОЛЖЕН совпадать на
# next install.sh run, иначе auth fails (BACKLOG #999.1).
CLEANUP_STAGE="install-dir"
if [[ "$KEEP_MODELS" == "true" ]] && [[ -s "${INSTALL_DIR}/.secrets/surrealdb_password" ]]; then
    mkdir -p /var/lib/agmind/state 2>/dev/null || true
    cp "${INSTALL_DIR}/.secrets/surrealdb_password" /var/lib/agmind/state/surrealdb_password.preserved
    chmod 600 /var/lib/agmind/state/surrealdb_password.preserved
    echo "  Preserved SurrealDB password (will be restored on next install.sh)"
fi
echo -e "${YELLOW}Removing ${INSTALL_DIR}...${NC}"
rm -rf "${INSTALL_DIR}"

# All done — clear stage so trap doesn't fire
CLEANUP_STAGE=""

echo ""
echo -e "${GREEN}=== AGMind removed ===${NC}"
echo ""
echo "Backups saved in /var/backups/agmind/ (remove manually if needed)"
echo "Docker remains installed (remove manually if needed)"
