#!/usr/bin/env bash
# ============================================================================
# AGMind Installer v3.0
# Full RAG stack: Dify + Open WebUI + Ollama/vLLM + Weaviate/Qdrant
# Usage: sudo bash install.sh [--non-interactive] [--force-restart]
# ============================================================================
set -euo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

VERSION="3.0.0"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/agmind"
TEMPLATE_DIR="${INSTALLER_DIR}/templates"

# Verify running from project directory
if [[ ! -f "${INSTALLER_DIR}/lib/common.sh" ]]; then
    echo "Error: run from project directory: sudo bash install.sh" >&2; exit 1
fi

# --- Source library modules ---
source "${INSTALLER_DIR}/lib/common.sh"
source "${INSTALLER_DIR}/lib/detect.sh"
# shellcheck source=lib/cluster_mode.sh
source "${INSTALLER_DIR}/lib/cluster_mode.sh"
# shellcheck source=lib/ssh_trust.sh
source "${INSTALLER_DIR}/lib/ssh_trust.sh"
source "${INSTALLER_DIR}/lib/tui.sh"
source "${INSTALLER_DIR}/lib/wizard.sh"
source "${INSTALLER_DIR}/lib/docker.sh"
source "${INSTALLER_DIR}/lib/config.sh"
source "${INSTALLER_DIR}/lib/compose.sh"
source "${INSTALLER_DIR}/lib/health.sh"
source "${INSTALLER_DIR}/lib/models.sh"
source "${INSTALLER_DIR}/lib/backup.sh"
source "${INSTALLER_DIR}/lib/security.sh"
source "${INSTALLER_DIR}/lib/authelia.sh"
source "${INSTALLER_DIR}/lib/tunnel.sh"
source "${INSTALLER_DIR}/lib/openwebui.sh"

# --- Global defaults ---
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
FORCE_RESTART="${FORCE_RESTART:-false}"
TIMEOUT_START="${TIMEOUT_START:-300}"
TIMEOUT_HEALTH="${TIMEOUT_HEALTH:-300}"
TIMEOUT_GPU_HEALTH="${TIMEOUT_GPU_HEALTH:-0}"  # no limit — GPU models can take 30+ min to download
TIMEOUT_MODELS="${TIMEOUT_MODELS:-1200}"
VDS_MODE="${VDS_MODE:-false}"

# --- Exclusive lock ---
_acquire_lock() {
    if [[ "$(uname)" == "Darwin" ]]; then
        LOCK_DIR="/tmp/agmind-install.lock"
        mkdir "$LOCK_DIR" 2>/dev/null || { echo "Another install is running" >&2; exit 1; }
        trap 'rmdir "$LOCK_DIR" 2>/dev/null; _cleanup_on_failure' EXIT
    else
        local lock="/var/lock/agmind-install.lock"
        if [[ -L "$lock" ]]; then echo "Lock is a symlink, aborting" >&2; exit 1; fi
        exec 9>"$lock"
        flock -n 9 || { log_error "Another install is running"; exit 1; }
        trap _cleanup_on_failure EXIT
    fi
}

_cleanup_on_failure() {
    local rc=$?
    if [[ $rc -eq 0 ]]; then return; fi
    echo ""
    log_error "Installation aborted (code: ${rc})."
    if [[ -f "${INSTALL_DIR}/.install_phase" ]]; then
        local p; p="$(cat "${INSTALL_DIR}/.install_phase" 2>/dev/null)"
        log_warn "Failed at phase ${p}/9. Re-run: sudo bash install.sh"
    fi
}

# --- Banner ---
show_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "    _    ____ __  __ _           _ "
    echo "   / \\  / ___|  \\/  (_)_ __   __| |"
    echo "  / _ \\| |  _| |\\/| | | '_ \\ / _\` |"
    echo " / ___ \\ |_| | |  | | | | | | (_| |"
    echo "/_/   \\_\\____|_|  |_|_|_| |_|\\__,_|"
    echo ""
    echo -e "${NC}${BOLD}  RAG Stack Installer v${VERSION}${NC}"
    echo ""
}

# --- Phase runners ---
run_phase() {
    local num="$1" total="$2" name="$3" func="$4"
    echo "$num" > "${INSTALL_DIR}/.install_phase"
    echo -e "\n${BOLD}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} ===${NC}"
    "$func"
    echo -e "${GREEN}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} DONE ===${NC}"
}

run_phase_with_timeout() {
    local num="$1" total="$2" name="$3" func="$4" timeout="$5"
    echo "$num" > "${INSTALL_DIR}/.install_phase"
    echo -e "\n${BOLD}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} (timeout: ${timeout}s) ===${NC}"
    local rc=0
    _run_with_timeout "$func" "$timeout" || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} DONE ===${NC}"
        return 0
    fi
    if [[ $rc -eq 124 ]]; then
        # Pull is idempotent — retry directly, no compose down
        local retry=$((timeout * 2))
        log_warn "Phase ${name} timed out after ${timeout}s. Retrying (${retry}s)..."
        rc=0
        _run_with_timeout "$func" "$retry" || rc=$?
        if [[ $rc -eq 0 ]]; then
            echo -e "${GREEN}[$(date +%H:%M:%S)] === PHASE ${num}/${total}: ${name} DONE (retry) ===${NC}"
            return 0
        fi
        if [[ $rc -eq 124 ]]; then
            log_warn "Phase ${name} timed out after ${retry}s"
            if [[ "$name" == "Models" ]]; then
                log_warn "Model download timed out. Containers continue downloading in background."
                local llm_provider="${LLM_PROVIDER:-ollama}"
                local embed_provider="${EMBED_PROVIDER:-ollama}"
                if [[ "$llm_provider" == "ollama" ]]; then
                    log_warn "Retry: docker exec agmind-ollama ollama pull ${LLM_MODEL:-qwen2.5:14b}"
                elif [[ "$llm_provider" == "vllm" ]]; then
                    log_warn "Monitor: docker logs -f agmind-vllm"
                fi
                if [[ "$embed_provider" == "tei" ]]; then
                    log_warn "Monitor: docker logs -f agmind-tei"
                elif [[ "$embed_provider" == "ollama" ]]; then
                    log_warn "Retry: docker exec agmind-ollama ollama pull ${EMBEDDING_MODEL:-bge-m3}"
                fi
                log_warn "Installation continues..."
                return 0
            fi
            log_error "Phase ${name} timed out after ${retry}s"
            return 1
        fi
    fi
    log_error "Phase ${name} failed (code: ${rc})"
    return "$rc"
}

_run_with_timeout() {
    local func="$1" secs="$2"
    "$func" & local pid=$! elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
        if [[ $elapsed -ge $secs ]]; then kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true; return 124; fi
        sleep 1; elapsed=$((elapsed + 1))
    done
    wait "$pid"
}

# --- Phase functions (thin wrappers) ---
phase_diagnostics() {
    run_diagnostics || _confirm_continue "System below minimum requirements"
    # MDNS-02: HARD abort exit 1 on foreign :5353 responder — never silent continue,
    # even in NON_INTERACTIVE mode. Broken mDNS is a silent deploy disaster (CLAUDE.md §8).
    # _assert_no_foreign_mdns is defined in lib/detect.sh (sourced above).
    if ! _assert_no_foreign_mdns; then
        log_error "Refusing to continue: foreign mDNS responder on UDP/5353 will break agmind-*.local"
        log_error "Follow the instructions above, then re-run: sudo bash install.sh"
        exit 1
    fi
    preflight_checks || _confirm_continue "Pre-flight errors found"
    # PEER-02, PEER-01: ensure lldpd running (QSFP neighbour table), then detect peer.
    # Never fails install — soft detection; sets PEER_HOSTNAME/PEER_IP/PEER_USER for wizard.
    # DETECTED_NETWORK env (set by preflight_checks) gates apt-install path in _ensure_lldpd.
    _ensure_lldpd
    hw_detect_peer
}
phase_wizard()      { run_wizard; }
phase_docker()      { setup_docker; }
phase_config()      { ensure_bind_mount_files; export INSTALL_DIR; generate_config "$DEPLOY_PROFILE" "$TEMPLATE_DIR"; enable_gpu_compose; setup_security; if [[ "$ENABLE_AUTHELIA" == "true" ]]; then configure_authelia "$TEMPLATE_DIR"; fi; _copy_runtime_files; }
phase_pull()        { compose_pull; }
phase_start()       { compose_start; create_openwebui_admin; }
phase_health()      { wait_healthy "$TIMEOUT_HEALTH" "$TIMEOUT_GPU_HEALTH"; _obtain_letsencrypt_cert; }
phase_models()      { download_models; }
phase_models_graceful() {
    local rc=0
    phase_models || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo ""
        log_warn "Models were not fully downloaded."
        log_warn "Containers continue downloading in background."
        echo ""
        local llm_provider="${LLM_PROVIDER:-ollama}"
        local embed_provider="${EMBED_PROVIDER:-ollama}"
        local llm_model="${LLM_MODEL:-qwen2.5:14b}"
        local embedding_model="${EMBEDDING_MODEL:-bge-m3}"
        if [[ "$llm_provider" == "ollama" ]]; then
            log_warn "Retry Ollama LLM:       docker exec agmind-ollama ollama pull ${llm_model}"
        elif [[ "$llm_provider" == "vllm" ]]; then
            log_warn "Monitor vLLM progress:  docker logs -f agmind-vllm"
        fi
        if [[ "$embed_provider" == "ollama" ]]; then
            log_warn "Retry Ollama Embedding: docker exec agmind-ollama ollama pull ${embedding_model}"
        elif [[ "$embed_provider" == "tei" ]]; then
            log_warn "Monitor TEI progress:   docker logs -f agmind-tei"
        fi
        echo ""
        log_warn "Installation continues..."
        return 0  # Do NOT propagate error — installation continues
    fi
}
phase_backups()     { setup_backups; setup_tunnel; }
phase_complete()    { create_openwebui_admin; _init_minio_bucket; _ensure_api_responsive; _init_dify_admin; _sync_grafana_admin_password; _ensure_docling_ocr_models; _save_credentials; _install_cli; _install_crons; _install_systemd_service; verify_services || true; _verify_post_install_smoke; _show_final_summary; _apply_dify_patches; }

