#!/usr/bin/env bash
# compose.sh — Docker compose up/down, DB sync, plugin DB, retry loop, post-launch.
# Dependencies: common.sh (log_*, ensure_bind_mount_files, preflight_bind_mount_check)
# Functions: compose_up(), compose_down(), sync_db_password(), create_plugin_db(),
#            post_launch_status(), build_compose_profiles()
# Expects: INSTALL_DIR, DEPLOY_PROFILE, wizard exports
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
IMAGE_VALIDATION_TIMEOUT="${IMAGE_VALIDATION_TIMEOUT:-20}"

# ============================================================================
# BUILD PROFILES
# ============================================================================

# Build comma-separated compose profiles from wizard choices.
# Returns profiles string in COMPOSE_PROFILE_STRING.
build_compose_profiles() {
    local profiles=""

    if [[ "${DEPLOY_PROFILE:-}" == "vps" ]]; then profiles="vps"; fi
    if [[ "${VECTOR_STORE:-weaviate}" == "qdrant" ]]; then profiles="${profiles:+$profiles,}qdrant"; fi
    if [[ "${VECTOR_STORE:-weaviate}" == "weaviate" ]]; then profiles="${profiles:+$profiles,}weaviate"; fi
    # Docling: check both wizard var (ENABLE_DOCLING) and .env var (ETL_TYPE) for resume support
    # Backward compat: ETL_ENHANCED=true without ENABLE_DOCLING → treat as ENABLE_DOCLING=true
    local docling_enabled="${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}"
    if [[ "$docling_enabled" == "true" || "${ETL_TYPE:-dify}" == "unstructured_api" ]]; then
        profiles="${profiles:+$profiles,}docling"
    fi
    if [[ "${MONITORING_MODE:-none}" == "local" ]]; then profiles="${profiles:+$profiles,}monitoring"; fi
    if [[ "${ENABLE_AUTHELIA:-false}" == "true" ]]; then profiles="${profiles:+$profiles,}authelia"; fi

    if [[ "${LLM_PROVIDER:-}" == "ollama" || "${EMBED_PROVIDER:-}" == "ollama" ]]; then
        profiles="${profiles:+$profiles,}ollama"
    fi
    if [[ "${LLM_PROVIDER:-}" == "vllm" ]]; then profiles="${profiles:+$profiles,}vllm"; fi
    if [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then profiles="${profiles:+$profiles,}tei"; fi
    if [[ "${EMBED_PROVIDER:-}" == "vllm-embed" ]]; then profiles="${profiles:+$profiles,}vllm-embed"; fi
    if [[ "${ENABLE_RERANKER:-false}" == "true" ]]; then
        if [[ "${RERANKER_PROVIDER:-tei}" == "vllm-rerank" ]]; then
            profiles="${profiles:+$profiles,}vllm-rerank"
        else
            profiles="${profiles:+$profiles,}reranker"
        fi
    fi
    if [[ "${ENABLE_LITELLM:-true}" == "true" ]]; then profiles="${profiles:+$profiles,}litellm"; fi
    if [[ "${ENABLE_SEARXNG:-false}" == "true" ]]; then profiles="${profiles:+$profiles,}searxng"; fi
    if [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]]; then profiles="${profiles:+$profiles,}notebook"; fi
    if [[ "${ENABLE_DBGPT:-false}" == "true" ]]; then profiles="${profiles:+$profiles,}dbgpt"; fi
    if [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]]; then profiles="${profiles:+$profiles,}crawl4ai"; fi
    if [[ "${ENABLE_OPENWEBUI:-false}" == "true" ]]; then profiles="${profiles:+$profiles,}openwebui"; fi
    if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then profiles="${profiles:+$profiles,}minio"; fi

    COMPOSE_PROFILE_STRING="$profiles"
    export COMPOSE_PROFILE_STRING
}

# ============================================================================
# PRE-PULL IMAGE VALIDATION (HTTP HEAD to registry API)
# ============================================================================

