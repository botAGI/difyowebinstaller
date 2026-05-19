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
# Notes: After vLLM is up, restricts peer :8000 to master QSFP IP / LAN subnet via
#   idempotent ufw/iptables rule applied on peer over ssh (non-fatal, defence-in-depth). See SC4.
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
# PRIVATE HELPERS — master-side (run on master, not via ssh)
# ============================================================================

# Stage master-side MASQUERADE NAT so the peer COULD route 192.168.100.0/24 →
# master's WAN via QSFP gateway (master IP 192.168.100.1). Idempotent.
# Phase A only: just enables forwarding + adds one POSTROUTING rule + persists.
# Phase B (peer default route swap to 192.168.100.1) is BACKLOG 999.12 — too risky
# to auto-toggle (could break wifi-WAN fallback on the peer side).
#
# Detection rules:
# - WAN interface = output of `ip route get 1.1.1.1` (the dev that leaves the box)
# - REFUSE if WAN interface IS the QSFP itself (192.168.100.x subnet) — that
#   would NAT through the destination of the route, which is nonsense
# - REFUSE if WAN interface is loopback or empty (no internet on master)
#
# Persistence:
# - sysctl: /etc/sysctl.d/99-agmind-peer-nat.conf  (survives reboot)
# - iptables: prefer netfilter-persistent (apt-get install -y if absent),
#   fallback to a tiny systemd oneshot that restores /etc/agmind/peer-nat.rules
#   at boot.
#
# Non-fatal: failure logs a warn and returns 1; caller (_deploy_image_to_peer)
# treats it as best-effort and continues with the existing wifi-WAN pull path.
_setup_master_nat() {
    local _qsfp_subnet="${AGMIND_CLUSTER_SUBNET:-192.168.100.0/24}"
    local _wan_if
    _wan_if="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [[ -z "$_wan_if" || "$_wan_if" == "lo" ]]; then
        log_warn "Master NAT: cannot detect a WAN interface (route to 1.1.1.1 missing/lo) — skipping"
        return 1
    fi
    # Refuse to MASQUERADE through the QSFP subnet itself (would be the destination).
    local _wan_addr
    _wan_addr="$(ip -4 -o addr show "$_wan_if" 2>/dev/null | awk '{print $4}' | head -1)"
    if [[ "$_wan_addr" == 192.168.100.* ]]; then
        log_warn "Master NAT: WAN interface ${_wan_if} is on the QSFP subnet (${_wan_addr}) — refusing to MASQUERADE through cluster fabric"
        return 1
    fi

    # 1. ip_forward (immediate + persistent)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 \
        || { log_warn "Master NAT: sysctl ip_forward=1 failed (need root)"; return 1; }
    local _sysctl_persist="/etc/sysctl.d/99-agmind-peer-nat.conf"
    if [[ ! -f "$_sysctl_persist" ]] || ! grep -q "^net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1" "$_sysctl_persist" 2>/dev/null; then
        { printf 'net.ipv4.ip_forward = 1\n' > "$_sysctl_persist"; } 2>/dev/null \
            || log_warn "Master NAT: could not persist sysctl to ${_sysctl_persist}"
        chmod 644 "$_sysctl_persist" 2>/dev/null || true
    fi

    # 2. iptables POSTROUTING MASQUERADE — check-or-add (idempotent)
    if ! iptables -t nat -C POSTROUTING -s "$_qsfp_subnet" -o "$_wan_if" -j MASQUERADE 2>/dev/null; then
        if ! iptables -t nat -A POSTROUTING -s "$_qsfp_subnet" -o "$_wan_if" -j MASQUERADE 2>/dev/null; then
            log_warn "Master NAT: iptables POSTROUTING MASQUERADE add failed"
            return 1
        fi
    fi

    # 3. Persist iptables across reboot — prefer netfilter-persistent, else systemd oneshot.
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 \
            || log_warn "Master NAT: netfilter-persistent save returned non-zero (rule still active until reboot)"
    elif command -v apt-get >/dev/null 2>&1 && [[ "${AGMIND_AUTOINSTALL_NETFILTER:-true}" == "true" ]]; then
        # Best-effort install (Ubuntu/Debian; DGX OS is Ubuntu-based). Non-fatal.
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iptables-persistent >/dev/null 2>&1 \
            && netfilter-persistent save >/dev/null 2>&1 \
            || log_warn "Master NAT: iptables-persistent install/save best-effort failed — falling back to systemd oneshot"
    fi
    # Fallback: if netfilter-persistent still absent, write a systemd oneshot that
    # restores rules on boot. Self-contained, no apt dependency.
    if ! command -v netfilter-persistent >/dev/null 2>&1; then
        local _rules_dir="/etc/agmind" _rules_file="/etc/agmind/peer-nat.rules"
        local _unit="/etc/systemd/system/agmind-peer-nat.service"
        mkdir -p "$_rules_dir" 2>/dev/null || true
        { iptables-save -t nat 2>/dev/null > "$_rules_file"; } 2>/dev/null \
            || log_warn "Master NAT: iptables-save failed"
        chmod 644 "$_rules_file" 2>/dev/null || true
        if [[ ! -f "$_unit" ]]; then
            cat > "$_unit" <<'UNIT'
[Unit]
Description=AGmind peer NAT (restore MASQUERADE rules for QSFP cluster)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore --noflush /etc/agmind/peer-nat.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
            chmod 644 "$_unit" 2>/dev/null || true
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable agmind-peer-nat.service >/dev/null 2>&1 || true
        fi
    fi

    log_success "Master NAT staged: ${_qsfp_subnet} → MASQUERADE via ${_wan_if}, ip_forward persistent"
    return 0
}

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
    # SEC-PEER-01: lock down secrets. scp preserves umask of $peer_user (typically
    # 022 → mode 0644), leaving every secret in the worker .env world-readable
    # for any account that gains shell on peer. Force 0600 root:root immediately.
    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" \
        "sudo -n chmod 600 ${peer_dir}/.env && sudo -n chown root:root ${peer_dir}/.env" \
        >/dev/null 2>&1 || {
        log_error "Failed to lock down peer .env permissions"
        cluster_status_update "failed" 2>/dev/null || true
        return 1
    }

    # 5b. Copy vllm-config/ (entrypoint wrapper + dflash.json) to peer.
    # MUST land BEFORE `docker compose up` — otherwise the bind-mount source
    # path does not exist and docker silently creates an EMPTY DIRECTORY on
    # target (default behavior for missing bind-mount source). This produced
    # the 2026-05-18 regression where /etc/vllm/dflash.json appeared as a
    # directory inside the container, breaking both the legacy file-mount
    # attempt and the new entrypoint wrapper.
    local template_vllm_config="${TEMPLATE_DIR:-${INSTALLER_DIR}/templates}/vllm-config"
    if [[ -d "${template_vllm_config}" ]]; then
        # shellcheck disable=SC2086
        ssh $ssh_opts "${peer_user}@${peer_ip}" "mkdir -p ${peer_dir}/vllm-config" >/dev/null 2>&1
        # shellcheck disable=SC2086
        if ! scp $ssh_opts -r "${template_vllm_config}/." \
                "${peer_user}@${peer_ip}:${peer_dir}/vllm-config/" >/dev/null 2>&1; then
            log_error "scp vllm-config/ to peer failed"
            cluster_status_update "failed" 2>/dev/null || true
            return 1
        fi
        # Ensure entrypoint.sh is executable on peer (scp inherits source mode,
        # but core.fileMode=false in our repo means the master copy may be 0644
        # in the index even if 0755 on disk — defensive chmod).
        # shellcheck disable=SC2086
        ssh $ssh_opts "${peer_user}@${peer_ip}" \
            "chmod 0755 ${peer_dir}/vllm-config/entrypoint.sh 2>/dev/null || true" \
            >/dev/null 2>&1
    else
        log_warn "Template ${template_vllm_config} not found — peer vLLM may fail to start"
    fi

    # 6. Install gpu-metrics.sh on peer + cron + textfile dir.
    # Feeds peer node-exporter textfile collector (enabled via compose volume +
    # --collector.textfile.directory=/textfile) so agmind_gpu_* HW metrics become
    # visible to Prometheus peer-node-exporter scrape, powering Grafana
    # "AGMind GPU — worker" dashboard (gauges temp/util/power/clock).
    _deploy_peer_gpu_metrics "$peer_ip" "$peer_user" "$ssh_opts" "$peer_dir" \
        || log_warn "Peer GPU metrics setup had issues (non-fatal — dashboard HW panels may stay empty)"

    # 7. docker compose up on peer
    # NOTE: force-recreate trap applies to master stack (Redis/Celery state — see docs/adr/0007-force-recreate-trap).
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

    # 8.5. Restrict peer vLLM :8000 to master QSFP IP / LAN subnet (SC4 / D-09).
    # Idempotent ufw/iptables rule applied on peer via ssh sudo -n; non-fatal.
    _apply_peer_vllm_firewall "$peer_ip" "$peer_user" "$ssh_opts"

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
VLLM_EXTRA_ARGS='${VLLM_EXTRA_ARGS:---kv-cache-dtype fp8 --enable-prefix-caching --enforce-eager}'
# JSON-typed vLLM args travel via dedicated env vars (consumed by
# templates/vllm-config/entrypoint.sh, NOT by VLLM_EXTRA_ARGS). They MUST be
# forwarded to the peer .env or DFlash/YaRN silently disappear from peer vLLM.
# Regression caught 2026-05-19 fresh-install: master had the value, peer .env
# rendered without these lines → speculative_config=None in vLLM logs even
# though wizard set it. See CLAUDE.md §8 "vLLM CLI: --speculative-config is
# JSON, not path".
VLLM_SPECULATIVE_CONFIG='${VLLM_SPECULATIVE_CONFIG:-}'
VLLM_ROPE_SCALING_CONFIG='${VLLM_ROPE_SCALING_CONFIG:-}'
VLLM_CUDA_SUFFIX=${VLLM_CUDA_SUFFIX:-}
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-65536}
# Peer = dedicated under vLLM (no docling/embed/rerank sharing GPU).
# Override master's shared-budget defaults with peer-dedicated values:
# - 0.85 util × 121 GiB unified = 103 GiB vLLM, 18 GiB OS headroom
# - 0.90 too tight for OS+Docker+ssh+avahi baseline.
VLLM_GPU_MEM_UTIL=${AGMIND_PEER_VLLM_GPU_MEM_UTIL:-0.85}
VLLM_MEM_LIMIT=${AGMIND_PEER_VLLM_MEM_LIMIT:-110g}
VLLM_CUDA_DEVICE=${VLLM_CUDA_DEVICE:-0}
HF_TOKEN=${HF_TOKEN:-}
# NVIDIA — compute,utility required for NVML/libcuda (see docs/adr/0005-driver-580-hold)
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

    # Stage master-side MASQUERADE so the peer COULD route via master QSFP if its
    # own WAN flakes. Phase A only — peer route swap is BACKLOG 999.12 (manual).
    # Non-fatal: skip on failure (existing wifi-WAN pull path still works).
    _setup_master_nat || log_warn "Master NAT setup had issues — peer may need own WAN"

    # 1. If peer already has image locally — skip (idempotent).
    # shellcheck disable=SC2086
    if ssh $ssh_opts "${peer_user}@${peer_ip}" \
            "sudo -n docker image inspect ${image} >/dev/null 2>&1"; then
        log_info "Image ${image} already present on peer — skipping transfer"
        return 0
    fi

    # 2. Prefer peer-side direct pull (saves 10+ GB SSH transfer if peer has WAN).
    # FIX 2026-05-15: GHCR rate-limit / transient TLS handshake timeouts hit
    # us here repeatedly — both peer wifi flakes AND master fallback failed on
    # first attempt, aborting phase 8. Retry both with exponential backoff
    # (15s / 60s / 180s) — covers transient registry hiccups + lets peer
    # wifi/DNS settle. Total worst case: ~4 min before bailing.
    local _attempt _delay _peer_ok=0
    for _attempt in 1 2 3; do
        log_info "Attempting peer-side pull of ${image} (attempt ${_attempt}/3 — peer's own WAN; master NAT staged, peer can manually route via 192.168.100.1 if needed)..."
        # shellcheck disable=SC2086
        if ssh $ssh_opts "${peer_user}@${peer_ip}" \
                "sudo -n docker pull ${image}" 2>&1 | tail -5; then
            # shellcheck disable=SC2086
            if ssh $ssh_opts "${peer_user}@${peer_ip}" \
                    "sudo -n docker image inspect ${image} >/dev/null 2>&1"; then
                log_success "Peer pulled ${image} directly"
                _peer_ok=1
                break
            fi
        fi
        if [[ $_attempt -lt 3 ]]; then
            _delay=$(( _attempt * 60 - 45 ))  # 15s, 75s — let registry/wifi recover
            log_warn "Peer-side pull attempt ${_attempt}/3 failed — sleeping ${_delay}s before retry..."
            sleep "$_delay"
        fi
    done
    [[ $_peer_ok -eq 1 ]] && return 0
    log_warn "Peer-side pull failed after 3 attempts — falling back to master save|load transfer"

    # 3. Fallback: master must have image locally to save. Pull if absent.
    # Also retry the master-side pull — GHCR rate-limit hits both nodes equally.
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
        local _master_ok=0
        for _attempt in 1 2 3; do
            log_info "Pulling ${image} on master for transfer (attempt ${_attempt}/3)..."
            if docker pull "${image}"; then _master_ok=1; break; fi
            if [[ $_attempt -lt 3 ]]; then
                _delay=$(( _attempt * 60 - 45 ))
                log_warn "Master pull attempt ${_attempt}/3 failed — sleeping ${_delay}s before retry..."
                sleep "$_delay"
            fi
        done
        if [[ $_master_ok -ne 1 ]]; then
            log_error "Master pull of ${image} failed after 3 attempts — cannot transfer to peer"
            log_error "  Diagnose: docker manifest inspect ${image}   (check GHCR reachability)"
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