# ============================================================================
# PEER DEPLOY (Plan 02-04, PEER-05)
# ============================================================================

# Generates minimal .env content for worker peer.
# Echoes to stdout — caller redirects to file before scp.
_render_worker_env() {
    cat <<EOF
# AGmind Worker .env — generated by master install.sh
# vLLM
VLLM_IMAGE=${VLLM_IMAGE:-${VLLM_SPARK_IMAGE:-vllm/vllm-openai:gemma4-cu130}}
VLLM_SPARK_IMAGE=${VLLM_SPARK_IMAGE:-vllm/vllm-openai:gemma4-cu130}
VLLM_MODEL=${VLLM_MODEL:-${VLLM_SPARK_MODEL:-google/gemma-4-26B-A4B-it}}
VLLM_SPARK_MODEL=${VLLM_SPARK_MODEL:-google/gemma-4-26B-A4B-it}
VLLM_CMD_PREFIX=${VLLM_CMD_PREFIX:-}
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:---kv-cache-dtype fp8 --enable-prefix-caching --enforce-eager}"
VLLM_CUDA_SUFFIX=${VLLM_CUDA_SUFFIX:-}
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-65536}
# Peer = dedicated under vLLM (no docling/embed/rerank sharing GPU).
# Override master's shared-budget defaults with peer-dedicated values:
# - 0.85 util × 121 GiB unified = 103 GiB vLLM, 18 GiB OS headroom
# - CLAUDE.md §8: 0.90 too tight for OS+Docker+ssh+avahi baseline.
VLLM_GPU_MEM_UTIL=${AGMIND_PEER_VLLM_GPU_MEM_UTIL:-0.85}
VLLM_MEM_LIMIT=${AGMIND_PEER_VLLM_MEM_LIMIT:-110g}
VLLM_CUDA_DEVICE=${VLLM_CUDA_DEVICE:-0}
HF_TOKEN=${HF_TOKEN:-}
# NVIDIA — CLAUDE.md §8 compute,utility required for NVML/libcuda
NVIDIA_DRIVER_CAPABILITIES=compute,utility
NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-all}
# Prometheus peer scrape target (Plan 02-05)
NODE_EXPORTER_VERSION=${NODE_EXPORTER_VERSION:-v1.11.1}
EOF
}

# Transfer a docker image from master to peer via SSH pipe.
# Uses docker save | ssh docker load. Skips if already present on peer.
_deploy_image_to_peer() {
    local image="${1:?image required}"
    local peer_ip="${2:?peer_ip required}"
    local peer_user="${3:-${AGMIND_PEER_USER:-agmind2}}"
    # shellcheck disable=SC2086  # intentional word splitting for ssh opts
    local ssh_opts
    ssh_opts="$(_agmind_peer_ssh_opts)"

    # Peer user NOT in docker group → all docker commands на peer use `sudo -n docker`.
    # NOPASSWD sudo pre-configured on DGX Spark peer (see project_spark_cluster memory).

    # 1. If peer already has image locally — skip (idempotent).
    # shellcheck disable=SC2086
    if ssh $ssh_opts "${peer_user}@${peer_ip}" \
            "sudo -n docker image inspect ${image} >/dev/null 2>&1"; then
        log_info "Image ${image} already present on peer — skipping transfer"
        return 0
    fi

    # 2. Prefer peer-side direct pull (saves 10+ GB SSH transfer if peer has WAN).
    log_info "Attempting peer-side pull of ${image} (peer has WAN via wifi)..."
    # shellcheck disable=SC2086
    if ssh $ssh_opts "${peer_user}@${peer_ip}" \
            "sudo -n docker pull ${image}" 2>&1 | tail -5; then
        # shellcheck disable=SC2086
        if ssh $ssh_opts "${peer_user}@${peer_ip}" \
                "sudo -n docker image inspect ${image} >/dev/null 2>&1"; then
            log_success "Peer pulled ${image} directly"
            return 0
        fi
    fi
    log_warn "Peer-side pull failed — falling back to master save|load transfer"

    # 3. Fallback: master must have image locally to save. Pull if absent.
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
        log_info "Pulling ${image} on master for transfer..."
        if ! docker pull "${image}"; then
            log_error "Master pull of ${image} failed — cannot transfer to peer"
            return 1
        fi
    fi

    log_info "Transferring image ${image} master→peer via SSH save|load (may take 5-10 min)..."
    # shellcheck disable=SC2086
    if ! docker save "${image}" | ssh $ssh_opts "${peer_user}@${peer_ip}" "sudo -n docker load" >/dev/null 2>&1; then
        log_error "Image transfer to peer failed"
        return 1
    fi
    log_success "Image ${image} loaded on peer"
}

# Wait for vLLM on peer to respond /v1/models with 200.
# Timeout 30 min (cold gemma-4-26B download may take 15+ min).
_wait_peer_vllm_ready() {
    local peer_ip="${1:?peer_ip required}"
    local timeout="${2:-5400}"
    local start elapsed
    start="$(date +%s)"
    log_info "Waiting for vLLM on peer ${peer_ip}:8000 (timeout: ${timeout}s)..."
    while true; do
        if curl -sSf --max-time 5 "http://${peer_ip}:8000/v1/models" >/dev/null 2>&1; then
            local model
            model="$(curl -sSf --max-time 5 "http://${peer_ip}:8000/v1/models" 2>/dev/null \
                | jq -r '.data[0].id // "unknown"' 2>/dev/null || echo "unknown")"
            log_success "vLLM on peer ready (model: ${model})"
            return 0
        fi
        elapsed=$(( $(date +%s) - start ))
        if [[ $elapsed -ge $timeout ]]; then
            log_error "vLLM on peer did not become ready within ${timeout}s"
            log_error "  Diagnose: ssh ${AGMIND_PEER_USER:-agmind2}@${peer_ip} docker logs agmind-vllm --tail 50"
            return 1
        fi
        log_info "  ...waiting (${elapsed}s elapsed)"
        [[ $elapsed -lt 300 ]] && sleep 5 || sleep 15
    done
}

# Main deploy orchestrator — runs only if AGMIND_MODE=master.
phase_deploy_peer() {
    # Read mode from wizard export or fallback to cluster.json.
    local mode="${AGMIND_MODE:-$(cluster_mode_read 2>/dev/null || echo single)}"
    if [[ "$mode" != "master" ]]; then
        log_info "Cluster mode=${mode:-single} — skipping peer deploy"
        return 0
    fi

    local peer_ip="${PEER_IP:-}"
    local peer_user="${PEER_USER:-${AGMIND_PEER_USER:-agmind2}}"
    if [[ -z "$peer_ip" ]]; then
        # Fallback: read from cluster.json
        if command -v jq >/dev/null 2>&1 && [[ -f "${AGMIND_CLUSTER_STATE_FILE:-/var/lib/agmind/state/cluster.json}" ]]; then
            peer_ip="$(jq -r '.peer_ip // empty' "${AGMIND_CLUSTER_STATE_FILE:-/var/lib/agmind/state/cluster.json}" 2>/dev/null || true)"
        fi
    fi
    if [[ -z "$peer_ip" ]]; then
        log_error "PEER_IP unavailable (not detected by hw_detect_peer, not in cluster.json) — cannot deploy"
        log_error "Fix: re-run install.sh with working QSFP link to peer, or AGMIND_MODE_OVERRIDE=single"
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    fi

    log_info "Deploying vLLM to peer ${peer_user}@${peer_ip}..."

    # 1. SSH trust
    _ensure_ssh_trust "$peer_ip" "$peer_user" || {
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    }
    # shellcheck disable=SC2086
    local ssh_opts
    ssh_opts="$(_agmind_peer_ssh_opts)"
    local peer_dir="/opt/agmind/docker"

    # 2. Ensure peer /opt/agmind/docker exists and is writable by peer_user
    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" \
        "sudo mkdir -p ${peer_dir} && sudo chown -R ${peer_user}: /opt/agmind" \
        2>/dev/null || log_warn "sudo chown may have failed on peer — proceeding"

    # 3. Idempotency: if vllm already running with same image → skip deploy
    local target_image="${VLLM_IMAGE:-${VLLM_SPARK_IMAGE:-vllm/vllm-openai:gemma4-cu130}}"
    local current_image
    # shellcheck disable=SC2086
    current_image="$(ssh $ssh_opts "${peer_user}@${peer_ip}" \
        "sudo -n docker ps --filter 'name=agmind-vllm' --format '{{.Image}}' 2>/dev/null | head -1" 2>/dev/null || true)"
    if [[ -n "$current_image" && "$current_image" == "$target_image" ]]; then
        log_info "vLLM already running on peer with image ${current_image} — checking health"
        if _wait_peer_vllm_ready "$peer_ip" 60; then
            cluster_status_update "running" 2>/dev/null || true
            log_success "Peer vLLM idempotent — deploy skipped"
            return 0
        fi
        log_warn "Peer vLLM running but unhealthy — proceeding with redeploy"
    fi

    # 4. Image transfer (air-gap safe — docker save|load; skip if already present)
    _deploy_image_to_peer "$target_image" "$peer_ip" "$peer_user" || {
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    }

    # 5. Copy worker compose + .env to peer
    local template_worker="${TEMPLATE_DIR:-${INSTALLER_DIR}/templates}/docker-compose.worker.yml"
    local master_worker_local="${INSTALL_DIR:-/opt/agmind}/docker/docker-compose.worker.yml"
    local master_worker_env_local="${INSTALL_DIR:-/opt/agmind}/docker/.env.worker"
    mkdir -p "$(dirname "$master_worker_local")"
    cp "$template_worker" "$master_worker_local"
    _render_worker_env > "$master_worker_env_local"
    chmod 0600 "$master_worker_env_local"

    # shellcheck disable=SC2086
    scp $ssh_opts "$master_worker_local" \
        "${peer_user}@${peer_ip}:${peer_dir}/docker-compose.worker.yml" >/dev/null 2>&1 || {
        log_error "scp worker compose failed"
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    }
    # shellcheck disable=SC2086
    scp $ssh_opts "$master_worker_env_local" \
        "${peer_user}@${peer_ip}:${peer_dir}/.env" >/dev/null 2>&1 || {
        log_error "scp worker .env failed"
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    }

    # 6. Install gpu-metrics.sh on peer + cron + textfile dir.
    # Feeds peer node-exporter textfile collector (enabled via compose volume +
    # --collector.textfile.directory=/textfile) so agmind_gpu_* HW metrics become
    # visible to Prometheus peer-node-exporter scrape, powering Grafana
    # "AGMind GPU — worker" dashboard (gauges temp/util/power/clock).
    _deploy_peer_gpu_metrics "$peer_ip" "$peer_user" "$ssh_opts" "$peer_dir" \
        || log_warn "Peer GPU metrics setup had issues (non-fatal — dashboard HW panels may stay empty)"

    # 7. docker compose up on peer
    # NOTE: CLAUDE.md §8 "force-recreate trap" applies to master stack (Redis/Celery state).
    # Worker compose = vllm + node-exporter only. No Redis, no Celery → no stale state.
    # Use `compose up -d` (not --force-recreate): respects existing containers.
    # shellcheck disable=SC2086
    if ! ssh $ssh_opts "${peer_user}@${peer_ip}" \
            "cd ${peer_dir} && sudo -n docker compose -f docker-compose.worker.yml up -d" >/dev/null 2>&1; then
        log_error "docker compose up on peer failed"
        log_error "  Diagnose: ssh ${peer_user}@${peer_ip} 'cd ${peer_dir} && sudo -n docker compose -f docker-compose.worker.yml logs'"
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    fi

    # 8. Wait for vllm healthy
    if ! _wait_peer_vllm_ready "$peer_ip" 5400; then
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    fi

    # 9. Install systemd unit on peer so `docker compose up -d` runs after reboot.
    # Without this, peer relies solely on restart=unless-stopped, with no
    # application-level safety net if docker daemon is restarted manually.
    _deploy_peer_systemd "$peer_ip" "$peer_user" "$ssh_opts" "$peer_dir" \
        || log_warn "Peer systemd unit install had issues (non-fatal — vLLM restart policy still covers reboot)"

    # 10. Persist success
    cluster_status_update "running" 2>/dev/null || true
    log_success "vLLM deployed and healthy on peer ${peer_ip}"
}

