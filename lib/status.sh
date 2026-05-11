#!/usr/bin/env bash
# status.sh — agmind status: service overview table + --json + --watch + --service.
# Dependencies: common.sh (colors, log_*), health.sh (get_service_list, check_backup_status,
#   _doctor_peer), service-map.sh (SERVICE_GROUPS, SERVICE_GROUP_ORDER, NAME_TO_SERVICES),
#   detect.sh (DETECTED_* for header), doctor.sh (footer-hint, _check shim).
# Functions: status_run([--json] [--watch [interval]] [--service <name>]) + _status_* helpers.
# Expects: INSTALL_DIR (default /opt/agmind), ENV_FILE, COMPOSE_FILE.
# Exports: STATUS_ROWS (array of \x1f-delimited records), status_run.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
ENV_FILE="${ENV_FILE:-${INSTALL_DIR}/docker/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-${INSTALL_DIR}/docker/docker-compose.yml}"

# Guard against double-sourcing
if [[ -n "${_STATUS_LOADED:-}" ]]; then return 0; fi
_STATUS_LOADED=1

# ============================================================================
# FALLBACK SHIMS (only active when sourced without common.sh / health.sh)
# ============================================================================

# Mirror lib/health.sh:11-18 + lib/doctor.sh:23-68
command -v log_info    >/dev/null 2>&1 || log_info()    { echo -e "  -> $*"; }
command -v log_success >/dev/null 2>&1 || log_success() { echo -e "  ✓ $*"; }
command -v log_warn    >/dev/null 2>&1 || log_warn()    { echo -e "  ⚠ $*"; }
command -v log_error   >/dev/null 2>&1 || log_error()   { echo -e "  ✗ $*"; }

# Fallback colors when sourced without common.sh
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
NC="${NC:-\033[0m}"

# _check shim — lib/health.sh::_doctor_peer calls _check as an injected dependency.
# WHY: lib/doctor.sh defines this; shim lets lib/status.sh work standalone in tests.
command -v _check >/dev/null 2>&1 || _check() {
    local sev="$1" label="$2" msg="${3:-}" fix="${4:-}"
    case "$sev" in
        OK)   echo -e "  ${GREEN}[OK]${NC}   ${label}" ;;
        WARN) echo -e "  ${YELLOW}[WARN]${NC} ${label} — ${msg}"
              [[ -n "$fix" ]] && echo -e "         ${CYAN}-> ${fix}${NC}" ;;
        FAIL) echo -e "  ${RED}[FAIL]${NC} ${label} — ${msg}"
              [[ -n "$fix" ]] && echo -e "         ${CYAN}-> ${fix}${NC}" ;;
        SKIP) echo -e "  ${CYAN}[SKIP]${NC} ${label} — ${msg}" ;;
    esac
}

# _read_env shim — reads a key from ENV_FILE (mirrors scripts/agmind.sh::_read_env).
# WHY: status.sh may be sourced standalone in tests without agmind.sh's helpers.
command -v _read_env >/dev/null 2>&1 || _read_env() {
    local key="$1" default="${2:-}"
    [[ -f "$ENV_FILE" ]] && grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "$default"
}

# ============================================================================
# CONSTANTS
# ============================================================================

# \x1f (ASCII Unit Separator) — not present in service names/URLs/notes.
# WHY: same pattern as lib/doctor.sh::DOCTOR_REGISTRY and lib/phases.sh::PHASES.
SEP=$'\x1f'
STATUS_ROWS=()
_STATUS_DOCKER_DOWN=0
DEFAULT_WATCH_INTERVAL=2

# Known init-containers: containers that are EXPECTED to exit cleanly.
# WHY: Exited(0) for these = STATE "done" (gray), not "exited" (red).
# Source: grep 'restart: "no"' templates/docker-compose.yml → redis-lock-cleaner (L892),
#         k6 (L1761), milvus-init (L680). CLAUDE.md §8 init-containers rule.
# shellcheck disable=SC2034  # referenced via substring match in _status_is_init_container
KNOWN_INIT_CONTAINERS="redis-lock-cleaner k6 milvus-init"

# Distroless containers: they have no /bin/sh and thus no healthcheck.
# WHY: docker inspect .State.Health == "" → STATE "running" (green), NOT "unhealthy".
# Source: tests/unit/test_distroless_no_healthcheck.sh + CLAUDE.md §8.
# NOT distroless: prometheus / alertmanager / postgres-exporter (busybox, healthcheck works).
# shellcheck disable=SC2034  # referenced in _status_docker_state via substring match
DISTROLESS_NO_HC="loki redis-exporter nginx-exporter alloy"

# ============================================================================
# ROW REGISTRY (mirrors lib/doctor.sh::DOCTOR_REGISTRY pattern)
# ============================================================================

