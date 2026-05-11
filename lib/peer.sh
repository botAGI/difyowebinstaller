#!/usr/bin/env bash
# peer.sh — Dual-Spark peer deploy: vLLM worker provisioning via SSH/Docker.
# Dependencies: common.sh (log_*), cluster_mode.sh (cluster_mode_read,
#   cluster_status_update, AGMIND_MODE), ssh_trust.sh (_ensure_ssh_trust,
#   _agmind_peer_ssh_opts), detect.sh (PEER_IP/PEER_USER/PEER_HOSTNAME globals)
# Functions: peer_deploy (public, registered in PHASES as "Deploy Peer"),
#   _render_worker_env, _deploy_image_to_peer, _wait_peer_vllm_ready,
#   _deploy_peer_gpu_metrics, _deploy_peer_systemd, _configure_backup_remote_peer
# Expects: INSTALLER_DIR, INSTALL_DIR, TEMPLATE_DIR, VLLM_IMAGE, VLLM_SPARK_IMAGE,
#   HF_TOKEN, AGMIND_PEER_USER, AGMIND_PEER_SSH_KEY, NODE_EXPORTER_VERSION,
#   PORTAINER_AGENT_SECRET, PORTAINER_AGENT_VERSION, PORTAINER_PORT, MONITORING_MODE
# Exports: nothing (side-effects only: cluster.json status, ssh/docker on peer, backup.conf)
set -euo pipefail

# ============================================================================
# FALLBACK SHIMS (only active when sourced without common.sh)
# ============================================================================

# Fallback log functions when sourced without common.sh (mirrors lib/doctor.sh / lib/health.sh)
command -v log_info    >/dev/null 2>&1 || log_info()    { echo -e "  -> $*" >&2; }
command -v log_success >/dev/null 2>&1 || log_success() { echo -e "  ok $*" >&2; }
command -v log_warn    >/dev/null 2>&1 || log_warn()    { echo -e "  ! $*" >&2; }
command -v log_error   >/dev/null 2>&1 || log_error()   { echo -e "  x $*" >&2; }

# ============================================================================
# PUBLIC API
# ============================================================================