# Returns the master's IP on the QSFP cluster subnet (192.168.100.0/24).
# Used to derive master_ip for the peer vLLM firewall rule (SC4 / D-09).
# Fallback: hardcoded 192.168.100.1 (NAT-on-demand master gateway per project_nat_qsfp_gateway).
_qsfp_master_ip() {
    ip -4 addr show 2>/dev/null | awk '/inet 192\.168\.100\./{print $2}' | cut -d/ -f1 | head -1
}

# Apply idempotent firewall rule on peer restricting vLLM :8000 to the master QSFP IP
# / LAN subnet (192.168.100.0/24). Uses ufw if active on peer, else iptables.
# All commands run via sudo -n on the peer (peer user has NOPASSWD sudo per project_spark_cluster).
# Non-fatal: ssh/sudo failure logs a warn and continues — defence-in-depth (peer is already
# air-gapped via wifi-off). Re-running is safe: check-before-add prevents duplicate rules.
# shellcheck disable=SC2086
_apply_peer_vllm_firewall() {
    local peer_ip="$1" peer_user="$2" ssh_opts="$3"
    local master_ip; master_ip="$(_qsfp_master_ip 2>/dev/null || true)"
    [[ -z "$master_ip" ]] && master_ip="192.168.100.1"
    local lan_subnet="${AGMIND_CLUSTER_SUBNET:-192.168.100.0/24}"

    log_info "Applying peer :8000 firewall rule (restrict to ${lan_subnet}) on ${peer_ip}..."
    # shellcheck disable=SC2086
    ssh $ssh_opts "${peer_user}@${peer_ip}" "
set -e
if command -v ufw >/dev/null 2>&1 && sudo -n ufw status 2>/dev/null | grep -q 'active'; then
    # ufw path: idempotent — only add if not already present
    sudo -n ufw status | grep -q '8000.*${lan_subnet}' \
        || { sudo -n ufw allow from ${lan_subnet} to any port 8000 comment 'AGmind vLLM LAN-only'; \
             sudo -n ufw deny 8000 comment 'AGmind vLLM block non-LAN'; }
else
    # iptables path: idempotent check-before-insert
    sudo -n iptables -C INPUT -p tcp --dport 8000 -s ${lan_subnet} -j ACCEPT 2>/dev/null \
        || sudo -n iptables -I INPUT -p tcp --dport 8000 -s ${lan_subnet} -j ACCEPT
    sudo -n iptables -C INPUT -p tcp --dport 8000 -j DROP 2>/dev/null \
        || sudo -n iptables -A INPUT -p tcp --dport 8000 -j DROP
    command -v netfilter-persistent >/dev/null 2>&1 || command -v iptables-save >/dev/null 2>&1 \
        && echo '(note: install iptables-persistent on the peer to persist this rule across reboots)' \
        || true
fi
" 2>/dev/null \
        && log_success "peer :8000 restricted to ${lan_subnet} (master ${master_ip})" \
        || log_warn "peer :8000 firewall rule not applied (non-fatal — defence-in-depth; peer is air-gapped via wifi-off)"
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