# Reset the STATUS_ROWS array before a fresh collection pass.
_status_row_reset() {
    STATUS_ROWS=()
    _STATUS_DOCKER_DOWN=0
}

# _status_row_add <name> <group> <state> <url> <notes> <restarts>
# Appends a \x1f-delimited record to STATUS_ROWS.
# WHY \x1f: ASCII Unit Separator — safe delimiter for split via IFS=$'\x1f'.
_status_row_add() {
    local name="$1" group="$2" state="$3" url="$4" notes="${5:---}" restarts="${6:-0}"
    STATUS_ROWS+=("${name}${SEP}${group}${SEP}${state}${SEP}${url}${SEP}${notes}${SEP}${restarts}")
}

# ============================================================================
# PROFILE / STATE HELPERS
# ============================================================================

# _status_installed — true if AGmind install dir + .env exist.
_status_installed() {
    [[ -d "${INSTALL_DIR}" && -f "${ENV_FILE}" ]]
}

# _status_docker_down — true if docker daemon is unreachable.
_status_docker_down() {
    ! docker info >/dev/null 2>&1
}

# _status_active_services — echo space-separated list of services that SHOULD be running.
# Delegates to lib/health.sh::get_service_list (encodes all .env profile logic, incl. LLM_ON_PEER).
# WHY: get_service_list already handles VECTOR_STORE/LLM_PROVIDER/MONITORING_MODE/ENABLE_* — reuse.
_status_active_services() {
    if command -v get_service_list >/dev/null 2>&1; then
        get_service_list 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# _status_is_active_service <svc> — true if the service is in the active/expected set.
# Services NOT in this set → state="disabled" (profile off).
_status_is_active_service() {
    local svc="$1"
    local active
    active="$(_status_active_services)"
    [[ " ${active} " == *" ${svc} "* ]]
}

# _status_is_init_container <svc> — true if this service is a known one-shot init container.
# WHY: init-containers exit cleanly = STATE "done" (gray), not "exited" (red). CLAUDE.md §8.
_status_is_init_container() {
    local svc="$1"
    [[ " ${KNOWN_INIT_CONTAINERS} " == *" ${svc} "* ]]
}

# _status_resolve_container <svc> — map short service name to full container name.
# Mirrors lib/health.sh::check_container name-mapping logic exactly.
_status_resolve_container() {
    local svc="$1"
    local c
    c="${svc//_/-}"
    case "$c" in
        open-webui)  c="openwebui" ;;
        open-notebook) c="notebook" ;;
        ragflow-es01)  c="ragflow-es" ;;
        *) ;;
    esac
    printf 'agmind-%s' "$c"
}

# _status_docker_state <svc> — determine STATE enum for a service.
# Returns STATE string on stdout; exit code: 0=ok, 1=problem.
#
# STATE enum: healthy/running/starting/unhealthy/restarting/exited/done/disabled/not-installed
# Algorithm: Pattern 2 from 02-RESEARCH.md (12 steps).
#
# CRITICAL ordering: init-container check BEFORE active-profile check.
# WHY: a known-init container not in the active set must resolve to "done", not "disabled".
# 02-02's test init_container_done catches this if wrong.
_status_docker_state() {
    local svc="$1"
    local container
    container="$(_status_resolve_container "$svc")"

    # Step 2: DISABLED — profile is OFF → state=disabled (gray). No docker probe needed.
    # WHY SC3: disabled profiles must NOT show as FAIL/red. CLAUDE.md §6.
    # EXCEPTION: init-containers checked for done-state below (step 5), before this gate
    # can trigger "disabled". But init-containers that are truly disabled (profile not active
    # AND they haven't run) → disabled is correct. The research says: check disabled FIRST,
    # THEN init-container. We follow the algorithm verbatim.
    if ! _status_is_active_service "$svc"; then
        echo "disabled"
        return 0
    fi

    # Step 3: query docker ps -a with EXACT name match (BUG-V3-039 avoidance).
    # WHY anchored: "^agmind-redis$" must not match "agmind-redis-lock-cleaner".
    local raw_status
    raw_status="$(docker ps -a --filter "name=^${container}$" --format '{{.Status}}' 2>/dev/null | head -1)"

    # Step 4: container doesn't exist yet
    if [[ -z "$raw_status" ]]; then
        echo "not-installed"
        return 0
    fi

    # Step 5: INIT CONTAINER — expected to exit cleanly.
    # WHY: redis-lock-cleaner/k6/milvus-init have restart:"no" → exit 0 = STATE "done".
    # CLAUDE.md §8 init-containers rule.
    if _status_is_init_container "$svc"; then
        if echo "$raw_status" | grep -qi "exited\|exit"; then
            echo "done"
            return 0
        fi
    fi

    # Step 6: EXITED unexpectedly
    if echo "$raw_status" | grep -qi "exited\|exit"; then
        echo "exited"
        return 1
    fi

    # Step 7: RESTARTING (restart-loop detected from status string)
    if echo "$raw_status" | grep -qi "restarting"; then
        echo "restarting"
        return 1
    fi

    # Step 7b: RESTARTING — RestartCount > 3 (container may show "Up" during restart window)
    local rc
    rc="$(docker inspect "$container" --format '{{.RestartCount}}' 2>/dev/null || echo 0)"
    if [[ "${rc:-0}" -gt 3 ]]; then
        echo "restarting"
        return 1
    fi

    # Step 8: STARTING (docker status string contains "starting")
    if echo "$raw_status" | grep -qi "starting"; then
        echo "starting"
        return 0
    fi

    # Step 9: inspect healthcheck status
    local hc_status
    hc_status="$(docker inspect "$container" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || echo "")"

    if [[ "$hc_status" == "unhealthy" ]]; then
        echo "unhealthy"
        return 1
    fi
    if [[ "$hc_status" == "starting" ]]; then
        echo "starting"
        return 0
    fi

    # Step 10: DISTROLESS — container is Up but has no healthcheck → STATE "running" (green).
    # WHY: loki/alloy/redis-exporter/nginx-exporter have no /bin/sh → no CMD-SHELL healthcheck.
    # docker inspect .State.Health == "" (empty string) for no-healthcheck containers.
    # CLAUDE.md §8 distroless rule.
    if [[ -z "$hc_status" ]]; then
        if echo "$raw_status" | grep -qi "^up"; then
            echo "running"
            return 0
        fi
    fi

    # Step 11: HEALTHY (healthcheck passing — docker ps shows "(healthy)")
    if echo "$raw_status" | grep -qi "healthy"; then
        echo "healthy"
        return 0
    fi

    # Step 12: UP but no healthcheck verdict → "running"
    if echo "$raw_status" | grep -qi "^up"; then
        echo "running"
        return 0
    fi

    echo "exited"
    return 1
}