# Parse image reference into registry, repo, tag components.
# Examples:
#   nginx:1.25           -> docker.io, library/nginx, 1.25
#   ghcr.io/org/img:v1   -> ghcr.io, org/img, v1
#   quay.io/org/img:v1   -> quay.io, org/img, v1
_parse_image_ref() {
    local image="$1"
    local -n _registry=$2 _repo=$3 _tag=$4

    # Split tag: last colon is a tag only if the part after it has no slash
    # (avoids confusing registry:port with image:tag)
    if [[ "$image" == *":"* ]]; then
        local _maybe_tag="${image##*:}"
        if [[ "$_maybe_tag" != *"/"* ]]; then
            _tag="$_maybe_tag"
            image="${image%:*}"
        else
            _tag="latest"
        fi
    else
        _tag="latest"
    fi

    # Split registry/repo
    if [[ "$image" == *"/"*"/"* ]]; then
        # Has registry: ghcr.io/org/repo or registry-1.docker.io/library/nginx
        _registry="${image%%/*}"
        _repo="${image#*/}"
    elif [[ "$image" == *"."*"/"* ]]; then
        # Domain-like first segment: gcr.io/repo
        _registry="${image%%/*}"
        _repo="${image#*/}"
    else
        # Docker Hub shorthand: library/nginx or just nginx
        _registry="docker.io"
        if [[ "$image" == *"/"* ]]; then
            _repo="$image"
        else
            _repo="library/${image}"
        fi
    fi
}

# Get anonymous bearer token for registry API.
# Docker Hub requires token from auth.docker.io; others may work without.
# Retries up to 3 times with 5s sleep on failure.
_get_registry_token() {
    local registry="$1"
    local repo="$2"
    local max_attempts=3
    local attempt=0 token_url=""

    case "$registry" in
        docker.io|registry-1.docker.io)
            token_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull"
            ;;
        ghcr.io)
            token_url="https://ghcr.io/token?scope=repository:${repo}:pull"
            ;;
        quay.io) echo ""; return ;;
        *)       echo ""; return ;;
    esac

    while [[ $attempt -lt $max_attempts ]]; do
        local result
        result="$(curl -sf --max-time 10 "$token_url" 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)" || true
        if [[ -n "$result" ]]; then
            echo "$result"
            return
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then sleep 5; fi
    done
    echo ""
}

# Check if a single image:tag exists in its registry via HTTP HEAD.
# Returns: 0 = exists, 1 = not found (404), 2 = registry error (skip)
_check_image_exists() {
    local full_image="$1"

    # Parse image into registry, repo, tag
    local registry repo tag
    _parse_image_ref "$full_image" registry repo tag

    # Get auth token (anonymous)
    local token=""
    token="$(_get_registry_token "$registry" "$repo")" || true

    # HEAD request to manifest endpoint
    local url
    case "$registry" in
        docker.io|registry-1.docker.io)
            url="https://registry-1.docker.io/v2/${repo}/manifests/${tag}"
            ;;
        *)
            url="https://${registry}/v2/${repo}/manifests/${tag}"
            ;;
    esac

    local http_code
    local auth_header=""
    if [[ -n "$token" ]]; then auth_header="Authorization: Bearer ${token}"; fi

    http_code="$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time "${IMAGE_VALIDATION_TIMEOUT:-20}" \
        -I \
        ${auth_header:+-H "$auth_header"} \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
        "$url" 2>/dev/null)" || { return 2; }

    case "$http_code" in
        200|301|302) return 0 ;;   # exists (or redirect = exists)
        404)         return 1 ;;   # not found
        *)           return 2 ;;   # registry error (401, 403, 405, 429, 500, etc.)
    esac
}

