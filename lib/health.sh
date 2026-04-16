#!/usr/bin/env bash
# health.sh — Healthcheck for all containers, extended reports, alerts.
# Dependencies: common.sh (log_*, colors)
# Functions: wait_healthy(timeout), check_all(), report_health(), send_alert(msg)
# Expects: INSTALL_DIR
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# Fallback log functions when sourced without common.sh (e.g. via agmind.sh)
command -v log_info    >/dev/null 2>&1 || log_info()    { echo -e "  → $*"; }
command -v log_success >/dev/null 2>&1 || log_success() { echo -e "  ✓ $*"; }
command -v log_warn    >/dev/null 2>&1 || log_warn()    { echo -e "  ⚠ $*"; }
command -v log_error   >/dev/null 2>&1 || log_error()   { echo -e "  ✗ $*"; }

# Fallback colors
RED="${RED:-\033[0;31m}"; GREEN="${GREEN:-\033[0;32m}"; YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"; BOLD="${BOLD:-\033[1m}"; NC="${NC:-\033[0m}"

# Service mappings — single source of truth
_HEALTH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=service-map.sh
source "${_HEALTH_SCRIPT_DIR}/service-map.sh"

# ============================================================================
# SERVICE LIST (dynamic based on .env)
# ============================================================================

get_service_list() {
    local compose_dir="${INSTALL_DIR}/docker"
    local env_file="${compose_dir}/.env"
    local services=(db redis sandbox ssrf_proxy api worker web plugin_daemon nginx)

    if [[ -f "$env_file" ]]; then
        # Vector store
        local vector_store
        vector_store="$(grep '^VECTOR_STORE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")"
        if [[ "$vector_store" == "qdrant" ]]; then
            services+=(qdrant)
        else
            services+=(weaviate)
        fi

        # LLM/Embedding providers
        local llm_provider embed_provider
        llm_provider="$(grep '^LLM_PROVIDER=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
        embed_provider="$(grep '^EMBED_PROVIDER=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
        if [[ "$llm_provider" == "ollama" || "$embed_provider" == "ollama" ]]; then
            services+=(ollama)
        fi
        if [[ "$llm_provider" == "vllm" ]]; then services+=(vllm); fi
        if [[ "$embed_provider" == "tei" ]]; then services+=(tei); fi
        if [[ "$embed_provider" == "vllm-embed" ]]; then services+=(vllm-embed); fi

        # Reranker
        local enable_reranker reranker_provider
        enable_reranker="$(grep '^ENABLE_RERANKER=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "false")"
        reranker_provider="$(grep '^RERANKER_PROVIDER=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "tei")"
        if [[ "$enable_reranker" == "true" ]]; then
            if [[ "$reranker_provider" == "vllm-rerank" ]]; then
                services+=(vllm-rerank)
            else
                services+=(tei-rerank)
            fi
        fi

        # Monitoring
        local monitoring_mode
        monitoring_mode="$(grep '^MONITORING_MODE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "none")"
        if [[ "$monitoring_mode" == "local" ]]; then
            services+=(prometheus alertmanager cadvisor node-exporter grafana portainer loki promtail)
        fi

        # ETL
        local etl_type
        etl_type="$(grep '^ETL_TYPE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "dify")"
        if [[ "${etl_type,,}" == "unstructured" || "$etl_type" == "unstructured_api" ]]; then
            services+=(docling)
        fi

        # LiteLLM
        local enable_litellm
        enable_litellm="$(grep '^ENABLE_LITELLM=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "true")"
        if [[ "$enable_litellm" == "true" ]]; then services+=(litellm); fi

        # Optional services
        local enable_searxng enable_notebook enable_dbgpt enable_crawl4ai
        enable_searxng="$(grep '^ENABLE_SEARXNG=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "false")"
        enable_notebook="$(grep '^ENABLE_NOTEBOOK=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "false")"
        enable_dbgpt="$(grep '^ENABLE_DBGPT=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "false")"
        enable_crawl4ai="$(grep '^ENABLE_CRAWL4AI=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "false")"
        if [[ "$enable_searxng" == "true" ]]; then services+=(searxng); fi
        if [[ "$enable_notebook" == "true" ]]; then services+=(surrealdb open-notebook); fi
        if [[ "$enable_dbgpt" == "true" ]]; then services+=(dbgpt); fi
        if [[ "$enable_crawl4ai" == "true" ]]; then services+=(crawl4ai); fi

        # Open WebUI
        local enable_openwebui
        enable_openwebui="$(grep '^ENABLE_OPENWEBUI=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "false")"
        if [[ "$enable_openwebui" == "true" ]]; then services+=(open-webui pipelines); fi
    else
        services+=(weaviate)
    fi

    echo "${services[@]}"
}

# ============================================================================
# CONTAINER CHECK
# ============================================================================

check_container() {
    local name="$1"
    # Map service names to container name suffixes
    # ssrf_proxy → ssrf-proxy, plugin_daemon → plugin-daemon, open-webui → openwebui
    local cname="${name//_/-}"
    if [[ "$cname" == "open-webui" ]]; then cname="openwebui"; fi
    if [[ "$cname" == "open-notebook" ]]; then cname="notebook"; fi

    # Exact name match to avoid confusion with init-containers (BUG-V3-039)
    # e.g. "agmind-redis" must not match "agmind-redis-lock-cleaner"
    local status
    status="$(docker ps -a --filter "name=^agmind-${cname}$" --format '{{.Status}}' 2>/dev/null | head -1)"
    if [[ -z "$status" ]]; then status="not found"; fi

    if echo "$status" | grep -qi "up\|healthy"; then
        echo -e "  ${GREEN}[OK]${NC}  ${name}"
        return 0
    elif echo "$status" | grep -qi "starting"; then
        echo -e "  ${YELLOW}[..]${NC}  ${name} (starting)"
        return 1
    else
        echo -e "  ${RED}[!!]${NC}  ${name} (${status})"
        return 1
    fi
}

# ============================================================================
# GPU HEALTH HELPERS
# ============================================================================

# Check if GPU service responds to HTTP health probe directly (faster than Docker healthcheck).
# Tries curl, wget, python — GPU containers often lack standard HTTP tools.
_gpu_svc_responds() {
    local svc="$1" compose_file="$2"
    local port=""
    case "$svc" in
        vllm|vllm-embed|vllm-rerank) port=8000 ;;
        tei|tei-rerank) port=80 ;;
        ollama)         port=11434 ;;
        *)              return 1 ;;
    esac
    local container
    container="$(docker compose -f "$compose_file" ps --format '{{.Name}}' "$svc" 2>/dev/null | head -1)"
    if [[ -z "$container" ]]; then return 1; fi
    docker exec "$container" curl -sf "http://localhost:${port}/health" >/dev/null 2>&1 \
        || docker exec "$container" wget -qO- "http://localhost:${port}/health" >/dev/null 2>&1 \
        || docker exec "$container" python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:${port}/health')" >/dev/null 2>&1
}