# _status_restart_count <svc> — echo the RestartCount for a service's container.
_status_restart_count() {
    local container
    container="$(_status_resolve_container "$1")"
    docker inspect "$container" --format '{{.RestartCount}}' 2>/dev/null || echo 0
}

# _status_state_color <state> — echo the ANSI color escape for a given state.
# Colors: green=healthy/running, yellow=starting, red=unhealthy/restarting/exited,
#         cyan(gray)=disabled/done/not-installed. Uses CYAN as "gray" (no gray in common.sh).
_status_state_color() {
    case "$1" in
        healthy|running)              printf '%b' "$GREEN" ;;
        starting)                     printf '%b' "$YELLOW" ;;
        unhealthy|restarting|exited)  printf '%b' "$RED" ;;
        disabled|done|not-installed)  printf '%b' "$CYAN" ;;
        *)                            printf '%b' "$NC" ;;
    esac
}

# ============================================================================
# URL HELPER (Phase 3 reuse: _status_service_url is the Phase 3 endpoint brick)
# ============================================================================

# _status_service_url <svc> — derive the public URL for a service.
# Returns mDNS alias URL (e.g. http://agmind-dify.local) or "—" for internal-only services.
# WHY reusable: Phase 3's `agmind endpoints` calls this directly without re-implementing.
# Source: templates/env.lan.template mDNS aliases + 02-RESEARCH.md Pattern 4.
_status_service_url() {
    local svc="$1"
    case "$svc" in
        api|worker|web|nginx)
            echo "http://agmind-dify.local" ;;
        open-webui|openwebui)
            echo "http://agmind-chat.local" ;;
        grafana)
            echo "http://agmind-grafana.local" ;;
        portainer)
            echo "https://agmind-portainer.local:9443" ;;
        ragflow)
            echo "http://agmind-ragflow.local" ;;
        minio)
            echo "http://$(hostname -I 2>/dev/null | awk '{print $1}'):9001" ;;
        litellm)
            echo "http://$(hostname -I 2>/dev/null | awk '{print $1}'):4001/ui/" ;;
        notebook|open-notebook)
            echo "http://agmind-notebook.local" ;;
        # Internal-only: no public URL exposed
        vllm|vllm-embed|vllm-rerank|tei|tei-rerank|ollama|\
        db|redis|weaviate|qdrant|docling|sandbox|ssrf_proxy|plugin-daemon|\
        prometheus|alertmanager|loki|alloy|node-exporter|cadvisor|\
        redis-exporter|postgres-exporter|nginx-exporter|\
        ragflow_mysql|ragflow_es01|ragflow-mysql|ragflow-es|\
        authelia|searxng|surrealdb|dbgpt|crawl4ai)
            echo "—" ;;
        *)
            echo "—" ;;
    esac
}

# ============================================================================
# NOTES HELPERS (per-service one-liner strings for the NOTES column)
# ============================================================================