# Validate that all required images exist in their registries before pulling.
# Uses HTTP HEAD (not GET) to avoid Docker Hub rate-limit consumption.
# Returns: 0 = all found, 1 = some not found (blocks install)
validate_images_exist() {
    local docker_dir="${INSTALL_DIR}/docker"

    # Skip if explicitly disabled
    if [[ "${SKIP_IMAGE_VALIDATION:-false}" == "true" ]]; then
        log_info "Image validation skipped (SKIP_IMAGE_VALIDATION=true)"
        return 0
    fi

    cd "$docker_dir"
    build_compose_profiles
    local profiles="$COMPOSE_PROFILE_STRING"

    local images_raw
    if [[ -n "$profiles" ]]; then
        images_raw="$(COMPOSE_PROFILES="$profiles" docker compose config --images 2>/dev/null)" || return 0
    else
        images_raw="$(docker compose config --images 2>/dev/null)" || return 0
    fi
    if [[ -z "$images_raw" ]]; then return 0; fi

    local -a images
    mapfile -t images <<< "$images_raw"
    local total=${#images[@]}
    if [[ $total -eq 0 ]]; then return 0; fi

    log_info "Validating ${total} images exist in registries..."

    local not_found=0
    local -a missing_images=()
    local max_parallel=5
    local -a pids=()
    local tmpdir
    tmpdir="$(mktemp -d)"

    for img in "${images[@]}"; do
        # Launch background check
        (
            local _key
            _key="$(printf '%s' "$img" | tr '/:@' '___')"
            local rc=0
            _check_image_exists "$img" || rc=$?
            if [[ $rc -eq 0 ]]; then
                echo "OK" > "${tmpdir}/${_key}"
            elif [[ $rc -eq 2 ]]; then
                echo "SKIP" > "${tmpdir}/${_key}"
            else
                echo "MISSING" > "${tmpdir}/${_key}"
            fi
        ) &
        pids+=($!)

        # Throttle: wait if we hit max_parallel
        if [[ ${#pids[@]} -ge $max_parallel ]]; then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
        fi
    done

    # Wait for remaining jobs
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Collect results
    for img in "${images[@]}"; do
        local _key
        _key="$(printf '%s' "$img" | tr '/:@' '___')"
        local result
        result="$(cat "${tmpdir}/${_key}" 2>/dev/null || echo "SKIP")"
        case "$result" in
            OK)      : ;;
            SKIP)    log_warn "Cannot verify image: ${img} — skipping check" ;;
            MISSING) log_error "WARNING: image not found: ${img}"; not_found=$((not_found + 1)); missing_images+=("$img") ;;
        esac
    done
    rm -rf "$tmpdir"

    if [[ $not_found -gt 0 ]]; then
        log_error "Blocking install: ${not_found} image(s) not found in registries:"
        for m in "${missing_images[@]}"; do
            log_error "  - ${m}"
        done
        log_error "Check tags in versions.env or set SKIP_IMAGE_VALIDATION=true to bypass"
        return 1
    fi

    log_info "All ${total} images verified"
    return 0
}

# ============================================================================
# PULL IMAGES (standalone phase — called from install.sh phase_pull)
# ============================================================================

compose_pull() {
    local docker_dir="${INSTALL_DIR}/docker"
    cd "$docker_dir"

    build_compose_profiles
    local profiles="$COMPOSE_PROFILE_STRING"

    # Pre-pull: validate images exist in registries (HTTP HEAD)
    validate_images_exist || {
        log_error "Image validation failed — aborting pull"
        return 1
    }

    # Bind mount safety before pull (ensures compose config is valid)
    ensure_bind_mount_files
    _nuclear_cleanup_dirs
    preflight_bind_mount_check

    _pull_with_progress "$profiles"
}

_pull_with_progress() {
    local profiles="${1:-}"
    local docker_dir="${INSTALL_DIR}/docker"
    cd "$docker_dir"

    # Get list of required images
    local images_raw
    if [[ -n "$profiles" ]]; then
        images_raw="$(COMPOSE_PROFILES="$profiles" docker compose config --images 2>/dev/null)" || { log_info "Pulling images..."; return 0; }
    else
        images_raw="$(docker compose config --images 2>/dev/null)" || { log_info "Pulling images..."; return 0; }
    fi
    if [[ -z "$images_raw" ]]; then return 0; fi

    local -a images
    mapfile -t images <<< "$images_raw"
    local total=${#images[@]}
    if [[ $total -eq 0 ]]; then return 0; fi

    log_info "Pulling ${total} images..."

    local pull_rc=0

    if [[ -n "${ORIGINAL_TTY_FD:-}" ]] && { true >&"${ORIGINAL_TTY_FD}"; } 2>/dev/null; then
        # TTY: pull in foreground on original TTY (fd 3) for interactive progress.
        # No watchdog — Docker handles its own timeouts. User can Ctrl+C if stuck.
        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="$profiles" docker compose pull >&"${ORIGINAL_TTY_FD}" 2>&1 || pull_rc=$?
        else
            docker compose pull >&"${ORIGINAL_TTY_FD}" 2>&1 || pull_rc=$?
        fi
    else
        # non-TTY: redirect to log file, monitor by file size
        local pull_log="/tmp/agmind-pull-$$.log"
        : > "$pull_log"
        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="$profiles" docker compose pull > "$pull_log" 2>&1 &
        else
            docker compose pull > "$pull_log" 2>&1 &
        fi
        local pull_pid=$!
        _monitor_pull_inactivity "$pull_pid" "$pull_log" || pull_rc=$?
        rm -f "$pull_log"
    fi

    # Verify pulled images
    local ready=0
    for img in "${images[@]}"; do
        docker image inspect "$img" >/dev/null 2>&1 && ready=$((ready + 1))
    done

    if [[ $ready -eq $total ]]; then
        log_success "Images ready: ${ready}/${total}"
    else
        log_warn "Images ready: ${ready}/${total}"
        _validate_pulled_images images "$total" || true
        return 1
    fi

    return 0
}

# Monitor background pull process (non-TTY only); kill if no output for 120s.
# non-TTY only — this is the ONLY timeout mechanism for pull.
# The absolute timeout from _run_with_timeout is a hard safety net; this should trigger first.
_monitor_pull_inactivity() {
    local pid="$1" logfile="$2"
    local inactivity_timeout=120  # kill if no new output for 2 min
    local last_size=0 idle_secs=0
    local is_tty=false
    [ -t 1 ] && is_tty=true

    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        local current_size
        current_size=$(stat -c%s "$logfile" 2>/dev/null || echo "0")
        if [[ "$current_size" -gt "$last_size" ]]; then
            last_size="$current_size"
            idle_secs=0
            # non-TTY: show periodic status (TTY already has tail -f)
            if [[ "$is_tty" == "false" ]]; then
                local last_line
                last_line=$(tail -1 "$logfile" 2>/dev/null || true)
                if [[ -n "$last_line" ]]; then log_info "Pull: ${last_line:0:80}"; fi
            fi
        else
            idle_secs=$((idle_secs + 5))
        fi
        if [[ $idle_secs -ge $inactivity_timeout ]]; then
            log_warn "Pull stalled (no output for ${inactivity_timeout}s) — interrupting"
            kill -TERM "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null || true
            return 124
        fi
    done
    wait "$pid"
}

# Check each image after pull; print error for each missing one.
_validate_pulled_images() {
    local -n _vimgs=$1
    local total="$2"
    local missing=0

    for img in "${_vimgs[@]}"; do
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            log_error "Image not found: ${img} — check tag in versions.env"
            missing=$((missing + 1))
        fi
    done

    return "$missing"
}

# ============================================================================
# COMPOSE UP (legacy — calls pull + start for backward compat)
# ============================================================================

compose_up() {
    compose_pull
    compose_start
}

# ============================================================================
# COMPOSE START (no pull — uses already-pulled images)
# ============================================================================

compose_start() {
    local docker_dir="${INSTALL_DIR}/docker"
    cd "$docker_dir"

    build_compose_profiles
    local profiles="$COMPOSE_PROFILE_STRING"

    # Persist COMPOSE_PROFILES to .env for systemd reboot support (BUG-V3-029)
    local env_file="${INSTALL_DIR}/docker/.env"
    if [[ -f "$env_file" ]]; then
        local tmp_env="${env_file}.tmp.$$"
        grep -v '^COMPOSE_PROFILES=' "$env_file" > "$tmp_env" || true
        echo "COMPOSE_PROFILES=${profiles}" >> "$tmp_env"
        mv "$tmp_env" "$env_file"
        chmod 600 "$env_file"
    fi

    # --- Cleanup stale containers ---
    _cleanup_stale_containers

    # --- Bind mount safety ---
    ensure_bind_mount_files
    preflight_bind_mount_check

    # --- Up (--pull missing as safety net for anything pull phase missed) ---
    local pull_flag="--pull missing"

    # --- Start DB first, ensure databases exist before other services ---
    log_info "Starting database..."
    docker compose up -d $pull_flag db
    create_plugin_db

    log_info "Starting containers (profiles: ${profiles:-core})..."
    if [[ -n "$profiles" ]]; then
        COMPOSE_PROFILES="$profiles" docker compose up -d $pull_flag
    else
        docker compose up -d $pull_flag
    fi

    # --- Post-up tasks ---
    sync_db_password
    _retry_stuck_containers "$profiles"
    _fix_storage_permissions
    post_launch_status
}

# ============================================================================
# COMPOSE DOWN
# ============================================================================

compose_down() {
    local docker_dir="${INSTALL_DIR}/docker"
    if [[ ! -d "$docker_dir" ]]; then
        log_warn "Docker dir not found: ${docker_dir}"
        return 0
    fi

    cd "$docker_dir"
    log_info "Stopping all containers..."
    # Source service map if not already loaded
    if [[ -z "${_SERVICE_MAP_LOADED:-}" ]]; then
        # shellcheck source=service-map.sh
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/service-map.sh"
    fi
    COMPOSE_PROFILES="${ALL_COMPOSE_PROFILES}" \
        docker compose down --remove-orphans 2>/dev/null || true
    log_success "All containers stopped"
}

# ============================================================================
# CLEANUP HELPERS
# ============================================================================

_cleanup_stale_containers() {
    local docker_dir="${INSTALL_DIR}/docker"
    cd "$docker_dir"

    # Stop ALL profiles — docker compose down without profiles won't touch
    # services that have profiles: [monitoring], etc.
    log_info "Cleaning up stale containers..."
    # Source service map if not already loaded
    if [[ -z "${_SERVICE_MAP_LOADED:-}" ]]; then
        # shellcheck source=service-map.sh
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/service-map.sh"
    fi
    COMPOSE_PROFILES="${ALL_COMPOSE_PROFILES}" \
        docker compose down --remove-orphans 2>/dev/null || true

    # Force-remove any agmind containers docker compose missed
    docker ps -a --filter "name=agmind-" -q 2>/dev/null | while read -r id; do
        docker rm -f "$id" 2>/dev/null || true
    done
}

# Remove any .yml/.yaml/.conf paths that are directories (Docker artifacts)
_nuclear_cleanup_dirs() {
    local docker_dir="${INSTALL_DIR}/docker"
    find "$docker_dir" -maxdepth 3 -name "*.yml" -type d -exec rm -rf {} + 2>/dev/null || true
    find "$docker_dir" -maxdepth 3 -name "*.yaml" -type d -exec rm -rf {} + 2>/dev/null || true
    find "$docker_dir" -maxdepth 3 -name "*.conf" -type d -exec rm -rf {} + 2>/dev/null || true
}

# ============================================================================
# RETRY STUCK CONTAINERS
# ============================================================================

# Containers with condition: service_healthy deps may stay in "Created" state.
# Re-run compose up to kick them once dependencies are healthy.
_retry_stuck_containers() {
    local profiles="${1:-}"
    local docker_dir="${INSTALL_DIR}/docker"
    cd "$docker_dir"

    log_info "Waiting for dependency cascade..."
    local retry backoff=10 created=0
    for retry in 1 2 3; do
        created="$(docker ps -a --filter "name=agmind-" --filter "status=created" --format '{{.ID}}' 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${created:-0}" -eq 0 ]]; then
            break
        fi
        log_info "Retry ${retry}/3: ${created} containers in Created state, waiting ${backoff}s..."
        sleep "$backoff"
        backoff=$((backoff * 2))
        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="$profiles" docker compose up -d 2>&1 | tail -5
        else
            docker compose up -d 2>&1 | tail -5
        fi
    done

    # Re-check after last retry
    created="$(docker ps -a --filter "name=agmind-" --filter "status=created" --format '{{.ID}}' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${created:-0}" -gt 0 ]]; then
        local stuck_names
        stuck_names="$(docker ps -a --filter "name=agmind-" --filter "status=created" --format '{{.Names}}' 2>/dev/null | tr '\n' ', ')"
        log_error "${created} containers failed to start after 3 retries: ${stuck_names}"
        echo "  Check logs: docker compose logs <service>"
    fi
}

