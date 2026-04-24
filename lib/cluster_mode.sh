#!/usr/bin/env bash
# cluster_mode.sh — Dual-Spark cluster mode selection and persistence.
# Mode: single (no peer) | master (runs stack, peer runs vLLM) | worker (only vLLM)
# State: /var/lib/agmind/state/cluster.json
# Dependencies: common.sh (log_*), tui.sh (wt_menu), jq (>=1.6)
# Exports: AGMIND_MODE, AGMIND_CLUSTER_SUBNET
set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

AGMIND_CLUSTER_STATE_DIR="${AGMIND_CLUSTER_STATE_DIR:-/var/lib/agmind/state}"
AGMIND_CLUSTER_STATE_FILE="${AGMIND_CLUSTER_STATE_FILE:-${AGMIND_CLUSTER_STATE_DIR}/cluster.json}"
AGMIND_CLUSTER_SUBNET="${AGMIND_CLUSTER_SUBNET:-192.168.100.0/24}"

# ============================================================================
# READ — return persisted mode or empty
# ============================================================================

cluster_mode_read() {
    # AGMIND_MODE_OVERRIDE takes priority (CI / non-interactive)
    case "${AGMIND_MODE_OVERRIDE:-}" in
        single|master|worker)
            echo "${AGMIND_MODE_OVERRIDE}"
            return 0
            ;;
        "")
            ;;  # not set — fall through
        *)
            log_error "Invalid AGMIND_MODE_OVERRIDE='${AGMIND_MODE_OVERRIDE}' (valid: single|master|worker)"
            exit 1
            ;;
    esac

    if [[ ! -f "$AGMIND_CLUSTER_STATE_FILE" ]]; then
        echo ""
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq missing — cannot read ${AGMIND_CLUSTER_STATE_FILE}"
        echo ""
        return 0
    fi
    local saved
    saved="$(jq -r '.mode // empty' "$AGMIND_CLUSTER_STATE_FILE" 2>/dev/null || true)"
    case "$saved" in
        single|master|worker) echo "$saved" ;;
        *)                    echo "" ;;
    esac
}

# ============================================================================
# SAVE — atomic jq write of cluster.json
# ============================================================================

cluster_mode_save() {
    local mode="$1"
    local peer_hostname="${2:-}"
    local peer_ip="${3:-}"
    local subnet="${4:-$AGMIND_CLUSTER_SUBNET}"
    local status="${5:-configured}"

    case "$mode" in
        single|master|worker) ;;
        *) log_error "cluster_mode_save: invalid mode '$mode'"; return 1 ;;
    esac

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq required for cluster.json write — not installed"
        return 1
    fi

    mkdir -p "$AGMIND_CLUSTER_STATE_DIR"
    local tmp="${AGMIND_CLUSTER_STATE_FILE}.tmp.$$"
    if ! jq -n \
        --arg mode "$mode" \
        --arg peer_hostname "$peer_hostname" \
        --arg peer_ip "$peer_ip" \
        --arg subnet "$subnet" \
        --arg status "$status" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{mode: $mode,
          peer_hostname: $peer_hostname,
          peer_ip: $peer_ip,
          subnet: $subnet,
          status: $status,
          updated_at: $ts}' > "$tmp"; then
        rm -f "$tmp"
        log_error "cluster_mode_save: jq failed"
        return 1
    fi
    # Validate written JSON before replacing destination (defence in depth)
    if ! jq -e . "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log_error "cluster_mode_save: written JSON is invalid — rollback"
        return 1
    fi
    chmod 0644 "$tmp"
    mv "$tmp" "$AGMIND_CLUSTER_STATE_FILE"

    # Canonical compute-placement flag — single source of truth for downstream
    # modules (compose.sh, config.sh, models.sh, health.sh, install.sh).
    # Replaces ad-hoc "if AGMIND_MODE=master + jq cluster.json" duplicates.
    case "$mode" in
        master) export LLM_ON_PEER=true  ;;
        *)      export LLM_ON_PEER=false ;;
    esac
}

# ============================================================================
# UPDATE STATUS — non-destructive field update (mode/peer preserved)
# ============================================================================