# All helpers return a plain string (no ANSI, no secrets).

# _status_notes_vllm — vLLM loaded model id or "loading…"
_status_notes_vllm() {
    local model
    model="$(curl -sSf --max-time 3 "http://localhost:8000/v1/models" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else '')" \
        2>/dev/null || echo "")"
    if [[ -n "$model" ]]; then
        printf 'model %s loaded' "$model"
    else
        printf 'loading\xe2\x80\xa6'
    fi
}

# _status_notes_vector <svc> — weaviate object count or qdrant collection count.
_status_notes_vector() {
    local svc="$1"
    local cnt=""
    if [[ "$svc" == "weaviate" ]]; then
        cnt="$(curl -sSf --max-time 3 "http://localhost:8080/v1/objects?limit=1" 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totalResults',''))" \
            2>/dev/null || echo "")"
        [[ -n "$cnt" ]] && printf '%s objects' "$cnt" || printf '—'
    elif [[ "$svc" == "qdrant" ]]; then
        cnt="$(curl -sSf --max-time 3 "http://localhost:6333/collections" 2>/dev/null \
            | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('result',{}).get('collections',[])))" \
            2>/dev/null || echo "")"
        [[ -n "$cnt" ]] && printf '%s collections' "$cnt" || printf '—'
    else
        printf '—'
    fi
}

# _status_notes_ragflow_es — Elasticsearch cluster health status string.
_status_notes_ragflow_es() {
    local s
    s="$(curl -sSf --max-time 3 "http://localhost:9200/_cluster/health" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" \
        2>/dev/null || echo "")"
    [[ -n "$s" ]] && printf '%s' "$s" || printf '—'
}

# _status_notes_backup — last backup date from check_backup_status output.
# Strips ANSI color codes before pattern matching.
_status_notes_backup() {
    local line=""
    if command -v check_backup_status >/dev/null 2>&1; then
        line="$(check_backup_status 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | grep -E '20[0-9]{2}' \
            | head -1 \
            | sed 's/^ *//; s/ *$//' || echo "")"
    fi
    [[ -n "$line" ]] && printf 'last %s' "$line" || printf 'never'
}

# _status_notes_restart_loop <rc> — "N restarts" when in a restart loop.
_status_notes_restart_loop() {
    local rc="${1:-0}"
    [[ "${rc:-0}" -gt 0 ]] && printf '%s restarts' "$rc" || printf '—'
}

# _status_notes_docling — GPU or CPU mode hint (best-effort).
_status_notes_docling() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        printf 'GPU'
    else
        printf 'CPU'
    fi
}

# ============================================================================
# ROW COLLECTION
# ============================================================================

# _status_find_group <svc> — return the SERVICE_GROUPS key that contains <svc>.
# Falls back to "optional" if not found in any group.
_status_find_group() {
    local svc="$1"
    local g svcs
    # shellcheck disable=SC2153  # SERVICE_GROUPS is sourced from service-map.sh
    for g in "${!SERVICE_GROUPS[@]}"; do
        svcs="${SERVICE_GROUPS[$g]}"
        if [[ " ${svcs} " == *" ${svc} "* ]]; then
            echo "$g"
            return 0
        fi
    done
    echo "optional"
}

# _status_all_known_services — union of: active services + all services in SERVICE_GROUPS.
# WHY: disabled services must appear in the table with state=disabled. If we only iterate
# active services, disabled ones are invisible — that violates SC3.
_status_all_known_services() {
    local active
    active="$(_status_active_services)"
    local g svcs
    local all="$active"
    # shellcheck disable=SC2153  # SERVICE_GROUPS is sourced from service-map.sh
    for g in "${!SERVICE_GROUPS[@]}"; do
        svcs="${SERVICE_GROUPS[$g]}"
        all="${all} ${svcs}"
    done
    # Deduplicate preserving first-occurrence order
    local seen="" svc out=""
    for svc in $all; do
        if [[ " ${seen} " != *" ${svc} "* ]]; then
            seen="${seen} ${svc}"
            out="${out} ${svc}"
        fi
    done
    echo "${out# }"
}

