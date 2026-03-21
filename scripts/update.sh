#!/usr/bin/env bash
# ============================================================================
# AGMind Update System — Rolling updates with rollback
# Usage: /opt/agmind/scripts/update.sh [--auto] [--check] [--component <name>]
#        [--version <tag>] [--rollback <name>]
# ============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"
VERSIONS_FILE="${INSTALL_DIR}/versions.env"
MANIFEST_FILE="${INSTALL_DIR}/release-manifest.json"
ROLLBACK_DIR="${INSTALL_DIR}/.rollback"
ENV_FILE="${INSTALL_DIR}/docker/.env"
LOG_FILE="${INSTALL_DIR}/logs/update_history.log"
BACKUP_SCRIPT="${INSTALL_DIR}/scripts/backup.sh"
HEALTH_SCRIPT="${INSTALL_DIR}/scripts/health.sh"
REMOTE_VERSIONS_URL="https://raw.githubusercontent.com/botAGI/difyowebinstaller/main/templates/versions.env"
REMOTE_FETCH_TIMEOUT=15

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Short name -> versions.env key
declare -A NAME_TO_VERSION_KEY=(
    [dify-api]=DIFY_VERSION
    [dify-worker]=DIFY_VERSION
    [dify-web]=DIFY_VERSION
    [openwebui]=OPENWEBUI_VERSION
    [pipelines]=PIPELINES_VERSION
    [ollama]=OLLAMA_VERSION
    [vllm]=VLLM_VERSION
    [tei]=TEI_VERSION
    [postgres]=POSTGRES_VERSION
    [redis]=REDIS_VERSION
    [weaviate]=WEAVIATE_VERSION
    [qdrant]=QDRANT_VERSION
    [docling]=DOCLING_SERVE_VERSION
    [xinference]=XINFERENCE_VERSION
    [sandbox]=SANDBOX_VERSION
    [nginx]=NGINX_VERSION
    [plugin-daemon]=PLUGIN_DAEMON_VERSION
    [grafana]=GRAFANA_VERSION
    [portainer]=PORTAINER_VERSION
    [prometheus]=PROMETHEUS_VERSION
    [alertmanager]=ALERTMANAGER_VERSION
    [loki]=LOKI_VERSION
    [promtail]=PROMTAIL_VERSION
    [node-exporter]=NODE_EXPORTER_VERSION
    [cadvisor]=CADVISOR_VERSION
    [authelia]=AUTHELIA_VERSION
    [certbot]=CERTBOT_VERSION
    [squid]=SQUID_VERSION
)

# Short name -> compose service name(s)
declare -A NAME_TO_SERVICES=(
    [dify-api]="api worker web sandbox plugin_daemon"
    [dify-worker]="api worker web sandbox plugin_daemon"
    [dify-web]="api worker web sandbox plugin_daemon"
    [openwebui]="open-webui"
    [pipelines]="pipelines"
    [ollama]="ollama"
    [vllm]="vllm"
    [tei]="tei"
    [postgres]="db"
    [redis]="redis"
    [weaviate]="weaviate"
    [qdrant]="qdrant"
    [docling]="docling"
    [xinference]="xinference"
    [sandbox]="api worker web sandbox plugin_daemon"
    [nginx]="nginx"
    [plugin-daemon]="api worker web sandbox plugin_daemon"
    [grafana]="grafana"
    [portainer]="portainer"
    [prometheus]="prometheus"
    [alertmanager]="alertmanager"
    [loki]="loki"
    [promtail]="promtail"
    [node-exporter]="node-exporter"
    [cadvisor]="cadvisor"
    [authelia]="authelia"
    [certbot]="certbot"
    [squid]="ssrf_proxy"
)

# Service groups: components sharing the same image
declare -A SERVICE_GROUPS=(
    [dify]="dify-api dify-worker dify-web sandbox plugin-daemon"
)

