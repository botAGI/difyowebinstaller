#!/usr/bin/env bash
# ============================================================================
# AGMind Update System — Bundle updates via GitHub Releases
# Usage: /opt/agmind/scripts/update.sh [--auto] [--check] [--component <name>]
#        [--version <tag>] [--rollback [<component>]] [--force]
# ============================================================================
set -euo pipefail
export LC_ALL=C  # Ensure consistent regex behavior across locales (BUG-V3-041)

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
COMPOSE_FILE="${INSTALL_DIR}/docker/docker-compose.yml"
VERSIONS_FILE="${INSTALL_DIR}/versions.env"
MANIFEST_FILE="${INSTALL_DIR}/release-manifest.json"
ROLLBACK_DIR="${INSTALL_DIR}/.rollback"
ENV_FILE="${INSTALL_DIR}/docker/.env"
LOG_FILE="${INSTALL_DIR}/logs/update_history.log"
BACKUP_SCRIPT="${INSTALL_DIR}/scripts/backup.sh"
HEALTH_SCRIPT="${INSTALL_DIR}/scripts/health.sh"
GITHUB_API_URL="https://api.github.com/repos/botAGI/AGmind/releases/latest"
RELEASE_FILE="${INSTALL_DIR}/RELEASE"
REMOTE_FETCH_TIMEOUT=15

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Define log functions BEFORE flock block that uses them
log_info()    { echo -e "${CYAN}-> $*${NC}"; }
log_success() { echo -e "${GREEN}OK $*${NC}"; }
log_warn()    { echo -e "${YELLOW}!! $*${NC}"; }
log_error()   { echo -e "${RED}!! $*${NC}"; }

# Service mappings — single source of truth
_UPDATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/service-map.sh
source "${_UPDATE_SCRIPT_DIR}/../lib/service-map.sh"

# Source compose lib for validate_images_exist() (and helpers)
# shellcheck source=../lib/compose.sh
source "${_UPDATE_SCRIPT_DIR}/../lib/compose.sh" 2>/dev/null || true

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
ROLLBACK_MODE=false
FORCE=false
UPDATE_BRANCH="${UPDATE_BRANCH:-release}"
SCRIPTS_ONLY="${SCRIPTS_ONLY:-false}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)         AUTO_UPDATE=true; shift ;;
        --check)        CHECK_ONLY=true; shift ;;
        --check-only)   CHECK_ONLY=true; shift ;;
        --component)    COMPONENT="${2:-}"; shift 2 ;;
        --version)      TARGET_VERSION="${2:-}"; shift 2 ;;
        --rollback)
            ROLLBACK_MODE=true
            # Next arg is optional component name (if not a flag)
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                ROLLBACK_TARGET="$2"; shift 2
            else
                ROLLBACK_TARGET=""; shift
            fi
            ;;
        --force)        FORCE=true; shift ;;
        --main)         UPDATE_BRANCH="main"; shift ;;
        --scripts-only) SCRIPTS_ONLY=true; shift ;;
        *)              log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Escape HTML special characters for Telegram parse_mode=HTML
_escape_html() {
    local text="$1"
    # Order matters: & first to avoid double-escaping
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    echo "$text"
}