# Install gpu-metrics.sh + cron on peer host so node-exporter textfile collector
# exposes agmind_gpu_temperature_celsius / utilization_percent / power_watts /
# clock_mhz / memory_* for peer-node-exporter scrape. Idempotent.
_deploy_peer_gpu_metrics() {
    local peer_ip="$1" peer_user="$2" ssh_opts="$3" peer_dir="$4"
    local script_src="${INSTALLER_DIR:-/opt/agmind}/scripts/gpu-metrics.sh"
    [[ -f "$script_src" ]] || script_src="${INSTALL_DIR:-/opt/agmind}/scripts/gpu-metrics.sh"
    if [[ ! -f "$script_src" ]]; then
        log_warn "gpu-metrics.sh not found at ${script_src} — skipping peer GPU textfile setup"
        return 1
    fi
    local peer_script="/opt/agmind/scripts/gpu-metrics.sh"
    local peer_textfile="${peer_dir}/monitoring/textfile"

    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" \
        "sudo -n mkdir -p /opt/agmind/scripts ${peer_textfile} && sudo -n chown ${peer_user}: /opt/agmind/scripts ${peer_textfile}" \
        >/dev/null 2>&1 || { log_warn "peer mkdir scripts/textfile failed"; return 1; }

    # shellcheck disable=SC2086
    scp $ssh_opts "$script_src" "${peer_user}@${peer_ip}:${peer_script}" >/dev/null 2>&1 \
        || { log_warn "scp gpu-metrics.sh to peer failed"; return 1; }

    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" "sudo -n chmod +x ${peer_script}" >/dev/null 2>&1 || true

    # Seed textfile so first scrape has data
    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" "sudo -n ${peer_script} ${peer_textfile}" >/dev/null 2>&1 || true

    # Install cron (4 ticks/min = 15s resolution, mirrors master _install_crons).
    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" "sudo -n tee /etc/cron.d/agmind-gpu-metrics >/dev/null <<CRON
* * * * * root ${peer_script} ${peer_textfile} >/dev/null 2>&1
* * * * * root sleep 15 && ${peer_script} ${peer_textfile} >/dev/null 2>&1
* * * * * root sleep 30 && ${peer_script} ${peer_textfile} >/dev/null 2>&1
* * * * * root sleep 45 && ${peer_script} ${peer_textfile} >/dev/null 2>&1
CRON
sudo -n chmod 644 /etc/cron.d/agmind-gpu-metrics" >/dev/null 2>&1 || {
        log_warn "peer cron install failed"
        return 1
    }

    log_info "Peer GPU metrics cron installed (15s interval, textfile ${peer_textfile})"
    return 0
}

# Install agmind-stack.service on peer — ensures `docker compose up -d` runs
# after peer reboot, matching master's auto-start pattern. Idempotent:
# subsequent runs overwrite unit file (safe — same content) + daemon-reload.
_deploy_peer_systemd() {
    local peer_ip="$1" peer_user="$2" ssh_opts="$3" peer_dir="$4"
    local unit_src="${TEMPLATE_DIR:-${INSTALLER_DIR}/templates}/agmind-stack-worker.service.template"
    if [[ ! -f "$unit_src" ]]; then
        log_warn "agmind-stack-worker.service.template not found — peer auto-start skipped"
        return 1
    fi

    # Render template — substitute __INSTALL_DIR__ with peer's install dir.
    local unit_tmp="${INSTALL_DIR:-/opt/agmind}/docker/agmind-stack.service.worker"
    sed "s|__INSTALL_DIR__|/opt/agmind|g" "$unit_src" > "$unit_tmp" || {
        log_warn "render worker systemd unit failed"
        return 1
    }
    chmod 0644 "$unit_tmp"

    # shellcheck disable=SC2086
    scp $ssh_opts "$unit_tmp" "${peer_user}@${peer_ip}:/tmp/agmind-stack.service" >/dev/null 2>&1 \
        || { log_warn "scp worker systemd unit to peer failed"; return 1; }

    # Install + enable (no start: compose up -d already ran in step 7 above,
    # service will reach active state on next reboot).
    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" \
        "sudo -n mv /tmp/agmind-stack.service /etc/systemd/system/agmind-stack.service \
            && sudo -n chmod 644 /etc/systemd/system/agmind-stack.service \
            && sudo -n systemctl daemon-reload \
            && sudo -n systemctl enable agmind-stack.service" >/dev/null 2>&1 || {
        log_warn "peer systemd enable failed"
        return 1
    }

    log_info "Peer systemd unit installed + enabled (agmind-stack.service)"
    return 0
}

_apply_dify_patches() {
    [[ "${ENABLE_DIFY_PREMIUM:-false}" == "true" ]] || return 0
    log_info "Applying Dify premium features patch..."
    bash "${INSTALLER_DIR}/scripts/patch_dify_features.sh" \
        "${COMPOSE_PROJECT_NAME:-agmind}-api" \
        "$INSTALL_DIR" || log_warn "Dify premium patch had warnings (non-fatal)"
}

_confirm_continue() {
    if [[ "$NON_INTERACTIVE" == "true" ]]; then log_warn "Non-interactive: continuing despite: $1"; return 0; fi
    read -rp "$1. Continue? (yes/no): " r; [[ "$r" == "yes" ]] || exit 1
}

