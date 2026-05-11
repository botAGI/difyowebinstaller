#!/usr/bin/env bash
# doctor.sh — System diagnostics aggregator: preflight + health + support bundle.
# Dependencies: common.sh (log_*, validate_*, colors), detect.sh (run_diagnostics,
#   preflight_checks, _assert_no_foreign_mdns), health.sh (check_all, verify_services,
#   _doctor_peer, check_gpu_status), security.sh (pin_nvidia_driver_dgx_spark),
#   service-map.sh (NAME_TO_SERVICES, ALL_COMPOSE_PROFILES).
# Functions: doctor_run([--preflight|--full] [--json] [--fix [--dry-run]] [--bundle] [--peer]),
#   doctor_check_arch_driver/docker/kernel/dns_mdns/gpu/resources/ports/images/models/
#   services/security_exposure/install_state/peer
# Expects: INSTALL_DIR (default /opt/agmind), ENV_FILE
# Exports: DOCTOR_REGISTRY (array), DOCTOR_ERRORS, DOCTOR_WARNINGS
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
ENV_FILE="${ENV_FILE:-${INSTALL_DIR}/docker/.env}"

# ============================================================================
# FALLBACK SHIMS (only active when sourced without common.sh / health.sh)
# ============================================================================

# Fallback log functions when sourced without common.sh (mirror lib/health.sh:11-14)
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

# _check shim — maps OK|WARN|FAIL|SKIP to colored output lines.
# Signature mirrors scripts/agmind.sh::cmd_doctor inline _check (lines 165-179).
# Guard: only define if not already defined by a calling script.
# WHY: lib/health.sh::_doctor_peer calls _check as an injected dependency.
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

# ============================================================================
# REGISTRY HELPERS
# ============================================================================

# Registry — indexed array of \x1f-delimited records (7 fields):
#   id | category | severity | message | fix_hint | fixable | fix_cmd
# WHY \x1f: ASCII Unit Separator — not present in normal diagnostic messages.
SEP=$'\x1f'
DOCTOR_REGISTRY=()
DOCTOR_ERRORS=0
DOCTOR_WARNINGS=0

# Category display labels (D-04 order)
declare -A CATEGORY_LABELS=(
    [arch-driver]="Arch + Driver"
    [docker]="Docker + Compose"
    [kernel-params]="Kernel Params"
    [dns-mdns]="DNS + mDNS"
    [gpu]="GPU"
    [resources]="Resources"
    [ports]="Ports"
    [images]="Images"
    [models]="Models"
    [services]="Services"
    [security-exposure]="Security Exposure"
    [install-state]="Install State"
    [peer]="Peer Node"
)

_registry_reset() {
    DOCTOR_REGISTRY=()
    DOCTOR_ERRORS=0
    DOCTOR_WARNINGS=0
}

# _registry_add id category severity message [fix_hint] [fixable] [fix_cmd]
_registry_add() {
    # Usage: _registry_add id category severity message fix_hint fixable fix_cmd
    local id="$1" category="$2" severity="$3" message="$4" \
          fix_hint="${5:-}" fixable="${6:-false}" fix_cmd="${7:-}"
    DOCTOR_REGISTRY+=("${id}${SEP}${category}${SEP}${severity}${SEP}${message}${SEP}${fix_hint}${SEP}${fixable}${SEP}${fix_cmd}")
}

# _registry_count — tallies DOCTOR_ERRORS and DOCTOR_WARNINGS from registry
_registry_count() {
    DOCTOR_ERRORS=0
    DOCTOR_WARNINGS=0
    local entry id category sev msg fix_hint fixable _fix_cmd
    for entry in "${DOCTOR_REGISTRY[@]+"${DOCTOR_REGISTRY[@]}"}"; do
        IFS=$'\x1f' read -r id category sev msg fix_hint fixable _fix_cmd <<< "$entry"
        case "$sev" in
            FAIL) DOCTOR_ERRORS=$((DOCTOR_ERRORS+1)) ;;
            WARN) DOCTOR_WARNINGS=$((DOCTOR_WARNINGS+1)) ;;
        esac
    done
}

# _registry_render_human — print colored check output grouped by category
_registry_render_human() {
    local entry id category sev msg fix_hint fixable _fix_cmd
    local cur_cat=""
    for entry in "${DOCTOR_REGISTRY[@]+"${DOCTOR_REGISTRY[@]}"}"; do
        IFS=$'\x1f' read -r id category sev msg fix_hint fixable _fix_cmd <<< "$entry"
        # Print section banner on category change
        if [[ "$category" != "$cur_cat" ]]; then
            echo -e "\n${BOLD}${CATEGORY_LABELS[$category]:-$category}:${NC}"
            cur_cat="$category"
        fi
        case "$sev" in
            OK)   echo -e "  ${GREEN}[OK]${NC}   ${msg}" ;;
            WARN) echo -e "  ${YELLOW}[WARN]${NC} ${msg}"
                  [[ -n "$fix_hint" ]] && echo -e "         ${CYAN}-> ${fix_hint}${NC}" ;;
            FAIL) echo -e "  ${RED}[FAIL]${NC} ${msg}"
                  [[ -n "$fix_hint" ]] && echo -e "         ${CYAN}-> ${fix_hint}${NC}" ;;
            SKIP) echo -e "  ${CYAN}[SKIP]${NC} ${msg}" ;;
        esac
    done
}

