#!/usr/bin/env bash
# multi-instance.sh — Create and manage isolated AGMind instances
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Defaults ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_BASE_DIR="/opt/agmind-instances"

# --- Global args (set by parse_args) ---
COMMAND=""
INSTANCE_NAME=""
PORT_OFFSET=""
INSTANCE_DOMAIN=""
BASE_DIR="${DEFAULT_BASE_DIR}"
FORCE=false

# --- Cleanup trap for create_instance ---
INSTANCE_DIR_CREATED=""
cleanup_instance() {
    if [[ -n "$INSTANCE_DIR_CREATED" ]] && [[ -d "$INSTANCE_DIR_CREATED" ]]; then
        echo -e "${RED}Instance creation failed — cleaning up...${NC}"
        rm -rf "$INSTANCE_DIR_CREATED"
    fi
}
trap cleanup_instance EXIT

# ============================================================================
# USAGE
# ============================================================================
show_usage() {
    cat <<EOF
Usage: multi-instance.sh <command> [options]

Commands:
  create    Create a new instance
  list      List all instances
  delete    Delete an instance
  status    Show instance status

Options:
  --name NAME           Instance name (required for create/delete)
  --port-offset N       Port offset from base (default: auto-increment)
  --domain DOMAIN       Domain for this instance
  --base-dir DIR        Base directory (default: ${DEFAULT_BASE_DIR})
  --force               Skip confirmation prompts

Examples:
  $(basename "$0") create --name client-alpha --domain alpha.example.com
  $(basename "$0") create --name client-beta --port-offset 200
  $(basename "$0") list
  $(basename "$0") status --name client-alpha
  $(basename "$0") delete --name client-alpha
EOF
}