# Send notification via configured alert channel
send_notification() {
    local message="$1"
    message="$(_escape_html "$message")"
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

# Update installer scripts via git pull from release (or main) branch
update_scripts() {
    local branch="${UPDATE_BRANCH:-release}"
    log_info "Updating scripts from branch: ${branch}..."

    cd "$INSTALL_DIR" || { log_error "Cannot cd to $INSTALL_DIR"; return 1; }

    # Ensure we are in a git repo
    if [[ ! -d ".git" ]]; then
        log_error "INSTALL_DIR is not a git repository — cannot update scripts"
        log_error "Manual fix: cd $INSTALL_DIR && git init && git remote add origin https://github.com/botAGI/AGmind.git"
        return 1
    fi

    # Stash any local changes (safety net per Pitfall C-01)
    local stash_msg="agmind-update-$(date +%s)"
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        log_info "Stashing local changes before pull..."
        git stash push -m "$stash_msg" --include-untracked 2>/dev/null || true
    fi

    # Fetch and checkout target branch
    git fetch origin "$branch" 2>/dev/null || {
        log_error "Failed to fetch branch '${branch}' from origin"
        log_error "Check network connectivity or run: git -C $INSTALL_DIR fetch origin"
        return 1
    }

    # Fast-forward pull (no merge commits)
    git checkout "$branch" 2>/dev/null || {
        log_error "Failed to checkout branch '${branch}'"
        return 1
    }

    git pull --ff-only origin "$branch" 2>/dev/null || {
        log_error "Failed to pull from '${branch}' — possible conflict"
        log_error "Manual fix: cd $INSTALL_DIR && git stash && git pull origin $branch"
        return 1
    }

    # If --main was used, switch back to release for next time
    if [[ "$branch" == "main" ]]; then
        log_warn "One-time pull from 'main' complete. Next 'agmind update' will use 'release'."
        # Do NOT persist the branch change -- UPDATE_BRANCH defaults to release
    fi

    log_success "Scripts updated from branch: ${branch}"
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

# Check for PostgreSQL major version change (data-incompatible upgrade)
check_pg_major_upgrade() {
    local current_pg="${CURRENT_VERSIONS[POSTGRES_VERSION]:-}"
    local new_pg="${NEW_VERSIONS[POSTGRES_VERSION]:-}"
    [[ -z "$current_pg" || -z "$new_pg" ]] && return 0
    [[ "$current_pg" == "$new_pg" ]] && return 0

    # Extract major version: "16-alpine" -> "16", "17.1-alpine" -> "17"
    local pg_major_old="${current_pg%%[.-]*}"
    local pg_major_new="${new_pg%%[.-]*}"

    if [[ "$pg_major_old" != "$pg_major_new" ]]; then
        echo ""
        log_error "PostgreSQL major upgrade detected: ${pg_major_old} -> ${pg_major_new}"
        log_error "Major PostgreSQL upgrades require manual data migration."
        log_error ""
        log_error "Before updating, run:"
        log_error "  1. pg_dump: docker exec agmind-db pg_dumpall -U postgres > backup_pg${pg_major_old}.sql"
        log_error "  2. Verify backup: ls -lh backup_pg${pg_major_old}.sql"
        log_error "  3. Then re-run: agmind update --force"
        log_error ""
        log_error "See: https://github.com/botAGI/AGmind/blob/main/docs/pg-upgrade.md"
        echo ""
        if [[ "$FORCE" != "true" ]]; then
            log_update "BLOCKED" "PostgreSQL major upgrade ${pg_major_old}->${pg_major_new} — manual migration required"
            exit 1
        fi
        log_warn "Continuing with --force (PostgreSQL major upgrade — operator responsibility)"
    fi
}

# Get current release tag from RELEASE file.
# BUG-V3-044: fallback chain when RELEASE file missing.
get_current_release() {
    if [[ -f "$RELEASE_FILE" ]]; then
        cat "$RELEASE_FILE" 2>/dev/null | tr -d '[:space:]'
        return
    fi
    # Fallback 1: exact tag on current commit
    local tag=""
    tag="$(cd "${INSTALL_DIR}" && git describe --tags --exact-match 2>/dev/null || true)"
    # Fallback 2: nearest tag + commits ahead (e.g. v1.2-3-gabcdef)
    [[ -z "$tag" ]] && tag="$(cd "${INSTALL_DIR}" && git describe --tags --always 2>/dev/null || true)"
    # Fallback 3: hash of versions.env content
    if [[ -z "$tag" && -f "${INSTALL_DIR}/docker/versions.env" ]]; then
        tag="dev-$(md5sum "${INSTALL_DIR}/docker/versions.env" | cut -c1-8)"
    fi
    if [[ -n "$tag" ]]; then
        # Persist for next time
        echo "$tag" > "$RELEASE_FILE"
        echo "$tag"
    else
        echo "unknown"
    fi
}

# Fetch latest release info from GitHub Releases API
# Sets globals: RELEASE_TAG, RELEASE_NAME, RELEASE_DATE, RELEASE_NOTES,
#               DOWNLOADED_VERSIONS_FILE, NEW_VERSIONS
fetch_release_info() {
    log_info "Fetching latest release info from GitHub..."

    local json_data
    json_data=$(curl -sf --max-time "$REMOTE_FETCH_TIMEOUT" "$GITHUB_API_URL") || {
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$REMOTE_FETCH_TIMEOUT" "$GITHUB_API_URL" 2>/dev/null || echo "000")
        if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
            log_warn "GitHub API rate limit exceeded (HTTP ${http_code})"
            log_warn "Version diff will use locally cached versions.env"
        else
            log_error "Cannot reach GitHub Releases API (HTTP ${http_code})"
            log_error "Check network or try: agmind update --component <name> --version <tag>"
        fi
        # Continue without release notes — versions.env already fetched from branch
        RELEASE_TAG=""; RELEASE_NAME=""; RELEASE_DATE=""; RELEASE_NOTES=""
        json_data=""
    }

    # Parse tag/name/date/notes from API response (if available)
    if [[ -n "$json_data" ]]; then
        eval "$(echo "$json_data" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tag = d.get('tag_name', '')
name = d.get('name', '')
date = d.get('published_at', '')[:10]
body = d.get('body', '').replace(\"'\", \"'\\\\''\")
print(f\"RELEASE_TAG='{tag}'\")
print(f\"RELEASE_NAME='{name}'\")
print(f\"RELEASE_DATE='{date}'\")
print(f\"RELEASE_NOTES='{body}'\")
")" || { log_warn "Failed to parse GitHub API response — continuing without release notes"; RELEASE_TAG=""; RELEASE_NAME=""; RELEASE_DATE=""; RELEASE_NOTES=""; }
    fi

    # Download versions.env from branch (not from release assets)
    local versions_url="https://raw.githubusercontent.com/botAGI/AGmind/${UPDATE_BRANCH}/templates/versions.env"
    local tmp_versions
    tmp_versions=$(mktemp)
    curl -sf --max-time "$REMOTE_FETCH_TIMEOUT" "$versions_url" -o "$tmp_versions" || {
        log_error "Failed to download versions.env from branch '${UPDATE_BRANCH}'"
        log_error "URL: ${versions_url}"
        rm -f "$tmp_versions"
        return 1
    }

    # CRITICAL: expose temp file path as global for main() to copy to VERSIONS_FILE
    DOWNLOADED_VERSIONS_FILE="$tmp_versions"

    # Parse into NEW_VERSIONS associative array
    declare -gA NEW_VERSIONS
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | tr -d '[:space:]')
        # Only include *_VERSION keys — skip config keys like VLLM_CUDA_SUFFIX (BUG-V3-045)
        [[ "$key" == *_VERSION ]] || continue
        NEW_VERSIONS["$key"]="$value"
    done < "$tmp_versions"

    if [[ -n "${RELEASE_TAG:-}" ]]; then
        log_success "Release info fetched: ${RELEASE_TAG} (${#NEW_VERSIONS[@]} versions)"
    else
        log_success "Version info fetched from branch '${UPDATE_BRANCH}' (${#NEW_VERSIONS[@]} versions)"
    fi
}

# Display bundle diff between current and latest release
# Returns 0 if updates available, 1 if already up to date
display_bundle_diff() {
    local current_release
    current_release="$(get_current_release)"

    # Quick check: if release tag matches current, skip the diff
    if [[ -n "${RELEASE_TAG:-}" && "$current_release" == "$RELEASE_TAG" ]]; then
        echo ""
        echo -e "${GREEN}AGMind ${current_release} — актуальная версия.${NC}"
        echo ""
        return 1  # return 1 = no updates available
    fi

    echo ""
    echo -e "Current release: ${BOLD}${current_release}${NC}"
    echo -e "Latest release:  ${BOLD}${RELEASE_TAG:-unknown}${NC}${RELEASE_DATE:+ (${RELEASE_DATE})}"
    echo ""
    echo "Changes:"

    # Build reverse map: version_key -> shortest short name
    declare -A KEY_TO_SHORT
    local name vk
    for name in "${!NAME_TO_VERSION_KEY[@]}"; do
        vk="${NAME_TO_VERSION_KEY[$name]}"
        if [[ -z "${KEY_TO_SHORT[$vk]+_}" ]] || [[ ${#name} -lt ${#KEY_TO_SHORT[$vk]} ]]; then
            KEY_TO_SHORT["$vk"]="$name"
        fi
    done

    local changed_count=0
    local unchanged_count=0
    local key current_ver new_ver short_name

    # First pass: show changed components
    for key in $(echo "${!NEW_VERSIONS[@]}" | tr ' ' '\n' | sort); do
        new_ver="${NEW_VERSIONS[$key]}"
        current_ver="${CURRENT_VERSIONS[$key]:-unknown}"
        short_name="${KEY_TO_SHORT[$key]:-${key%_VERSION}}"

        if [[ "$current_ver" != "$new_ver" ]]; then
            printf "  %-25s %-10s ->  %s\n" "$short_name" "$current_ver" "$new_ver"
            changed_count=$((changed_count + 1))
        else
            unchanged_count=$((unchanged_count + 1))
        fi
    done

    if [[ $unchanged_count -gt 0 ]]; then
        echo "  (${unchanged_count} components unchanged)"
    fi

    # Show full release notes
    if [[ -n "${RELEASE_NOTES:-}" ]]; then
        echo ""
        echo -e "${BOLD}Release notes (${RELEASE_TAG}):${NC}"
        echo ""
        while IFS= read -r line; do
            echo "  ${line}"
        done <<< "${RELEASE_NOTES}"
        echo ""
        echo -e "  ${CYAN}https://github.com/botAGI/AGmind/releases/tag/${RELEASE_TAG}${NC}"
    elif [[ -z "${RELEASE_TAG:-}" ]]; then
        echo ""
        echo -e "${YELLOW}Release notes unavailable (GitHub API error or rate limit).${NC}"
        echo "  Check manually: https://github.com/botAGI/AGmind/releases"
    fi
    echo ""

    return 0
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

    # Save current RELEASE tag
    [[ -f "$RELEASE_FILE" ]] && cp "$RELEASE_FILE" "${ROLLBACK_DIR}/RELEASE.bak"

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
    if [[ -f "${ROLLBACK_DIR}/RELEASE.bak" ]]; then
        cp "${ROLLBACK_DIR}/RELEASE.bak" "$RELEASE_FILE"
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

    # Restart affected services (pull all, then recreate together)
    cd "${INSTALL_DIR}/docker"
    local svc
    for svc in $services; do
        docker compose -f "$COMPOSE_FILE" pull "$svc" 2>/dev/null || true
    done
    # shellcheck disable=SC2086
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate $services 2>/dev/null || true

    # Ensure entire stack is healthy — picks up anything that fell over via depends_on
    docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null || true

    log_success "${name}: rolled back to ${old_version}"
    log_update "MANUAL_ROLLBACK" "${name}: ${current_version} -> ${old_version}"
    send_notification "AGMind ${name} rolled back: ${current_version} -> ${old_version}"
}

# Bundle rollback: restore entire stack to state saved in .rollback/
rollback_bundle() {
    if [[ ! -f "${ROLLBACK_DIR}/dot-env.bak" ]]; then
        log_error "No rollback state found in ${ROLLBACK_DIR}/"
        log_error "Rollback is only available after a failed or recent update"
        exit 1
    fi

    local current_release
    current_release="$(get_current_release)"
    local rollback_release="unknown"
    if [[ -f "${ROLLBACK_DIR}/RELEASE.bak" ]]; then
        rollback_release="$(cat "${ROLLBACK_DIR}/RELEASE.bak" 2>/dev/null | tr -d '[:space:]')"
    fi

    log_warn "Rolling back: ${current_release} -> ${rollback_release}"

    perform_rollback

    # Restore RELEASE file (perform_rollback already does this, but be explicit)
    if [[ -f "${ROLLBACK_DIR}/RELEASE.bak" ]]; then
        cp "${ROLLBACK_DIR}/RELEASE.bak" "$RELEASE_FILE"
    fi

    verify_rollback || log_warn "Some services may not have rolled back correctly"

    # Post-rollback health verification (UPDT-03)
    log_info "Running post-rollback health check..."
    local doctor_output
    if doctor_output=$("${INSTALL_DIR}/scripts/agmind.sh" doctor --json 2>&1); then
        log_success "Post-rollback health check passed"
    else
        log_warn "Post-rollback health check found issues:"
        echo "$doctor_output" | head -20
    fi
    # Log doctor output to install.log
    mkdir -p "${INSTALL_DIR}/logs"
    {
        echo "--- Post-rollback doctor $(date '+%Y-%m-%d %H:%M:%S') ---"
        echo "$doctor_output"
        echo "--- End doctor ---"
    } >> "${INSTALL_DIR}/logs/install.log"

    log_update "MANUAL_ROLLBACK" "Bundle rollback: ${current_release} -> ${rollback_release}"
    send_notification "AGMind rolled back: ${current_release} -> ${rollback_release}"
}

# Validate short name and show service group confirmation if needed
resolve_component() {
    local name="$1"
    if [[ -z "${NAME_TO_VERSION_KEY[$name]+_}" ]]; then
        log_error "Unknown component: ${name}" >&2
        echo "" >&2
        echo "Available components:" >&2
        printf "  %s\n" "${!NAME_TO_VERSION_KEY[@]}" | sort >&2
        return 1
    fi

    local version_key="${NAME_TO_VERSION_KEY[$name]}"
    local services="${NAME_TO_SERVICES[$name]}"
    local service_count
    service_count=$(echo "$services" | wc -w)

    if [[ "$service_count" -gt 1 && "$AUTO_UPDATE" != "true" && "$FORCE" != "true" ]]; then
        log_warn "Component '${name}' shares image with: ${services}" >&2
        read -rp "Also updating these services. Continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Cancelled." >&2
            return 1
        fi
    fi

    echo "${version_key}|${services}"
}

# Update a single component to a specific version
update_component() {
    local name="$1"
    local version="$2"

    # Emergency mode warning (EMRG-01, EMRG-02)
    if [[ "$FORCE" != "true" ]]; then
        echo ""
        echo -e "${YELLOW}=========================================${NC}"
        echo -e "${YELLOW}  WARNING: Single-component update${NC}"
        echo -e "${YELLOW}  bypasses release compatibility.${NC}"
        echo -e "${YELLOW}=========================================${NC}"
        echo ""
        echo "  Recommended: use 'agmind update' for tested bundle updates."
        echo ""
        read -rp "  Continue anyway? [y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled."
            exit 0
        fi
    fi

    local resolved
    resolved="$(resolve_component "$name")" || exit $?
    if [[ -z "$resolved" ]]; then
        log_error "Failed to resolve component: ${name}"
        exit 1
    fi
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

# Perform bundle update: pull and restart only changed services
perform_bundle_update() {
    local update_order=(
        "db" "redis"
        "api" "worker" "web" "sandbox" "plugin_daemon"
        "pipelines" "ollama" "vllm" "tei"
        "nginx" "open-webui"
        "weaviate" "qdrant" "docling"
        "grafana" "portainer" "prometheus" "alertmanager"
        "loki" "promtail" "node-exporter" "cadvisor" "authelia"
    )

    # Build set of services that need updating
    declare -A SERVICES_TO_UPDATE
    local svc_count=0
    local key name svc
    for key in "${!NEW_VERSIONS[@]}"; do
        [[ "${NEW_VERSIONS[$key]}" == "${CURRENT_VERSIONS[$key]:-}" ]] && continue
        # Find all short names mapping to this key, then their services
        for name in "${!NAME_TO_VERSION_KEY[@]}"; do
            [[ "${NAME_TO_VERSION_KEY[$name]}" == "$key" ]] || continue
            for svc in ${NAME_TO_SERVICES[$name]}; do
                SERVICES_TO_UPDATE["$svc"]=1
                svc_count=$((svc_count + 1))
            done
        done
    done

    if [[ $svc_count -eq 0 ]]; then
        log_success "No services need updating"
        return 0
    fi

    log_info "Services to update: ${!SERVICES_TO_UPDATE[*]}"

    local failed=0 updated=0 skipped=0
    local service
    for service in "${update_order[@]}"; do
        # Skip if not in changed set
        [[ -z "${SERVICES_TO_UPDATE[$service]+_}" ]] && continue

        # Skip if not running
        if ! docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' "$service" 2>/dev/null | grep -q .; then
            skipped=$((skipped + 1))
            continue
        fi

        if update_service "$service"; then
            updated=$((updated + 1))
        else
            failed=$((failed + 1))
            log_error "Bundle update aborted at ${service}"
            break
        fi
    done

    echo ""
    echo -e "${BOLD}Result:${NC}"
    echo "  Updated: ${updated}"
    echo "  Skipped: ${skipped}"
    echo "  Errors:  ${failed}"

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

    # Load current versions from .env
    load_current_versions
    local CURRENT_RELEASE
    CURRENT_RELEASE="$(get_current_release)"

    # Handle --rollback (no argument = bundle rollback)
    if [[ "$ROLLBACK_MODE" == "true" ]]; then
        if [[ -n "$ROLLBACK_TARGET" ]]; then
            # Legacy per-component rollback (kept for compatibility)
            rollback_component "$ROLLBACK_TARGET"
        else
            rollback_bundle
        fi
        exit $?
    fi

    # Handle --component with --version (emergency single-component update)
    if [[ -n "$COMPONENT" && -n "$TARGET_VERSION" ]]; then
        update_component "$COMPONENT" "$TARGET_VERSION"
        exit $?
    fi

    # Handle --component without --version (use latest release version)
    if [[ -n "$COMPONENT" && -z "$TARGET_VERSION" ]]; then
        if ! fetch_release_info; then
            exit 1
        fi
        local version_key="${NAME_TO_VERSION_KEY[$COMPONENT]:-}"
        if [[ -z "$version_key" ]]; then
            log_error "Unknown component: ${COMPONENT}"
            exit 1
        fi
        local remote_version="${NEW_VERSIONS[$version_key]:-}"
        if [[ -z "$remote_version" ]]; then
            log_error "No version found for ${COMPONENT} in latest release"
            exit 1
        fi
        update_component "$COMPONENT" "$remote_version"
        exit $?
    fi

    # === Bundle update flow ===

    # Update installer scripts via git pull from release (or main) branch
    if ! update_scripts; then
        log_error "Script update failed — check git repository state"
        exit 1
    fi

    # Exit after scripts update if --scripts-only flag was set
    if [[ "$SCRIPTS_ONLY" == "true" ]]; then
        log_success "Scripts/configs updated successfully (--scripts-only)"
        log_update "SUCCESS" "Scripts-only update from branch '${UPDATE_BRANCH}'"
        exit 0
    fi

    # Fetch latest release info from GitHub
    if ! fetch_release_info; then
        exit 1
    fi

    # Display bundle diff
    if ! display_bundle_diff; then
        # current == latest, no updates
        log_update "SKIP" "Already up to date (${CURRENT_RELEASE})"
        exit 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        exit 0
    fi

    # Check for dangerous PostgreSQL major upgrade (UPDT-01)
    check_pg_major_upgrade

    # Confirm update
    if [[ "$AUTO_UPDATE" != "true" ]]; then
        read -rp "Update to ${RELEASE_TAG}? [y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled."
            exit 0
        fi
    fi

    # Backup
    create_update_backup

    # Save rollback state (images + configs + RELEASE)
    save_rollback_state

    # Save .env backup for rollback
    cp "$ENV_FILE" "${ENV_FILE}.pre-update"
    chmod 600 "${ENV_FILE}.pre-update"

    # Apply new versions to .env
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

    # Update versions.env from downloaded release asset
    if [[ -n "${DOWNLOADED_VERSIONS_FILE:-}" && -f "$DOWNLOADED_VERSIONS_FILE" ]]; then
        cp "$DOWNLOADED_VERSIONS_FILE" "$VERSIONS_FILE"
    fi

    # --- Xinference removal cleanup (v2.5) ---
    # Xinference was removed in v2.5. Stop orphan container and remove volume if present.
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^agmind-xinference$'; then
        log_info "Removing legacy Xinference container (removed in v2.5)..."
        docker stop agmind-xinference 2>/dev/null || true
        docker rm agmind-xinference 2>/dev/null || true
    fi
    if docker volume ls -q 2>/dev/null | grep -q '^agmind_xinference_data$'; then
        log_info "Removing legacy Xinference volume..."
        docker volume rm agmind_xinference_data 2>/dev/null || true
    fi

    echo ""
    log_info "Starting bundle update to ${RELEASE_TAG}..."
    echo ""

    cd "${INSTALL_DIR}/docker"

    # Validate images exist before pulling (HTTP HEAD) — warn-only for update
    if [[ "${SKIP_IMAGE_VALIDATION:-false}" != "true" ]]; then
        validate_images_exist || {
            log_warn "Some images may not exist — proceeding with caution"
        }
    fi

    if perform_bundle_update; then
        # Update RELEASE file
        echo "$RELEASE_TAG" > "$RELEASE_FILE"

        log_success "Update to ${RELEASE_TAG} completed successfully!"
        log_update "SUCCESS" "Bundle update to ${RELEASE_TAG}"
        send_notification "AGMind updated to ${RELEASE_TAG} on $(hostname 2>/dev/null || echo 'server')"
    else
        log_error "Update to ${RELEASE_TAG} failed — rolling back"
        perform_rollback
        verify_rollback || log_warn "Some services may not have rolled back correctly"
        log_update "ROLLBACK" "Bundle update to ${RELEASE_TAG} failed, rolled back"
        send_notification "AGMind update to ${RELEASE_TAG} FAILED, rolled back on $(hostname 2>/dev/null || echo 'server')"
        exit 1
    fi
}

main "$@"