# ============================================================================
# GPU PROGRESS PARSER
# ============================================================================

# _parse_gpu_progress — reads last log line of a GPU service and returns a
# human-readable progress string (e.g. "Downloading 47%" or "Loading model...").
# Used by wait_healthy Phase 2 to display real progress instead of a blind timer.
_parse_gpu_progress() {
    local svc="$1"
    local compose_file="$2"
    local last_line
    last_line="$(docker compose -f "$compose_file" logs --tail=1 --no-log-prefix "$svc" 2>/dev/null | tr -d '\r')"
    if [[ -z "$last_line" ]]; then echo "waiting..."; return; fi

    # vLLM / general downloading patterns
    if echo "$last_line" | grep -qiE 'downloading|fetching'; then
        local pct
        pct="$(echo "$last_line" | grep -oE '[0-9]+%' | tail -1)"
        echo "Downloading ${pct:-...}"
        return
    fi
    if echo "$last_line" | grep -qiE 'loading model|loading weights|loading safetensors'; then
        echo "Loading model..."
        return
    fi
    if echo "$last_line" | grep -qiE 'warming up|compilation|compiling'; then
        echo "Warming up..."
        return
    fi

    # Ollama patterns
    if echo "$last_line" | grep -qiE 'pulling.*manifest|pulling.*layer|verifying'; then
        local pct
        pct="$(echo "$last_line" | grep -oE '[0-9]+%' | tail -1)"
        echo "Pulling ${pct:-...}"
        return
    fi

    # TEI patterns
    if echo "$last_line" | grep -qiE 'downloading model|downloading.*shard|warming up model'; then
        local pct
        pct="$(echo "$last_line" | grep -oE '[0-9]+%' | tail -1)"
        echo "Loading ${pct:-...}"
        return
    fi

    echo "starting..."
}