_check_critical_services() {
    local svc failed=0
    for svc in db redis api worker web nginx; do
        local st; st="$(docker ps --filter "name=agmind-${svc}" --format "{{.Status}}" 2>/dev/null | head -1)"
        if echo "$st" | grep -qi "unhealthy\|restarting\|exited"; then
            log_error "Critical service ${svc}: ${st}"; docker logs --tail 5 "agmind-${svc}" 2>&1 | sed 's/^/    /'; failed=$((failed+1))
        fi
    done
    # GPU compatibility hint for vLLM (warning only — not critical)
    # AGMIND_MODE=master → vllm runs on peer, no local container to check.
    if [[ "${LLM_PROVIDER:-}" == "vllm" && "${AGMIND_MODE:-single}" != "master" ]]; then
        local vllm_st; vllm_st="$(docker ps --filter "name=agmind-vllm" --format "{{.Status}}" 2>/dev/null | head -1)"
        if echo "$vllm_st" | grep -qi "exited\|restarting"; then
            log_warn "vLLM не запустился: ${vllm_st}"
            if docker logs --tail 20 agmind-vllm 2>&1 | grep -qi "no kernel image"; then
                log_warn "GPU compute capability не поддерживается данной сборкой vLLM."
                log_warn "Решение: переустановите с VLLM_CUDA_SUFFIX=-cu130 или переключитесь на Ollama."
            elif docker logs --tail 20 agmind-vllm 2>&1 | grep -qi "out of memory\|OOM\|CUDA.*memory"; then
                log_warn "Недостаточно VRAM для выбранной модели."
                if [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then
                    log_warn "TEI занимает ~1.5-2 GB VRAM на той же GPU."
                fi
                log_warn "Решение: выберите AWQ-квантизированную модель (например Qwen/Qwen2.5-7B-Instruct-AWQ)."
            fi
        fi
    fi
    # TEI hint (warning only — not critical)
    if [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then
        local tei_st; tei_st="$(docker ps --filter "name=agmind-tei" --format "{{.Status}}" 2>/dev/null | head -1)"
        if echo "$tei_st" | grep -qi "exited\|restarting"; then
            log_warn "TEI не запустился: ${tei_st}"
            docker logs --tail 5 agmind-tei 2>&1 | sed 's/^/    /' || true
        fi
    fi
    if [[ $failed -gt 0 ]]; then
        log_error "${failed} critical service(s) failed"
        return 1
    fi
}

_copy_runtime_files() {
    # When installer runs from INSTALL_DIR (git clone /opt/agmind), skip script
    # self-copy but still populate scripts/{health,detect}.sh from lib/ subdir.
    # Glob-copy — no whitelist. Whitelist protukaet every time a new script is
    # added; classes of regression include docling-bench.sh, loadtest/ etc.
    if [[ "$INSTALLER_DIR" != "$INSTALL_DIR" ]]; then
        cp "${INSTALLER_DIR}/scripts/"*.sh "${INSTALL_DIR}/scripts/" 2>/dev/null || true
        # Subdirectories — explicit list (directories are less common additions)
        local script_subdirs=(loadtest)
        for d in "${script_subdirs[@]}"; do
            if [[ -d "${INSTALLER_DIR}/scripts/${d}" ]]; then
                mkdir -p "${INSTALL_DIR}/scripts/${d}"
                cp -r "${INSTALLER_DIR}/scripts/${d}/." "${INSTALL_DIR}/scripts/${d}/"
            fi
        done
    fi
    # lib/ → scripts/ copy: different subdirs, always safe even in self-install
    cp "${INSTALLER_DIR}/lib/health.sh" "${INSTALL_DIR}/scripts/health.sh" 2>/dev/null || true
    cp "${INSTALLER_DIR}/lib/detect.sh" "${INSTALL_DIR}/scripts/detect.sh" 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
}

# Cleans stale Redis state left by prior force-recreate of api/worker.
# Celery hostnames change on recreate, but generate_task_belong:* (DB 0) and
# celery-task-meta-* (DB 1) still reference the dead hostname — workers pub/sub
# on wrong channels → new tasks hang. See CLAUDE.md §8 "force-recreate trap".
# Safe to run anytime: DEL by pattern, no FLUSHDB (Redis ACL blocks it anyway).
_clean_stale_celery_state() {
    local pw
    pw="$(grep '^REDIS_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2-)"
    [[ -z "$pw" ]] && return 0
    docker ps --filter 'name=agmind-redis' --filter 'status=running' --format '{{.Names}}' \
        | grep -q agmind-redis || return 0
    docker exec agmind-redis sh -c "redis-cli -a '$pw' --no-auth-warning -n 0 --scan --pattern 'generate_task_belong:*' | xargs -r redis-cli -a '$pw' --no-auth-warning -n 0 DEL >/dev/null" 2>/dev/null || true
    docker exec agmind-redis sh -c "redis-cli -a '$pw' --no-auth-warning -n 1 --scan --pattern 'celery-task-meta-*' | xargs -r redis-cli -a '$pw' --no-auth-warning -n 1 DEL >/dev/null" 2>/dev/null || true
}

# Verifies Dify API is truly responsive, not just gunicorn-listening.
# Gunicorn can accept TCP but gevent worker can deadlock during cold boot
# (lazy imports + migrations + aws_s3 init). /health answers fast, but real
# endpoints like /console/api/setup hang for 60+ sec.
# If deadlock detected → clean stale state → docker restart (NOT recreate).
_ensure_api_responsive() {
    if ! docker ps --filter 'name=agmind-api' --filter 'status=running' --format '{{.Names}}' | grep -q agmind-api; then
        return 0
    fi
    log_info "Verifying Dify API is responsive (deep check: /console/api/setup)..."
    local attempts=0 max_attempts=24  # 24 × 5s = 2 min
    while [[ $attempts -lt $max_attempts ]]; do
        if docker exec agmind-api sh -c 'curl -sf --max-time 5 http://localhost:5001/console/api/setup -o /dev/null' 2>/dev/null; then
            log_success "Dify API responsive"
            return 0
        fi
        sleep 5
        attempts=$((attempts + 1))
    done

    log_warn "Dify API deadlock detected (gunicorn listening but endpoints hang)"
    log_warn "  Applying CLAUDE.md §8 force-recreate recovery: clean Redis + restart"
    _clean_stale_celery_state
    docker restart agmind-api agmind-worker >/dev/null 2>&1 || true

    attempts=0
    while [[ $attempts -lt $max_attempts ]]; do
        if docker exec agmind-api sh -c 'curl -sf --max-time 5 http://localhost:5001/console/api/setup -o /dev/null' 2>/dev/null; then
            log_success "Dify API recovered after restart"
            return 0
        fi
        sleep 5
        attempts=$((attempts + 1))
    done
    log_warn "Dify API still unresponsive after restart — _init_dify_admin may skip"
    return 0
}

_init_dify_admin() {
    # Skip if already initialized
    if [[ -f "${INSTALL_DIR}/.dify_initialized" ]]; then log_info "Dify already initialized"; return 0; fi

    local env_file="${INSTALL_DIR}/docker/.env"
    local init_password
    init_password="$(grep '^INIT_PASSWORD=' "$env_file" 2>/dev/null | cut -d'=' -f2-)"
    if [[ -z "$init_password" ]]; then return 0; fi

    local admin_password
    admin_password="$(echo "$init_password" | base64 -d 2>/dev/null || echo "$init_password")"

    # Wait for Dify API health only (don't check init endpoint — its codes vary by version)
    local attempts=0 max_attempts=120  # 120 × 5s = 10 min
    while [[ $attempts -lt $max_attempts ]]; do
        if docker exec agmind-api curl -sf http://localhost:5001/health >/dev/null 2>&1; then
            break
        fi
        sleep 5
        attempts=$((attempts + 1))
    done
    if [[ $attempts -ge $max_attempts ]]; then
        log_warn "[dify-init] Dify API not ready after 10 min, skipping auto-init"
        log_warn "[dify-init] Run 'agmind init-dify' manually after API is healthy"
        return 0
    fi
    # Extra settle time — API may accept /health before init endpoints are ready
    sleep 5

    log_info "[dify-init] Initializing Dify admin (two-step: init → setup)..."

    # Two-step init: POST /console/api/init → check → POST /console/api/setup
    # Step 1 returns a session cookie required by step 2
    local try
    for try in 1 2 3; do
        local resp
        resp="$(docker exec \
            -e "INIT_PWD=${init_password}" \
            -e "ADMIN_PWD=${admin_password}" \
            agmind-api sh -c '
                # Step 1: init — get session cookie
                init_code=$(curl -s -o /tmp/dify_init_resp -w "%{http_code}" \
                    -c /tmp/dify_cookies \
                    -H "Content-Type: application/json" \
                    -d "{\"password\":\"$INIT_PWD\"}" \
                    http://localhost:5001/console/api/init)
                init_body=$(cat /tmp/dify_init_resp 2>/dev/null)

                # If init says already setup — we are done
                if echo "$init_body" | grep -qi "already"; then
                    echo "ALREADY_INIT"
                    rm -f /tmp/dify_cookies /tmp/dify_init_resp
                    exit 0
                fi

                # If init failed (non-2xx) — report and bail
                case "$init_code" in
                    2*) ;;  # 2xx — success, continue to setup
                    *)  echo "INIT_FAIL:${init_code}:${init_body}"
                        rm -f /tmp/dify_cookies /tmp/dify_init_resp
                        exit 0 ;;
                esac

                # Step 2: setup — create admin account using session cookie
                setup_resp=$(curl -s -w "\nHTTP_%{http_code}" \
                    -b /tmp/dify_cookies \
                    -H "Content-Type: application/json" \
                    -d "{\"email\":\"admin@agmind.ai\",\"name\":\"AGMind Admin\",\"password\":\"$ADMIN_PWD\"}" \
                    http://localhost:5001/console/api/setup)
                echo "$setup_resp"
                rm -f /tmp/dify_cookies /tmp/dify_init_resp
            ' 2>&1)" || true

        # Check result
        if echo "$resp" | grep -qi "ALREADY_INIT\|already.*setup\|already.*initialized"; then
            log_info "[dify-init] Dify already initialized"
            touch "${INSTALL_DIR}/.dify_initialized"
            return 0
        elif echo "$resp" | grep -q "HTTP_2"; then
            log_success "[dify-init] Dify admin initialized"
            touch "${INSTALL_DIR}/.dify_initialized"
            return 0
        elif echo "$resp" | grep -q "INIT_FAIL"; then
            log_warn "[dify-init] Dify init step failed (attempt ${try}/3): $(echo "$resp" | head -c 200)"
        else
            log_warn "[dify-init] Dify setup step failed (attempt ${try}/3): $(echo "$resp" | head -c 200)"
        fi

        [[ $try -lt 3 ]] || break
        sleep 60
    done
    log_warn "[dify-init] Dify init failed after 3 attempts — run 'agmind init-dify' manually"
}

# Pre-download EasyOCR Cyrillic model so first OCR on RU scans doesn't
# stall on network fetch (or fail in air-gapped installs). CLAUDE.md §8:
# cyrillic_g2.pth не в bundled image, качается at first-use, теряется при
# recreate. Download here makes it persistent in docling_cache volume.
_ensure_docling_ocr_models() {
    [[ "${ENABLE_DOCLING:-false}" == "true" ]] || return 0
    docker ps --filter 'name=agmind-docling' --filter 'status=running' --format '{{.Names}}' \
        | grep -q agmind-docling || return 0
    local lang="${OCR_LANG:-rus,eng}"
    case ",$lang," in
        *,rus,*|*,ru,*|*,cyrillic,*) ;;
        *) log_info "Docling OCR: ${lang} — Cyrillic pre-download skipped"; return 0 ;;
    esac

    # Volume path inside container (matches compose mount: agmind_docling_cache → /opt/app-root/src/.cache).
    local easyocr_dir='/opt/app-root/src/.cache/docling/models/EasyOcr'
    if docker exec agmind-docling sh -c "test -f '${easyocr_dir}/cyrillic_g2.pth'" 2>/dev/null; then
        log_info "Docling OCR: cyrillic_g2.pth already present"
        return 0
    fi

    log_info "Docling OCR: downloading cyrillic_g2.pth (~15 MB)..."
    if docker exec agmind-docling python3 -c "
import easyocr
easyocr.Reader(['ru','en'], model_storage_directory='${easyocr_dir}', download_enabled=True, verbose=False)
" >/dev/null 2>&1; then
        log_success "Docling OCR: Cyrillic model ready"
    else
        log_warn "Docling OCR: cyrillic download failed — first RU scan will fetch on-demand"
    fi
}