# Define log functions BEFORE flock block that uses them
log_info()    { echo -e "${CYAN}-> $*${NC}"; }
log_success() { echo -e "${GREEN}OK $*${NC}"; }
log_warn()    { echo -e "${YELLOW}!! $*${NC}"; }
log_error()   { echo -e "${RED}!! $*${NC}"; }

# Exclusive lock — prevent parallel operations
LOCK_FILE="/var/lock/agmind-operation.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log_error "Another AGMind operation is running. Wait for it to finish."
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# Fix log file permissions
mkdir -p "$(dirname "$LOG_FILE")"
chmod 700 "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Cleanup on failure
cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Update interrupted. .env may have been partially updated."
        log_error "Check: diff ${ENV_FILE} ${ENV_FILE}.pre-update"
    fi
}
trap cleanup_on_failure EXIT INT TERM

AUTO_UPDATE="${AUTO_UPDATE:-false}"
CHECK_ONLY=false
COMPONENT=""
TARGET_VERSION=""
ROLLBACK_TARGET=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)       AUTO_UPDATE=true; shift ;;
        --check)      CHECK_ONLY=true; shift ;;
        --check-only) CHECK_ONLY=true; shift ;;
        --component)  COMPONENT="${2:-}"; shift 2 ;;
        --version)    TARGET_VERSION="${2:-}"; shift 2 ;;
        --rollback)   ROLLBACK_TARGET="${2:-}"; shift 2 ;;
        *)            log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Send notification via configured alert channel