# _registry_render_json — emit a JSON summary object
# WHY python3: shell string concat breaks on quotes/newlines in messages (Edge Case 7).
_registry_render_json() {
    local entry id category sev msg fix_hint fixable fix_cmd
    local checks_json="" first=1
    _registry_count
    for entry in "${DOCTOR_REGISTRY[@]+"${DOCTOR_REGISTRY[@]}"}"; do
        IFS=$'\x1f' read -r id category sev msg fix_hint fixable fix_cmd <<< "$entry"
        local rec
        rec="$(python3 -c "
import json, sys
rec = {
    'id': sys.argv[1],
    'category': sys.argv[2],
    'severity': sys.argv[3],
    'message': sys.argv[4],
    'fix_hint': sys.argv[5],
    'fixable': sys.argv[6] == 'true',
    'fix_cmd': sys.argv[7],
}
print(json.dumps(rec))
" "$id" "$category" "$sev" "$msg" "$fix_hint" "$fixable" "$fix_cmd")"
        if [[ "$first" -eq 1 ]]; then
            checks_json="$rec"
            first=0
        else
            checks_json="${checks_json},${rec}"
        fi
    done
    # Determine overall status string
    local status="ok"
    [[ "$DOCTOR_WARNINGS" -gt 0 ]] && status="warn"
    [[ "$DOCTOR_ERRORS"   -gt 0 ]] && status="fail"
    printf '{"status":"%s","errors":%d,"warnings":%d,"checks":[%s]}\n' \
        "$status" "$DOCTOR_ERRORS" "$DOCTOR_WARNINGS" "$checks_json"
}

# ============================================================================
# CHECK FUNCTIONS (stubs — bodies filled in 01-02/01-03)
# ============================================================================
# Each stub adds a single SKIP record so doctor_run returns 0 on the skeleton.
# WHY D-04 order: arch-driver → docker → kernel-params → dns-mdns → gpu →
#   resources → ports → images → models → services → security-exposure →
#   install-state → peer (CONTEXT.md D-04)

doctor_check_arch_driver() {
    # Stub: will check uname -m, nvidia-smi driver version + apt-mark pin (01-02)
    # WHY: aarch64-only since v3.1; driver 580 HOLD mandatory (CLAUDE.md §6/§8)
    _registry_add "arch_driver_stub" "arch-driver" "SKIP" \
        "arch+driver checks not implemented yet" "" false ""
}

doctor_check_docker() {
    # Stub: will check docker version, compose version, daemon health (01-02)
    _registry_add "docker_stub" "docker" "SKIP" \
        "docker checks not implemented yet" "" false ""
}

doctor_check_kernel() {
    # Stub: will check vm.max_map_count (≥262144 for ES/RAGFlow) (01-02)
    # WHY WARN/FAIL: ES bootstrap hard-fails if < 262144 (CLAUDE.md §8)
    _registry_add "kernel_stub" "kernel-params" "SKIP" \
        "kernel param checks not implemented yet" "" false ""
}

doctor_check_dns_mdns() {
    # Stub: will check DNS resolve, mdns-status.sh, agmind-mdns.service,
    #   foreign :5353 responder via _assert_no_foreign_mdns (01-02)
    # WHY: dead mDNS / foreign responder are known §8 failure classes
    _registry_add "dns_mdns_stub" "dns-mdns" "SKIP" \
        "DNS+mDNS checks not implemented yet" "" false ""
}

doctor_check_gpu() {
    # Stub: will check host nvidia-smi, GPU-in-container visibility,
    #   NVIDIA_DRIVER_CAPABILITIES env in running GPU containers (01-02)
    # WHY: NVIDIA_DRIVER_CAPABILITIES=compute,utility mandatory on Spark (CLAUDE.md §8)
    _registry_add "gpu_stub" "gpu" "SKIP" \
        "GPU checks not implemented yet" "" false ""
}

doctor_check_resources() {
    # Stub: will check disk free, RAM total, swap (01-02)
    _registry_add "resources_stub" "resources" "SKIP" \
        "resource checks not implemented yet" "" false ""
}

doctor_check_ports() {
    # Stub: will check port conflicts (80/443) + exposed 0.0.0.0 bindings (01-02)
    _registry_add "ports_stub" "ports" "SKIP" \
        "port checks not implemented yet" "" false ""
}

doctor_check_images() {
    # Stub: will check local docker image inspect per compose image:tag (01-02)
    # WHY: catches LLM-hallucinated tags before docker pull fails (CLAUDE.md §8)
    _registry_add "images_stub" "images" "SKIP" \
        "image availability checks not implemented yet" "" false ""
}

doctor_check_models() {
    # Stub: will check model cache files (vllm cache, docling OCR cyrillic_g2.pth) (01-02)
    # WHY: missing OCR model = silent cyrillic fail (CLAUDE.md §8 docling specifics)
    _registry_add "models_stub" "models" "SKIP" \
        "model file checks not implemented yet" "" false ""
}