# ============================================================================
# WAIT HEALTHY
# ============================================================================

wait_healthy() {
    local timeout="${1:-300}"
    local gpu_timeout="${2:-${TIMEOUT_GPU_HEALTH:-900}}"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300
    [[ "$gpu_timeout" =~ ^[0-9]+$ ]] || gpu_timeout=900
    local interval=5
    local elapsed=0
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"

    # Critical services: exit of any of these = immediate failure
    local critical_services="db redis sandbox ssrf_proxy api worker web plugin_daemon nginx"

    # GPU services: extended startup time for model loading / CUDA init
    local gpu_services=" vllm vllm-embed vllm-rerank tei tei-rerank ollama docling "

    local services
    read -ra services <<< "$(get_service_list)"

    # Split into core and GPU lists
    local -a core_svcs=()
    local -a gpu_svcs=()
    for svc in "${services[@]}"; do
        if [[ "$gpu_services" == *" $svc "* ]]; then
            gpu_svcs+=("$svc")
        else
            core_svcs+=("$svc")
        fi
    done

    local optional_exited=""

    # === Phase 1: Core services (strict timeout) ===
    log_info "Waiting for core containers to be healthy (timeout: ${timeout}s)..."
    echo ""

    while [[ $elapsed -lt $timeout ]]; do
        local all_ok=true

        for svc in "${core_svcs[@]}"; do
            local status
            status="$(docker compose -f "$compose_file" ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")"
            # Fail fast: critical container exited
            if echo "$status" | grep -qi "exited"; then
                if echo " $critical_services " | grep -q " $svc "; then
                    echo ""
                    log_error "Critical container '${svc}' has exited — not waiting for timeout"
                    echo -e "  ${RED}Last logs from ${svc}:${NC}"
                    docker compose -f "$compose_file" logs --tail=15 "$svc" 2>/dev/null || true
                    echo ""
                    check_all
                    return 1
                else
                    if ! echo "$optional_exited" | grep -q " $svc "; then
                        optional_exited="${optional_exited} ${svc} "
                        log_warn "Optional service '${svc}' exited (non-critical, continuing)"
                        docker compose -f "$compose_file" logs --tail=5 "$svc" 2>/dev/null || true
                    fi
                    continue
                fi
            fi
            if ! echo "$status" | grep -qi "up\|healthy"; then
                all_ok=false
                break
            fi
        done

        if [[ "$all_ok" == "true" ]]; then
            log_success "Core services are up!"
            break
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -ne "\r  Waiting for core services... ${elapsed}/${timeout}s"
    done

    if [[ $elapsed -ge $timeout && "$all_ok" != "true" ]]; then
        echo ""
        log_error "Timeout! Core containers not ready within ${timeout}s"
        echo ""
        check_all
        return 1
    fi

    # === Phase 2: GPU services (extended timeout, non-blocking) ===
    if [[ ${#gpu_svcs[@]} -eq 0 ]]; then
        echo ""
        check_all
        return 0
    fi

    echo ""
    log_info "Waiting for GPU services — loading models (timeout: ${gpu_timeout}s)..."

    local gpu_done=""
    local gpu_elapsed=0

    while [[ $gpu_elapsed -lt $gpu_timeout ]]; do
        local gpu_ready=0

        for svc in "${gpu_svcs[@]}"; do
            if [[ "$gpu_done" == *" $svc "* ]]; then gpu_ready=$((gpu_ready + 1)); continue; fi

            local status
            status="$(docker compose -f "$compose_file" ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")"

            # Exited — mark done, not an error (optional GPU service)
            if echo "$status" | grep -qi "exited"; then
                if ! echo "$optional_exited" | grep -q " $svc "; then
                    optional_exited="${optional_exited} ${svc} "
                    log_warn "GPU service '${svc}' exited (non-critical)"
                fi
                gpu_done="${gpu_done} ${svc} "
                gpu_ready=$((gpu_ready + 1))
                continue
            fi

            # Healthy — via Docker status OR direct HTTP probe
            if echo "$status" | grep -qi "healthy" || _gpu_svc_responds "$svc" "$compose_file"; then
                gpu_done="${gpu_done} ${svc} "
                log_success "${svc} is healthy"
                gpu_ready=$((gpu_ready + 1))
                continue
            fi
        done

        if [[ $gpu_ready -ge ${#gpu_svcs[@]} ]]; then break; fi

        sleep "$interval"
        gpu_elapsed=$((gpu_elapsed + interval))

        # Compact progress line (works in both TTY and non-TTY)
        local progress_info=""
        for svc in "${gpu_svcs[@]}"; do
            if [[ "$gpu_done" == *" $svc "* ]]; then continue; fi
            local svc_progress
            svc_progress="$(_parse_gpu_progress "$svc" "$compose_file")"
            progress_info="${progress_info:+${progress_info} | }${svc}: ${svc_progress}"
        done
        echo -e "  ${progress_info}  [${gpu_elapsed}/${gpu_timeout}s]"
    done
    echo ""

    # Check which GPU services are still not ready
    local still_loading=""
    for svc in "${gpu_svcs[@]}"; do
        if [[ "$gpu_done" == *" $svc "* ]]; then continue; fi
        # Container still alive — it's loading, not broken
        local status
        status="$(docker compose -f "$compose_file" ps --format '{{.Status}}' "$svc" 2>/dev/null || echo "")"
        if echo "$status" | grep -qi "up\|starting"; then
            still_loading="${still_loading:+${still_loading}, }${svc}"
        else
            optional_exited="${optional_exited} ${svc} "
            log_warn "GPU service '${svc}' is not running (${status})"
        fi
    done

    if [[ -n "$still_loading" ]]; then
        log_warn "GPU services still loading: ${still_loading}"
        log_warn "Installation continues — models will finish in background"
        log_warn "Check later: agmind status"
    elif [[ -z "$still_loading" ]]; then
        log_success "All GPU services ready!"
    fi

    echo ""
    check_all
    return 0
}

# ============================================================================
# CHECK ALL
# ============================================================================

check_all() {
    echo -e "${CYAN}=== Container Status ===${NC}"

    local services
    read -ra services <<< "$(get_service_list)"
    local failed=0

    for svc in "${services[@]}"; do
        check_container "$svc" || failed=$((failed + 1))
    done

    echo ""
    if [[ $failed -eq 0 ]]; then
        log_success "All services running"
    else
        log_warn "${failed} service(s) not running"
        local server_ip="unknown"
        if [[ "$(uname)" == "Darwin" ]]; then
            server_ip="$(ipconfig getifaddr en0 2>/dev/null || echo "unknown")"
        else
            server_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")"
        fi
        if [[ -z "${server_ip:-}" ]]; then server_ip="$(hostname 2>/dev/null || echo 'unknown')"; fi
        send_alert "AGMind: ${failed} service(s) not running. Check: ${server_ip}"
        echo "  Check logs: docker compose logs <service>"
    fi

    return "$failed"
}

# ============================================================================
# VERIFY SERVICES (HTTP liveness checks)
# ============================================================================

# verify_services — performs real HTTP liveness checks against profile-specific endpoints.
# Populates global VERIFY_RESULTS array: "Name|URL|OK|FAIL" per service.
# Returns: number of failed checks (0 = all OK).
# Usable from both install.sh (post-install) and scripts/agmind.sh (agmind doctor).
verify_services() {
    local compose_dir="${INSTALL_DIR}/docker"
    local env_file="${compose_dir}/.env"
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
    local domain="${DOMAIN:-$ip}"

    # Service check definitions: name|url|container(empty=host curl)|profile_condition
    local -a svc_checks=()

    # Always check core services (nginx proxied — accessible from host)
    svc_checks+=("Dify App|http://${domain}/||always")
    svc_checks+=("Dify Console|http://${domain}:3000/console/api/setup||always")

    # Open WebUI (optional)
    if [[ -f "${compose_dir}/.env" ]]; then
        local _owui
        _owui="$(grep '^ENABLE_OPENWEBUI=' "${compose_dir}/.env" 2>/dev/null | cut -d'=' -f2- || echo "false")"
        if [[ "$_owui" == "true" ]]; then
            svc_checks+=("Open WebUI|http://${domain}/chat||openwebui")
        fi
    fi

    # Profile-conditional services — internal ports, use docker exec
    if [[ -f "$env_file" ]]; then
        local llm_prov embed_prov vector_store
        llm_prov="$(grep '^LLM_PROVIDER=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
        embed_prov="$(grep '^EMBED_PROVIDER=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
        vector_store="$(grep '^VECTOR_STORE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")"

        if [[ "$llm_prov" == "vllm" ]]; then svc_checks+=("vLLM|http://localhost:8000/v1/models|agmind-vllm|vllm"); fi
        if [[ "$llm_prov" == "ollama" || "$embed_prov" == "ollama" ]]; then svc_checks+=("Ollama|http://localhost:11434/api/tags|agmind-ollama|ollama"); fi
        if [[ "$embed_prov" == "tei" ]]; then svc_checks+=("TEI|http://localhost:80/info|agmind-tei|tei"); fi
        if [[ "$vector_store" == "weaviate" ]]; then svc_checks+=("Weaviate|http://localhost:8080/v1/.well-known/ready|agmind-weaviate|weaviate"); fi
        if [[ "$vector_store" == "qdrant" ]]; then svc_checks+=("Qdrant|http://localhost:6333/readyz|agmind-qdrant|qdrant"); fi
    fi

    # Global results array (accessible to caller)
    VERIFY_RESULTS=()
    local total=0 ok=0 fail=0

    for entry in "${svc_checks[@]}"; do
        IFS='|' read -r name url container _cond <<< "$entry"
        total=$((total + 1))
        local status="FAIL"
        local http_code

        # Build check command — docker exec for internal services, host curl for proxied
        # Fallback: if container has no curl, resolve container IP and curl from host
        local _do_check
        if [[ -n "$container" ]]; then
            if docker exec "$container" command -v curl &>/dev/null 2>&1; then
                _do_check() { docker exec "$container" curl -sf --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000"; }
            elif docker exec "$container" command -v wget &>/dev/null 2>&1; then
                _do_check() { docker exec "$container" wget -qO /dev/null --timeout=5 "$url" 2>/dev/null && echo "200" || echo "000"; }
            else
                # No curl/wget in container — get container IP and curl from host
                local cip
                cip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null | head -1)"
                if [[ -n "$cip" ]]; then
                    local port path
                    port="$(echo "$url" | sed -E 's|https?://[^:/]+:?([0-9]*)/.*|\1|')"
                    path="$(echo "$url" | sed -E 's|https?://[^/]+(/.*)|\1|')"
                    if [[ -z "$port" || "$port" == "$url" ]]; then port=80; fi
                    local host_url="http://${cip}:${port}${path}"
                    _do_check() { curl -sf --max-time 5 -o /dev/null -w '%{http_code}' "$host_url" 2>/dev/null || echo "000"; }
                else
                    _do_check() { echo "000"; }
                fi
            fi
        else
            _do_check() { curl -sf --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000"; }
        fi

        # GPU services need extended retries (model loading / CUDA init)
        local max_retries=1 retry_interval=10
        case "$name" in
            vLLM|TEI|Ollama) max_retries=5; retry_interval=15 ;;
        esac

        # First attempt
        http_code="$(_do_check)"
        if [[ "$http_code" =~ ^[23] ]]; then
            status="OK"
        else
            local attempt=0
            while [[ $attempt -lt $max_retries ]]; do
                attempt=$((attempt + 1))
                if [[ "$max_retries" -gt 1 ]]; then echo -ne "\r  ⏳ ${name}: retry ${attempt}/${max_retries}...          "; fi
                sleep "$retry_interval"
                http_code="$(_do_check)"
                if [[ "$http_code" =~ ^[23] ]]; then
                    status="OK"
                    break
                fi
            done
            if [[ "$max_retries" -gt 1 ]]; then echo -ne "\r                                              \r"; fi
        fi

        if [[ "$status" == "OK" ]]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi

        VERIFY_RESULTS+=("${name}|${url}|${status}")
    done

    echo -e "${CYAN}=== Service Verification ===${NC}"
    for entry in "${VERIFY_RESULTS[@]}"; do
        IFS='|' read -r name url status <<< "$entry"
        if [[ "$status" == "OK" ]]; then
            echo -e "  ${GREEN}[OK]${NC}   ${name}  ${url}"
        else
            # Per-service troubleshoot hints
            local hint=""
            case "$name" in
                vLLM)           hint="Model still loading. Check: agmind logs vllm" ;;
                Ollama)         hint="Check: agmind logs ollama" ;;
                TEI)            hint="Check: agmind logs tei" ;;
                "Dify Console") hint="Check: agmind logs api" ;;
                "Open WebUI")   hint="Check: agmind logs open-webui" ;;
                Weaviate)       hint="Check: agmind logs weaviate" ;;
                Qdrant)         hint="Check: agmind logs qdrant" ;;
                *)              hint="Check service logs" ;;
            esac
            echo -e "  ${RED}[FAIL]${NC} ${name}  ${url}"
            echo -e "         ${CYAN}-> ${hint}${NC}"
        fi
    done
    echo ""
    echo -e "  Total: ${ok}/${total} services reachable"
    echo ""

    return "$fail"
}

