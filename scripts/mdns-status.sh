#!/usr/bin/env bash
# scripts/mdns-status.sh — AGmind mDNS diagnostics (agmind mdns-status)
# Four checks:
#   (a) Published agmind-*.local names resolve to primary uplink IP (via avahi-resolve)
#   (b) agmind-mdns.service unit is active
#   (c) UDP/5353 is empty or owned only by avahi-daemon (no NoMachine, iTunes, etc.)
#   (d) Primary uplink IP responds to ping
# Exit: 0 if all green, 1 if any issue. Output: human-readable OR --json.
#
# Non-root: check (c) requires root to read process names from ss. Without root we
# emit INFO (not WARN/FAIL) so regular-user invocation exits 0 if other checks pass.
set -euo pipefail

AGMIND_DIR="${AGMIND_DIR:-$(cd "$(dirname "$(realpath "$0")")/.." && pwd)}"
SCRIPTS_DIR="${AGMIND_DIR}/scripts"

# Source shared helpers. scripts/detect.sh is the runtime copy of lib/detect.sh
# made during install (phase_config _copy_runtime_files). Tests may source lib/detect.sh
# directly when AGMIND_DIR points at repo root.
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/detect.sh" 2>/dev/null \
    || source "${AGMIND_DIR}/lib/detect.sh" 2>/dev/null \
    || { echo "ERROR: cannot source detect.sh from ${SCRIPTS_DIR} or ${AGMIND_DIR}/lib" >&2; exit 2; }

# Colors (fallback if common.sh not sourced)
RED="${RED:-\033[0;31m}"; GREEN="${GREEN:-\033[0;32m}"; YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"; BOLD="${BOLD:-\033[1m}"; NC="${NC:-\033[0m}"

OUTPUT_JSON=false
case "${1:-}" in
    --json) OUTPUT_JSON=true ;;
    -h|--help)
        cat <<'EOF'
Usage: agmind mdns-status [--json]

Diagnose AGmind mDNS publishing. Four checks:
  a) published agmind-*.local names resolve to primary uplink
  b) agmind-mdns.service active
  c) UDP/5353 has only avahi-daemon
  d) primary uplink IP answers ping

Exit: 0 = all green, 1 = any issue.
EOF
        exit 0 ;;
esac

issues=0
json_checks=()

_human() { [[ "$OUTPUT_JSON" == "true" ]] || echo -e "$@"; }

_json_add() { json_checks+=("$1"); }

_check_ok()   {
    local msg="$1" key="$2" detail="$3"
    _human "  ${GREEN}[OK]${NC}   ${msg}"
    _json_add "{\"check\":\"${key}\",\"status\":\"ok\",\"detail\":\"${detail}\"}"
}

# Non-fatal INFO — does NOT increment issues. Used for skips that require elevation.
_check_info() {
    local msg="$1" key="$2" detail="$3"
    _human "  ${CYAN}[INFO]${NC} ${msg}"
    _json_add "{\"check\":\"${key}\",\"status\":\"info\",\"detail\":\"${detail}\"}"
}

_check_warn() {
    local msg="$1" key="$2" detail="$3"
    _human "  ${YELLOW}[WARN]${NC} ${msg}"
    issues=$((issues+1))
    _json_add "{\"check\":\"${key}\",\"status\":\"warn\",\"detail\":\"${detail}\"}"
}

_check_fail() {
    local msg="$1" key="$2" detail="$3"
    _human "  ${RED}[FAIL]${NC} ${msg}"
    issues=$((issues+1))
    _json_add "{\"check\":\"${key}\",\"status\":\"fail\",\"detail\":\"${detail}\"}"
}

_human "${BOLD}${CYAN}AGmind mDNS status${NC}"
_human ""

# Determine published names from .env (source of truth for ENABLE_* toggles).
ENV_FILE="${AGMIND_DIR}/docker/.env"
names=("agmind-dify")
if [[ -r "$ENV_FILE" ]]; then
    set +u
    # shellcheck source=/dev/null
    source "$ENV_FILE" 2>/dev/null || true
    set -u
    [[ "${ENABLE_OPENWEBUI:-false}" == "true" ]] && names+=("agmind-chat")
    [[ "${ENABLE_MINIO:-false}" == "true" ]]    && names+=("agmind-storage")
    [[ "${ENABLE_DBGPT:-false}" == "true" ]]    && names+=("agmind-dbgpt")
    [[ "${ENABLE_NOTEBOOK:-false}" == "true" ]] && names+=("agmind-notebook")
    [[ "${ENABLE_SEARXNG:-false}" == "true" ]]  && names+=("agmind-search")
    [[ "${ENABLE_CRAWL4AI:-false}" == "true" ]] && names+=("agmind-crawl")
fi

