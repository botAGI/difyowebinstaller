#!/usr/bin/env bash
# compose.sh — Docker compose up/down, DB sync, plugin DB, retry loop, post-launch.
# Dependencies: common.sh (log_*, ensure_bind_mount_files, preflight_bind_mount_check)
# Functions: compose_up(), compose_down(), sync_db_password(), create_plugin_db(),
#            post_launch_status(), build_compose_profiles()
# Expects: INSTALL_DIR, DEPLOY_PROFILE, wizard exports
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# BUILD PROFILES
# ============================================================================

# Build comma-separated compose profiles from wizard choices.
# Returns profiles string in COMPOSE_PROFILE_STRING.
build_compose_profiles() {
    local profiles=""

    [[ "${DEPLOY_PROFILE:-}" == "vps" ]] && profiles="vps"
    [[ "${VECTOR_STORE:-weaviate}" == "qdrant" ]] && profiles="${profiles:+$profiles,}qdrant"
    [[ "${VECTOR_STORE:-weaviate}" == "weaviate" ]] && profiles="${profiles:+$profiles,}weaviate"
    # Docling: check both wizard var (ENABLE_DOCLING) and .env var (ETL_TYPE) for resume support
    # Backward compat: ETL_ENHANCED=true without ENABLE_DOCLING → treat as ENABLE_DOCLING=true
    local docling_enabled="${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}"
    if [[ "$docling_enabled" == "true" || "${ETL_TYPE:-dify}" == "unstructured_api" ]]; then
        profiles="${profiles:+$profiles,}docling"
    fi
    [[ "${MONITORING_MODE:-none}" == "local" ]] && profiles="${profiles:+$profiles,}monitoring"
    [[ "${ENABLE_AUTHELIA:-false}" == "true" ]] && profiles="${profiles:+$profiles,}authelia"

    if [[ "${LLM_PROVIDER:-}" == "ollama" || "${EMBED_PROVIDER:-}" == "ollama" ]]; then
        profiles="${profiles:+$profiles,}ollama"
    fi
    [[ "${LLM_PROVIDER:-}" == "vllm" ]] && profiles="${profiles:+$profiles,}vllm"
    [[ "${EMBED_PROVIDER:-}" == "tei" ]] && profiles="${profiles:+$profiles,}tei"
    [[ "${ENABLE_RERANKER:-false}" == "true" ]] && profiles="${profiles:+$profiles,}reranker"

    COMPOSE_PROFILE_STRING="$profiles"
    export COMPOSE_PROFILE_STRING
}

# ============================================================================
# PULL IMAGES (standalone phase — called from install.sh phase_pull)
# ============================================================================