# ============================================================================
# SEND ALERT
# ============================================================================

send_alert() {
    local message="$1"

    # Rate-limit: skip if same message was sent within cooldown period
    local cooldown_file
    cooldown_file="/tmp/agmind_alert_cooldown_$(echo "$message" | md5sum | cut -c1-8)"
    local cooldown_seconds=900  # 15 minutes
    if [[ -f "$cooldown_file" ]]; then
        local last_alert
        last_alert=$(stat -c %Y "$cooldown_file" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        if (( now - last_alert < cooldown_seconds )); then
            return 0  # already alerted recently
        fi
    fi

    local env_file="${INSTALL_DIR}/docker/.env"
    [[ -f "$env_file" ]] || return 0

    local alert_mode
    alert_mode="$(grep '^ALERT_MODE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "none")"

    case "$alert_mode" in
        webhook)
            local webhook_url
            webhook_url="$(grep '^ALERT_WEBHOOK_URL=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
            if [[ -n "$webhook_url" ]]; then
                local escaped_message
                escaped_message="$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')"
                curl -sf --max-time 10 -X POST "$webhook_url" \
                    -H "Content-Type: application/json" \
                    -d "{\"text\":\"${escaped_message}\",\"source\":\"agmind-health\"}" \
                    >/dev/null 2>&1 || true
            fi
            ;;
        telegram)
            local tg_token tg_chat_id
            tg_token="$(grep '^ALERT_TELEGRAM_TOKEN=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
            tg_chat_id="$(grep '^ALERT_TELEGRAM_CHAT_ID=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")"
            if [[ -n "$tg_token" && -n "$tg_chat_id" ]]; then
                # Escape HTML special chars for Telegram parse_mode=HTML.
                # & must be escaped FIRST to avoid double-escaping.
                local tg_message="$message"
                tg_message="${tg_message//&/&amp;}"
                tg_message="${tg_message//</&lt;}"
                tg_message="${tg_message//>/&gt;}"
                curl -sf --max-time 10 -K - \
                    -d "chat_id=${tg_chat_id}" \
                    -d "text=${tg_message}" \
                    -d "parse_mode=HTML" \
                    >/dev/null 2>&1 <<CURL_CFG || true