doctor_check_services() {
    # Stub: will wrap lib/health.sh::check_all / verify_services (01-02)
    _registry_add "services_stub" "services" "SKIP" \
        "service health checks not implemented yet" "" false ""
}

doctor_check_security_exposure() {
    # Stub: will check exposed ports + docker.sock consumers (Phase 7 subset) (01-02)
    _registry_add "security_exposure_stub" "security-exposure" "SKIP" \
        "security exposure checks not implemented yet" "" false ""
}

doctor_check_install_state() {
    # Stub: will check .install_phase, scripts/loadtest/*.js, install.log errors (01-02)
    # WHY: missing loadtest scripts = install whitelist regression (CLAUDE.md §8)
    _registry_add "install_state_stub" "install-state" "SKIP" \
        "install state checks not implemented yet" "" false ""
}

doctor_check_peer() {
    # Stub: will wrap lib/health.sh::_doctor_peer when cluster.json present (01-02)
    # WHY D-04: peer is last — only if cluster.json exists (LLM_ON_PEER aware)
    _registry_add "peer_stub" "peer" "SKIP" \
        "peer node checks not implemented yet" "" false ""
}

# ============================================================================
# FIX + BUNDLE (stubs — bodies filled in 01-02/01-03)
# ============================================================================

# _registry_fix_all [--dry-run] — iterate fixable=true records, apply fix_cmd.
# WHY D-08: only idempotent, non-destructive fixes: sysctl, mDNS restart, driver pin.
_registry_fix_all() {
    local dry_run=false
    [[ "${1:-}" == "--dry-run" ]] && dry_run=true
    # Stub — implementation in 01-02
    return 0
}

# _doctor_bundle — create sanitized support archive.
# WHY D-13/D-14/D-15: tar.gz with whitelist + post-collection scrub + self-test gate.
_doctor_bundle() {
    log_error "bundle not implemented (01-03)"
    return 2
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# doctor_run [--preflight|--full] [--json] [--fix [--dry-run]] [--bundle] [--peer]
# Exit codes (D-05): 0 = all OK/SKIP, 1 = WARN, 2 = FAIL.
# WHY skeleton exits 0: all checks are SKIP stubs — green skeleton per 01-VALIDATION.md.
doctor_run() {
    local output_json=false
    local do_fix=false
    local dry_run=false
    local do_bundle=false
    # mode and peer_only are used by 01-02 check function bodies.
    # Store in _doctor_mode/_doctor_peer_only so shellcheck sees a use via export.
    _doctor_mode="full"
    _doctor_peer_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --preflight) _doctor_mode="preflight" ;;
            --full)      _doctor_mode="full" ;;
            --json)      output_json=true ;;
            --fix)       do_fix=true ;;
            --dry-run)   dry_run=true ;;
            --bundle)    do_bundle=true ;;
            --peer)      _doctor_peer_only=true ;;
            *)
                log_warn "doctor: unknown flag '$1' (ignored)"
                ;;
        esac
        shift
    done

    # Reset registry for idempotent invocations (Pitfall 4)
    _registry_reset

    # Bundle shortcut — delegates to _doctor_bundle (01-03 fills body)
    if [[ "$do_bundle" == "true" ]]; then
        _doctor_bundle
        return $?
    fi

    # Call all 13 stub check functions in D-04 category order
    doctor_check_arch_driver
    doctor_check_docker
    doctor_check_kernel
    doctor_check_dns_mdns
    doctor_check_gpu
    doctor_check_resources
    doctor_check_ports
    doctor_check_images
    doctor_check_models
    doctor_check_services
    doctor_check_security_exposure
    doctor_check_install_state
    doctor_check_peer

    # Auto-fix pass (stub in this plan; 01-02 fills body)
    if [[ "$do_fix" == "true" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            _registry_fix_all --dry-run
        else
            _registry_fix_all
        fi
    fi

    # Tally counts
    _registry_count

    # Render output
    if [[ "$output_json" == "true" ]]; then
        _registry_render_json
    else
        _registry_render_human
        echo ""
        echo "  Errors: ${DOCTOR_ERRORS}   Warnings: ${DOCTOR_WARNINGS}"
    fi

    # Exit codes D-05: 0 = all OK/SKIP, 1 = WARN, 2 = FAIL
    if [[ "$DOCTOR_ERRORS" -gt 0 ]]; then
        return 2
    elif [[ "$DOCTOR_WARNINGS" -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

# ============================================================================
# STANDALONE ENTRYPOINT (bash lib/doctor.sh --json works without agmind CLI)
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Source sibling libs with graceful degradation (same pattern as health.sh)
    _DOCTOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    source "${_DOCTOR_SCRIPT_DIR}/common.sh"  2>/dev/null || true
    # shellcheck source=/dev/null
    source "${_DOCTOR_SCRIPT_DIR}/detect.sh"  2>/dev/null || true
    # shellcheck source=/dev/null
    source "${_DOCTOR_SCRIPT_DIR}/health.sh"  2>/dev/null || true
    doctor_run "$@"
fi