# ============================================================================
# PARSE ARGS
# ============================================================================
parse_args() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi

    COMMAND="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                [[ $# -ge 2 ]] || { echo "Missing value for --name"; exit 1; }
                INSTANCE_NAME="$2"
                shift 2
                ;;
            --port-offset)
                [[ $# -ge 2 ]] || { echo "Missing value for --port-offset"; exit 1; }
                PORT_OFFSET="$2"
                shift 2
                ;;
            --domain)
                [[ $# -ge 2 ]] || { echo "Missing value for --domain"; exit 1; }
                INSTANCE_DOMAIN="$2"
                shift 2
                ;;
            --base-dir)
                [[ $# -ge 2 ]] || { echo "Missing value for --base-dir"; exit 1; }
                BASE_DIR="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
        esac
    done

    # --- Validate BASE_DIR ---
    [[ "$BASE_DIR" == /opt/agmind* ]] || { echo -e "${RED}Base dir must be under /opt/agmind*${NC}"; exit 1; }

    # --- Validate PORT_OFFSET ---
    if [[ -n "$PORT_OFFSET" ]]; then
        [[ "$PORT_OFFSET" =~ ^[0-9]+$ ]] || { echo -e "${RED}Port offset must be a positive integer${NC}"; exit 1; }
        [[ "$PORT_OFFSET" -gt 0 && "$PORT_OFFSET" -lt 65000 ]] || { echo -e "${RED}Port offset must be 1-65000${NC}"; exit 1; }
    fi
}

# ============================================================================
# GENERATE PASSWORD
# ============================================================================
generate_password() {
    local length="${1:-32}"
    openssl rand -hex "$length"
}

# ============================================================================
# AUTO PORT OFFSET
# ============================================================================
auto_port_offset() {
    local base_dir="$1"
    local max_offset=0

    if [[ ! -d "$base_dir" ]]; then
        echo 100
        return
    fi

    for instance_dir in "${base_dir}"/*/; do
        [[ -d "$instance_dir" ]] || continue
        local env_file="${instance_dir}.env"
        [[ -f "$env_file" ]] || continue
        local port
        port=$(grep -E '^EXPOSE_NGINX_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo "0")
        local offset=$((port - 80))
        if [[ $offset -gt $max_offset ]]; then
            max_offset=$offset
        fi
    done

    echo $((max_offset + 100))
}

# ============================================================================
# CREATE INSTANCE
# ============================================================================
create_instance() {
    local name="${INSTANCE_NAME}"
    local base_dir="${BASE_DIR}"
    local domain="${INSTANCE_DOMAIN}"
    local offset="${PORT_OFFSET}"

    # --- Validate name ---
    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: --name is required for create${NC}"
        show_usage
        exit 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        echo -e "${RED}Error: Instance name must be alphanumeric with hyphens only (cannot start/end with hyphen)${NC}"
        exit 1
    fi

    # --- Auto port offset ---
    if [[ -z "$offset" ]]; then
        offset=$(auto_port_offset "$base_dir")
        echo -e "${CYAN}Auto-assigned port offset: ${offset}${NC}"
    fi

    # --- Check existence ---
    local instance_dir="${base_dir}/${name}"
    if [[ -d "$instance_dir" ]]; then
        echo -e "${RED}Error: Instance '${name}' already exists at ${instance_dir}${NC}"
        exit 1
    fi

    echo -e "${BLUE}Creating instance '${name}'...${NC}"
    echo ""

    # --- Create directory structure ---
    mkdir -p "${instance_dir}"
    INSTANCE_DIR_CREATED="${instance_dir}"

    # --- Copy docker-compose.yml and configs ---
    if [[ -f "${INSTALLER_DIR}/templates/docker-compose.yml" ]]; then
        cp "${INSTALLER_DIR}/templates/docker-compose.yml" "${instance_dir}/docker-compose.yml"
    else
        echo -e "${RED}Error: docker-compose.yml template not found at ${INSTALLER_DIR}/templates/${NC}"
        exit 1
    fi

    # Copy nginx config if present
    if [[ -f "${INSTALLER_DIR}/templates/nginx.conf.template" ]]; then
        cp "${INSTALLER_DIR}/templates/nginx.conf.template" "${instance_dir}/nginx.conf"
    fi

    # Copy monitoring configs if present
    if [[ -d "${INSTALLER_DIR}/monitoring" ]]; then
        cp -r "${INSTALLER_DIR}/monitoring" "${instance_dir}/monitoring"
    fi

    # Copy branding if present
    if [[ -d "${INSTALLER_DIR}/branding" ]]; then
        cp -r "${INSTALLER_DIR}/branding" "${instance_dir}/branding"
    fi

    # --- Generate secrets ---
    local secret_key
    secret_key=$(generate_password 32)
    local db_password
    db_password=$(generate_password 16)
    local redis_password
    redis_password=$(generate_password 16)
    local sandbox_api_key
    sandbox_api_key=$(generate_password 16)
    local plugin_daemon_key
    plugin_daemon_key=$(generate_password 16)
    local plugin_inner_api_key
    plugin_inner_api_key=$(generate_password 16)
    local admin_token
    admin_token=$(generate_password 24)
    local grafana_password
    grafana_password=$(generate_password 12)
    local init_password
    init_password=$(generate_password 8)

    # --- Compute ports ---
    local nginx_port=$((80 + offset))
    local nginx_ssl_port=$((443 + offset))
    local grafana_port=$((3001 + offset))
    local portainer_port=$((9443 + offset))

    # --- Domain / URL setup ---
    local url_scheme="http"
    local url_host="${domain:-localhost:${nginx_port}}"
    if [[ -n "$domain" ]]; then
        url_scheme="https"
    fi
    local base_url="${url_scheme}://${url_host}"

    # --- Write .env ---
    umask 077
    cat > "${instance_dir}/.env" <<ENVEOF
# =========================================
# AGMind Instance: ${name}
# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =========================================

# --- Instance Identity ---
COMPOSE_PROJECT_NAME=agmind-${name}
INSTANCE_NAME=${name}

# --- Dify Version ---
DIFY_VERSION=1.13.0

# --- Secrets ---
SECRET_KEY=${secret_key}
DB_PASSWORD=${db_password}
REDIS_PASSWORD=${redis_password}
SANDBOX_API_KEY=${sandbox_api_key}
PLUGIN_DAEMON_KEY=${plugin_daemon_key}
PLUGIN_INNER_API_KEY=${plugin_inner_api_key}

# --- Database ---
DB_USERNAME=postgres
DB_HOST=db
DB_PORT=5432
DB_DATABASE=dify_${name//[-]/_}

# --- Redis ---
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_DB=0
REDIS_USE_SSL=false
BROKER_USE_SSL=false

# --- Init Admin ---
INIT_PASSWORD=${init_password}

# --- URLs ---
CONSOLE_WEB_URL=${base_url}
CONSOLE_API_URL=${base_url}
SERVICE_API_URL=${base_url}
APP_API_URL=${base_url}
APP_WEB_URL=${base_url}
FILES_URL=${base_url}

# --- Storage ---
STORAGE_TYPE=local

# --- Vector Store ---
VECTOR_STORE=weaviate
WEAVIATE_ENDPOINT=http://weaviate:8080
WEAVIATE_API_KEY=$(generate_password 16)
QDRANT_HOST=qdrant
QDRANT_PORT=6333
QDRANT_API_KEY=

# --- ETL ---
ETL_TYPE=dify
UNSTRUCTURED_API_URL=http://docling:8765

# --- Marketplace ---
MARKETPLACE_ENABLED=true
CHECK_UPDATE_URL=https://updates.dify.ai

# --- Sandbox ---
SANDBOX_ENABLE_NETWORK=true
SANDBOX_PORT=8194
SANDBOX_WORKER_TIMEOUT=15

# --- SSRF Proxy ---
SSRF_PROXY_HTTP_URL=http://ssrf_proxy:3128
SSRF_PROXY_HTTPS_URL=http://ssrf_proxy:3128

# --- Ollama ---
OLLAMA_API_BASE=http://ollama:11434
LLM_MODEL=
EMBEDDING_MODEL=bge-m3

# --- Nginx ---
EXPOSE_NGINX_PORT=${nginx_port}
EXPOSE_NGINX_SSL_PORT=${nginx_ssl_port}
NGINX_PORT=80
NGINX_SSL_PORT=443
NGINX_HTTPS_ENABLED=${domain:+true}
NGINX_HTTPS_ENABLED=${NGINX_HTTPS_ENABLED:-false}
NGINX_SERVER_NAME=${domain:-localhost}

# --- Certbot ---
CERTBOT_EMAIL=
CERTBOT_DOMAIN=${domain:-}

# --- Pipeline ---
DIFY_API_KEY=

# --- Admin Token ---
ADMIN_TOKEN=${admin_token}

# --- Open WebUI ---
COMPANY_NAME=${name}
ENABLE_SIGNUP=false
ENABLE_OLLAMA_API=false

# --- Plugin Daemon ---
PLUGIN_DAEMON_VERSION=0.1.0-local
PLUGIN_DAEMON_PORT=5002
PLUGIN_DB_DATABASE=dify_plugin_${name//[-]/_}
PLUGIN_STORAGE_TYPE=local
PLUGIN_STORAGE_LOCAL_PATH=/app/storage
PLUGIN_DIFY_INNER_API_URL=http://api:5001
MAX_PLUGIN_PACKAGE_SIZE=52428800
PLUGIN_PPROF_ENABLED=false

# --- Other versions ---
OLLAMA_VERSION=latest
POSTGRES_VERSION=15-alpine
REDIS_VERSION=7-alpine
WEAVIATE_VERSION=1.19.0
SANDBOX_VERSION=0.2.12
SQUID_VERSION=latest
NGINX_VERSION=alpine
CERTBOT_VERSION=latest

# --- TLS ---
TLS_MODE=none

# --- Monitoring ---
MONITORING_MODE=none
MONITORING_ENDPOINT=
MONITORING_TOKEN=
GRAFANA_PORT=${grafana_port}
GRAFANA_ADMIN_PASSWORD=${grafana_password}
PORTAINER_PORT=${portainer_port}

# --- Alerts ---
ALERT_MODE=none
ALERT_WEBHOOK_URL=
ALERT_TELEGRAM_TOKEN=
ALERT_TELEGRAM_CHAT_ID=

# --- Versions ---
QDRANT_VERSION=v1.12.1
DOCLING_VERSION=latest
XINFERENCE_VERSION=latest
GRAFANA_VERSION=latest
PORTAINER_VERSION=latest
CADVISOR_VERSION=latest
PROMETHEUS_VERSION=latest

# --- Security ---
ENABLE_UFW=false
ENABLE_FAIL2BAN=false
ENABLE_SOPS=false
SKIP_DOCKER_HARDENING=false
ENABLE_SECRET_ROTATION=false
LAN_SUBNET=192.168.0.0/16
VPN_INTERFACE=tun0

# --- Deploy ---
DEPLOY_ENV=PRODUCTION
LOG_LEVEL=INFO
MIGRATION_ENABLED=true
NEXT_TELEMETRY_DISABLED=1
FORCE_VERIFYING_SIGNATURE=true

# --- Network ---
AGMIND_NETWORK=agmind-${name}-network

# --- Healthchecks ---
HEALTHCHECK_INTERVAL=30s
HEALTHCHECK_RETRIES=5
ENVEOF
    chmod 600 "${instance_dir}/.env"

    # --- Save admin password to file instead of printing ---
    echo "${init_password}" > "${instance_dir}/.admin_password"
    chmod 600 "${instance_dir}/.admin_password"

    # Clear cleanup trap — creation succeeded
    INSTANCE_DIR_CREATED=""

    echo -e "${GREEN}Instance '${name}' created successfully!${NC}"
    echo ""
    echo -e "${CYAN}Instance details:${NC}"
    echo "  Directory:      ${instance_dir}"
    echo "  Project name:   agmind-${name}"
    echo "  HTTP port:      ${nginx_port}"
    echo "  HTTPS port:     ${nginx_ssl_port}"
    echo "  Grafana port:   ${grafana_port}"
    echo "  Portainer port: ${portainer_port}"
    echo "  DB name:        dify_${name//[-]/_}"
    echo "  Plugin DB:      dify_plugin_${name//[-]/_}"
    if [[ -n "$domain" ]]; then
        echo "  Domain:         ${domain}"
        echo "  URL:            ${base_url}"
    fi
    echo ""
    echo -e "${YELLOW}To start this instance:${NC}"
    echo "  cd ${instance_dir} && docker compose up -d"
    echo ""
    echo -e "  Admin password saved to: ${instance_dir}/.admin_password"
}

# ============================================================================
# LIST INSTANCES
# ============================================================================
list_instances() {
    local base_dir="${BASE_DIR}"

    if [[ ! -d "$base_dir" ]]; then
        echo -e "${YELLOW}No instances found. Base directory does not exist: ${base_dir}${NC}"
        exit 0
    fi

    local has_instances=false

    # Print header
    printf "${CYAN}%-20s %-12s %-30s %-10s %-20s %-10s${NC}\n" \
        "NAME" "STATUS" "DOMAIN" "PORT" "CREATED" "DISK"
    printf "%-20s %-12s %-30s %-10s %-20s %-10s\n" \
        "----" "------" "------" "----" "-------" "----"

    for instance_dir in "${base_dir}"/*/; do
        [[ -d "$instance_dir" ]] || continue
        local env_file="${instance_dir}.env"
        [[ -f "$env_file" ]] || continue

        has_instances=true

        local inst_name
        inst_name=$(basename "$instance_dir")

        # Read values from .env
        local inst_domain inst_port inst_project created_date
        inst_domain=$(grep -E '^NGINX_SERVER_NAME=' "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
        inst_port=$(grep -E '^EXPOSE_NGINX_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo "-")
        inst_project=$(grep -E '^COMPOSE_PROJECT_NAME=' "$env_file" 2>/dev/null | cut -d= -f2 || echo "agmind-${inst_name}")

        # Get creation date from .env comment or directory mtime
        created_date=$(grep -E '^# Created:' "$env_file" 2>/dev/null | sed 's/# Created: //' || echo "-")
        if [[ "$created_date" == "-" || -z "$created_date" ]]; then
            created_date=$(stat -f "%Sm" -t "%Y-%m-%d" "$instance_dir" 2>/dev/null || \
                           stat -c "%y" "$instance_dir" 2>/dev/null | cut -d' ' -f1 || \
                           echo "-")
        fi

        # Get disk usage
        local disk_usage
        disk_usage=$(du -sh "$instance_dir" 2>/dev/null | cut -f1 || echo "-")

        # Check container status
        local status
        if docker compose -f "${instance_dir}docker-compose.yml" \
            --project-name "$inst_project" ps --status running 2>/dev/null | grep -q .; then
            status="${GREEN}running${NC}"
        elif docker compose -f "${instance_dir}docker-compose.yml" \
            --project-name "$inst_project" ps 2>/dev/null | grep -q .; then
            status="${YELLOW}stopped${NC}"
        else
            status="${RED}down${NC}"
        fi

        printf "%-20s %-12b %-30s %-10s %-20s %-10s\n" \
            "$inst_name" "$status" "$inst_domain" "$inst_port" "$created_date" "$disk_usage"
    done

    if [[ "$has_instances" != "true" ]]; then
        echo -e "${YELLOW}No instances found in ${base_dir}${NC}"
    fi
}

# ============================================================================
# DELETE INSTANCE
# ============================================================================
delete_instance() {
    local name="${INSTANCE_NAME}"
    local base_dir="${BASE_DIR}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: --name is required for delete${NC}"
        show_usage
        exit 1
    fi

    local instance_dir="${base_dir}/${name}"

    if [[ ! -d "$instance_dir" ]]; then
        echo -e "${RED}Error: Instance '${name}' not found at ${instance_dir}${NC}"
        exit 1
    fi

    # --- Confirmation ---
    if [[ "$FORCE" != "true" ]]; then
        echo -e "${YELLOW}WARNING: This will permanently delete instance '${name}' and all its data.${NC}"
        echo "  Directory: ${instance_dir}"
        echo ""
        read -rp "Type the instance name to confirm deletion: " confirm
        if [[ "$confirm" != "$name" ]]; then
            echo -e "${RED}Deletion cancelled.${NC}"
            exit 1
        fi
    fi

    echo -e "${BLUE}Deleting instance '${name}'...${NC}"

    # --- Read project name ---
    local inst_project="agmind-${name}"
    if [[ -f "${instance_dir}/.env" ]]; then
        inst_project=$(grep -E '^COMPOSE_PROJECT_NAME=' "${instance_dir}/.env" 2>/dev/null | cut -d= -f2 || echo "$inst_project")
    fi

    # --- Stop and remove containers + volumes ---
    if [[ -f "${instance_dir}/docker-compose.yml" ]]; then
        echo "  Stopping containers..."
        docker compose -f "${instance_dir}/docker-compose.yml" \
            --project-name "$inst_project" \
            down -v --remove-orphans 2>/dev/null || true
    fi

    # --- Remove directory ---
    echo "  Removing directory..."
    rm -rf "${instance_dir}"

    echo -e "${GREEN}Instance '${name}' deleted successfully.${NC}"
}

# ============================================================================
# SHOW STATUS
# ============================================================================
show_status() {
    local name="${INSTANCE_NAME}"
    local base_dir="${BASE_DIR}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: --name is required for status${NC}"
        show_usage
        exit 1
    fi

    local instance_dir="${base_dir}/${name}"

    if [[ ! -d "$instance_dir" ]]; then
        echo -e "${RED}Error: Instance '${name}' not found at ${instance_dir}${NC}"
        exit 1
    fi

    local env_file="${instance_dir}/.env"

    echo -e "${CYAN}=== Instance: ${name} ===${NC}"
    echo ""

    # --- Read key config values ---
    if [[ -f "$env_file" ]]; then
        local inst_project inst_domain inst_port inst_ssl_port grafana_port portainer_port db_name
        inst_project=$(grep -E '^COMPOSE_PROJECT_NAME=' "$env_file" | cut -d= -f2 || echo "-")
        inst_domain=$(grep -E '^NGINX_SERVER_NAME=' "$env_file" | cut -d= -f2 || echo "-")
        inst_port=$(grep -E '^EXPOSE_NGINX_PORT=' "$env_file" | cut -d= -f2 || echo "-")
        inst_ssl_port=$(grep -E '^EXPOSE_NGINX_SSL_PORT=' "$env_file" | cut -d= -f2 || echo "-")
        grafana_port=$(grep -E '^GRAFANA_PORT=' "$env_file" | cut -d= -f2 || echo "-")
        portainer_port=$(grep -E '^PORTAINER_PORT=' "$env_file" | cut -d= -f2 || echo "-")
        db_name=$(grep -E '^DB_DATABASE=' "$env_file" | cut -d= -f2 || echo "-")

        echo -e "${BLUE}Configuration:${NC}"
        echo "  Project name:   ${inst_project}"
        echo "  Domain:         ${inst_domain}"
        echo "  HTTP port:      ${inst_port}"
        echo "  HTTPS port:     ${inst_ssl_port}"
        echo "  Grafana port:   ${grafana_port}"
        echo "  Portainer port: ${portainer_port}"
        echo "  Database:       ${db_name}"
        echo "  Directory:      ${instance_dir}"
        echo ""
    fi

    # --- Disk usage ---
    echo -e "${BLUE}Disk usage:${NC}"
    du -sh "${instance_dir}" 2>/dev/null | awk '{print "  Total: " $1}'
    echo ""

    # --- Container status ---
    echo -e "${BLUE}Containers:${NC}"
    local inst_project="agmind-${name}"
    if [[ -f "$env_file" ]]; then
        inst_project=$(grep -E '^COMPOSE_PROJECT_NAME=' "$env_file" | cut -d= -f2 || echo "$inst_project")
    fi

    if [[ -f "${instance_dir}/docker-compose.yml" ]]; then
        docker compose -f "${instance_dir}/docker-compose.yml" \
            --project-name "$inst_project" \
            ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
            echo "  (not running)"
    else
        echo "  (no docker-compose.yml found)"
    fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    parse_args "$@"

    case "${COMMAND:-}" in
        create) create_instance ;;
        list)   list_instances ;;
        delete) delete_instance ;;
        status) show_status ;;
        *)      show_usage; exit 1 ;;
    esac
}

main "$@"