url = "https://api.telegram.org/bot${tg_token}/sendMessage"
CURL_CFG
            fi
            ;;
    esac

    # Mark alert as sent for cooldown tracking
    touch "$cooldown_file" 2>/dev/null || true
}

# ============================================================================
# EXTENDED CHECKS (for report_health)
# ============================================================================

check_gpu_status() {
    echo -e "${BOLD}GPU Status:${NC}"
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,temperature.gpu,utilization.gpu \
            --format=csv,noheader 2>/dev/null | while IFS=',' read -r name mem_total mem_used mem_free temp util; do
            name="$(echo "$name" | xargs)"
            mem_total="$(echo "$mem_total" | xargs)"
            mem_used="$(echo "$mem_used" | xargs)"
            mem_free="$(echo "$mem_free" | xargs)"
            temp="$(echo "$temp" | xargs)"
            util="$(echo "$util" | xargs)"
            # Unified memory fallback: nvidia-smi returns [N/A] on DGX Spark
            local unified_label=""
            if [[ "$mem_total" == *"N/A"* || -z "$mem_total" ]]; then
                local meminfo_total meminfo_avail
                meminfo_total=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
                meminfo_avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
                mem_total="${meminfo_total} MiB"
                mem_used="$((meminfo_total - meminfo_avail)) MiB"
                mem_free="${meminfo_avail} MiB"
                unified_label=" (unified)"
            fi
            printf "  %-20s | Mem: %s / %s%s | Temp: %s | Load: %s\n" \
                "$name" "$mem_used" "$mem_total" "$unified_label" "$temp" "$util"
        done
    elif command -v rocm-smi &>/dev/null; then
        rocm-smi --showuse --showmemuse --showtemp 2>/dev/null | head -20
    else
        echo "  CPU mode (no GPU detected)"
    fi
    echo ""
}