# Grafana persists admin pw in grafana.db on first boot and IGNORES
# GF_SECURITY_ADMIN_PASSWORD on subsequent boots. If .env password was
# regenerated (second install / upgrade), stored pw diverges from .env and
# credentials.txt — user gets 401. Force-sync via grafana-cli is idempotent:
# on fresh install no-op (matches env), on regen install — rewrites.
_sync_grafana_admin_password() {
    [[ "${MONITORING_MODE:-}" == "local" ]] || return 0
    docker ps --filter 'name=agmind-grafana' --filter 'status=running' --format '{{.Names}}' \
        | grep -q agmind-grafana || return 0

    local pw
    pw="$(grep '^GRAFANA_ADMIN_PASSWORD=' "${INSTALL_DIR}/docker/.env" 2>/dev/null | cut -d'=' -f2-)"
    [[ -z "$pw" ]] && return 0

    # Wait for /api/health — grafana.db must be migrated & unlocked
    local attempts=0
    while [[ $attempts -lt 40 ]]; do
        if docker exec agmind-grafana wget -qO- http://localhost:3000/api/health 2>/dev/null | grep -q '"database":"ok"'; then
            break
        fi
        sleep 3
        attempts=$((attempts + 1))
    done
    [[ $attempts -ge 40 ]] && { log_warn "Grafana not ready in 2 min — admin password sync skipped"; return 0; }

    if docker exec agmind-grafana grafana cli admin reset-admin-password "$pw" >/dev/null 2>&1; then
        log_info "Grafana admin password synced with .env"
    else
        log_warn "Grafana password sync failed — credentials.txt may be out of date"
    fi
}

_init_minio_bucket() {
    [[ "${ENABLE_MINIO:-false}" == "true" ]] || return 0
    log_info "Creating MinIO bucket..."
    local user pass bucket
    user="$(grep '^MINIO_ROOT_USER=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2-)"
    pass="$(grep '^MINIO_ROOT_PASSWORD=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2-)"
    bucket="$(grep '^S3_BUCKET_NAME=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2-)"
    bucket="${bucket:-dify-storage}"

    # Wait for MinIO container to be running (healthcheck may take longer)
    local i=0
    while [[ $i -lt 12 ]]; do
        if docker ps --filter "name=agmind-minio" --filter "status=running" --format '{{.Names}}' | grep -q agmind-minio; then
            break
        fi
        sleep 5
        (( i++ )) || true
    done

    # Use minio/mc sidecar container — robust across all minio image versions.
    # Joins the same Docker network to reach minio:9000 by service name.
    local net
    net="$(docker network ls --format '{{.Name}}' | grep -m1 agmind-backend)"
    docker run --rm --network "$net" \
        -e "MC_HOST_local=http://${user}:${pass}@agmind-minio:9000" \
        minio/mc:latest mb --ignore-existing "local/${bucket}" 2>/dev/null \
        || log_warn "MinIO bucket creation failed — create manually via http://<IP>:9001"

    # v3.0 hotfix (2026-04-19): Dify writes to MinIO via S3_ACCESS_KEY/S3_SECRET_KEY,
    # which are DIFFERENT from MINIO_ROOT_USER/_PASSWORD. Without a service account
    # bound to those keys, Dify init fails with "InvalidAccessKeyId" on PutObject.
    local s3_ak s3_sk
    s3_ak="$(grep '^S3_ACCESS_KEY=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2-)"
    s3_sk="$(grep '^S3_SECRET_KEY=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2-)"
    if [[ -n "$s3_ak" && -n "$s3_sk" && "$s3_ak" != "$user" ]]; then
        docker run --rm --network "$net" \
            -e "MC_HOST_local=http://${user}:${pass}@agmind-minio:9000" \
            minio/mc:latest admin user svcacct add \
                --access-key "$s3_ak" \
                --secret-key "$s3_sk" \
                local "$user" >/dev/null 2>&1 \
            || log_warn "MinIO service account creation failed — Dify storage will be unavailable"
    fi
}