# _status_collect_rows — main pipeline: enumerate all services, determine state, build STATUS_ROWS.
_status_collect_rows() {
    _status_row_reset

    # Docker daemon down → single synthetic row, bail early.
    if _status_docker_down; then
        _STATUS_DOCKER_DOWN=1
        _status_row_add "docker" "core" "not-installed" "—" "Docker daemon not running" "0"
        return 0
    fi

    local all_svcs
    all_svcs="$(_status_all_known_services)"

    local svc group state url notes rc_count

    for svc in ${all_svcs}; do
        group="$(_status_find_group "$svc")"

        # Determine STATE enum (Pattern 2 — 12 steps)
        state="$(_status_docker_state "$svc" 2>/dev/null || echo "exited")"

        # Restart count (used for NOTES and state override)
        rc_count="$(_status_restart_count "$svc" 2>/dev/null || echo 0)"

        # Derive URL (public-facing only; internal-only → "—")
        url="$(_status_service_url "$svc")"

        # Compute NOTES based on service type
        case "$svc" in
            vllm|vllm-embed|vllm-rerank)
                notes="$(_status_notes_vllm)" ;;
            weaviate|qdrant)
                notes="$(_status_notes_vector "$svc")" ;;
            ragflow_es01|ragflow-es)
                notes="$(_status_notes_ragflow_es)" ;;
            docling)
                notes="$(_status_notes_docling)" ;;
            *)
                notes="—" ;;
        esac

        # State-based NOTES overrides (more informative than service-type defaults)
        case "$state" in
            restarting)
                notes="$(_status_notes_restart_loop "$rc_count")" ;;
            disabled)
                notes="profile off" ;;
            done)
                notes="init complete" ;;
            not-installed)
                notes="not deployed" ;;
        esac

        _status_row_add "$svc" "$group" "$state" "$url" "$notes" "$rc_count"
    done

    # Synthetic backup row (backup is not a container — it's a state)
    local backup_notes
    backup_notes="$(_status_notes_backup)"
    _status_row_add "backup" "core" "running" "—" "$backup_notes" "0"

    # LLM_ON_PEER handling: if vLLM runs on a peer spark, add a peer-vllm row.
    # WHY: LLM_ON_PEER=true means vllm is on peer node spark-69a2, not local. CLAUDE.md §6.
    local llm_on_peer
    llm_on_peer="$(_read_env LLM_ON_PEER "false")"
    if [[ "$llm_on_peer" == "true" ]]; then
        local cluster_json="${AGMIND_CLUSTER_STATE_FILE:-/var/lib/agmind/state/cluster.json}"
        local peer_state="disabled"
        if [[ -f "$cluster_json" ]] && command -v jq >/dev/null 2>&1; then
            local peer_ip
            peer_ip="$(jq -r '.peer_ip // empty' "$cluster_json" 2>/dev/null || echo "")"
            if [[ -n "$peer_ip" ]]; then
                if curl -sSf --max-time 3 "http://${peer_ip}:8000/v1/models" >/dev/null 2>&1; then
                    peer_state="healthy"
                else
                    peer_state="unhealthy"
                fi
            fi
        fi
        _status_row_add "peer-vllm" "llm" "$peer_state" "—" "peer spark" "0"
    fi
}

# ============================================================================
# RENDER
# ============================================================================

# _status_overall — scan STATUS_ROWS and echo "ok|warn|fail" overall assessment.
_status_overall() {
    local entry name group state url notes restarts
    local overall="ok"
    for entry in "${STATUS_ROWS[@]+"${STATUS_ROWS[@]}"}"; do
        IFS=$'\x1f' read -r name group state url notes restarts <<< "$entry"
        case "$state" in
            unhealthy|restarting|exited)
                overall="fail" ;;
            starting)
                [[ "$overall" != "fail" ]] && overall="warn" ;;
        esac
    done
    echo "$overall"
}

# _status_header_line — print one-line header: arch · hostname · uptime · overall.
_status_header_line() {
    local arch hostname_s uptime_s overall clr
    arch="$(uname -m 2>/dev/null || echo '?')"
    hostname_s="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '?')"
    uptime_s="$(uptime -p 2>/dev/null | sed 's/^up //' || echo '?')"
    overall="$(_status_overall)"
    case "$overall" in
        ok)   clr="$GREEN" ;;
        warn) clr="$YELLOW" ;;
        fail) clr="$RED" ;;
        *)    clr="$NC" ;;
    esac
    printf '%s · %s · up %s · %b%s%b\n' \
        "$arch" "$hostname_s" "$uptime_s" "$clr" "$overall" "$NC"
}