check_ollama_models() {
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    echo -e "${BOLD}Ollama Models:${NC}"
    local response
    response="$(docker compose -f "$compose_file" exec -T ollama ollama list 2>/dev/null)" || {
        echo -e "  ${RED}Ollama API not available${NC}"
        echo ""
        return 1
    }

    if [[ -z "$response" ]] || ! echo "$response" | grep -q "NAME"; then
        echo "  (no models loaded)"
    else
        echo "$response" | tail -n +2 | while IFS= read -r line; do
            if [[ -n "$line" ]]; then echo "  $line"; fi
        done
    fi
    echo ""
}

check_vector_health() {
    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"
    local env_file="${INSTALL_DIR}/docker/.env"
    echo -e "${BOLD}Vector Store:${NC}"

    local vs="weaviate"
    if [[ -f "$env_file" ]]; then vs="$(grep '^VECTOR_STORE=' "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "weaviate")"; fi

    case "$vs" in
        weaviate)
            local meta
            meta="$(docker compose -f "$compose_file" exec -T weaviate curl -sf --max-time 5 http://localhost:8080/v1/meta 2>/dev/null)" || {
                echo -e "  ${RED}Weaviate: not available${NC}"
                echo ""
                return 1
            }
            local version
            version="$(echo "$meta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")"
            echo -e "  ${GREEN}Weaviate: v${version} — OK${NC}"
            ;;
        qdrant)
            if docker compose -f "$compose_file" exec -T qdrant curl -sf --max-time 5 http://localhost:6333/healthz >/dev/null 2>&1; then
                local collections
                collections="$(docker compose -f "$compose_file" exec -T qdrant curl -sf --max-time 5 http://localhost:6333/collections 2>/dev/null | \
                    python3 -c "import json,sys; colls=json.load(sys.stdin).get('result',{}).get('collections',[]); print(len(colls))" 2>/dev/null || echo "?")"
                echo -e "  ${GREEN}Qdrant: OK (${collections} collections)${NC}"
            else
                echo -e "  ${RED}Qdrant: not available${NC}"
            fi
            ;;
    esac
    echo ""
}