_save_credentials() {
    local ip; ip="$(_get_ip)"
    local url="http://${ip}"; if [[ "${DEPLOY_PROFILE:-}" == "vps" && -n "${DOMAIN:-}" ]]; then url="https://${DOMAIN}"; fi
    local owui_pass=""; if [[ -f "${INSTALL_DIR}/.admin_password" ]]; then owui_pass="$(cat "${INSTALL_DIR}/.admin_password")"; fi
    {
        echo "# AGMind Credentials — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "Dify App:    ${url}"
        echo "Dify Console: http://${DOMAIN:-$ip}:3000"
        echo "  Login: admin@agmind.ai"
        echo "  Pass:  ${owui_pass:-N/A}"
        if [[ "${ENABLE_OPENWEBUI:-false}" == "true" ]]; then
            echo ""
            echo "Open WebUI:  ${url}/chat"
            echo "  Login: admin@agmind.ai"
            echo "  Pass:  ${owui_pass:-N/A}"
        fi
        if [[ "${MONITORING_MODE:-}" == "local" ]]; then
            echo ""
            echo "Grafana: http://${ip}:${GRAFANA_PORT:-3001}"
            echo "  Login: admin"
            echo "  Pass:  ${GRAFANA_ADMIN_PASSWORD:-admin}"
            echo ""
            echo "Portainer: https://${ip}:${PORTAINER_PORT:-9443}"
            echo "  (создайте admin при первом входе)"
            if [[ "${ADMIN_UI_OPEN:-false}" != "true" ]]; then
                echo ""
                echo "Portainer SSH tunnel (если Portainer недоступен извне):"
                echo "  ssh -L 9443:127.0.0.1:9443 $(whoami)@${ip}"
                echo "  Затем откройте: https://localhost:9443"
            fi
        fi
        if [[ ! -f "${INSTALL_DIR}/.dify_initialized" ]]; then
            echo ""
            echo "Dify Admin (ручная настройка):"
            echo "  Dify не был инициализирован автоматически."
            echo "  Откройте http://${DOMAIN:-$ip}:3000/install"
            echo "  Пароль инициализации: grep INIT_PASSWORD ${INSTALL_DIR}/docker/.env | cut -d= -f2-"
        fi
        # Model API Endpoints — Dify "Add Model" form fields, copy-paste ready
        if [[ "${LLM_PROVIDER:-}" == "vllm" ]]; then
            # In master/worker cluster mode the LLM runs on peer (via QSFP) —
            # master has no local agmind-vllm container. Read cluster.json to pick host.
            local _vllm_host="agmind-vllm"
            local _state_file="${AGMIND_CLUSTER_STATE_FILE:-/var/lib/agmind/state/cluster.json}"
            if command -v jq >/dev/null 2>&1 && [[ -f "$_state_file" ]]; then
                local _mode _peer_ip
                _mode="$(jq -r '.mode // "single"' "$_state_file" 2>/dev/null)"
                _peer_ip="$(jq -r '.peer_ip // empty' "$_state_file" 2>/dev/null)"
                if [[ "$_mode" == "master" && -n "$_peer_ip" ]]; then
                    _vllm_host="$_peer_ip"
                fi
            fi
            echo ""
            echo "=== vLLM (Dify → Settings → Model Provider → OpenAI-API-compatible) ==="
            echo "  Model Type:              LLM"
            echo "  Model Name:              ${VLLM_MODEL:-QuantTrio/Qwen3.5-27B-AWQ}"
            echo "  API endpoint URL:        http://${_vllm_host}:8000/v1"
            echo "  API Key:                 none"
            echo "  model name for endpoint: ${VLLM_MODEL:-QuantTrio/Qwen3.5-27B-AWQ}"
            if [[ "$_vllm_host" != "agmind-vllm" ]]; then
                echo "  Note: LLM runs on peer Spark (${_vllm_host}) via QSFP — master has no local vllm container"
            fi
        fi
        if [[ "${LLM_PROVIDER:-}" == "ollama" || "${EMBED_PROVIDER:-}" == "ollama" ]]; then
            echo ""
            echo "=== Ollama (Dify → Settings → Model Provider → Ollama) ==="
            echo "  Base URL:                http://agmind-ollama:11434"
            if [[ "${LLM_PROVIDER:-}" == "ollama" ]]; then
                echo "  Model Type:              LLM"
                echo "  Model Name:              ${LLM_MODEL:-qwen2.5:14b}"
            fi
            if [[ "${EMBED_PROVIDER:-}" == "ollama" ]]; then
                echo "  Model Type:              Text Embedding"
                echo "  Model Name:              ${EMBEDDING_MODEL:-bge-m3}"
            fi
        fi
        if [[ "${EMBED_PROVIDER:-}" == "tei" ]]; then
            echo ""
            echo "=== TEI Embedding (Dify → Settings → Model Provider → OpenAI-API-compatible) ==="
            echo "  Model Type:              Text Embedding"
            echo "  Model Name:              ${EMBEDDING_MODEL:-deepvk/USER-bge-m3}"
            echo "  API endpoint URL:        http://agmind-tei:80"
            echo "  API Key:                 none"
            echo "  model name for endpoint: ${EMBEDDING_MODEL:-deepvk/USER-bge-m3}"
        fi
        if [[ "${EMBED_PROVIDER:-}" == "vllm-embed" ]]; then
            echo ""
            echo "=== vLLM Embedding (DGX Spark) ==="
            echo "  Model Type:              Text Embedding"
            echo "  Model Name:              ${VLLM_EMBED_MODEL:-deepvk/USER-bge-m3}"
            echo "  API endpoint URL:        http://agmind-vllm-embed:8000/v1"
            echo "  API Key:                 none"
            echo "  Dify:                    Settings → Model Provider → OpenAI-API-compatible"
            echo "  model name for endpoint: ${VLLM_EMBED_MODEL:-deepvk/USER-bge-m3}"
        fi
        if [[ "${ENABLE_RERANKER:-false}" == "true" && "${RERANKER_PROVIDER:-tei}" != "vllm-rerank" ]]; then
            echo ""
            echo "=== TEI Reranker (Dify → Settings → Model Provider → OpenAI-API-compatible) ==="
            echo "  Model Type:              Rerank"
            echo "  Model Name:              ${RERANK_MODEL:-BAAI/bge-reranker-base}"
            echo "  API endpoint URL:        http://agmind-tei-rerank:80"
            echo "  API Key:                 none"
            echo "  model name for endpoint: ${RERANK_MODEL:-BAAI/bge-reranker-base}"
        fi
        if [[ "${RERANKER_PROVIDER:-tei}" == "vllm-rerank" ]]; then
            echo ""
            echo "=== vLLM Reranker (DGX Spark) ==="
            echo "  Model Type:              Rerank"
            echo "  Model Name:              ${VLLM_RERANK_MODEL:-BAAI/bge-reranker-v2-m3}"
            echo "  API endpoint URL:        http://agmind-vllm-rerank:8000/v1"
            echo "  API Key:                 none"
            echo "  Dify:                    Settings → Model Provider → OpenAI-API-compatible"
            echo "  model name for endpoint: ${VLLM_RERANK_MODEL:-BAAI/bge-reranker-v2-m3}"
        fi
        # LiteLLM AI Gateway
        if [[ "${ENABLE_LITELLM:-true}" == "true" ]]; then
            echo ""
            echo "=== LiteLLM AI Gateway ==="
            echo "  Dashboard: http://${DOMAIN:-$ip}:4001/ui/"
            echo "  API:       http://agmind-litellm:4000/v1  (internal, for Dify/OWUI)"
            echo "  Master Key: ${LITELLM_MASTER_KEY:-see .env}"
            echo ""
            echo "  Dify Model Provider (Settings -> Model Provider -> OpenAI-API-compatible):"
            echo "    Model Type:              LLM"
            echo "    Model Name:              litellm"
            echo "    API endpoint URL:        http://agmind-litellm:4000/v1"
            echo "    API Key:                 ${LITELLM_MASTER_KEY:-see .env}"
            echo "    model name for endpoint: *"
        fi
        # Optional Services
        if [[ "${ENABLE_SEARXNG:-false}" == "true" ]]; then
            echo ""
            echo "=== SearXNG (Поисковый движок) ==="
            echo "  URL:           http://${ip}:${EXPOSE_SEARXNG_PORT:-8888}"
            echo "  JSON API:      http://${ip}:${EXPOSE_SEARXNG_PORT:-8888}/search?q=test&format=json"
        fi
        if [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]]; then
            echo ""
            echo "=== Open Notebook (Исследовательский ассистент) ==="
            echo "  URL:           http://${ip}:${EXPOSE_NOTEBOOK_PORT:-8502}"
            echo "  Настройте LLM провайдер в Settings после первого входа."
        fi
        if [[ "${ENABLE_DBGPT:-false}" == "true" ]]; then
            echo ""
            echo "=== DB-GPT (Аналитика данных) ==="
            echo "  URL:           http://${ip}:${EXPOSE_DBGPT_PORT:-5670}"
        fi
        if [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]]; then
            echo ""
            echo "=== Crawl4AI (Веб-краулер) ==="
            echo "  API:           http://${ip}:${EXPOSE_CRAWL4AI_PORT:-11235}"
            echo "  API Docs:      http://${ip}:${EXPOSE_CRAWL4AI_PORT:-11235}/docs"
            echo "  Dify:          HTTP Request tool → POST http://agmind-crawl4ai:11235/crawl"
        fi
        if [[ "${ENABLE_DOCLING:-false}" == "true" ]]; then
            local _docling_mode="CPU"
            if [[ "${NVIDIA_VISIBLE_DEVICES:-}" == "all" ]]; then _docling_mode="GPU"; fi
            echo ""
            echo "=== Docling (Обработка документов, ${_docling_mode}) ==="
            echo "  API:           http://${ip}:${EXPOSE_DOCLING_PORT:-8765}"
            echo "  API Docs:      http://${ip}:${EXPOSE_DOCLING_PORT:-8765}/docs"
            echo "  Dify ETL:      настроен автоматически (Dify → Settings → Data Source → Docling)"
            echo "  Dify Tool:     HTTP Request → POST http://agmind-docling:8765/v1/convert"
        fi
        if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
            local _minio_user _minio_pass
            _minio_user="$(grep '^MINIO_ROOT_USER=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2-)"
            _minio_pass="$(grep '^MINIO_ROOT_PASSWORD=' "${INSTALL_DIR}/docker/.env" | cut -d'=' -f2-)"
            echo ""
            echo "=== MinIO (S3 Object Storage) ==="
            echo "  Console: http://${ip}:9001"
            echo "  User:    ${_minio_user:-agmind-admin}"
            echo "  Pass:    ${_minio_pass:-see .env}"
            echo "  Bucket:  dify-storage"
            echo "  API:     http://minio:9000 (internal)"
        fi
        case "${ALERT_MODE:-none}" in
            telegram)
                echo ""
                echo "=== Alerts → Telegram ==="
                echo "  Bot token:  в .env (ALERT_TELEGRAM_TOKEN, chmod 600)"
                echo "  Chat ID:    ${ALERT_TELEGRAM_CHAT_ID:-не задан}"
                echo "  Config:     ${INSTALL_DIR}/docker/monitoring/alertmanager.yml"
                echo "  Ротация:    создайте нового бота через @BotFather → revoke старого →"
                echo "              обновите ALERT_TELEGRAM_TOKEN в .env →"
                echo "              sudo docker compose restart alertmanager"
                ;;
            email)
                echo ""
                echo "=== Alerts → Email (SMTP) ==="
                echo "  SMTP:    ${ALERT_EMAIL_SMARTHOST:-see .env}"
                echo "  To:      ${ALERT_EMAIL_TO:-see .env}"
                echo "  From:    ${ALERT_EMAIL_FROM:-alerts@agmind.local}"
                echo "  Config:  ${INSTALL_DIR}/docker/monitoring/alertmanager.yml"
                ;;
            webhook)
                echo ""
                echo "=== Alerts → Webhook ==="
                echo "  URL:     ${ALERT_WEBHOOK_URL:-see .env}"
                echo "  Config:  ${INSTALL_DIR}/docker/monitoring/alertmanager.yml"
                ;;
            none|*)
                echo ""
                echo "=== Alerts ==="
                echo "  Channel: OFF (alerts только в Grafana UI)"
                echo "  Включить канал: запустите sudo bash install.sh повторно и выберите"
                echo "  пункт 2/3/4 на шаге 'Уведомления о сбоях', либо вручную:"
                echo "    1. Отредактируйте ALERT_MODE + ALERT_* в ${INSTALL_DIR}/docker/.env"
                echo "    2. sudo docker compose restart alertmanager"
                ;;
        esac
        echo ""
        echo "# ---"
        echo "# ВНИМАНИЕ: Эти пароли актуальны на момент установки."
        echo "# При смене пароля через UI обновите этот файл вручную."
        echo "# WARNING: Passwords reflect installation defaults."
        echo "# If changed via UI, update this file manually."
    } > "${INSTALL_DIR}/credentials.txt"
    chmod 600 "${INSTALL_DIR}/credentials.txt"
    log_info "Credentials: ${INSTALL_DIR}/credentials.txt"
}

_get_ip() { if [[ "$(uname)" == "Darwin" ]]; then ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1"; else hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"; fi; }

_obtain_letsencrypt_cert() {
    if [[ "${TLS_MODE:-none}" != "letsencrypt" ]]; then return 0; fi
    if [[ -z "${DOMAIN:-}" ]]; then log_warn "TLS: letsencrypt requires DOMAIN — skipping cert obtain"; return 0; fi
    if [[ -z "${CERTBOT_EMAIL:-}" ]]; then log_warn "TLS: letsencrypt requires CERTBOT_EMAIL — skipping cert obtain"; return 0; fi

    local compose_file="${INSTALL_DIR}/docker/docker-compose.yml"

    log_info "Obtaining Let's Encrypt certificate for ${DOMAIN}..."

    # Certbot obtains cert via webroot (nginx serves /.well-known/acme-challenge/)
    if docker compose -f "$compose_file" run --rm certbot \
        certonly --webroot \
        --webroot-path=/var/www/certbot \
        --email "${CERTBOT_EMAIL}" \
        --agree-tos --no-eff-email \
        -d "${DOMAIN}" \
        --non-interactive 2>&1 | tail -5; then

        log_success "Let's Encrypt certificate obtained for ${DOMAIN}"

        # Update nginx config to use real LE cert paths
        local nginx_conf="${INSTALL_DIR}/docker/nginx/nginx.conf"
        local le_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        local le_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        sed -i "s|/etc/nginx/ssl/cert.pem|${le_cert}|g" "$nginx_conf"
        sed -i "s|/etc/nginx/ssl/key.pem|${le_key}|g" "$nginx_conf"

        # Reload nginx to pick up real cert
        docker compose -f "$compose_file" exec -T nginx nginx -s reload 2>/dev/null || {
            log_warn "nginx reload failed — restart nginx manually: docker compose restart nginx"
        }
        log_success "Nginx reloaded with Let's Encrypt certificate"
    else
        log_warn "Let's Encrypt cert obtain failed — nginx continues with self-signed placeholder"
        log_warn "Retry manually: docker compose run --rm certbot certonly --webroot --webroot-path=/var/www/certbot -d ${DOMAIN} --email ${CERTBOT_EMAIL} --agree-tos"
    fi
}