# ── (a) Published names resolve to primary uplink IP ────────────────────────
_human "${BOLD}(a) Published names:${NC}"
primary_ip=""
primary_ip="$(_mdns_get_primary_ip 2>/dev/null || true)"
if [[ -z "$primary_ip" ]]; then
    _check_fail "cannot determine primary uplink IP (no default route?)" "primary_ip" "empty"
else
    _check_ok "primary uplink IP: ${primary_ip}" "primary_ip" "$primary_ip"
fi
if command -v avahi-resolve >/dev/null 2>&1; then
    for name in "${names[@]}"; do
        resolved=""
        resolved="$(avahi-resolve -n -4 "${name}.local" 2>/dev/null | awk 'NR==1 {print $2}' || true)"
        if [[ -z "$resolved" ]]; then
            _check_fail "${name}.local: no resolution (avahi-resolve timeout)" "resolve_${name}" "timeout"
        elif [[ -n "$primary_ip" && "$resolved" != "$primary_ip" ]]; then
            _check_warn "${name}.local: resolves to ${resolved} (expected ${primary_ip})" "resolve_${name}" "$resolved"
        else
            _check_ok "${name}.local -> ${resolved}" "resolve_${name}" "$resolved"
        fi
    done
else
    _check_warn "avahi-resolve not available — install avahi-utils" "avahi_utils" "missing"
fi

# ── (b) agmind-mdns.service active ──────────────────────────────────────────
_human ""
_human "${BOLD}(b) agmind-mdns.service:${NC}"
if command -v systemctl >/dev/null 2>&1; then
    state=""
    state="$(systemctl is-active agmind-mdns.service 2>/dev/null || true)"
    [[ -z "$state" ]] && state="missing"
    case "$state" in
        active)   _check_ok "agmind-mdns.service: active" "unit_active" "active" ;;
        inactive) _check_fail "agmind-mdns.service: inactive (should be active)" "unit_active" "inactive" ;;
        failed)   _check_fail "agmind-mdns.service: failed — see journalctl -u agmind-mdns" "unit_active" "failed" ;;
        missing)  _check_fail "agmind-mdns.service: not installed (re-run install.sh)" "unit_active" "missing" ;;
        *)        _check_warn "agmind-mdns.service: unknown state '${state}'" "unit_active" "$state" ;;
    esac
else
    _check_warn "systemctl not available" "unit_active" "no_systemctl"
fi

# ── (c) UDP/5353 foreign responder check ────────────────────────────────────
_human ""
_human "${BOLD}(c) UDP/5353 responder:${NC}"
if [[ "$EUID" -ne 0 ]]; then
    # Non-root: INFO not WARN/FAIL — skip does not count as issue (WARNING 5 fix).
    _check_info "skipped: requires root for ss process names (try: sudo agmind mdns-status)" "foreign_responder" "skipped_no_root"
elif declare -F _assert_no_foreign_mdns >/dev/null 2>&1; then
    set +e
    _assert_no_foreign_mdns >/dev/null 2>&1
    foreign_rc=$?
    set -e
    if [[ $foreign_rc -eq 0 ]]; then
        _check_ok "UDP/5353: only avahi-daemon (or none)" "foreign_responder" "clean"
    else
        if [[ "$OUTPUT_JSON" != "true" ]]; then
            _assert_no_foreign_mdns 2>&1 || true
        fi
        _check_fail "UDP/5353: foreign responder present (see stderr for fix)" "foreign_responder" "foreign_present"
    fi
else
    _check_warn "_assert_no_foreign_mdns helper missing (lib/detect.sh not loaded)" "foreign_responder" "helper_missing"
fi

# ── (d) Primary uplink IP ping ───────────────────────────────────────────────
_human ""
_human "${BOLD}(d) Primary uplink ping:${NC}"
if [[ -z "${primary_ip}" ]]; then
    _check_warn "skipped — no primary IP" "ping_uplink" "skipped_no_ip"
elif ping -c 1 -W 2 "$primary_ip" >/dev/null 2>&1; then
    _check_ok "ping ${primary_ip}: ok" "ping_uplink" "pong"
else
    _check_fail "ping ${primary_ip}: timeout (uplink may be down)" "ping_uplink" "timeout"
fi

# ── Final output ─────────────────────────────────────────────────────────────
if [[ "$OUTPUT_JSON" == "true" ]]; then
    # Build JSON array manually (no jq dependency)
    joined=""
    first=true
    for item in "${json_checks[@]}"; do
        if [[ "$first" == "true" ]]; then
            joined="${item}"
            first=false
        else
            joined="${joined},${item}"
        fi
    done
    echo "{\"issues\":${issues},\"primary_ip\":\"${primary_ip}\",\"checks\":[${joined}]}"
else
    _human ""
    if [[ $issues -eq 0 ]]; then
        _human "${GREEN}mDNS: OK${NC}"
    else
        _human "${RED}mDNS: ${issues} issue(s) — see above${NC}"
    fi
fi

exit "$issues"