# _status_emit_table_lines — emit the table body lines to stdout.
# Called by _status_render_table (plain) and _status_render_table_watch (with \e[K suffix).
_status_emit_table_lines() {
    local entry name group state url notes restarts clr

    # Determine group iteration order
    local group_order="${SERVICE_GROUP_ORDER:-}"
    if [[ -z "$group_order" ]]; then
        # shellcheck disable=SC2153  # SERVICE_GROUPS sourced from service-map.sh
        group_order="${!SERVICE_GROUPS[*]}"
    fi

    # Header row
    printf '\n'
    printf "${BOLD}%-22s %-13s %-32s %s${NC}\n" "SERVICE" "STATE" "URL" "NOTES"

    local printed_groups="" cur_group g
    for g in ${group_order} __other__; do
        local printed_header=0
        for entry in "${STATUS_ROWS[@]+"${STATUS_ROWS[@]}"}"; do
            IFS=$'\x1f' read -r name group state url notes restarts <<< "$entry"
            # For __other__: emit rows whose group wasn't in group_order
            if [[ "$g" == "__other__" ]]; then
                if [[ " ${printed_groups} " == *" ${group} "* ]]; then
                    continue
                fi
                cur_group="$group"
            else
                [[ "$group" != "$g" ]] && continue
                cur_group="$g"
            fi
            if [[ "$printed_header" -eq 0 ]]; then
                printf "${BOLD}${CYAN}── %s ──${NC}\n" "$cur_group"
                printed_header=1
                [[ " ${printed_groups} " != *" ${cur_group} "* ]] && \
                    printed_groups="${printed_groups} ${cur_group}"
            fi
            clr="$(_status_state_color "$state")"
            # shellcheck disable=SC2059  # $clr / $NC are escape strings used with %b
            printf "  %-20s %b%-13s%b %-32s %s\n" \
                "$name" "$clr" "$state" "$NC" "$url" "$notes"
        done
    done

    printf '\n'
    printf "${CYAN}→ \`agmind doctor\` for full diagnostics · \`agmind status --service <name>\` for details${NC}\n"
}

# _status_render_table — render the full human-readable table to stdout (plain lines).
_status_render_table() {
    printf '\n'
    printf "${BOLD}${CYAN}AGmind Status${NC}\n"
    _status_header_line
    _status_emit_table_lines
}

# _status_render_table_watch — same as _status_render_table but each line ends with \e[K.
# WHY \e[K: clears to end-of-line so old longer content doesn't ghost when table shrinks.
_status_render_table_watch() {
    printf '\n'
    printf "${BOLD}${CYAN}AGmind Status${NC}\e[K\n"
    _status_header_line | sed 's/$/\x1b[K/'
    _status_emit_table_lines | sed 's/$/\x1b[K/'
}

# _status_json_escape — escape a string for safe use in hand-built JSON (fallback path).
_status_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]//g'
}

# _status_render_json — emit D-11 JSON schema to stdout.
# WHY python3: shell string concat breaks on quotes/newlines in notes/messages.
# Mirror of lib/doctor.sh::_registry_render_json (CLAUDE.md §8 precedent).
_status_render_json() {
    local entry name group state url notes restarts
    local services_json="" first=1

    for entry in "${STATUS_ROWS[@]+"${STATUS_ROWS[@]}"}"; do
        IFS=$'\x1f' read -r name group state url notes restarts <<< "$entry"
        local rec
        if command -v python3 >/dev/null 2>&1; then
            rec="$(python3 -c "
import json, sys
rec = {
    'name': sys.argv[1],
    'group': sys.argv[2],
    'state': sys.argv[3],
    'url': sys.argv[4],
    'notes': sys.argv[5],
    'restarts': int(sys.argv[6] or 0),
}
print(json.dumps(rec))
" "$name" "$group" "$state" "$url" "$notes" "$restarts")"
        else
            # Fallback: hand-built JSON with careful escaping
            local n_e g_e s_e u_e no_e
            n_e="$(_status_json_escape "$name")"
            g_e="$(_status_json_escape "$group")"
            s_e="$(_status_json_escape "$state")"
            u_e="$(_status_json_escape "$url")"
            no_e="$(_status_json_escape "$notes")"
            rec="{\"name\":\"${n_e}\",\"group\":\"${g_e}\",\"state\":\"${s_e}\",\"url\":\"${u_e}\",\"notes\":\"${no_e}\",\"restarts\":${restarts:-0}}"
        fi
        if [[ "$first" -eq 1 ]]; then
            services_json="$rec"
            first=0
        else
            services_json="${services_json},${rec}"
        fi
    done

    local overall
    overall="$(_status_overall)"
    local ts hostname_s arch_s gpu_type gpu_note

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    hostname_s="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo 'unknown')"
    arch_s="$(uname -m 2>/dev/null || echo 'unknown')"
    gpu_type="$(command -v nvidia-smi >/dev/null 2>&1 && echo nvidia || echo none)"
    # WHY GB10 note: NVML --query-gpu=memory.used returns [N/A] on DGX Spark unified memory.
    gpu_note="GB10 unified — NVML mem N/A"

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
data = {
    'generated_at': sys.argv[1],
    'hostname': sys.argv[2],
    'arch': sys.argv[3],
    'overall': sys.argv[4],
    'services': json.loads('[' + sys.argv[5] + ']') if sys.argv[5] else [],
    'gpu': {
        'type': sys.argv[6],
        'note': sys.argv[7],
    },
    'endpoints': {
        'dify': 'http://agmind-dify.local',
        'webui': 'http://agmind-chat.local',
        'grafana': 'http://agmind-grafana.local',
        'ragflow': 'http://agmind-ragflow.local',
    },
}
print(json.dumps(data))
" "$ts" "$hostname_s" "$arch_s" "$overall" "$services_json" "$gpu_type" "$gpu_note"
    else
        # python3 absent: hand-built minimal JSON
        local ts_e hn_e ar_e ov_e gpu_e gn_e
        ts_e="$(_status_json_escape "$ts")"
        hn_e="$(_status_json_escape "$hostname_s")"
        ar_e="$(_status_json_escape "$arch_s")"
        ov_e="$(_status_json_escape "$overall")"
        gpu_e="$(_status_json_escape "$gpu_type")"
        gn_e="$(_status_json_escape "$gpu_note")"
        printf '{"generated_at":"%s","hostname":"%s","arch":"%s","overall":"%s","services":[%s],"gpu":{"type":"%s","note":"%s"},"endpoints":{"dify":"http://agmind-dify.local","webui":"http://agmind-chat.local","grafana":"http://agmind-grafana.local","ragflow":"http://agmind-ragflow.local"}}\n' \
            "$ts_e" "$hn_e" "$ar_e" "$ov_e" "$services_json" "$gpu_e" "$gn_e"
    fi
}