_install_cli() {
    if [[ -d /usr/local/bin ]]; then ln -sf "${INSTALL_DIR}/scripts/agmind.sh" /usr/local/bin/agmind && log_success "'agmind' command available"; fi
    date -u +%Y-%m-%dT%H:%M:%SZ > "${INSTALL_DIR}/.agmind_installed"
    # Write RELEASE tag for update system (BUG-V3-044: fallback when RELEASE file missing)
    if [[ -f "${INSTALLER_DIR}/RELEASE" && "$INSTALLER_DIR" != "$INSTALL_DIR" ]]; then
        cp "${INSTALLER_DIR}/RELEASE" "${INSTALL_DIR}/RELEASE"
    elif [[ ! -f "${INSTALL_DIR}/RELEASE" ]]; then
        local release_tag=""
        # Try git describe (works if installed from tagged commit)
        release_tag="$(cd "${INSTALLER_DIR}" && git describe --tags --exact-match 2>/dev/null || true)"
        # Fallback: git describe --always (short hash with tag prefix if available)
        if [[ -z "$release_tag" ]]; then release_tag="$(cd "${INSTALLER_DIR}" && git describe --tags --always 2>/dev/null || true)"; fi
        # Last resort: hash of versions.env content
        if [[ -z "$release_tag" && -f "${INSTALL_DIR}/docker/versions.env" ]]; then
            release_tag="dev-$(md5sum "${INSTALL_DIR}/docker/versions.env" | cut -c1-8)"
        fi
        if [[ -n "$release_tag" ]]; then
            echo "$release_tag" > "${INSTALL_DIR}/RELEASE"
            log_info "RELEASE tag set to: ${release_tag} (fallback)"
        fi
    fi
}

_install_crons() {
    if [[ -d /etc/cron.d ]]; then
        echo "* * * * * root ${INSTALL_DIR}/scripts/health-gen.sh >> ${INSTALL_DIR}/health-gen.log 2>&1" > /etc/cron.d/agmind-health
        chmod 644 /etc/cron.d/agmind-health

        # GPU metrics for Prometheus (via node-exporter textfile collector)
        if [[ "${MONITORING_MODE:-none}" == "local" ]] && command -v nvidia-smi &>/dev/null; then
            local gpu_script="${INSTALL_DIR}/scripts/gpu-metrics.sh"
            local textfile_dir="${INSTALL_DIR}/docker/monitoring/textfile"
            mkdir -p "$textfile_dir"
            if [[ -x "$gpu_script" ]]; then
                cat > /etc/cron.d/agmind-gpu-metrics <<GPUCRON
* * * * * root ${gpu_script} ${textfile_dir} >/dev/null 2>&1
* * * * * root sleep 15 && ${gpu_script} ${textfile_dir} >/dev/null 2>&1
* * * * * root sleep 30 && ${gpu_script} ${textfile_dir} >/dev/null 2>&1
* * * * * root sleep 45 && ${gpu_script} ${textfile_dir} >/dev/null 2>&1
GPUCRON
                chmod 644 /etc/cron.d/agmind-gpu-metrics
                # Generate initial metrics so Prometheus has data on first scrape
                "$gpu_script" "$textfile_dir" 2>/dev/null || true
                log_info "GPU metrics cron installed (15s interval)"
            fi
        fi
    fi
    # Create initial health.json placeholder so nginx /health works before first cron tick.
    # Phase 36: mount is now directory-based (./nginx/health/ -> /etc/nginx/health/).
    # Directory mount keeps bind stable across health-gen.sh atomic rename.
    local health_dir="${INSTALL_DIR}/docker/nginx/health"
    mkdir -p "$health_dir"
    # Clean up legacy layout: if previous deploy used file-mount, docker may have
    # created ${INSTALL_DIR}/docker/nginx/health.json as a directory — remove it.
    local legacy_path="${INSTALL_DIR}/docker/nginx/health.json"
    if [[ -e "$legacy_path" ]]; then rm -rf "$legacy_path"; fi
    if [[ ! -f "${health_dir}/health.json" ]]; then
        echo '{"status": "starting", "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "${health_dir}/health.json"
    fi
}

_install_systemd_service() {
    # Install systemd service for auto-start after reboot
    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found — skipping auto-start service"
        return 0
    fi

    local service_src="${TEMPLATE_DIR}/agmind-stack.service.template"
    local service_dst="/etc/systemd/system/agmind-stack.service"

    if [[ ! -f "$service_src" ]]; then
        log_warn "Service template not found: ${service_src}"
        return 0
    fi

    sed "s|__INSTALL_DIR__|${INSTALL_DIR}|g" "$service_src" > "$service_dst"
    chmod 644 "$service_dst"
    systemctl daemon-reload
    systemctl enable agmind-stack.service
    log_success "Auto-start service installed (agmind-stack.service)"
}

# Smoke peer vLLM check — STRICT. Returns 0 if no peer required (mode != master).
# Returns 0 if peer healthy. Returns 1 if peer required but unhealthy.
# cluster.json is source of truth (not AGMIND_MODE env — resume path may not have wizard run).
_smoke_peer_vllm_check() {
    local state_file="${AGMIND_CLUSTER_STATE_FILE:-/var/lib/agmind/state/cluster.json}"
    if [[ ! -f "$state_file" ]]; then
        return 0  # No cluster state — nothing to check
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq missing — cannot verify cluster.json for peer smoke check"
        return 0
    fi
    local mode peer_ip
    mode="$(jq -r '.mode // "single"' "$state_file" 2>/dev/null || echo single)"
    peer_ip="$(jq -r '.peer_ip // empty' "$state_file" 2>/dev/null || true)"

    [[ "$mode" != "master" ]] && return 0
    if [[ -z "$peer_ip" ]]; then
        log_error "STRICT: cluster.json mode=master but peer_ip empty — phase_deploy_peer inconsistency"
        return 1
    fi

    if ! curl -sSf --max-time 5 "http://${peer_ip}:8000/v1/models" >/dev/null 2>&1; then
        log_error "STRICT: peer vLLM on ${peer_ip}:8000 not reachable (mode=master)"
        log_error "  Diagnose: ssh ${AGMIND_PEER_USER:-agmind2}@${peer_ip} 'docker logs agmind-vllm --tail 50'"
        log_error "  Fix: rerun 'sudo bash install.sh' — phase_deploy_peer idempotent"
        return 1
    fi
    local model
    model="$(curl -sSf --max-time 5 "http://${peer_ip}:8000/v1/models" 2>/dev/null \
        | jq -r '.data[0].id // "unknown"' 2>/dev/null || echo "unknown")"
    log_success "Peer vLLM on ${peer_ip} healthy (model: ${model})"
    return 0
}

_verify_post_install_smoke() {
    # Post-install smoke: catches regressions that shellcheck + bash -n miss.
    # Soft checks: log warnings. Strict checks: return 1 (propagates via phase_complete).
    local warn_count=0
    local strict_fail=0

    # --- Soft checks (warnings only, install continues) ---

    # mDNS: first configured name should resolve via avahi (not /etc/hosts fallback)
    if command -v avahi-resolve >/dev/null 2>&1; then
        if ! timeout 4 avahi-resolve -n agmind-dify.local >/dev/null 2>&1; then
            log_warn "mDNS: agmind-dify.local does not resolve via avahi"
            log_warn "  Causes: foreign mDNS stack on :5353 (NoMachine, iTunes), missing default route, or libnss-mdns not installed"
            log_warn "  Diagnose:  journalctl -u avahi-daemon -n 50 ; ss -ulnp | grep 5353"
            log_warn "  Fallback:  /etc/hosts entries work host-local only — LAN clients will fail"
            warn_count=$((warn_count + 1))
        fi
    fi

    # Loadtest scenarios: agmind CLI needs scripts/loadtest/*.js to function
    local loadtest_dir="${INSTALL_DIR}/scripts/loadtest"
    if [[ ! -d "$loadtest_dir" ]] || [[ -z "$(ls -A "$loadtest_dir" 2>/dev/null)" ]]; then
        log_warn "loadtest: ${loadtest_dir} missing or empty"
        log_warn "  'agmind loadtest chat|kb-indexing|embed-burst' will fail"
        log_warn "  Regression from install.sh _copy_runtime_files script_subdirs whitelist"
        warn_count=$((warn_count + 1))
    fi

    # MDNS-04/05: STRICT mDNS smoke per CLAUDE.md §8 "Post-install smoke обязателен".
    if command -v agmind >/dev/null 2>&1; then
        if ! agmind mdns-status >/dev/null 2>&1; then
            log_error "FATAL smoke: agmind mdns-status reported issue(s) — details below:"
            agmind mdns-status || true
            log_error "Fix mDNS before using AGmind — agmind-*.local will not resolve"
            log_error "Re-run install.sh after fixing the issue"
            strict_fail=$((strict_fail + 1))
        else
            log_success "post-install smoke: mDNS OK"
        fi
    elif [[ -x "${INSTALL_DIR}/scripts/mdns-status.sh" ]]; then
        if ! bash "${INSTALL_DIR}/scripts/mdns-status.sh" >/dev/null 2>&1; then
            log_error "FATAL smoke: agmind mdns-status reported issue(s)"
            bash "${INSTALL_DIR}/scripts/mdns-status.sh" || true
            strict_fail=$((strict_fail + 1))
        else
            log_success "post-install smoke: mDNS OK"
        fi
    fi

    # --- STRICT checks (install fails if any breaks) ---

    # PEER-06: if cluster.json mode=master, peer vLLM MUST respond /v1/models.
    _smoke_peer_vllm_check || strict_fail=$((strict_fail + 1))

    # --- Result ---

    [[ $warn_count -eq 0 && $strict_fail -eq 0 ]] && log_success "Post-install smoke: all checks passed"
    [[ $warn_count -gt 0 ]] && log_warn "Post-install smoke: ${warn_count} warning(s)"

    if [[ $strict_fail -gt 0 ]]; then
        log_error "Post-install smoke STRICT check FAILED (${strict_fail}). Installation cannot be considered successful."
        return 1
    fi
    return 0
}