# ============================================================================
# FIX STORAGE PERMISSIONS
# ============================================================================

_fix_storage_permissions() {
    docker exec -u root agmind-api chown -R dify:dify /app/api/storage 2>/dev/null || true
}

# ============================================================================
# SYNC DB PASSWORD
# ============================================================================

# If db volume exists from a previous attempt, the password in the DB won't
# match the newly generated .env password. ALTER USER to sync.
sync_db_password() {
    local env_file="${INSTALL_DIR}/docker/.env"
    local db_pass db_user

    db_pass="$(grep '^DB_PASSWORD=' "$env_file" 2>/dev/null | cut -d'=' -f2-)"
    if [[ -z "$db_pass" ]]; then return 0; fi

    db_user="$(grep '^DB_USERNAME=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "postgres")"
    db_user="${db_user:-postgres}"

    # Validate inputs (prevent SQL injection)
    if [[ ! "$db_user" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid DB_USERNAME: contains disallowed characters"
        return 1
    fi
    if [[ ! "$db_pass" =~ ^[a-zA-Z0-9]+$ ]]; then
        log_error "Invalid DB_PASSWORD: contains disallowed characters"
        return 1
    fi

    log_info "Syncing PostgreSQL password..."
    local attempts=0
    while [[ $attempts -lt 45 ]]; do
        if docker exec agmind-db pg_isready -U "$db_user" &>/dev/null; then
            if docker exec agmind-db psql -U "$db_user" -c \
                "ALTER USER ${db_user} WITH PASSWORD '${db_pass}';" &>/dev/null; then
                log_success "PostgreSQL password synced"
                return 0
            fi
            log_error "Failed to sync PostgreSQL password via ALTER USER"
            log_error "Manual fix: docker exec -it agmind-db psql -U ${db_user} -c \"ALTER USER ${db_user} WITH PASSWORD '\$(grep DB_PASSWORD ${env_file} | cut -d= -f2-)'\;\""
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    log_error "PostgreSQL not ready after 90s — password sync skipped"
    log_error "If auth fails, run: docker exec -it agmind-db psql -U postgres -c \"ALTER USER postgres WITH PASSWORD '\$(grep DB_PASSWORD ${env_file} | cut -d= -f2-)'\;\""
    return 1
}

# ============================================================================
# CREATE PLUGIN DB
# ============================================================================

create_plugin_db() {
    local env_file="${INSTALL_DIR}/docker/.env"
    local db_user plugin_db

    db_user="$(grep '^DB_USERNAME=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "postgres")"
    db_user="${db_user:-postgres}"
    plugin_db="$(grep '^PLUGIN_DB_DATABASE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "dify_plugin")"
    plugin_db="${plugin_db:-dify_plugin}"

    # Validate (prevent SQL injection)
    if [[ ! "$db_user" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid DB_USERNAME: ${db_user}"
        return 1
    fi
    if [[ ! "$plugin_db" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid PLUGIN_DB_DATABASE: ${plugin_db}"
        return 1
    fi

    # All databases that must exist (init scripts only run on fresh volumes)
    local -a required_dbs=("$plugin_db")
    local enable_litellm
    enable_litellm="$(grep '^ENABLE_LITELLM=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "true")"
    if [[ "$enable_litellm" == "true" ]]; then required_dbs+=("litellm"); fi

    local attempts=0
    while [[ $attempts -lt 15 ]]; do
        if docker exec agmind-db pg_isready -U "$db_user" &>/dev/null; then
            for dbname in "${required_dbs[@]}"; do
                if docker exec agmind-db psql -U "$db_user" -tc \
                    "SELECT 1 FROM pg_database WHERE datname = '${dbname}';" 2>/dev/null | grep -q 1; then
                    : # exists
                else
                    if docker exec agmind-db psql -U "$db_user" -c \
                        "CREATE DATABASE ${dbname};" &>/dev/null; then
                        log_success "Database ${dbname} created"
                    fi
                fi
            done
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    log_error "PostgreSQL not ready after 30s — plugin DB creation skipped"
    return 1
}

# ============================================================================
# POST-LAUNCH STATUS
# ============================================================================

post_launch_status() {
    # GPU containers have long model-loading startup — exclude from stabilization wait
    local gpu_containers=" agmind-vllm agmind-tei agmind-ollama agmind-vllm-embed agmind-vllm-rerank "

    log_info "Waiting for containers to stabilize..."
    local elapsed=0
    while [[ $elapsed -lt 120 ]]; do
        local starting=0
        while IFS= read -r cname; do
            if [[ -z "$cname" ]]; then continue; fi
            # Skip GPU containers — they load models for minutes, not seconds
            if [[ "$gpu_containers" == *" $cname "* ]]; then continue; fi
            starting=$((starting + 1))
        done < <(docker ps --filter "name=agmind-" --filter "health=starting" --format "{{.Names}}" 2>/dev/null || true)
        if [[ "$starting" -eq 0 ]]; then break; fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done
    echo ""

    # Check for unhealthy/restarting (real failures, not slow GPU startup)
    local bad
    bad="$(docker ps --filter "name=agmind-" --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -iE "unhealthy|restarting" || true)"
    if [[ -n "$bad" ]]; then
        log_warn "Containers with issues:"
        while IFS=$'\t' read -r name status; do
            log_error "${name}: ${status}"
            local logs
            logs="$(docker logs --tail 3 "$name" 2>&1 || true)"
            if [[ -n "$logs" ]]; then
                echo "$logs" | head -3 | sed 's/^/    /'
            fi
        done <<< "$bad"
        echo ""
        echo "  Use 'docker logs <container>' for details"
    else
        log_success "All containers running"
    fi

    # Report GPU containers still loading models (informational, not error)
    local gpu_loading=""
    while IFS= read -r cname; do
        if [[ -z "$cname" ]]; then continue; fi
        if [[ "$gpu_containers" == *" $cname "* ]]; then gpu_loading="${gpu_loading:+${gpu_loading}, }${cname}"; fi
    done < <(docker ps --filter "name=agmind-" --filter "health=starting" --format "{{.Names}}" 2>/dev/null || true)

    if [[ -n "$gpu_loading" ]]; then
        log_info "GPU containers loading models (this is normal): ${gpu_loading}"
    fi
}

# ============================================================================
# STANDALONE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"
    echo "compose.sh: use compose_up() or compose_down()"
fi