compose_pull() {
    local docker_dir="${INSTALL_DIR}/docker"
    cd "$docker_dir"

    build_compose_profiles
    local profiles="$COMPOSE_PROFILE_STRING"

    if [[ "${DEPLOY_PROFILE:-}" == "offline" ]]; then
        log_info "Offline profile: skipping image pull"
        return 0
    fi

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
    [[ -z "$images_raw" ]] && return 0

    local -a images
    mapfile -t images <<< "$images_raw"
    local total=${#images[@]}
    [[ $total -eq 0 ]] && return 0

    log_info "Pulling ${total} images..."

    local pull_rc=0

    if [ -t 1 ]; then
        # TTY: pull in foreground (keeps TTY for interactive progress bars).
        # Background watchdog kills pull if no new images for 120s.
        _start_pull_watchdog images "$total" &
        local watchdog_pid=$!
        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="$profiles" docker compose pull || pull_rc=$?
        else
            docker compose pull || pull_rc=$?
        fi
        kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null || true
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

# Background watchdog for TTY pull: kills the foreground docker compose pull
# if no new image appears for 120 seconds. Runs as a subshell.
_start_pull_watchdog() {
    local -n _wd_imgs=$1
    local total="$2"
    local inactivity_timeout=120
    local last_ready=0 idle_secs=0
    local parent_pid=$$

    for img in "${_wd_imgs[@]}"; do
        docker image inspect "$img" >/dev/null 2>&1 && last_ready=$((last_ready + 1))
    done

    while true; do
        sleep 10
        # Parent finished — exit watchdog
        kill -0 "$parent_pid" 2>/dev/null || exit 0

        local ready=0
        for img in "${_wd_imgs[@]}"; do
            docker image inspect "$img" >/dev/null 2>&1 && ready=$((ready + 1))
        done
        if [[ $ready -gt $last_ready ]]; then
            last_ready=$ready
            idle_secs=0
        else
            idle_secs=$((idle_secs + 10))
        fi
        if [[ $idle_secs -ge $inactivity_timeout ]]; then
            echo ""
            log_warn "Pull stalled (no new images for ${inactivity_timeout}s)"
            # Find and kill docker compose pull process
            pkill -f "docker compose pull" 2>/dev/null || true
            exit 0
        fi
    done
}

# Monitor background pull process; kill only if no output for INACTIVITY_TIMEOUT seconds.
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
                [[ -n "$last_line" ]] && log_info "Pull: ${last_line:0:80}"
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
        sed -i '/^COMPOSE_PROFILES=/d' "$env_file"
        echo "COMPOSE_PROFILES=${profiles}" >> "$env_file"
    fi

    # --- Cleanup stale containers ---
    _cleanup_stale_containers

    # --- Bind mount safety ---
    ensure_bind_mount_files
    preflight_bind_mount_check

    # --- Up (--pull missing as safety net for anything pull phase missed) ---
    local pull_flag="--pull missing"
    if [[ "${DEPLOY_PROFILE:-}" == "offline" ]]; then
        pull_flag="--pull never"
    fi

    log_info "Starting containers (profiles: ${profiles:-core})..."
    if [[ -n "$profiles" ]]; then
        COMPOSE_PROFILES="$profiles" docker compose up -d $pull_flag
    else
        docker compose up -d $pull_flag
    fi

    # --- Post-up tasks ---
    sync_db_password
    create_plugin_db
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
    COMPOSE_PROFILES=vps,monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei,reranker \
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
    COMPOSE_PROFILES=vps,monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei,reranker \
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
    local retry created=0
    for retry in 1 2 3; do
        created="$(docker ps -a --filter "name=agmind-" --filter "status=created" --format '{{.ID}}' 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${created:-0}" -eq 0 ]]; then
            break
        fi
        log_info "Retry ${retry}/3: ${created} containers in Created state, restarting..."
        sleep 10
        if [[ -n "$profiles" ]]; then
            COMPOSE_PROFILES="$profiles" docker compose up -d 2>&1 | tail -5
        else
            docker compose up -d 2>&1 | tail -5
        fi
    done

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
    [[ -z "$db_pass" ]] && return 0

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

    local attempts=0
    while [[ $attempts -lt 15 ]]; do
        if docker exec agmind-db pg_isready -U "$db_user" &>/dev/null; then
            if docker exec agmind-db psql -U "$db_user" -tc \
                "SELECT 1 FROM pg_database WHERE datname = '${plugin_db}';" 2>/dev/null | grep -q 1; then
                return 0  # Already exists
            fi
            if docker exec agmind-db psql -U "$db_user" -c \
                "CREATE DATABASE ${plugin_db};" &>/dev/null; then
                log_success "Database ${plugin_db} created"
            fi
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
}

# ============================================================================
# POST-LAUNCH STATUS
# ============================================================================

post_launch_status() {
    # GPU containers have long model-loading startup — exclude from stabilization wait
    local gpu_containers=" agmind-vllm agmind-tei agmind-ollama "

    log_info "Waiting for containers to stabilize..."
    local elapsed=0
    while [[ $elapsed -lt 120 ]]; do
        local starting=0
        while IFS= read -r cname; do
            [[ -z "$cname" ]] && continue
            # Skip GPU containers — they load models for minutes, not seconds
            [[ "$gpu_containers" == *" $cname "* ]] && continue
            starting=$((starting + 1))
        done < <(docker ps --filter "name=agmind-" --filter "health=starting" --format "{{.Names}}" 2>/dev/null || true)
        [[ "$starting" -eq 0 ]] && break
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
        [[ -z "$cname" ]] && continue
        [[ "$gpu_containers" == *" $cname "* ]] && gpu_loading="${gpu_loading:+${gpu_loading}, }${cname}"
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