# Main deploy orchestrator — runs only if AGMIND_MODE=master.
# Registered in PHASES array (lib/phases.sh) as:
# "Deploy Peer${SEP}peer_deploy${SEP}1800${SEP}optional,master-only".
peer_deploy() {
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
        log_error "PEER_IP unavailable (not detected via LLDP/detect.sh, not in cluster.json) — cannot deploy"
        log_error "Fix: re-run install.sh with working QSFP link to peer, or AGMIND_MODE_OVERRIDE=single"
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    fi

    # Strict regex validation BEFORE any ssh/scp invocation. PEER_IP/PEER_USER are
    # untrusted (LLDP frame source on QSFP segment) — without validation a malicious
    # neighbor could inject shell metacharacters into the remote command line.
    # Subnet anchored to 192.168.100.0/24 — our QSFP cluster subnet (cluster_mode.sh).
    if ! [[ "$peer_ip" =~ ^192\.168\.100\.[0-9]{1,3}$ ]]; then
        log_error "PEER_IP failed validation: '${peer_ip}' (must match 192.168.100.X)"
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    fi
    # POSIX-portable username regex per useradd(8): [a-z_][a-z0-9_-]{0,31}
    if ! [[ "$peer_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        log_error "PEER_USER failed validation: '${peer_user}' (must match POSIX username)"
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

    # 10. Persist success — peer Portainer endpoint данные уйдут в credentials.txt
    # для ручного добавления через UI master Portainer (см. _generate_credentials).
    cluster_status_update "running" 2>/dev/null || true
    log_success "vLLM deployed and healthy on peer ${peer_ip}"
    log_info "Peer Portainer Agent listens on ${peer_ip}:9001 — добавь руками через UI:"
    log_info "  https://$(_get_ip):${PORTAINER_PORT:-9443} → Environments → Add → Agent"
    log_info "  Endpoint данные + AGENT_SECRET записаны в ${INSTALL_DIR}/credentials.txt"
}

# ============================================================================
# PRIVATE HELPERS
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
# Portainer agent — registered в master Portainer peer_deploy'ом.
# AGENT_SECRET shared с master через persistent file
# (lib/config.sh::_PORTAINER_AGENT_SECRET).
PORTAINER_AGENT_SECRET=${PORTAINER_AGENT_SECRET:-}
# §8: master Portainer и peer agent версии ОБЯЗАНЫ совпадать (TLS handshake EOF
# при protocol drift между minor'ами). Fallback синхронизирован с
# templates/versions.env (PORTAINER_VERSION) и templates/env.lan.template.
PORTAINER_AGENT_VERSION=${PORTAINER_AGENT_VERSION:-2.41.1}
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

# Configure backup.conf to mirror master backups onto peer Spark via QSFP DAC.
# Peer has 3.4 TB free SSD — natural off-master backup target without external NAS.
# Idempotent: rewrites file each call (admin can override post-install via edit + flock).
# No-op when not in master mode or peer SSH key absent.
# NOTE: This function is private by convention (_prefix) but is called cross-module
# from install.sh::_install_crons (in phase_complete). It is safe because install.sh
# sources lib/peer.sh in its source block — _configure_backup_remote_peer is available
# at the time _install_crons runs. Plan 03 will add a comment at the call site.
_configure_backup_remote_peer() {
    local mode="${AGMIND_MODE:-$(cluster_mode_read 2>/dev/null || echo single)}"
    [[ "$mode" == "master" ]] || return 0

    local peer_ip="${PEER_IP:-}"
    if [[ -z "$peer_ip" ]] && command -v jq >/dev/null 2>&1; then
        local _state="${AGMIND_CLUSTER_STATE_FILE:-/var/lib/agmind/state/cluster.json}"
        [[ -f "$_state" ]] && peer_ip="$(jq -r '.peer_ip // empty' "$_state" 2>/dev/null)"
    fi
    [[ -z "$peer_ip" ]] && return 0

    local peer_user="${PEER_USER:-${AGMIND_PEER_USER:-agmind2}}"
    local peer_key="${AGMIND_PEER_SSH_KEY:-/root/.ssh/agmind_peer_ed25519}"
    [[ -f "$peer_key" ]] || { log_warn "Peer SSH key missing (${peer_key}) — skipping backup remote target setup"; return 0; }

    # Strict re-validation (matches peer_deploy guards)
    [[ "$peer_ip" =~ ^192\.168\.100\.[0-9]{1,3}$ ]] || return 0
    [[ "$peer_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 0

    # Ensure remote dir exists, owned by peer_user, mode 0700
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes -i ${peer_key}"
    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" \
        "sudo -n mkdir -p /opt/agmind/backups-remote && sudo -n chown -R ${peer_user}: /opt/agmind/backups-remote && sudo -n chmod 700 /opt/agmind/backups-remote" \
        >/dev/null 2>&1 || { log_warn "Failed to prepare /opt/agmind/backups-remote on peer — skipping"; return 0; }

    # Render backup.conf with safe permissions (0600 root:root via tee redirect from current root context)
    cat > "${INSTALL_DIR}/scripts/backup.conf" <<BACKUPCONF
# AGMind Backup Configuration — auto-generated by install.sh
INSTALL_DIR=${INSTALL_DIR}
BACKUP_DIR=/var/backups/agmind
BACKUP_RETENTION_DAYS=7

# Cluster mode=master: mirror to peer Spark (4 TB SSD, ~3.4 TB free, QSFP DAC)
REMOTE_BACKUP_ENABLED=true
REMOTE_BACKUP_HOST=${peer_ip}
REMOTE_BACKUP_PORT=22
REMOTE_BACKUP_USER=${peer_user}
REMOTE_BACKUP_PATH=/opt/agmind/backups-remote
REMOTE_BACKUP_KEY=${peer_key}
BACKUPCONF
    chmod 600 "${INSTALL_DIR}/scripts/backup.conf"
    log_info "Backup remote target → ${peer_user}@${peer_ip}:/opt/agmind/backups-remote"
}