# _status_render_watch [interval] — live ANSI cursor-home refresh loop.
# WHY cursor-home + \e[K + \e[J: no-flicker (no full clear \e[2J → no flash).
# WHY non-TTY one-shot: piping `agmind status --watch | grep` must not loop forever.
# Source: 02-RESEARCH.md Pattern 5.
_status_render_watch() {
    local interval="${1:-$DEFAULT_WATCH_INTERVAL}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=$DEFAULT_WATCH_INTERVAL

    # Non-TTY: print once and exit (no ANSI, no infinite loop)
    if [[ ! -t 1 ]]; then
        _status_collect_rows
        _status_render_table
        return 0
    fi

    # TTY: hide cursor, trap SIGINT/TERM for clean exit (restore cursor + newline)
    printf '\e[?25l'
    # shellcheck disable=SC2064  # intentional immediate-expansion for printf
    trap 'printf "\e[?25h\n"; exit 0' INT TERM

    while true; do
        _status_collect_rows
        printf '\e[H'              # cursor to home (no clear → no flash)
        _status_render_table_watch # each line ends with \e[K (clear to EOL)
        printf '\e[J'              # clear from cursor to end of screen
        sleep "$interval"
    done
}

# ============================================================================
# SERVICE DETAIL
# ============================================================================

# _status_service_detail <name> — detailed view of one service.
# Accepts name with optional "agmind-" prefix. Exit 0=healthy/running/done, 1=not.
# Source: 02-RESEARCH.md Pattern 6.
_status_service_detail() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "usage: agmind status --service <name>"
        return 1
    fi

    # Strip "agmind-" prefix if given
    local svc="${name#agmind-}"
    local container
    container="$(_status_resolve_container "$svc")"

    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_error "service '${svc}' not found (container ${container} does not exist)"
        return 1
    fi

    echo "=== Service: ${svc} ==="
    docker inspect "$container" \
        --format 'Image: {{.Config.Image}}