_show_final_summary() {
    local ip; ip="$(_get_ip)"
    local url="http://${ip}"
    if [[ "${DEPLOY_PROFILE:-}" == "vps" && -n "${DOMAIN:-}" ]]; then url="https://${DOMAIN}"; fi
    local owui_pass=""
    if [[ -f "${INSTALL_DIR}/.admin_password" ]]; then owui_pass="$(cat "${INSTALL_DIR}/.admin_password")"; fi

    local container_count
    container_count="$(docker ps --filter "name=agmind-" -q 2>/dev/null | wc -l | tr -d ' ')"

    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  +--------------------------------------------------+"
    echo "  |            AGMind — Установка завершена           |"
    echo "  +--------------------------------------------------+"
    echo -e "${NC}"
    echo -e "  ${BOLD}Dify App:${NC}        ${GREEN}${url}${NC}"
    echo -e "  ${BOLD}Dify Console:${NC}    ${GREEN}http://agmind-dify.local${NC}"
    echo -e "    Login:         admin@agmind.ai"
    echo -e "    Pass:          ${owui_pass:-см. credentials.txt}"
    if [[ "${ENABLE_OPENWEBUI:-false}" == "true" ]]; then
        echo ""
        echo -e "  ${BOLD}Open WebUI:${NC}      ${GREEN}http://agmind-chat.local${NC}"
        echo -e "    Login:         admin@agmind.ai"
        echo -e "    Pass:          ${owui_pass:-см. credentials.txt}"
    fi
    echo ""
    if [[ "${ENABLE_LITELLM:-true}" == "true" ]]; then
        echo -e "  ${BOLD}LiteLLM UI:${NC}      ${GREEN}http://${ip}:4001/ui/${NC}"
    fi
    if [[ "${ENABLE_DBGPT:-false}" == "true" ]]; then
        echo -e "  ${BOLD}DB-GPT:${NC}          ${GREEN}http://agmind-dbgpt.local${NC}"
    fi
    if [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]]; then
        echo -e "  ${BOLD}Open Notebook:${NC}   ${GREEN}http://agmind-notebook.local${NC}"
    fi
    if [[ "${ENABLE_SEARXNG:-false}" == "true" ]]; then
        echo -e "  ${BOLD}SearXNG:${NC}         ${GREEN}http://agmind-search.local${NC}"
    fi
    if [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]]; then
        echo -e "  ${BOLD}Crawl4AI:${NC}        ${GREEN}http://agmind-crawl.local/docs${NC}"
    fi
    if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
        echo -e "  ${BOLD}MinIO:${NC}           ${GREEN}http://${ip}:9001${NC}"
        echo -e "    (credentials in ${INSTALL_DIR}/credentials.txt)"
    fi
    if [[ "${MONITORING_MODE:-}" == "local" ]]; then
        echo ""
        echo -e "  ${BOLD}Grafana:${NC}         ${GREEN}http://${ip}:${GRAFANA_PORT:-3001}${NC}"
        echo -e "    Login:         admin"
        echo -e "    Pass:          ${GRAFANA_ADMIN_PASSWORD:-admin}"
        echo ""
        echo -e "  ${BOLD}Portainer:${NC}       ${GREEN}https://${ip}:${PORTAINER_PORT:-9443}${NC}"
        echo -e "    (создайте admin при первом входе)"
        if [[ "${ADMIN_UI_OPEN:-false}" != "true" ]]; then
            echo ""
            echo -e "  ${YELLOW}${BOLD}Portainer доступен только через SSH tunnel:${NC}"
            echo -e "  ${CYAN}ssh -L 9443:127.0.0.1:9443 $(whoami)@${ip}${NC}"
            echo -e "  Затем откройте: ${GREEN}https://localhost:9443${NC}"
        fi
    fi
    echo ""
    # Service verification results (populated by verify_services)
    if [[ ${#VERIFY_RESULTS[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Проверка сервисов:${NC}"
        for entry in "${VERIFY_RESULTS[@]}"; do
            IFS='|' read -r name url status <<< "$entry"
            if [[ "$status" == "OK" ]]; then
                echo -e "    ${GREEN}[OK]${NC}   ${name}"
            else
                echo -e "    ${RED}[FAIL]${NC} ${name} — проверьте: agmind logs"
            fi
        done
        echo ""
    fi
    echo -e "  ${BOLD}Профиль:${NC}         ${DEPLOY_PROFILE:-lan}"
    echo -e "  ${BOLD}LLM:${NC}             ${LLM_PROVIDER:-ollama} ${LLM_MODEL:-}${VLLM_MODEL:+ (${VLLM_MODEL})}"
    echo -e "  ${BOLD}Эмбеддинги:${NC}      ${EMBED_PROVIDER:-ollama} ${EMBEDDING_MODEL:-bge-m3}"
    echo -e "  ${BOLD}Контейнеры:${NC}      ${container_count} запущено"
    echo ""
    echo -e "  ${BOLD}Credentials:${NC}     nano ${INSTALL_DIR}/credentials.txt"
    echo -e "  ${BOLD}Логи:${NC}            ${INSTALL_DIR}/install.log"
    echo -e "  ${BOLD}CLI:${NC}             agmind status | agmind health"
    echo -e "  ${BOLD}Документация:${NC}    ${INSTALL_DIR}/docs/  (citations, alerts, docling)"
    echo ""
    echo -e "  +--------------------------------------------------+"
    echo ""
}

# --- Main ---
main() {
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE=true;;
            --force-restart) FORCE_RESTART=true;;
            --dry-run) DRY_RUN=true;;
            --vds) DEPLOY_PROFILE="vps"; VDS_MODE=true;;
            --mode=*)
                AGMIND_MODE_OVERRIDE="${1#*=}"
                case "$AGMIND_MODE_OVERRIDE" in
                    single|master|worker) ;;
                    *) echo "ERROR: --mode must be one of: single, master, worker (got: $AGMIND_MODE_OVERRIDE)" >&2; exit 1 ;;
                esac
                export AGMIND_MODE_OVERRIDE
                ;;
            --help|-h) echo "Usage: sudo bash install.sh [--non-interactive] [--force-restart] [--dry-run] [--vds] [--mode=single|master|worker]"; exit 0;;
        esac; shift
    done

    # Root check
    if [[ "$(id -u)" -ne 0 && "$(uname)" != "Darwin" ]]; then log_error "Run as root: sudo bash install.sh"; exit 1; fi

    _acquire_lock
    mkdir -p "$INSTALL_DIR"

    # Initialize git repo so agmind update --main works after fresh install
    if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
        git -C "$INSTALL_DIR" init -b main >/dev/null 2>&1
        git -C "$INSTALL_DIR" remote add origin https://github.com/botAGI/AGmind.git 2>/dev/null || true
    fi

    # Save original TTY fd before tee redirect (used by docker compose pull for progress)
    ORIGINAL_TTY_FD=""
    if [ -t 1 ]; then
        exec 3>&1
        ORIGINAL_TTY_FD=3
    fi
    export ORIGINAL_TTY_FD

    # Logging (BUG-002 fix: touch+chmod BEFORE tee)
    local LOG_FILE="${INSTALL_DIR}/install.log"
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    show_banner

    # Checkpoint resume
    local start=1
    if [[ "$FORCE_RESTART" == "true" ]]; then rm -f "${INSTALL_DIR}/.install_phase"; fi
    if [[ -f "${INSTALL_DIR}/.install_phase" ]]; then
        local saved; saved="$(cat "${INSTALL_DIR}/.install_phase" 2>/dev/null)"
        if [[ "$saved" =~ ^[1-9]$ ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then start="$saved"
            else read -rp "Resume from phase ${saved}/9? (yes/no/restart): " r
                case "$r" in yes|y) start="$saved";; restart) rm -f "${INSTALL_DIR}/.install_phase";; *) exit 0;; esac
            fi
        fi
    fi
    # On resume past wizard: load existing .env
    if [[ $start -gt 2 && -f "${INSTALL_DIR}/docker/.env" ]]; then
        set +u; source "${INSTALL_DIR}/docker/.env"; set -u
    fi

    # On resume: always re-run diagnostics to populate DETECTED_* vars (BFIX-42)
    # Only run_diagnostics (lightweight detection, no prompts) -- NOT phase_diagnostics
    # which would re-run preflight_checks and may prompt the user.
    # || true: detection may partially fail (e.g. no nvidia-smi) but sets safe defaults.
    if [[ $start -gt 1 ]]; then
        log_info "Resume: re-running system diagnostics..."
        run_diagnostics || true
    fi

    # Phase table
    local t=11
    if [[ $start -le 1  ]]; then run_phase 1  $t "Diagnostics"   phase_diagnostics; fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        preflight_checks || true
        preflight_rc=$?
        log_info "Dry-run complete — exiting without starting containers"
        exit "$preflight_rc"
    fi
    if [[ $start -le 2  ]]; then run_phase 2  $t "Wizard"        phase_wizard; fi
    if [[ $start -le 3  ]]; then run_phase 3  $t "Docker"        phase_docker; fi
    if [[ $start -le 4  ]]; then run_phase 4  $t "Configuration" phase_config; fi
    if [[ $start -le 5  ]]; then run_phase 5  $t "Pull"   phase_pull; fi   # inactivity timeout inside _pull_with_progress
    if [[ $start -le 6  ]]; then run_phase_with_timeout 6  $t "Start"  phase_start  "$TIMEOUT_START"; fi
    # Phase 7 — deploy vLLM to peer when AGMIND_MODE=master. Skips otherwise (single/worker).
    if [[ $start -le 7  ]]; then run_phase 7  $t "Deploy Peer"   phase_deploy_peer; fi
    if [[ $start -le 8  ]]; then run_phase 8  $t "Health"        phase_health; fi   # inactivity timeout inside wait_healthy
    if [[ $start -le 9  ]]; then run_phase 9  $t "Models"        phase_models_graceful; fi  # graceful: non-fatal on timeout
    if [[ $start -le 10 ]]; then run_phase 10 $t "Backups"       phase_backups; fi
    if [[ $start -le 11 ]]; then run_phase 11 $t "Complete"      phase_complete; fi

    rm -f "${INSTALL_DIR}/.install_phase"
}

main "$@"