cluster_status_update() {
    local new_status="$1"
    if [[ ! -f "$AGMIND_CLUSTER_STATE_FILE" ]]; then
        log_warn "cluster.json missing — status update skipped"
        return 0
    fi
    local current
    current="$(cat "$AGMIND_CLUSTER_STATE_FILE")"
    local tmp="${AGMIND_CLUSTER_STATE_FILE}.tmp.$$"
    if ! echo "$current" | jq \
        --arg status "$new_status" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {status: $status, updated_at: $ts}' > "$tmp"; then
        rm -f "$tmp"
        log_error "cluster_status_update: jq failed"
        return 1
    fi
    mv "$tmp" "$AGMIND_CLUSTER_STATE_FILE"
}

# ============================================================================
# SELECT — TUI mode selection with whiptail+readline fallback
# ============================================================================

# cluster_mode_select [peer_hostname] [peer_ip]
#   -> echoes selected mode (single|master|worker) to stdout
#   -> if peer not detected (both args empty), menu still shown but
#      workers/masters require a peer to make sense — UI warns and defaults single
cluster_mode_select() {
    local peer_hostname="${1:-}"
    local peer_ip="${2:-}"

    # 1. Priority: env override
    case "${AGMIND_MODE_OVERRIDE:-}" in
        single|master|worker) echo "${AGMIND_MODE_OVERRIDE}"; return 0 ;;
        "") ;;
        *)  log_error "Invalid AGMIND_MODE_OVERRIDE='${AGMIND_MODE_OVERRIDE}' (valid: single|master|worker)"
            exit 1 ;;
    esac

    # 2. Priority: persisted state (re-install idempotency)
    local saved
    saved="$(cluster_mode_read)"
    if [[ -n "$saved" ]]; then
        log_info "Cluster mode loaded from ${AGMIND_CLUSTER_STATE_FILE}: ${saved}"
        echo "$saved"
        return 0
    fi

    # 3. Priority: TUI prompt
    # MAJOR 5 FIX — ROADMAP Phase 2 SC#1 locks default=single (ALWAYS, even if peer detected).
    # Rationale: user may physically have QSFP linkup but not intend dual-Spark for THIS install.
    # We show the detected peer as a HINT but never pre-select master/worker — user must opt in.
    local title desc peer_label
    local default_tag="single"   # ALWAYS single per ROADMAP SC#1 — do not change
    if [[ -n "$peer_ip" ]]; then
        peer_label="Peer detected: ${peer_hostname:-unknown-host} @ ${peer_ip}"
        desc="Обнаружен второй AGmind узел (${peer_label}). Выберите режим развёртывания (default=single per ROADMAP SC#1):"
    else
        peer_label="No peer detected on ${AGMIND_CLUSTER_SUBNET}"
        desc="Второй узел не обнаружен. Режим single (без peer) выбран по умолчанию.
Если это ошибка (peer есть, но ещё не виден по QSFP) — выберите master/worker вручную.

${peer_label}"
    fi
    title="AGmind cluster mode"

    local choice
    if command -v wt_menu >/dev/null 2>&1; then
        choice="$(wt_menu "$title" "$desc" \
            "single" "Single-node — всё на этом хосте (рекомендуется если peer не нужен)" \
            "master" "Master — основной стек локально + vLLM на peer (для dual-Spark)" \
            "worker" "Worker — только vLLM на этом хосте (основной стек на другом)" \
        || true)"
        [[ -z "$choice" ]] && choice="$default_tag"
    else
        # readline fallback — no whiptail
        echo "" >&2
        echo "$title" >&2
        echo "$desc" >&2
        echo "" >&2
        echo "  1) single — всё локально" >&2
        echo "  2) master — стек локально + vLLM на peer" >&2
        echo "  3) worker — только vLLM на этом хосте" >&2
        echo "" >&2
        local ans
        local default_num="1"
        case "$default_tag" in
            single) default_num="1" ;;
            master) default_num="2" ;;
            worker) default_num="3" ;;
        esac
        read -rp "Выбор [1-3, default=${default_num}]: " ans </dev/tty || ans=""
        case "$ans" in
            1) choice="single" ;;
            2) choice="master" ;;
            3) choice="worker" ;;
            "") choice="$default_tag" ;;
            *) log_warn "Неверный выбор — использую default: $default_tag"; choice="$default_tag" ;;
        esac
    fi

    case "$choice" in
        single|master|worker) echo "$choice" ;;
        *) log_warn "Неверный ответ меню — использую default: $default_tag"; echo "$default_tag" ;;
    esac
}