Status: {{.State.Status}}
StartedAt: {{.State.StartedAt}}
RestartCount: {{.RestartCount}}' 2>/dev/null || echo "(inspect unavailable)"

    # Last health log entry (if healthcheck exists)
    local last_hc
    last_hc="$(docker inspect "$container" \
        --format '{{if .State.Health}}Last health: {{(index .State.Health.Log 0).Output}}{{end}}' \
        2>/dev/null | head -1 || true)"
    [[ -n "$last_hc" ]] && echo "$last_hc"

    echo ""
    echo "--- Resources ---"
    docker stats --no-stream \
        --format 'CPU: {{.CPUPerc}}   MEM: {{.MemUsage}}' \
        "$container" 2>/dev/null || echo "(stats unavailable)"

    # GPU section (only for GPU-using services)
    # WHY --query-compute-apps: on GB10 (DGX Spark), --query-gpu=memory.used returns [N/A].
    # Use per-PID query instead. CLAUDE.md §6/§8.
    case "$svc" in
        vllm|vllm-embed|vllm-rerank|tei|tei-rerank|docling)
            echo ""
            echo "--- GPU ---"
            local pid gpu_mem
            pid="$(docker inspect "$container" --format '{{.State.Pid}}' 2>/dev/null || echo "")"
            if [[ -n "$pid" && "$pid" != "0" ]]; then
                gpu_mem="$(nvidia-smi --query-compute-apps=pid,used_gpu_memory \
                    --format=csv,noheader,nounits 2>/dev/null \
                    | grep "^${pid}," | cut -d',' -f2 | xargs || echo "")"
                echo "GPU mem (PID ${pid}): ${gpu_mem:-N/A (GB10 unified)}"
            else
                echo "GPU mem: N/A (GB10 unified)"
            fi
            ;;
    esac

    echo ""
    echo "--- Details ---"
    case "$svc" in
        vllm|vllm-embed|vllm-rerank)
            local model
            model="$(curl -sSf --max-time 5 "http://localhost:8000/v1/models" 2>/dev/null \
                | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else '(loading)')" \
                2>/dev/null || echo "(not reachable)")"
            echo "Loaded model: ${model}"
            # Surface gpu_memory_utilization / --enforce-eager from compose env (best-effort)
            local vllm_args
            vllm_args="$(docker inspect "$container" \
                --format '{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null \
                | grep -oE 'gpu.memory.utilization[ =][0-9.]+|--enforce-eager' \
                | sed 's/^/arg: /' || true)"
            [[ -n "$vllm_args" ]] && echo "$vllm_args"
            ;;
        weaviate|qdrant)
            local vs_url
            if [[ "$svc" == "weaviate" ]]; then
                vs_url="http://localhost:8080/v1/meta"
            else
                vs_url="http://localhost:6333/readyz"
            fi
            curl -sSf --max-time 5 "$vs_url" 2>/dev/null \
                | python3 -c "import json,sys; d=json.load(sys.stdin); print('version: ' + str(d.get('version','?')))" \
                2>/dev/null || echo "(not reachable)"
            ;;
        ragflow-es|ragflow_es01)
            curl -sSf --max-time 5 "http://localhost:9200/_cluster/health" 2>/dev/null \
                | python3 -c "import json,sys; d=json.load(sys.stdin); print('ES status: ' + str(d.get('status','?')))" \
                2>/dev/null || echo "(not reachable)"
            ;;
        db)
            docker exec "$container" psql -U postgres -d dify \
                -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null \
                | tail -2 || echo "(db not reachable)"
            ;;
        redis)
            # WHY grep: only show non-secret highlights. REDIS_PASSWORD never echoed.
            # CLAUDE.md §5 — no credentials in stdout/logs.
            local redis_pw
            redis_pw="$(_read_env REDIS_PASSWORD "")"
            docker exec "$container" redis-cli -a "$redis_pw" INFO server 2>/dev/null \
                | grep -E 'redis_version|uptime_in_seconds|connected_clients' \
                || echo "(redis not reachable)"
            ;;
        *)
            echo "(no service-specific details)"
            ;;
    esac

    echo ""
    echo "--- Logs (last 30 lines) ---"
    docker logs --tail 30 "$container" 2>&1 | tail -30 || echo "(logs unavailable)"

    # Exit code based on container health
    local st
    st="$(_status_docker_state "$svc" 2>/dev/null || echo "exited")"
    case "$st" in
        healthy|running|done) return 0 ;;
        *)                    return 1 ;;
    esac
}

# ============================================================================
# PUBLIC API
# ============================================================================

# status_run [--json] [--watch [interval]] [--service <name>]
# Main entry point for `agmind status`. Always exits 0 for table/json/watch.
# --service exits 0 if healthy, 1 if not (useful in scripts: agmind status --service vllm && ...).
status_run() {
    local mode="table"
    local watch_interval="$DEFAULT_WATCH_INTERVAL"
    local service_name=""

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                mode="json"
                shift
                ;;
            --watch)
                mode="watch"
                shift
                # Optional interval argument
                if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                    watch_interval="$1"
                    shift
                fi
                ;;
            --service)
                mode="service"
                shift
                if [[ $# -eq 0 || -z "${1:-}" ]]; then
                    log_error "--service requires a service name"
                    return 2
                fi
                service_name="$1"
                shift
                ;;
            -*)
                log_error "unknown flag: $1"
                return 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # NOT-INSTALLED gate: graceful before any docker call.
    # WHY: D-06/D-07 — not-installed is a graceful state, exit 0.
    if ! _status_installed; then
        if [[ "$mode" == "json" ]]; then
            if command -v python3 >/dev/null 2>&1; then
                python3 -c "import json; print(json.dumps({'overall':'fail','error':'not-installed','services':[]}))"
            else
                printf '{"overall":"fail","error":"not-installed","services":[]}\n'
            fi
            return 0
        else
            printf '%b' "${YELLOW}"
            echo "AGmind not installed at ${INSTALL_DIR} — run \`sudo bash install.sh\`"
            printf '%b' "${NC}"
            return 0
        fi
    fi

    # Dispatch
    case "$mode" in
        table)
            _status_collect_rows
            _status_render_table
            return 0
            ;;
        json)
            _status_collect_rows
            _status_render_json
            return 0
            ;;
        watch)
            _status_render_watch "$watch_interval"
            return 0
            ;;
        service)
            _status_service_detail "$service_name"
            return $?
            ;;
    esac
}