check_disk_usage() {
    echo -e "${BOLD}Disk Usage:${NC}"
    local docker_df
    docker_df="$(docker system df 2>/dev/null)" || {
        log_warn "docker system df not available"
        echo ""
        return 0
    }
    echo "$docker_df" | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""
    if [[ -d "${INSTALL_DIR}" ]]; then
        local dir_size
        dir_size="$(du -sh "${INSTALL_DIR}" 2>/dev/null | cut -f1 || echo "?")"
        echo "  Install dir (${INSTALL_DIR}): ${dir_size}"
    fi
    if [[ -d "/var/backups/agmind" ]]; then
        local backup_size
        backup_size="$(du -sh /var/backups/agmind 2>/dev/null | cut -f1 || echo "?")"
        echo "  Backups (/var/backups/agmind): ${backup_size}"
    fi
    echo ""
}

check_backup_status() {
    echo -e "${BOLD}Last Backup:${NC}"
    local backup_dir="/var/backups/agmind"

    if [[ ! -d "$backup_dir" ]]; then
        echo -e "  ${YELLOW}Backup directory not found${NC}"
        echo ""
        return 0
    fi

    local latest
    latest="$(ls -1d "${backup_dir}"/20* 2>/dev/null | sort -r | head -1)"
    if [[ -z "$latest" ]]; then
        echo -e "  ${YELLOW}No backups found${NC}"
        echo ""
        return 0
    fi

    local backup_date backup_size
    backup_date="$(basename "$latest")"
    backup_size="$(du -sh "$latest" 2>/dev/null | cut -f1 || echo "?")"

    local backup_ts now_ts age_hours
    backup_ts="$(date -d "${backup_date//_/ }" +%s 2>/dev/null || stat -f %m "$latest" 2>/dev/null || echo 0)"
    now_ts="$(date +%s)"
    if [[ "$backup_ts" -gt 0 ]]; then
        age_hours=$(( (now_ts - backup_ts) / 3600 ))
        if [[ $age_hours -lt 24 ]]; then
            echo -e "  ${GREEN}${backup_date} (${backup_size}, ${age_hours}h ago)${NC}"
        elif [[ $age_hours -lt 72 ]]; then
            echo -e "  ${YELLOW}${backup_date} (${backup_size}, ${age_hours}h ago)${NC}"
        else
            echo -e "  ${RED}${backup_date} (${backup_size}, ${age_hours}h ago — stale!)${NC}"
        fi
    else
        echo "  ${backup_date} (${backup_size})"
    fi

    if [[ -f "${latest}/sha256sums.txt" ]]; then
        echo -e "  ${GREEN}Checksums: present${NC}"
    fi
    echo ""
}

# ============================================================================
# FULL HEALTH REPORT
# ============================================================================

report_health() {
    echo ""
    echo -e "${BOLD}${CYAN}=========================================${NC}"
    echo -e "${BOLD}${CYAN}  AGMind Health Report${NC}"
    echo -e "${BOLD}${CYAN}=========================================${NC}"
    echo ""

    check_all || true
    echo ""
    check_gpu_status
    check_ollama_models || true
    check_vector_health || true
    check_disk_usage
    check_backup_status
}

# ============================================================================
# STANDALONE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=common.sh
    source "${SCRIPT_DIR}/common.sh"

    INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

    case "${1:-}" in
        --send-test)
            log_info "Sending test alert..."
            send_alert "Test alert AGMind — system operating normally"
            log_success "Test sent!"
            ;;
        --full)
            report_health
            ;;
        *)
            check_all
            ;;
    esac
fi