send_notification() {
    local message="$1"
    [[ ! -f "$ENV_FILE" ]] && return 0

    local alert_mode
    alert_mode=$(grep '^ALERT_MODE=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "none")

    case "$alert_mode" in
        telegram)
            local token chat_id
            token=$(grep '^ALERT_TELEGRAM_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
            chat_id=$(grep '^ALERT_TELEGRAM_CHAT_ID=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
            if [[ -n "$token" && -n "$chat_id" ]]; then
                curl -sf --max-time 10 -K - \
                    -d "chat_id=${chat_id}" \
                    -d "text=${message}" \
                    -d "parse_mode=HTML" \
                    >/dev/null 2>&1 <<CURL_CFG || true
url = "https://api.telegram.org/bot${token}/sendMessage"
CURL_CFG
            fi
            ;;
        webhook)
            local url
            url=$(grep '^ALERT_WEBHOOK_URL=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
            if [[ -n "$url" ]]; then
                local escaped_msg
                escaped_msg=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
                curl -sf --max-time 10 -X POST "$url" \
                    -H "Content-Type: application/json" \
                    -d "{\"text\":\"${escaped_msg}\",\"source\":\"agmind-update\"}" \
                    >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

check_preflight() {
    log_info "Pre-flight checks..."
    local errors=0

    # Disk space
    local free_gb
    free_gb=$(df -BG "${INSTALL_DIR}" 2>/dev/null | awk 'NR==2{gsub(/G/,"");print $4}' || echo "0")
    if ! [[ "$free_gb" =~ ^[0-9]+$ ]]; then
        free_gb=0
    fi
    if [[ "$free_gb" -lt 5 ]]; then
        log_error "Insufficient disk space: ${free_gb}GB (5GB+ required)"
        errors=$((errors + 1))
    else
        log_success "Disk: ${free_gb}GB free"
    fi

    # Docker running
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running"
        errors=$((errors + 1))
    else
        log_success "Docker: running"
    fi

    # Compose file exists
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "docker-compose.yml not found: ${COMPOSE_FILE}"
        errors=$((errors + 1))
    fi

    return $errors
}

create_update_backup() {
    local tag
    tag="pre-update-$(date +%Y%m%d_%H%M%S)"
    log_info "Creating backup: ${tag}..."

    if [[ -x "$BACKUP_SCRIPT" ]]; then
        BACKUP_TAG="$tag" bash "$BACKUP_SCRIPT" >/dev/null 2>&1 && \
            log_success "Backup created: ${tag}" || \
            log_warn "Backup completed with errors (continuing)"
    else
        log_warn "Backup script not found -- skipping"
    fi
}

load_current_versions() {
    declare -gA CURRENT_VERSIONS
    if [[ -f "$ENV_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ _VERSION$ ]] && CURRENT_VERSIONS["$key"]="$value"
        done < <(grep '_VERSION=' "$ENV_FILE" 2>/dev/null | grep -v '^#')
    fi
}

fetch_remote_versions() {
    declare -gA NEW_VERSIONS
    local tmp_versions
    tmp_versions="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp_versions}'" RETURN

    log_info "Fetching available versions from GitHub..."
    if curl -sfL --max-time "$REMOTE_FETCH_TIMEOUT" "$REMOTE_VERSIONS_URL" -o "$tmp_versions" 2>/dev/null; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            [[ "$key" =~ _VERSION$ ]] && NEW_VERSIONS["$key"]="$value"
        done < "$tmp_versions"
        log_success "Remote versions fetched (${#NEW_VERSIONS[@]} components)"
    else
        log_warn "Cannot reach GitHub -- showing current versions only"
        log_warn "Use --component <name> --version <tag> for manual update"
        # Copy current as new so display_version_diff shows all OK
        for key in "${!CURRENT_VERSIONS[@]}"; do
            NEW_VERSIONS["$key"]="${CURRENT_VERSIONS[$key]}"
        done
    fi
}

# Save current state for rollback
save_rollback_state() {
    mkdir -p "$ROLLBACK_DIR"
    chmod 700 "$ROLLBACK_DIR"

    # Save current versions.env
    [[ -f "$VERSIONS_FILE" ]] && cp "$VERSIONS_FILE" "${ROLLBACK_DIR}/versions.env.bak"

    # Save current .env
    [[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "${ROLLBACK_DIR}/dot-env.bak"

    # Save current manifest
    [[ -f "$MANIFEST_FILE" ]] && cp "$MANIFEST_FILE" "${ROLLBACK_DIR}/release-manifest.json.bak"

    # Save running image IDs (digest format for deterministic rollback verification)
    if command -v docker &>/dev/null; then
        : > "${ROLLBACK_DIR}/running-images.txt"
        docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | while read -r cid; do
            local svc img_id
            svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$cid" 2>/dev/null || true)
            img_id=$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)
            [[ -n "$svc" && -n "$img_id" ]] && echo "${svc}=${img_id}" >> "${ROLLBACK_DIR}/running-images.txt"
        done
    fi

    log_success "Rollback state saved to ${ROLLBACK_DIR}"
}

# Rollback to previous state
perform_rollback() {
    log_warn "Rolling back to previous state..."

    if [[ -f "${ROLLBACK_DIR}/versions.env.bak" ]]; then
        cp "${ROLLBACK_DIR}/versions.env.bak" "$VERSIONS_FILE"
    fi
    if [[ -f "${ROLLBACK_DIR}/dot-env.bak" ]]; then
        cp "${ROLLBACK_DIR}/dot-env.bak" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    fi
    if [[ -f "${ROLLBACK_DIR}/release-manifest.json.bak" ]]; then
        cp "${ROLLBACK_DIR}/release-manifest.json.bak" "$MANIFEST_FILE"
    fi

    cd "${INSTALL_DIR}/docker"
    docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null || true

    log_success "Rollback complete"
    send_notification "AGMind Update ROLLBACK -- previous versions restored"
}

# Verify rollback by comparing running images against saved state
verify_rollback() {
    local saved="${ROLLBACK_DIR}/running-images.txt"
    [[ -f "$saved" ]] || { log_warn "No saved images to verify rollback against"; return 0; }

    local mismatches=0
    while IFS='=' read -r svc expected_id; do
        [[ -z "$svc" || -z "$expected_id" ]] && continue
        local cid current_id
        cid=$(docker compose -f "$COMPOSE_FILE" ps -q "$svc" 2>/dev/null | head -1)
        if [[ -z "$cid" ]]; then
            log_warn "Rollback verify: ${svc} not running"
            mismatches=$((mismatches + 1))
            continue
        fi
        current_id=$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)
        if [[ "$current_id" == "$expected_id" ]]; then
            log_success "Rollback verify: ${svc} OK"
        else
            log_error "Rollback verify: ${svc} mismatch (expected ${expected_id:0:20}..., got ${current_id:0:20}...)"
            mismatches=$((mismatches + 1))
        fi
    done < "$saved"

    return "$mismatches"
}

display_version_diff() {
    echo ""
    echo -e "${BOLD}Version comparison:${NC}"
    printf "  %-25s %-20s %-20s %s\n" "COMPONENT" "CURRENT" "AVAILABLE" "STATUS"
    echo "  $(printf '%.0s-' {1..80})"

    local has_updates=false
    # Build reverse map: version_key -> short name (pick shortest)
    declare -A KEY_TO_SHORT
    local name vk
    for name in "${!NAME_TO_VERSION_KEY[@]}"; do
        vk="${NAME_TO_VERSION_KEY[$name]}"
        if [[ -z "${KEY_TO_SHORT[$vk]+_}" ]] || [[ ${#name} -lt ${#KEY_TO_SHORT[$vk]} ]]; then
            KEY_TO_SHORT["$vk"]="$name"
        fi
    done

    local key current new status short
    for key in $(echo "${!NEW_VERSIONS[@]}" | tr ' ' '\n' | sort); do
        current="${CURRENT_VERSIONS[$key]:-unknown}"
        new="${NEW_VERSIONS[$key]}"
        status=""
        short="${KEY_TO_SHORT[$key]:-${key%_VERSION}}"

        if [[ "$current" == "$new" ]]; then
            status="${GREEN}OK${NC}"
        else
            status="${YELLOW}UPDATE${NC}"
            has_updates=true
        fi
        printf "  %-25s %-20s %-20s %b\n" "$short" "$current" "$new" "$status"
    done
    echo ""

    if [[ "$has_updates" == "false" ]]; then
        log_success "All versions are up to date"
        return 1
    fi
    return 0
}

# Get image name for a service from docker compose
get_service_image() {
    local service="$1"
    docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
svc = data.get('services', {}).get(sys.argv[1], {})
print(svc.get('image', 'unknown'))
" "$service" 2>/dev/null || echo ""
}

# Save current image digest for rollback
save_current_image() {
    local service="$1"
    local image
    image=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Image}}' "$service" 2>/dev/null | head -1)
    echo "$image"
}

update_service() {
    local service="$1"
    local old_image
    old_image=$(save_current_image "$service")

    log_info "Updating ${service}..."

    # Pull new image (with retries)
    local attempts=0
    while [[ $attempts -lt 3 ]]; do
        if docker compose -f "$COMPOSE_FILE" pull "$service" 2>/dev/null; then
            break
        fi
        attempts=$((attempts + 1))
        log_warn "Pull failed for ${service}, retry ${attempts}/3..."
        sleep 5
    done

    if [[ $attempts -ge 3 ]]; then
        log_error "Pull failed for ${service} after 3 attempts"
        return 1
    fi

    # Stop and restart service
    docker compose -f "$COMPOSE_FILE" stop "$service" 2>/dev/null
    docker compose -f "$COMPOSE_FILE" up -d "$service" 2>/dev/null

    # Wait for health check
    log_info "Waiting for healthcheck on ${service}..."
    local wait=0
    local max_wait=120
    while [[ $wait -lt $max_wait ]]; do
        local status
        status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$service" 2>/dev/null | head -1)
        if echo "$status" | grep -qi "healthy"; then
            log_success "${service}: healthy"
            return 0
        elif echo "$status" | grep -qi "unhealthy\|exit"; then
            log_error "${service}: unhealthy after update"
            rollback_service "$service" "$old_image"
            return 1
        fi
        sleep 5
        wait=$((wait + 5))
    done

    # Timeout -- check if at least running
    local status
    status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$service" 2>/dev/null | head -1)
    if echo "$status" | grep -qi "up\|running"; then
        log_warn "${service}: running but healthcheck did not pass within ${max_wait}s"
        return 0
    fi

    log_error "${service}: failed to start"
    rollback_service "$service" "$old_image"
    return 1
}

rollback_service() {
    local service="$1"
    local old_image="$2"

    if [[ -z "$old_image" ]]; then
        log_warn "No image to rollback ${service}"
        return 1
    fi

    log_warn "Rolling back ${service} -> ${old_image}..."

    # Restore pre-update config so compose reads OLD version tags
    if [[ -f "${ROLLBACK_DIR}/dot-env.bak" ]]; then
        cp "${ROLLBACK_DIR}/dot-env.bak" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    fi
    if [[ -f "${ROLLBACK_DIR}/versions.env.bak" ]]; then
        cp "${ROLLBACK_DIR}/versions.env.bak" "$VERSIONS_FILE"
    fi

    docker compose -f "$COMPOSE_FILE" stop "$service" 2>/dev/null
    docker compose -f "$COMPOSE_FILE" up -d "$service" 2>/dev/null

    send_notification "AGMind update FAILED for ${service}, rolled back to ${old_image}"
}

# Manual rollback: restore a specific component to the version saved in .rollback/
rollback_component() {
    local name="$1"

    if [[ -z "${NAME_TO_VERSION_KEY[$name]+_}" ]]; then
        log_error "Unknown component: ${name}"
        printf "  Available: %s\n" "$(echo "${!NAME_TO_VERSION_KEY[@]}" | tr ' ' '\n' | sort | tr '\n' ' ')"
        exit 1
    fi

    if [[ ! -f "${ROLLBACK_DIR}/dot-env.bak" ]]; then
        log_error "No rollback state found in ${ROLLBACK_DIR}/"
        log_error "Rollback is only available after a failed or recent update"
        exit 1
    fi

    local version_key="${NAME_TO_VERSION_KEY[$name]}"
    local services="${NAME_TO_SERVICES[$name]}"

    # Read old version from rollback backup
    local old_version
    old_version="$(grep "^${version_key}=" "${ROLLBACK_DIR}/dot-env.bak" 2>/dev/null | cut -d'=' -f2-)"
    if [[ -z "$old_version" ]]; then
        log_error "Cannot find ${version_key} in rollback state"
        exit 1
    fi

    local current_version="${CURRENT_VERSIONS[$version_key]:-unknown}"
    log_info "MANUAL_ROLLBACK: ${name} ${current_version} -> ${old_version}"

    # Restore version key in .env
    local env_tmp="${ENV_FILE}.tmp"
    grep -v "^${version_key}=" "$ENV_FILE" > "$env_tmp"
    echo "${version_key}=${old_version}" >> "$env_tmp"
    mv "$env_tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    # Restart affected services
    cd "${INSTALL_DIR}/docker"
    local restarted=0
    for svc in $services; do
        if docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' "$svc" 2>/dev/null | grep -q .; then
            docker compose -f "$COMPOSE_FILE" pull "$svc" 2>/dev/null || true
            docker compose -f "$COMPOSE_FILE" stop "$svc" 2>/dev/null
            docker compose -f "$COMPOSE_FILE" up -d "$svc" 2>/dev/null
            restarted=$((restarted + 1))
        fi
    done

    log_success "${name}: rolled back to ${old_version} (${restarted} service(s) restarted)"
    log_update "MANUAL_ROLLBACK" "${name}: ${current_version} -> ${old_version}"
    send_notification "AGMind ${name} rolled back: ${current_version} -> ${old_version}"
}

# Validate short name and show service group confirmation if needed
resolve_component() {
    local name="$1"
    if [[ -z "${NAME_TO_VERSION_KEY[$name]+_}" ]]; then
        log_error "Unknown component: ${name}"
        echo ""
        echo "Available components:"
        printf "  %s\n" "${!NAME_TO_VERSION_KEY[@]}" | sort
        exit 1
    fi

    local version_key="${NAME_TO_VERSION_KEY[$name]}"
    local services="${NAME_TO_SERVICES[$name]}"
    local service_count
    service_count=$(echo "$services" | wc -w)

    if [[ "$service_count" -gt 1 && "$AUTO_UPDATE" != "true" ]]; then
        log_warn "Component '${name}' shares image with: ${services}"
        read -rp "Also updating these services. Continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Cancelled."
            exit 0
        fi
    fi

    echo "${version_key}|${services}"
}

# Update a single component to a specific version
update_component() {
    local name="$1"
    local version="$2"

    local resolved
    resolved="$(resolve_component "$name")"
    local version_key="${resolved%%|*}"
    local services="${resolved#*|}"

    local current_version="${CURRENT_VERSIONS[$version_key]:-unknown}"

    # Pre-flight: check if any service for this component is actually running
    cd "${INSTALL_DIR}/docker"
    local running_count=0
    local svc
    for svc in $services; do
        if docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' "$svc" 2>/dev/null | grep -q .; then
            running_count=$((running_count + 1))
        fi
    done
    if [[ "$running_count" -eq 0 ]]; then
        log_warn "${name}: not in active profile — no running services found"
        log_warn "Enable the profile first, then retry: agmind update --component ${name} --version ${version}"
        log_update "SKIP" "${name}: not in active profile, no services running"
        return 1
    fi

    log_info "Updating ${name}: ${current_version} -> ${version}"

    # Save rollback state
    save_rollback_state

    # Update version in .env
    local env_tmp="${ENV_FILE}.tmp"
    grep -v "^${version_key}=" "$ENV_FILE" > "$env_tmp"
    echo "${version_key}=${version}" >> "$env_tmp"
    mv "$env_tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    # Update each service (already cd'd in pre-flight)
    local failed=0 updated=0
    for svc in $services; do
        # Check if service is running (skip if not in active profile)
        if ! docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' "$svc" 2>/dev/null | grep -q .; then
            log_info "${svc}: not running (skipped)"
            continue
        fi

        if update_service "$svc"; then
            updated=$((updated + 1))
        else
            failed=$((failed + 1))
            log_error "${name}: ${svc} failed -- rolling back all"
            # Restore .env from rollback
            if [[ -f "${ROLLBACK_DIR}/dot-env.bak" ]]; then
                cp "${ROLLBACK_DIR}/dot-env.bak" "$ENV_FILE"
                chmod 600 "$ENV_FILE"
            fi
            # Restart all affected services with old version
            local rollback_svc
            for rollback_svc in $services; do
                if docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' "$rollback_svc" 2>/dev/null | grep -q .; then
                    docker compose -f "$COMPOSE_FILE" up -d "$rollback_svc" 2>/dev/null || true
                fi
            done
            log_error "${name}: rolled back to ${current_version}"
            send_notification "AGMind update FAILED for ${name}, rolled back to ${current_version}"
            log_update "ROLLBACK" "${name}: ${version} failed healthcheck, rolled back to ${current_version}"
            return 1
        fi
    done

    log_success "${name}: updated to ${version} (${updated} service(s))"
    log_update "SUCCESS" "${name}: ${current_version} -> ${version}"
    send_notification "AGMind ${name} updated: ${current_version} -> ${version}"
    return 0
}

perform_rolling_update() {
    # Update order: infrastructure first, then app, then frontend
    local update_order=(
        "db"
        "redis"
        "api"
        "worker"
        "web"
        "sandbox"
        "plugin_daemon"
        "pipelines"
        "ollama"
        "vllm"
        "tei"
        "nginx"
        "open-webui"
        "weaviate"
        "qdrant"
        "docling"
        "xinference"
        "grafana"
        "portainer"
        "prometheus"
        "alertmanager"
        "loki"
        "promtail"
        "node-exporter"
        "cadvisor"
        "authelia"
    )

    local failed=0
    local updated=0
    local skipped=0
    local total_attempted=0

    local service
    for service in "${update_order[@]}"; do
        # Check if service is running
        if ! docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' "$service" 2>/dev/null | grep -q .; then
            skipped=$((skipped + 1))
            continue
        fi

        total_attempted=$((total_attempted + 1))
        if update_service "$service"; then
            updated=$((updated + 1))
        else
            failed=$((failed + 1))
            log_error "Update aborted due to error in ${service}"
            if [[ $failed -gt 0 ]]; then
                log_error "${updated}/${total_attempted} updated, ${service} failed, remaining skipped"
            fi
            break
        fi
    done

    echo ""
    echo -e "${BOLD}Result:${NC}"
    echo "  Updated: ${updated}"
    echo "  Skipped: ${skipped}"
    echo "  Errors: ${failed}"

    return $failed
}

log_update() {
    local status="$1"
    local details="$2"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${status} | ${details}" >> "$LOG_FILE"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    echo ""
    echo -e "${BOLD}${CYAN}=======================================${NC}"
    echo -e "${BOLD}${CYAN}  AGMind Update System${NC}"
    echo -e "${BOLD}${CYAN}=======================================${NC}"
    echo ""

    # Pre-flight
    if ! check_preflight; then
        log_error "Pre-flight checks failed"
        exit 1
    fi

    # Handle --rollback
    if [[ -n "$ROLLBACK_TARGET" ]]; then
        load_current_versions
        rollback_component "$ROLLBACK_TARGET"
        exit $?
    fi

    # Load current versions from .env
    load_current_versions

    # Handle --component with --version (no remote fetch needed)
    if [[ -n "$COMPONENT" && -n "$TARGET_VERSION" ]]; then
        update_component "$COMPONENT" "$TARGET_VERSION"
        exit $?
    fi

    # For --check or full update: fetch remote versions
    fetch_remote_versions

    # Display diff
    if ! display_version_diff; then
        log_update "SKIP" "All versions up to date"
        exit 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        exit 0
    fi

    # Handle --component without --version (use remote version)
    if [[ -n "$COMPONENT" ]]; then
        local version_key="${NAME_TO_VERSION_KEY[$COMPONENT]:-}"
        if [[ -z "$version_key" ]]; then
            log_error "Unknown component: ${COMPONENT}"
            exit 1
        fi
        local remote_version="${NEW_VERSIONS[$version_key]:-}"
        if [[ -z "$remote_version" ]]; then
            log_error "No remote version found for ${COMPONENT}"
            exit 1
        fi
        update_component "$COMPONENT" "$remote_version"
        exit $?
    fi

    # Full update (all components)
    if [[ "$AUTO_UPDATE" != "true" ]]; then
        read -rp "Update all components? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Cancelled."
            exit 0
        fi
    fi

    # Backup
    create_update_backup

    # Save rollback state (images + configs)
    save_rollback_state

    # Save .env backup for rollback
    cp "$ENV_FILE" "${ENV_FILE}.pre-update"
    chmod 600 "${ENV_FILE}.pre-update"

    # Apply new versions to .env BEFORE rolling update
    # (rolling update reads image tags from .env via compose)
    local key new current
    for key in "${!NEW_VERSIONS[@]}"; do
        new="${NEW_VERSIONS[$key]}"
        current="${CURRENT_VERSIONS[$key]:-}"
        [[ "$new" == "$current" ]] && continue
        [[ -z "$new" ]] && continue
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp"
        echo "${key}=${new}" >> "${ENV_FILE}.tmp"
        mv "${ENV_FILE}.tmp" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    done

    echo ""
    log_info "Starting rolling update..."
    echo ""

    cd "${INSTALL_DIR}/docker"

    if perform_rolling_update; then
        log_success "Update completed successfully!"
        log_update "SUCCESS" "Rolling update completed"
        send_notification "AGMind updated successfully on $(hostname 2>/dev/null || echo 'server')"
    else
        log_error "Update completed with errors"
        perform_rollback
        verify_rollback || log_warn "Some services may not have rolled back correctly"
        log_update "PARTIAL_FAILURE" "Some services failed to update"
        send_notification "AGMind update completed with errors on $(hostname 2>/dev/null || echo 'server')"
        exit 1
    fi
}

main "$@"
