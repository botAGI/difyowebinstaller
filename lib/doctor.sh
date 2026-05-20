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
COMPOSE_FILE="${COMPOSE_FILE:-${INSTALL_DIR}/docker/docker-compose.yml}"

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

# validate_path shim — whitelist-check for safe output paths (T-01-11).
# Guard: only define if not provided by common.sh.
# WHY: common.sh is NOT sourced in the agmind.sh → doctor.sh path (health.sh uses fallbacks);
#      without this shim, _doctor_bundle calls validate_path which doesn't exist → bundle FAIL.
command -v validate_path >/dev/null 2>&1 || validate_path() {
    local input="${1:-}"
    [[ -z "$input" ]] && { log_error "validate_path: empty path"; return 1; }
    local resolved
    resolved="$(realpath "$input" 2>/dev/null)" || { log_error "validate_path: cannot resolve: ${input}"; return 1; }
    local allowed=false
    local prefix
    for prefix in /tmp /home /root /etc/ssl /opt /var/backups; do
        if [[ "$resolved" == "${prefix}"/* || "$resolved" == "$prefix" ]]; then allowed=true; break; fi
    done
    [[ "$allowed" != "true" ]] && { log_error "validate_path: rejected: ${resolved}"; return 1; }
    printf '%s' "$resolved"
}

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
# Module-level flag: set to 1 when Docker daemon is down so container checks SKIP.
_DOCTOR_DOCKER_DOWN=0

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
    _DOCTOR_DOCKER_DOWN=0
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
# PRIVATE HELPERS
# ============================================================================

# _doctor_is_root — returns 0 if running as root
_doctor_is_root() { [[ "$EUID" -eq 0 ]]; }

# _doctor_installed — returns 0 if INSTALL_DIR exists (post-install)
_doctor_installed() { [[ -d "${INSTALL_DIR}" ]]; }

# _doctor_running_container <name> — returns 0 if container is running
_doctor_running_container() {
    local name="$1"
    docker ps --filter "name=^${name}$" --filter "status=running" \
        --format '{{.Names}}' 2>/dev/null | grep -q "."
}

# _doctor_read_env_safe KEY DEFAULT — reads ENV_FILE without failing if unreadable
_doctor_read_env_safe() {
    local key="$1" default="${2:-}"
    if [[ ! -f "$ENV_FILE" ]]; then echo "$default"; return; fi
    grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "$default"
}

# ============================================================================
# CHECK FUNCTIONS — D-04 category order
# ============================================================================
# WHY D-04 order: arch-driver → docker → kernel-params → dns-mdns → gpu →
#   resources → ports → images → models → services → security-exposure →
#   install-state → peer (CONTEXT.md D-04)

# ----------------------------------------------------------------------------
# doctor_check_arch_driver — arch (aarch64), NVIDIA driver version, apt-mark pin
# WHY: aarch64-only since v3.1; driver 580 HOLD mandatory (see docs/adr/0001-arm64-only, docs/adr/0005-driver-580-hold)
# ----------------------------------------------------------------------------
doctor_check_arch_driver() {
    # Arch check
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        _registry_add "arch" "arch-driver" "OK" "Arch: ${arch} (arm64 — OK)"
    else
        # WHY WARN: AGMIND_ALLOW_AMD64=true override exists but not recommended
        if [[ "${AGMIND_ALLOW_AMD64:-false}" == "true" ]]; then
            _registry_add "arch" "arch-driver" "WARN" \
                "Arch: ${arch} — AGmind оптимизирован для aarch64/DGX Spark (override: AGMIND_ALLOW_AMD64=true)" \
                "Запустите на DGX Spark (arm64)"
        else
            _registry_add "arch" "arch-driver" "WARN" \
                "Arch: ${arch} — AGmind requires aarch64/arm64 (DGX Spark); set AGMIND_ALLOW_AMD64=true to override" \
                "Запустите на DGX Spark / arm64"
        fi
    fi

    # NVIDIA driver version check
    # WHY: --query-gpu=driver_version НЕ NVML memory query — verify on live spark-3eac (RESEARCH A1)
    if ! command -v nvidia-smi &>/dev/null; then
        _registry_add "driver_version" "arch-driver" "WARN" \
            "nvidia-smi not found — GPU driver check skipped"
        return 0
    fi

    local drv=""
    set +e
    drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | xargs)"
    set -e

    # Handle [N/A] — unified memory fallback: try nvidia-smi -q parsing
    # WHY: GB10 unified memory returns [N/A] for some NVML queries; driver_version
    #   should still work (RESEARCH A1), but be defensive.
    if [[ -z "$drv" || "$drv" == "[N/A]" ]]; then
        set +e
        drv="$(nvidia-smi -q 2>/dev/null | awk '/Driver Version/{print $NF}' | head -1)"
        set -e
    fi

    if [[ -z "$drv" ]]; then
        _registry_add "driver_version" "arch-driver" "WARN" \
            "Не удалось определить версию NVIDIA драйвера (nvidia-smi --query-gpu=driver_version вернул пустой результат)"
        return 0
    fi

    local drv_major
    drv_major="${drv%%.*}"
    # WHY FAIL ≥590: три регрессии на GB10 UMA — CUDAGraph deadlock,
    #   UMA memory leak, Blackwell TMA bug. NVIDIA staff: not supported past 580.126.09.
    #   (see docs/adr/0005-driver-580-hold)
    if [[ "${drv_major:-0}" -ge 590 ]] 2>/dev/null; then
        _registry_add "driver_version" "arch-driver" "FAIL" \
            "NVIDIA driver ${drv} — FAIL: ≥590 сломан на DGX Spark GB10 (CUDAGraph deadlock / UMA leak / TMA bug)" \
            "Downgrade: sudo apt install nvidia-driver-580-open; sudo reboot — см. docs/adr/0005-driver-580-hold"
    elif [[ "${drv_major:-0}" -ge 580 ]] 2>/dev/null; then
        _registry_add "driver_version" "arch-driver" "OK" \
            "NVIDIA driver ${drv} (580.x — golden для DGX Spark)"
    else
        _registry_add "driver_version" "arch-driver" "WARN" \
            "NVIDIA driver ${drv} — версия ниже 580.x, ожидается 580.142 на DGX Spark"
    fi

    # Driver pin check (apt-mark showhold)
    # WHY: driver 580 must be held to prevent unattended-upgrades pulling 590+ (see docs/adr/0005-driver-580-hold)
    if ! command -v apt-mark &>/dev/null; then
        _registry_add "driver_pin" "arch-driver" "SKIP" \
            "apt-mark недоступен (non-Debian) — проверка pin пропущена"
        return 0
    fi
    # Only warn about pin if we're running 580.x (pin is for 580)
    if [[ "${drv_major:-0}" -ge 580 && "${drv_major:-0}" -lt 590 ]] 2>/dev/null; then
        local held
        set +e
        held="$(apt-mark showhold 2>/dev/null | grep -c nvidia || true)"
        set -e
        if [[ "${held:-0}" -gt 0 ]]; then
            _registry_add "driver_pin" "arch-driver" "OK" \
                "NVIDIA driver 580.x pin: apt-mark hold выставлен"
        else
            # WHY WARN fixable: unattended-upgrades may pull 590+ which breaks Spark (see docs/adr/0005-driver-580-hold)
            _registry_add "driver_pin" "arch-driver" "WARN" \
                "NVIDIA driver 580.x не зафиксирован (apt-mark hold не выставлен) — риск обновления до 590+" \
                "sudo agmind doctor --fix (выставит apt-mark hold)" \
                true "pin_nvidia_driver_dgx_spark"
        fi
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_docker — Docker daemon, version, Compose version
# ----------------------------------------------------------------------------
doctor_check_docker() {
    if ! command -v docker &>/dev/null; then
        _registry_add "docker_present" "docker" "FAIL" \
            "Docker не установлен" \
            "curl -fsSL https://get.docker.com | sh"
        _DOCTOR_DOCKER_DOWN=1
        return 0
    fi

    # Check daemon health
    set +e
    docker info &>/dev/null
    local _di_rc=$?
    set -e
    if [[ $_di_rc -ne 0 ]]; then
        _registry_add "docker_daemon" "docker" "FAIL" \
            "Docker daemon не отвечает (docker info failed)" \
            "systemctl start docker"
        _DOCTOR_DOCKER_DOWN=1
        return 0
    fi

    # Docker version
    local dv
    dv="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")"
    local dm="${dv%%.*}"
    if [[ "${dm:-0}" -ge 24 ]] 2>/dev/null; then
        _registry_add "docker_version" "docker" "OK" "Docker v${dv}"
    elif [[ "${dm:-0}" -ge 20 ]] 2>/dev/null; then
        _registry_add "docker_version" "docker" "WARN" \
            "Docker v${dv} — 24.0+ рекомендуется"
    else
        _registry_add "docker_version" "docker" "FAIL" \
            "Docker v${dv} — требуется 24.0+"
    fi

    # Docker Compose version
    if docker compose version &>/dev/null 2>&1; then
        local cv
        cv="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
        local cmaj cmin
        cmaj="$(echo "$cv" | cut -d. -f1)"
        cmin="$(echo "$cv" | cut -d. -f2)"
        if [[ "${cmaj:-0}" -ge 3 ]] 2>/dev/null; then
            _registry_add "compose_version" "docker" "OK" "Compose v${cv}"
        elif [[ "${cmaj:-0}" -eq 2 && "${cmin:-0}" -ge 20 ]] 2>/dev/null; then
            _registry_add "compose_version" "docker" "OK" "Compose v${cv}"
        else
            _registry_add "compose_version" "docker" "WARN" \
                "Compose v${cv} — 2.20+ рекомендуется"
        fi
    else
        _registry_add "compose_version" "docker" "FAIL" \
            "Docker Compose не установлен или не работает"
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_kernel — vm.max_map_count (ES/RAGFlow requirement)
# WHY WARN/FAIL: ES bootstrap hard-fails if < 262144 (see docs/troubleshooting.md)
# ----------------------------------------------------------------------------
doctor_check_kernel() {
    local mmc
    set +e
    mmc="$(sysctl -n vm.max_map_count 2>/dev/null || echo "0")"
    set -e
    mmc="${mmc//[^0-9]/}"
    mmc="${mmc:-0}"

    if [[ "$mmc" -ge 262144 ]] 2>/dev/null; then
        _registry_add "vm_max_map_count" "kernel-params" "OK" \
            "vm.max_map_count=${mmc} (≥262144 — OK для Elasticsearch)"
    else
        # WHY FAIL if RAGFlow active: ES requires this for bootstrap (see docs/troubleshooting.md)
        local ragflow_active
        ragflow_active="$(_doctor_read_env_safe ENABLE_RAGFLOW false)"
        if [[ "$ragflow_active" == "true" ]]; then
            _registry_add "vm_max_map_count" "kernel-params" "FAIL" \
                "vm.max_map_count=${mmc} — FAIL: <262144 и ENABLE_RAGFLOW=true (ES не запустится)" \
                "sudo agmind doctor --fix (sysctl + /etc/sysctl.d/99-agmind-es.conf) — ES требует ≥262144" \
                true "_ensure_es_sysctl"
        else
            _registry_add "vm_max_map_count" "kernel-params" "WARN" \
                "vm.max_map_count=${mmc} — <262144 (нужно для Elasticsearch/RAGFlow)" \
                "sudo agmind doctor --fix (sysctl + /etc/sysctl.d/99-agmind-es.conf) — ES требует ≥262144" \
                true "_ensure_es_sysctl"
        fi
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_dns_mdns — DNS resolve, mDNS status, foreign :5353 responder
# WHY: dead mDNS / foreign responder are known failure classes (see docs/troubleshooting.md)
# ----------------------------------------------------------------------------
doctor_check_dns_mdns() {
    # DNS resolution check
    set +e
    host registry.ollama.ai &>/dev/null 2>&1 || nslookup registry.ollama.ai &>/dev/null 2>&1
    local _dns_rc=$?
    set -e
    if [[ $_dns_rc -eq 0 ]]; then
        _registry_add "dns_resolve" "dns-mdns" "OK" "DNS: registry.ollama.ai резолвится"
    else
        _registry_add "dns_resolve" "dns-mdns" "WARN" \
            "DNS: не удалось резолвить registry.ollama.ai"
    fi

    # Docker Hub reachability
    set +e
    curl -sf --max-time 5 https://registry-1.docker.io/v2/ &>/dev/null
    local _hub_rc=$?
    set -e
    if [[ $_hub_rc -eq 0 ]]; then
        _registry_add "docker_hub" "dns-mdns" "OK" "Docker Hub: доступен"
    else
        _registry_add "docker_hub" "dns-mdns" "WARN" "Docker Hub: недоступен"
    fi

    # mDNS status — prefer mdns-status.sh --json if available
    local mdns_script=""
    if [[ -x "${INSTALL_DIR}/scripts/mdns-status.sh" ]]; then
        mdns_script="${INSTALL_DIR}/scripts/mdns-status.sh"
    elif [[ -x "./scripts/mdns-status.sh" ]]; then
        mdns_script="./scripts/mdns-status.sh"
    fi

    if [[ -n "$mdns_script" ]]; then
        local mdns_out mdns_rc
        set +e
        mdns_out="$(bash "$mdns_script" --json 2>/dev/null)"
        mdns_rc=$?
        set -e
        if [[ -n "$mdns_out" ]] && command -v jq &>/dev/null; then
            # Parse each sub-check from mdns-status.sh JSON output
            while IFS=$'\t' read -r mstatus mcheck mdetail; do
                [[ -z "$mcheck" ]] && continue
                local msev="OK"
                case "$mstatus" in
                    warn) msev="WARN" ;;
                    fail) msev="FAIL" ;;
                    info) msev="OK" ;;
                esac
                local mfixable=false mfix_hint=""
                if [[ "$msev" == "WARN" || "$msev" == "FAIL" ]]; then
                    mfixable=true
                    mfix_hint="systemctl restart avahi-daemon agmind-mdns.service (или sudo agmind doctor --fix)"
                fi
                _registry_add "mdns_${mcheck// /_}" "dns-mdns" "$msev" \
                    "mDNS ${mcheck}: ${mdetail}" "$mfix_hint" "$mfixable" "_doctor_fix_mdns"
            done < <(echo "$mdns_out" | jq -r '.checks[]? | "\(.status)\t\(.check)\t\(.detail)"' 2>/dev/null)
        elif [[ -n "$mdns_out" ]]; then
            # No jq — just report aggregate
            if [[ "$mdns_rc" -eq 0 ]]; then
                _registry_add "mdns_status" "dns-mdns" "OK" "mDNS: OK (mdns-status.sh exit 0)"
            else
                _registry_add "mdns_status" "dns-mdns" "WARN" \
                    "mDNS: ${mdns_rc} проблем(ы) (см. agmind mdns-status)" \
                    "systemctl restart avahi-daemon agmind-mdns.service (или sudo agmind doctor --fix)" \
                    true "_doctor_fix_mdns"
            fi
        else
            _registry_add "mdns_status" "dns-mdns" "SKIP" \
                "jq не найден — подробный mDNS статус недоступен (см. agmind mdns-status)"
        fi
    else
        # Inline fallback: avahi-resolve + systemctl checks
        if command -v avahi-resolve &>/dev/null; then
            set +e
            timeout 4 avahi-resolve -n "agmind-dify.local" &>/dev/null
            local _ar_rc=$?
            set -e
            if [[ $_ar_rc -eq 0 ]]; then
                _registry_add "mdns_status" "dns-mdns" "OK" \
                    "mDNS: agmind-dify.local резолвится"
            else
                # Check if avahi is alive but agmind-mdns.service failed
                # WHY: dead mDNS while avahi is alive = agmind-mdns.service failed (see docs/troubleshooting.md)
                local avahi_active agmind_mdns_active
                set +e
                avahi_active="$(systemctl is-active avahi-daemon 2>/dev/null || echo "unknown")"
                agmind_mdns_active="$(systemctl is-active agmind-mdns.service 2>/dev/null || echo "unknown")"
                set -e
                if [[ "$avahi_active" == "active" && "$agmind_mdns_active" != "active" ]]; then
                    _registry_add "mdns_status" "dns-mdns" "WARN" \
                        "mDNS: agmind-dify.local не резолвится (agmind-mdns.service: ${agmind_mdns_active}, avahi: ${avahi_active})" \
                        "systemctl restart avahi-daemon agmind-mdns.service (или sudo agmind doctor --fix)" \
                        true "_doctor_fix_mdns"
                else
                    _registry_add "mdns_status" "dns-mdns" "WARN" \
                        "mDNS: agmind-dify.local не резолвится (avahi: ${avahi_active})" \
                        "systemctl restart avahi-daemon"
                fi
            fi
        else
            _registry_add "mdns_status" "dns-mdns" "SKIP" \
                "avahi-resolve не найден — mDNS check пропущен"
        fi
    fi

    # Foreign :5353 responder check
    # WHY: second mDNS responder on :5353 breaks avahi and all agmind-*.local aliases (see docs/troubleshooting.md)
    local _foreign_tmp
    _foreign_tmp="$(mktemp)"
    local _foreign_rc
    set +e
    # _assert_no_foreign_mdns is from lib/detect.sh — orchestrate, don't duplicate
    if declare -F _assert_no_foreign_mdns >/dev/null 2>&1; then
        _assert_no_foreign_mdns 2>"$_foreign_tmp"
        _foreign_rc=$?
    else
        # Inline fallback if detect.sh not sourced
        local squatters
        squatters="$(ss -ulnp 2>/dev/null \
            | awk '$4 ~ /:5353$/ {
                if (match($0, /users:\(\("([^"]+)"/, a) && a[1] != "" && a[1] != "avahi-daemon") print a[1]
              }' | sort -u | tr '\n' ' ' || true)"
        squatters="${squatters% }"
        if [[ -n "$squatters" ]]; then
            printf '  [FAIL] mDNS port 5353 occupied by non-avahi: %s\n' "$squatters" > "$_foreign_tmp"
            printf '         -> NoMachine: set EnableLocalNetworkBroadcast 0\n' >> "$_foreign_tmp"
            _foreign_rc=1
        else
            _foreign_rc=0
        fi
    fi
    set -e

    if [[ "$_foreign_rc" -eq 0 ]]; then
        _registry_add "foreign_mdns" "dns-mdns" "OK" \
            "mDNS :5353 занят только avahi-daemon — OK"
    else
        local _foreign_msg
        _foreign_msg="$(head -2 "$_foreign_tmp" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        # Extract squatter names for user-facing message
        local _squatter_hint
        _squatter_hint="$(grep -oE '(nxserver|nxserver\.bin|systemd-resolve|iTunes|mDNSResponder)' "$_foreign_tmp" 2>/dev/null | head -3 | tr '\n' ',' | sed 's/,$//' || echo "non-avahi process")"
        _registry_add "foreign_mdns" "dns-mdns" "FAIL" \
            "mDNS :5353 занят сторонним процессом (${_squatter_hint:-non-avahi}) — avahi не может публиковать .local-имена" \
            "NoMachine: EnableLocalNetworkBroadcast 0 в /etc/NX/server/localhost/server.cfg; systemctl restart nxserver (см. docs/troubleshooting.md раздел 5)"
    fi
    rm -f "$_foreign_tmp"
}

# ----------------------------------------------------------------------------
# doctor_check_gpu — host nvidia-smi, nvidia runtime, GPU-in-container visibility
# WHY: NVIDIA_DRIVER_CAPABILITIES=compute,utility mandatory on Spark (see docs/adr/0005-driver-580-hold)
# ----------------------------------------------------------------------------
doctor_check_gpu() {
    # Skip entire check if both providers are external
    local lp ep
    lp="$(_doctor_read_env_safe LLM_PROVIDER unknown)"
    ep="$(_doctor_read_env_safe EMBED_PROVIDER unknown)"
    if [[ "$lp" == "external" && "$ep" == "external" ]]; then
        _registry_add "gpu_host" "gpu" "SKIP" \
            "GPU check пропущен — LLM_PROVIDER и EMBED_PROVIDER оба external"
        return 0
    fi

    # Host-side nvidia-smi
    if command -v nvidia-smi &>/dev/null; then
        local gpu_name
        set +e
        gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
        set -e
        _registry_add "gpu_host" "gpu" "OK" \
            "NVIDIA GPU: ${gpu_name:-GB10} (nvidia-smi доступен)"
    else
        _registry_add "gpu_host" "gpu" "WARN" \
            "nvidia-smi не найден — GPU недоступен"
        return 0
    fi

    # NVIDIA container runtime
    if [[ "$_DOCTOR_DOCKER_DOWN" -eq 1 ]]; then
        _registry_add "nvidia_runtime" "gpu" "SKIP" \
            "Docker daemon не доступен — NVIDIA runtime check пропущен"
        return 0
    fi
    # PRECISION FIX 2026-05-19: previous `grep -qi nvidia` against full `docker info`
    # gave false-positives (host GPU description matched even when Runtimes:
    # line lacked nvidia). Match the `Runtimes:` line specifically — it lists
    # registered container runtimes and is the actual signal Docker uses when
    # launching GPU containers. False-OK here masked the regression where
    # `install_nvidia_toolkit` skipped `nvidia-ctk runtime configure` on
    # re-installs, leaving every GPU container with NVML init failures.
    # See CLAUDE.md §8 entry "Docker daemon nvidia runtime".
    set +e
    docker info 2>/dev/null | grep -qE '^[[:space:]]*Runtimes:.*\bnvidia\b'
    local _nr_rc=$?
    set -e
    if [[ $_nr_rc -eq 0 ]]; then
        _registry_add "nvidia_runtime" "gpu" "OK" "NVIDIA Container Toolkit runtime registered"
    else
        _registry_add "nvidia_runtime" "gpu" "FAIL" \
            "NVIDIA runtime отсутствует в Docker daemon — все GPU контейнеры будут CPU-fallback (NVML init fail)" \
            "Run: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
    fi

    # GPU-in-container visibility for vllm and docling
    local llm_on_peer
    llm_on_peer="$(_doctor_read_env_safe LLM_ON_PEER false)"
    for svc in vllm docling; do
        local cname="agmind-${svc}"
        # WHY: vLLM on peer node (LLM_ON_PEER=true) — skip local GPU check (see docs/adr/0001-arm64-only)
        if [[ "$svc" == "vllm" && "$llm_on_peer" == "true" ]]; then
            _registry_add "gpu_in_vllm" "gpu" "SKIP" \
                "vLLM на peer (LLM_ON_PEER=true) — проверяется через --peer"
            continue
        fi
        # Only check running containers
        set +e
        _doctor_running_container "$cname"
        local _running=$?
        set -e
        if [[ $_running -ne 0 ]]; then
            _registry_add "gpu_in_${svc}" "gpu" "SKIP" \
                "${cname}: не запущен — GPU check пропущен"
            continue
        fi

        # Quick nvidia-smi -L inside container
        set +e
        docker exec "$cname" nvidia-smi -L &>/dev/null
        local _nsmi_rc=$?
        set -e

        if [[ $_nsmi_rc -eq 0 ]]; then
            _registry_add "gpu_in_${svc}" "gpu" "OK" \
                "${cname}: nvidia-smi -L видит GPU"
        else
            # Check if NVIDIA_DRIVER_CAPABILITIES env is missing
            local env_caps
            set +e
            env_caps="$(docker inspect "$cname" \
                --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
                | grep 'NVIDIA_DRIVER_CAPABILITIES' || true)"
            set -e
            if echo "$env_caps" | grep -q "compute"; then
                # Caps present but nvidia-smi still fails — check torch
                local torch_out
                set +e
                if docker exec "$cname" command -v python3 &>/dev/null 2>&1; then
                    torch_out="$(timeout 15 docker exec "$cname" \
                        python3 -c 'import torch; print(torch.cuda.is_available())' \
                        2>/dev/null || echo "error")"
                else
                    torch_out="nopython"
                fi
                set -e
                if [[ "$torch_out" == "False" || "$torch_out" == "error" ]]; then
                    _registry_add "gpu_in_${svc}" "gpu" "FAIL" \
                        "${cname}: torch.cuda.is_available()=False / NVML init fail" \
                        "Добавить NVIDIA_DRIVER_CAPABILITIES=compute,utility в compose env (см. docs/adr/0005-driver-580-hold)"
                elif [[ "$torch_out" == "nopython" ]]; then
                    _registry_add "gpu_in_${svc}" "gpu" "SKIP" \
                        "${cname}: nvidia-smi -L failed но python3 недоступен для torch-check"
                else
                    _registry_add "gpu_in_${svc}" "gpu" "OK" \
                        "${cname}: torch.cuda.is_available()=True"
                fi
            else
                # WHY FAIL: NVIDIA_DRIVER_CAPABILITIES=compute,utility обязательно на Spark (see docs/adr/0005-driver-580-hold)
                _registry_add "gpu_in_${svc}" "gpu" "FAIL" \
                    "${cname}: NVIDIA_DRIVER_CAPABILITIES=compute отсутствует в env контейнера — GPU недоступен" \
                    "Добавить NVIDIA_DRIVER_CAPABILITIES=compute,utility в compose env (см. docs/adr/0005-driver-580-hold)"
            fi
        fi
    done
}

# ----------------------------------------------------------------------------
# doctor_check_resources — disk, RAM, swap
# ----------------------------------------------------------------------------
doctor_check_resources() {
    # Disk check
    local free_gb disk_total disk_pct
    free_gb="$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo "0")"
    disk_total="$(df -BG / 2>/dev/null | tail -1 | awk '{print $2}' | tr -d 'G' || echo "0")"
    disk_pct="$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || echo "0")"
    if [[ "${free_gb:-0}" -ge 20 ]] 2>/dev/null; then
        _registry_add "disk" "resources" "OK" \
            "Disk: ${free_gb}GB свободно (${disk_pct}% занято из ${disk_total}GB)"
    elif [[ "${free_gb:-0}" -ge 10 ]] 2>/dev/null; then
        _registry_add "disk" "resources" "WARN" \
            "Disk: ${free_gb}GB свободно (${disk_pct}% занято) — рекомендуется ≥20GB" \
            "docker system prune"
    else
        _registry_add "disk" "resources" "FAIL" \
            "Disk: ${free_gb}GB свободно — критически мало" \
            "docker system prune -af"
    fi

    # RAM check
    local ram_gb ram_used ram_pct
    ram_gb="$(LANG=C free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")"
    ram_used="$(LANG=C free -g 2>/dev/null | awk '/^Mem:/{print $3}' || echo "0")"
    if [[ "${ram_gb:-0}" -gt 0 ]] 2>/dev/null; then
        ram_pct=$(( (ram_used * 100) / ram_gb ))
    else
        ram_pct=0
    fi
    if [[ "${ram_gb:-0}" -ge 8 ]] 2>/dev/null; then
        _registry_add "ram" "resources" "OK" \
            "RAM: ${ram_gb}GB всего (${ram_pct}% используется)"
    elif [[ "${ram_gb:-0}" -ge 4 ]] 2>/dev/null; then
        _registry_add "ram" "resources" "WARN" \
            "RAM: ${ram_gb}GB (${ram_pct}% используется) — рекомендуется ≥8GB"
    else
        _registry_add "ram" "resources" "FAIL" \
            "RAM: ${ram_gb}GB — минимум 4GB"
    fi

    # Swap info (informational)
    local swap_total
    swap_total="$(LANG=C free -g 2>/dev/null | awk '/^Swap:/{print $2}' || echo "0")"
    _registry_add "swap" "resources" "OK" \
        "Swap: ${swap_total}GB настроено"
}

# ----------------------------------------------------------------------------
# doctor_check_ports — port conflicts (80/443) + exposed admin ports
# ----------------------------------------------------------------------------
doctor_check_ports() {
    # WHY: ss -tlnp without root omits process names → can't grep 'nginx|docker'.
    # Instead: first check via docker ps whether AGmind container owns the port
    # (agmind-nginx publishes 80/443). Fall back to ss process-name grep (works with root).
    local _agmind_ports=""
    if [[ "$_DOCTOR_DOCKER_DOWN" -ne 1 ]]; then
        _agmind_ports="$(docker ps --format '{{.Ports}}' 2>/dev/null || true)"
    fi
    for port in 80 443; do
        local pp owned_by_agmind=0
        pp="$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 || true)"
        # Check 1: docker ps output contains 0.0.0.0:<port>->  (AGmind nginx)
        if echo "$_agmind_ports" | grep -qE "0\.0\.0\.0:${port}->|:::${port}->|\[::\]:${port}->"; then
            owned_by_agmind=1
        fi
        # Check 2: ss shows process name (works when running as root)
        if [[ $owned_by_agmind -eq 0 ]] && echo "$pp" | grep -q "agmind\|nginx\|docker"; then
            owned_by_agmind=1
        fi
        if [[ -z "$pp" ]]; then
            _registry_add "port_${port}" "ports" "OK" "Port ${port}: свободен"
        elif [[ $owned_by_agmind -eq 1 ]]; then
            _registry_add "port_${port}" "ports" "OK" "Port ${port}: используется AGmind/nginx"
        else
            _registry_add "port_${port}" "ports" "FAIL" \
                "Port ${port}: занят сторонним процессом" \
                "Проверьте: ss -tlnp | grep ':${port}'"
        fi
    done
}

# ----------------------------------------------------------------------------
# doctor_check_images — local docker image availability per compose config
# WHY: catches images not yet pulled before docker compose up fails
# ----------------------------------------------------------------------------
doctor_check_images() {
    if [[ "$_DOCTOR_DOCKER_DOWN" -eq 1 ]]; then
        _registry_add "images_docker_down" "images" "SKIP" \
            "Docker недоступен — image check пропущен"
        return 0
    fi

    if [[ ! -f "$COMPOSE_FILE" ]]; then
        _registry_add "images_compose" "images" "SKIP" \
            "docker-compose.yml не найден — image check пропущен"
        return 0
    fi

    local imgs
    set +e
    imgs="$(docker compose -f "$COMPOSE_FILE" config 2>/dev/null \
        | awk '/^[[:space:]]*image:/ {print $2}' | sort -u)"
    set -e

    if [[ -z "$imgs" ]]; then
        _registry_add "images_compose" "images" "SKIP" \
            "docker compose config не вернул images — check пропущен"
        return 0
    fi

    # TODO Phase 4: --check-registry for arm64 manifest verification via docker manifest inspect
    local img_count=0 warn_count=0
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        img_count=$((img_count + 1))
        local img_id
        img_id="${img//[^a-zA-Z0-9._-]/_}"
        set +e
        docker image inspect "$img" &>/dev/null
        local _ii_rc=$?
        set -e
        if [[ $_ii_rc -eq 0 ]]; then
            _registry_add "image_${img_id}" "images" "OK" "${img}: присутствует локально"
        else
            warn_count=$((warn_count + 1))
            _registry_add "image_${img_id}" "images" "WARN" \
                "${img}: не скачан — будет скачан при docker compose up" \
                "docker compose pull"
        fi
    done <<< "$imgs"

    if [[ $img_count -eq 0 ]]; then
        _registry_add "images_none" "images" "SKIP" "Нет images для проверки"
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_models — model cache files on disk
# ----------------------------------------------------------------------------
doctor_check_models() {
    local llm_prov
    llm_prov="$(_doctor_read_env_safe LLM_PROVIDER "")"
    local enable_docling
    enable_docling="$(_doctor_read_env_safe ENABLE_DOCLING false)"

    if [[ "$_DOCTOR_DOCKER_DOWN" -eq 1 ]]; then
        _registry_add "model_docker_down" "models" "SKIP" \
            "Docker недоступен — model cache check пропущен"
        return 0
    fi

    # vLLM model cache volume (only when self-hosted LLM)
    if [[ "$llm_prov" == "vllm" || "$llm_prov" == "ollama" ]]; then
        set +e
        docker volume inspect agmind_vllm_cache &>/dev/null
        local _vrc=$?
        set -e
        if [[ $_vrc -eq 0 ]]; then
            _registry_add "model_vllm" "models" "OK" "vLLM model cache volume: присутствует"
        else
            _registry_add "model_vllm" "models" "WARN" \
                "vLLM model cache volume отсутствует — модель будет скачана при первом запуске" \
                "agmind model list / повторно запустите install.sh"
        fi
    else
        _registry_add "model_vllm" "models" "SKIP" \
            "LLM_PROVIDER=${llm_prov:-неизвестен} — vLLM cache check пропущен"
    fi

    # Docling OCR cache (cyrillic_g2.pth)
    if [[ "$enable_docling" == "true" ]]; then
        set +e
        docker volume inspect agmind_docling_cache &>/dev/null
        local _drc=$?
        set -e
        if [[ $_drc -eq 0 ]]; then
            _registry_add "model_docling_ocr" "models" "OK" "Docling cache volume: присутствует"
        else
            _registry_add "model_docling_ocr" "models" "WARN" \
                "Docling cache volume отсутствует — OCR модели (incl. cyrillic_g2.pth) будут скачаны при первом запуске" \
                "Повторно запустите install.sh"
        fi
    else
        _registry_add "model_docling_ocr" "models" "SKIP" \
            "ENABLE_DOCLING!=true — docling OCR cache check пропущен"
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_services — container health, HTTP endpoints, .env completeness
# ----------------------------------------------------------------------------
doctor_check_services() {
    local is_installed=false
    [[ -f "${INSTALL_DIR}/.agmind_installed" || -d "${INSTALL_DIR}/docker" ]] && is_installed=true

    if [[ "$_DOCTOR_DOCKER_DOWN" -ne 1 ]] && [[ "$is_installed" == "true" ]]; then
        # Unhealthy containers
        local unhealthy
        unhealthy="$(docker ps --filter "name=agmind-" --filter "health=unhealthy" \
            --format '{{.Names}}' 2>/dev/null || true)"
        if [[ -n "$unhealthy" ]]; then
            while IFS= read -r c; do
                _registry_add "unhealthy_${c}" "services" "FAIL" \
                    "Unhealthy: ${c}" \
                    "docker logs --tail 20 ${c}"
            done <<< "$unhealthy"
        else
            _registry_add "unhealthy_none" "services" "OK" "Нет unhealthy контейнеров"
        fi

        # Exited containers (excluding expected init containers)
        local exited
        exited="$(docker ps -a --filter "name=agmind-" --filter "status=exited" \
            --format '{{.Names}}' 2>/dev/null || true)"
        if [[ -n "$exited" ]]; then
            while IFS= read -r c; do
                [[ "$c" == *"lock-cleaner"* ]] && continue
                _registry_add "exited_${c}" "services" "WARN" \
                    "Exited: ${c} — контейнер остановлен" \
                    "docker start ${c}"
            done <<< "$exited"
        fi

        # High restart count (>3)
        local restarts
        restarts="$(docker ps --filter "name=agmind-" \
            --format '{{.Names}}' 2>/dev/null || true)"
        if [[ -n "$restarts" ]]; then
            while IFS= read -r cname; do
                [[ -z "$cname" ]] && continue
                local rcount
                rcount="$(docker inspect --format '{{.RestartCount}}' "$cname" 2>/dev/null || echo "0")"
                if [[ "${rcount:-0}" -gt 3 ]] 2>/dev/null; then
                    _registry_add "restart_${cname}" "services" "WARN" \
                        "Restarts: ${cname} — ${rcount} перезапусков" \
                        "docker logs --tail 30 ${cname}"
                fi
            done <<< "$restarts"
        fi

        # LiteLLM check
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'agmind-litellm'; then
            set +e
            docker exec agmind-litellm curl -sf --max-time 5 http://localhost:4000/health \
                >/dev/null 2>&1
            local _llm_rc=$?
            set -e
            if [[ $_llm_rc -eq 0 ]]; then
                _registry_add "litellm" "services" "OK" "LiteLLM Gateway: healthy"
            else
                _registry_add "litellm" "services" "WARN" \
                    "LiteLLM Gateway: контейнер запущен, health check failed" \
                    "docker compose restart agmind-litellm"
            fi
        fi

        # HTTP Endpoints via verify_services (lib/health.sh)
        if declare -F verify_services >/dev/null 2>&1; then
            set +e
            verify_services >/dev/null 2>&1
            set -e
            if [[ ${VERIFY_RESULTS+x} && ${#VERIFY_RESULTS[@]} -gt 0 ]]; then
                for ve in "${VERIFY_RESULTS[@]}"; do
                    IFS='|' read -r vname vurl vstatus <<< "$ve"
                    [[ -z "$vname" ]] && continue
                    local vid="endpoint_${vname// /_}"
                    if [[ "$vstatus" == "OK" ]]; then
                        _registry_add "$vid" "services" "OK" \
                            "${vname} (${vurl}): OK"
                    else
                        local vhint="agmind logs ${vname,,}"
                        _registry_add "$vid" "services" "FAIL" \
                            "${vname} (${vurl}): сервис не отвечает" \
                            "$vhint"
                    fi
                done
            fi
        fi
    fi

    # .env Completeness — run even if Docker is down (reads file, not daemon)
    if [[ -f "$ENV_FILE" ]]; then
        if [[ ! -r "$ENV_FILE" ]]; then
            _registry_add "env_readable" "services" "SKIP" \
                ".env: нет прав чтения — запустите: sudo agmind doctor"
        else
            local required_vars=(LLM_PROVIDER EMBED_PROVIDER SECRET_KEY DB_PASSWORD REDIS_PASSWORD INIT_PASSWORD)
            local optional_vars=(DOMAIN DEPLOY_PROFILE)
            local env_ok=0 env_missing=0
            for var in "${required_vars[@]}"; do
                local val
                val="$(_doctor_read_env_safe "$var" "")"
                if [[ -n "$val" ]]; then
                    env_ok=$((env_ok + 1))
                    # WHY: report as set/unset only — never the value (THREAT T-01-04)
                    _registry_add "env_${var}" "services" "OK" ".env ${var}: задан (значение скрыто)"
                else
                    _registry_add "env_${var}" "services" "FAIL" \
                        ".env ${var}: не задан" \
                        "Проверьте ${ENV_FILE}"
                    env_missing=$((env_missing + 1))
                fi
            done
            for var in "${optional_vars[@]}"; do
                local val
                val="$(_doctor_read_env_safe "$var" "")"
                if [[ -n "$val" ]]; then
                    env_ok=$((env_ok + 1))
                else
                    _registry_add "env_${var}" "services" "WARN" \
                        ".env ${var}: не задан (опционально для LAN)"
                fi
            done
        fi
    elif [[ "$is_installed" == "true" ]]; then
        _registry_add "env_missing" "services" "WARN" \
            ".env не найден: ${ENV_FILE}"
    else
        _registry_add "env_missing" "services" "SKIP" \
            "AGmind не установлен — .env check пропущен"
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_security_exposure — exposed admin ports + docker.sock consumers
# WHY: read-only subset of Phase 7 security audit
# ----------------------------------------------------------------------------
doctor_check_security_exposure() {
    # Admin UI ports that should NOT be bound to 0.0.0.0/all interfaces
    local admin_ports=(3000 9000 9443 9090 3100 5601 9001)
    local exposed_any=false

    local ss_out
    ss_out="$(ss -tlnp 2>/dev/null || true)"
    for p in "${admin_ports[@]}"; do
        if echo "$ss_out" | grep -qE "0\.0\.0\.0:${p}|^\*:${p}"; then
            _registry_add "exposed_${p}" "security-exposure" "WARN" \
                "Port ${p} привязан к 0.0.0.0 — admin UI доступен с любого интерфейса" \
                "Ограничьте bind-адрес; см. agmind security audit (Phase 7)"
            exposed_any=true
        fi
    done
    if [[ "$exposed_any" == "false" ]]; then
        _registry_add "exposed_none" "security-exposure" "OK" \
            "Нет admin UI, привязанных к 0.0.0.0"
    fi

    # Docker.sock consumers
    if [[ "$_DOCTOR_DOCKER_DOWN" -eq 1 ]]; then
        _registry_add "sock_docker_down" "security-exposure" "SKIP" \
            "Docker недоступен — docker.sock consumer check пропущен"
        return 0
    fi

    local containers
    set +e
    containers="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
    set -e
    if [[ -n "$containers" ]]; then
        while IFS= read -r c; do
            [[ -z "$c" ]] && continue
            local mounts
            set +e
            mounts="$(docker inspect "$c" \
                --format '{{range .Mounts}}{{.Source}}={{.RW}} {{end}}' 2>/dev/null || true)"
            set -e
            case "$mounts" in
                *"/var/run/docker.sock=true"*)
                    _registry_add "sock_${c}" "security-exposure" "WARN" \
                        "${c}: монтирует docker.sock rw — повышенный риск" \
                        "см. agmind security audit (Phase 7)" ;;
                *"/var/run/docker.sock=false"*)
                    _registry_add "sock_${c}" "security-exposure" "OK" \
                        "${c}: монтирует docker.sock ro — OK" ;;
            esac
        done <<< "$containers"
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_install_state — .install_phase, install.log errors, loadtest scripts
# WHY: missing loadtest scripts = _copy_runtime_files script_subdirs regression (see docs/troubleshooting.md)
# ----------------------------------------------------------------------------
doctor_check_install_state() {
    if ! _doctor_installed; then
        _registry_add "install_phase" "install-state" "SKIP" \
            "AGmind не установлен (${INSTALL_DIR} отсутствует) — install-state check пропущен"
        return 0
    fi

    # Last install phase
    local phase_val
    phase_val="$(cat "${INSTALL_DIR}/.install_phase" 2>/dev/null || echo "")"
    if [[ -n "$phase_val" ]] && [[ "$phase_val" =~ ^[0-9]+$ ]]; then
        # WHY 11 = TOTAL phases in install.sh main()
        if [[ "$phase_val" -lt 11 ]] 2>/dev/null; then
            _registry_add "install_phase" "install-state" "WARN" \
                "Установка не завершена: последняя фаза ${phase_val}/11" \
                "sudo bash install.sh"
        else
            _registry_add "install_phase" "install-state" "OK" \
                "Установка завершена (фаза ${phase_val}/11)"
        fi
    else
        _registry_add "install_phase" "install-state" "SKIP" \
            ".install_phase отсутствует или пуст"
    fi

    # Last errors (informational, not FAIL)
    local err_count
    err_count="$(
        {
            grep -iE 'ERROR|✗' "${INSTALL_DIR}/install.log" 2>/dev/null | tail -10
            journalctl -u agmind-stack --no-pager -p err -n 20 2>/dev/null
        } | wc -l
    )"
    _registry_add "last_errors" "install-state" "OK" \
        "${err_count} строк с ошибками в install.log + journalctl (grep -i ERROR ${INSTALL_DIR}/install.log | tail)"

    # Loadtest scripts check
    # WHY: missing scripts/loadtest = _copy_runtime_files script_subdirs whitelist regression
    local ld_dir="${MOCK_LOADTEST_DIR:-${INSTALL_DIR}/scripts/loadtest}"
    if [[ -d "$ld_dir" && -n "$(ls -A "$ld_dir" 2>/dev/null)" ]]; then
        _registry_add "loadtest_scripts" "install-state" "OK" \
            "loadtest скрипты присутствуют в ${ld_dir}"
    else
        _registry_add "loadtest_scripts" "install-state" "WARN" \
            "loadtest dir пуст или отсутствует (${ld_dir}) — регрессия _copy_runtime_files script_subdirs whitelist" \
            "sudo bash install.sh"
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_peer — delegates to lib/health.sh::_doctor_peer
# WHY D-04: peer is last — only if cluster.json might exist (LLM_ON_PEER aware)
# ----------------------------------------------------------------------------
doctor_check_peer() {
    if declare -F _doctor_peer >/dev/null 2>&1; then
        set +e
        _doctor_peer 2>/dev/null
        set -e
    else
        _registry_add "peer_unavail" "peer" "SKIP" \
            "lib/health.sh не загружен — peer check пропущен"
    fi
}

# ============================================================================
# FIX HELPERS — idempotent, non-destructive only (D-08)
# ============================================================================

# _doctor_fix_mapcount — reproduce install.sh::_ensure_es_sysctl logic.
# WHY: ES bootstrap fails if vm.max_map_count < 262144 (see docs/troubleshooting.md).
# Idempotent: TRUNCATE (not append) so a repeat run overwrites, not duplicates (D-08).
# RESEARCH Pitfall 6: must use > not >> on /etc/sysctl.d/99-agmind-es.conf.
_doctor_fix_mapcount() {
    local current
    current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
    current="${current//[^0-9]/}"
    if [[ "${current:-0}" -ge 262144 ]] 2>/dev/null; then
        log_info "fix: vm.max_map_count=${current} уже ≥262144 — пропущено"
        return 0
    fi
    log_info "fix: vm.max_map_count — записываем /etc/sysctl.d/99-agmind-es.conf и применяем sysctl -w"
    # TRUNCATE (>) not append — idempotent per RESEARCH Pitfall 6
    echo "vm.max_map_count=262144" > /etc/sysctl.d/99-agmind-es.conf \
        || { log_warn "fix: не удалось записать /etc/sysctl.d/99-agmind-es.conf"; return 1; }
    sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 \
        || { log_warn "fix: sysctl -w vm.max_map_count=262144 не удался"; return 1; }
    return 0
}

# _doctor_fix_mdns — restart avahi-daemon then agmind-mdns.service.
# WHY: dead mDNS while avahi is alive = agmind-mdns.service failed (see docs/troubleshooting.md).
# Idempotent: systemctl restart is always safe to re-run.
_doctor_fix_mdns() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "fix: systemctl не найден — mDNS restart невозможен"
        return 1
    fi
    log_info "fix: mDNS — перезапускаем avahi-daemon"
    systemctl restart avahi-daemon 2>/dev/null || true
    log_info "fix: mDNS — перезапускаем agmind-mdns.service"
    systemctl restart agmind-mdns.service 2>/dev/null \
        || { log_warn "fix: agmind-mdns.service restart не удался"; return 1; }
    return 0
}

# _doctor_fix_driver_pin — apply apt-mark hold on installed nvidia-* packages.
# WHY: apt-mark hold so unattended-upgrades won't pull 590+ (see docs/adr/0005-driver-580-hold).
# Idempotent: apt-mark hold is safe to repeat; already-held packages stay held.
_doctor_fix_driver_pin() {
    if ! command -v apt-mark >/dev/null 2>&1; then
        log_warn "fix: apt-mark не найден — driver pin невозможен"
        return 1
    fi
    # Prefer calling pin_nvidia_driver_dgx_spark if available (defined in lib/security.sh)
    if declare -F pin_nvidia_driver_dgx_spark >/dev/null 2>&1; then
        DETECTED_DGX_SPARK=true pin_nvidia_driver_dgx_spark
        return $?
    fi
    # Fallback: inline equivalent of pin_nvidia_driver_dgx_spark
    local pkgs=()
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && pkgs+=("$pkg")
    done < <(dpkg -l 2>/dev/null | awk '/^ii  nvidia-(driver|dkms|kernel)/ {print $2}')
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        log_warn "fix: нет установленных nvidia-driver пакетов — pin отложен"
        return 0
    fi
    apt-mark hold "${pkgs[@]}" >/dev/null 2>&1 \
        || { log_warn "fix: apt-mark hold не удался"; return 1; }
    log_info "fix: driver pin выставлен: ${pkgs[*]}"
    return 0
}

# _doctor_dispatch_fix <token> — maps a fix_cmd token to the actual fix helper.
# WHY D-09/D-13: only 3 idempotent auto-fixes; everything else is print-only.
_doctor_dispatch_fix() {
    case "${1:-}" in
        _ensure_es_sysctl|_doctor_fix_mapcount)
            _doctor_fix_mapcount ;;
        _doctor_fix_mdns)
            _doctor_fix_mdns ;;
        pin_nvidia_driver_dgx_spark|_doctor_fix_driver_pin)
            _doctor_fix_driver_pin ;;
        *)
            log_warn "fix: нет обработчика для '${1}' — пропускаем"
            return 1
            ;;
    esac
}

# ============================================================================
# _registry_fix_all — iterate fixable=true records; apply or preview each fix.
# WHY D-08: root-only (gate BEFORE any side effect), non-interactive (no prompts),
#   only the 3 idempotent/non-destructive fixes from D-08 are auto-applied;
#   everything else prints the manual command only (D-09).
# Signature: _registry_fix_all [dry_run_bool]
#   dry_run_bool = "true" → print plan, zero side effects, return 0 (D-10, SC4).
# Exit: _registry_fix_all always returns 0 — caller (doctor_run) re-derives
#   DOCTOR_ERRORS after re-running checks and uses that for the final exit code.
# ============================================================================
_registry_fix_all() {
    local dry_run="${1:-false}"

    # Root gate FIRST — before any side effect (D-10, T-01-12).
    # --dry-run is allowed without root since it performs no side effects (D-10).
    if [[ "$dry_run" != "true" && "$EUID" -ne 0 ]]; then
        log_error "agmind doctor --fix требует root — запустите: sudo agmind doctor --fix"
        return 2
    fi

    local fixed=0 manual=0 fixable_would=0
    local entry id category sev msg fix_hint fixable fix_cmd

    for entry in "${DOCTOR_REGISTRY[@]+"${DOCTOR_REGISTRY[@]}"}"; do
        IFS=$'\x1f' read -r id category sev msg fix_hint fixable fix_cmd <<< "$entry"
        # Only process WARN and FAIL records
        [[ "$sev" == "WARN" || "$sev" == "FAIL" ]] || continue

        if [[ "$fixable" == "true" && -n "$fix_cmd" ]]; then
            if [[ "$dry_run" == "true" ]]; then
                log_info "fix (dry-run): ${id} — would run ${fix_cmd} (${msg})"
                fixable_would=$((fixable_would + 1))
            else
                log_info "fix: ${id} — запускаем ${fix_cmd}"
                set +e
                _doctor_dispatch_fix "$fix_cmd"
                local _fix_rc=$?
                set -e
                if [[ $_fix_rc -eq 0 ]]; then
                    fixed=$((fixed + 1))
                else
                    log_warn "fix: ${fix_cmd} завершился с ошибкой для ${id}"
                fi
            fi
        else
            # Non-fixable: print the manual command (D-09)
            manual=$((manual + 1))
            if [[ -n "$fix_hint" ]]; then
                log_info "manual: ${id} — ${fix_hint}"
            else
                log_info "manual: ${id} — требует ручного вмешательства"
            fi
        fi
    done

    if [[ "$dry_run" == "true" ]]; then
        log_info "fix (dry-run): ${fixable_would} было бы исправлено автоматически, ${manual} требуют ручного действия"
        return 0
    fi

    log_info "fix: ${fixed} исправлено, ${manual} требуют ручного действия"
    return 0
}

# ============================================================================
# SANITIZE HELPER (shared by --bundle, also useful standalone)
# ============================================================================

# _sanitize_text — scrub secret-like values from text (file or stdin).
# WHY D-14.2: docker compose config / .env / docker inspect / journalctl may contain
#   credentials — scrub before writing to the bundle (T-01-09, SC3).
# Accepts a filename OR '-' for stdin (sed reads stdin on '-').
# Four rules: KV-style secrets, Authorization header, Bearer tokens, known weak defaults.
_sanitize_text() {
    # Rule 1: KV-style secrets — match variable names ENDING in sensitive keywords.
    # WHY no \b prefix: composite names like DB_PASSWORD have _ before PASSWORD
    #   which is a word character, so \b before PASSWORD never fires. Instead,
    #   match [A-Za-z0-9_]* prefix so DB_PASSWORD, REDIS_SECRET etc all match.
    # Rule 2: Authorization header value
    # Rule 3: Bearer token (OAuth/JWT)
    # Rule 4: Known weak AGmind default values (belt-and-suspenders)
    sed -E \
        -e 's/([A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|API_?KEY|AUTH_KEY|WEBHOOK_SECRET))([[:space:]]*[=:][[:space:]]*)[^[:space:]"'"'"']{4,}/\1\3<redacted>/gI' \
        -e 's/(_KEY)([[:space:]]*[=:][[:space:]]*)[^[:space:]"'"'"']{4,}/\1\2<redacted>/gI' \
        -e 's/(Authorization:[[:space:]]*).{4,}/\1<redacted>/gI' \
        -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/-]{8,}/Bearer <redacted>/gI' \
        -e 's/\b(difyai123456|QaHbTe77|changeme|admin123)\b/<redacted_default>/gI' \
        "$@"
}

# ============================================================================
# BUNDLE — _doctor_bundle [dry_run_bool]
# WHY D-13/D-14/D-15: collect a WHITELIST of debug artifacts into a mktemp staging
#   dir, scrub all text with _sanitize_text, enforce the BLACKLIST, run a final
#   self-test grep gate BEFORE tar that aborts on any secret-like hit, then
#   tar czf + chmod 600 + validate_path the output (T-01-09 to T-01-15, SC3).
# ============================================================================
_doctor_bundle() {
    local dry_run="${1:-false}"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local bdir="support-bundle-${ts}"

    # Dry-run: print what would be collected, create nothing.
    if [[ "$dry_run" == "true" ]]; then
        log_info "bundle (dry-run): would collect into ${INSTALL_DIR}/${bdir}.tar.gz:"
        log_info "  install.log, versions.env, .env (sanitized), docker compose config (sanitized),"
        log_info "  doctor.json, docker ps -a, docker images, docker system df,"
        log_info "  docker inspect agmind-* (sanitized), nvidia-smi -q, journalctl tails,"
        log_info "  OS/kernel facts, cluster.json, .install_phase"
        log_info "bundle (dry-run): создание архива пропущено"
        return 0
    fi

    # AGmind must be installed
    if [[ ! -d "${INSTALL_DIR}" ]]; then
        log_error "bundle: AGmind не установлен — ${INSTALL_DIR} не найден"
        return 2
    fi

    # Create staging directory with guaranteed cleanup on any return path.
    local staging
    staging="$(mktemp -d)" || { log_error "bundle: mktemp -d не удался"; return 2; }
    # shellcheck disable=SC2064  # intentional: expand $staging at trap-definition time
    trap "rm -rf '${staging}'" RETURN

    mkdir -p "${staging}/${bdir}/system" \
             "${staging}/${bdir}/logs" \
             "${staging}/${bdir}/diagnostics"

    # Disable -e for the collection phase — many sub-commands legitimately fail
    # (journalctl unit not found, nvidia-smi absent, etc.)
    set +e

    # ── meta.json ──────────────────────────────────────────────────────────────
    local _hostname _agmind_ver
    _hostname="$(hostname 2>/dev/null || echo unknown)"
    _agmind_ver="$(cat "${INSTALL_DIR}/RELEASE" 2>/dev/null \
               || cat "$(git rev-parse --show-toplevel 2>/dev/null)/RELEASE" 2>/dev/null \
               || echo unknown)"
    printf '{"timestamp":"%s","hostname":"%s","agmind_version":"%s"}\n' \
        "$ts" "$_hostname" "$_agmind_ver" \
        > "${staging}/${bdir}/meta.json"

    # ── versions.env ───────────────────────────────────────────────────────────
    # WHY: no secrets in versions.env — copy as-is (pinned image:tag list)
    local _venv=""
    if [[ -f "${INSTALL_DIR}/docker/versions.env" ]]; then
        _venv="${INSTALL_DIR}/docker/versions.env"
    elif [[ -f "$(git rev-parse --show-toplevel 2>/dev/null)/core/versions.env" ]]; then
        _venv="$(git rev-parse --show-toplevel 2>/dev/null)/core/versions.env"
    elif [[ -f "$(git rev-parse --show-toplevel 2>/dev/null)/versions.env" ]]; then
        _venv="$(git rev-parse --show-toplevel 2>/dev/null)/versions.env"
    fi
    if [[ -n "$_venv" && -f "$_venv" ]]; then
        cp "$_venv" "${staging}/${bdir}/versions.env"
    else
        printf '(file not found: versions.env)\n' > "${staging}/${bdir}/versions.env"
    fi

    # ── env.sanitized ──────────────────────────────────────────────────────────
    # WHY T-01-09: .env contains all stack passwords — MUST be sanitized before bundle
    if [[ -f "${ENV_FILE}" ]]; then
        _sanitize_text "${ENV_FILE}" > "${staging}/${bdir}/env.sanitized" 2>/dev/null \
            || printf '(sanitize failed for env)\n' > "${staging}/${bdir}/env.sanitized"
    else
        printf '(file not found: %s)\n' "${ENV_FILE}" > "${staging}/${bdir}/env.sanitized"
    fi

    # ── compose.sanitized ─────────────────────────────────────────────────────
    # WHY T-01-09: docker compose config EXPANDS .env → has real secrets (RESEARCH Pitfall 1)
    if [[ -f "${COMPOSE_FILE}" ]]; then
        docker compose -f "${COMPOSE_FILE}" config 2>/dev/null \
            | _sanitize_text - > "${staging}/${bdir}/compose.sanitized" 2>/dev/null \
            || printf '(docker compose config failed)\n' > "${staging}/${bdir}/compose.sanitized"
    else
        printf '(COMPOSE_FILE not found: %s)\n' "${COMPOSE_FILE}" \
            > "${staging}/${bdir}/compose.sanitized"
    fi

    # ── doctor.json ────────────────────────────────────────────────────────────
    # WHY: run_diagnostics in a clean subshell — do not recurse the live registry
    local _repo_root
    _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "${INSTALL_DIR}")"
    (
        export PATH="${PATH}"
        # shellcheck source=/dev/null
        source "${_repo_root}/lib/common.sh"  2>/dev/null || true
        # shellcheck source=/dev/null
        source "${_repo_root}/lib/detect.sh"  2>/dev/null || true
        # shellcheck source=/dev/null
        source "${_repo_root}/lib/health.sh"  2>/dev/null || true
        # shellcheck source=/dev/null
        source "${_repo_root}/lib/doctor.sh"  2>/dev/null || true
        doctor_run --json 2>/dev/null
    ) > "${staging}/${bdir}/doctor.json" 2>/dev/null \
        || printf '{"error":"doctor_run failed"}\n' > "${staging}/${bdir}/doctor.json"

    # ── docker-ps.txt ─────────────────────────────────────────────────────────
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' \
        > "${staging}/${bdir}/docker-ps.txt" 2>/dev/null \
        || printf '(docker ps -a failed)\n' > "${staging}/${bdir}/docker-ps.txt"

    # ── docker-images.txt ─────────────────────────────────────────────────────
    docker images > "${staging}/${bdir}/docker-images.txt" 2>/dev/null \
        || printf '(docker images failed)\n' > "${staging}/${bdir}/docker-images.txt"

    # ── docker-df.txt ─────────────────────────────────────────────────────────
    docker system df -v > "${staging}/${bdir}/docker-df.txt" 2>/dev/null \
        || printf '(docker system df -v failed)\n' > "${staging}/${bdir}/docker-df.txt"

    # ── docker-inspect.txt ────────────────────────────────────────────────────
    # WHY T-01-09: docker inspect env sections contain secrets — MUST sanitize
    {
        local _c
        for _c in $(docker ps -a --format '{{.Names}}' 2>/dev/null \
                    | grep '^agmind-' || true); do
            docker inspect "$_c" 2>/dev/null || true
        done
    } | _sanitize_text - > "${staging}/${bdir}/docker-inspect.txt" 2>/dev/null \
        || printf '(docker inspect failed)\n' > "${staging}/${bdir}/docker-inspect.txt"

    # ── nvidia-smi.txt ────────────────────────────────────────────────────────
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi -q > "${staging}/${bdir}/nvidia-smi.txt" 2>/dev/null \
            || printf '(nvidia-smi -q failed)\n' > "${staging}/${bdir}/nvidia-smi.txt"
    else
        printf '(nvidia-smi not installed)\n' > "${staging}/${bdir}/nvidia-smi.txt"
    fi

    # ── system/* ──────────────────────────────────────────────────────────────
    uname -a > "${staging}/${bdir}/system/uname.txt" 2>/dev/null \
        || printf '(uname -a failed)\n' > "${staging}/${bdir}/system/uname.txt"

    cat /etc/os-release > "${staging}/${bdir}/system/os-release.txt" 2>/dev/null \
        || printf '(os-release not found)\n' > "${staging}/${bdir}/system/os-release.txt"

    { free -h; echo; grep -E 'MemTotal|MemAvailable|Swap' /proc/meminfo; } \
        > "${staging}/${bdir}/system/meminfo.txt" 2>/dev/null \
        || printf '(meminfo failed)\n' > "${staging}/${bdir}/system/meminfo.txt"

    sysctl -a 2>/dev/null | grep -E 'max_map_count|swappiness|vm\.' \
        > "${staging}/${bdir}/system/sysctl.txt" 2>/dev/null \
        || printf '(sysctl -a failed)\n' > "${staging}/${bdir}/system/sysctl.txt"

    df -h > "${staging}/${bdir}/system/df.txt" 2>/dev/null \
        || printf '(df -h failed)\n' > "${staging}/${bdir}/system/df.txt"

    local _cluster_file="${AGMIND_CLUSTER_STATE_FILE:-/var/lib/agmind/state/cluster.json}"
    if [[ -f "$_cluster_file" ]]; then
        cp "$_cluster_file" "${staging}/${bdir}/system/cluster.json"
    else
        printf '(file not found: %s)\n' "$_cluster_file" \
            > "${staging}/${bdir}/system/cluster.json"
    fi

    # ── logs/* ────────────────────────────────────────────────────────────────
    # WHY T-01-09: install.log may contain secrets leaked via env expansions — sanitize
    if [[ -f "${INSTALL_DIR}/install.log" ]]; then
        _sanitize_text "${INSTALL_DIR}/install.log" \
            > "${staging}/${bdir}/logs/install.log.sanitized" 2>/dev/null \
            || printf '(install.log sanitize failed)\n' \
               > "${staging}/${bdir}/logs/install.log.sanitized"
    else
        printf '(file not found: %s/install.log)\n' "${INSTALL_DIR}" \
            > "${staging}/${bdir}/logs/install.log.sanitized"
    fi

    journalctl -u agmind-stack --no-pager -n 500 \
        > "${staging}/${bdir}/logs/agmind-stack.log" 2>/dev/null \
        || printf '(journalctl -u agmind-stack failed or unit not found)\n' \
           > "${staging}/${bdir}/logs/agmind-stack.log"

    journalctl -u agmind-mdns --no-pager -n 100 \
        > "${staging}/${bdir}/logs/agmind-mdns.log" 2>/dev/null \
        || printf '(journalctl -u agmind-mdns failed or unit not found)\n' \
           > "${staging}/${bdir}/logs/agmind-mdns.log"

    journalctl -u avahi-daemon --no-pager -n 50 \
        > "${staging}/${bdir}/logs/avahi-daemon.log" 2>/dev/null \
        || printf '(journalctl -u avahi-daemon failed or unit not found)\n' \
           > "${staging}/${bdir}/logs/avahi-daemon.log"

    # ── diagnostics/* ─────────────────────────────────────────────────────────
    # Capture derived facts from run_diagnostics in a subshell
    if declare -F run_diagnostics >/dev/null 2>&1; then
        ( run_diagnostics ) > "${staging}/${bdir}/diagnostics/run_diagnostics.txt" 2>&1 \
            || printf '(run_diagnostics failed)\n' \
               > "${staging}/${bdir}/diagnostics/run_diagnostics.txt"
    else
        printf '(run_diagnostics not available — lib/detect.sh not sourced)\n' \
            > "${staging}/${bdir}/diagnostics/run_diagnostics.txt"
    fi

    if [[ -f "${INSTALL_DIR}/.install_phase" ]]; then
        cat "${INSTALL_DIR}/.install_phase" \
            > "${staging}/${bdir}/diagnostics/install_phase.txt" 2>/dev/null \
            || printf '(read failed)\n' \
               > "${staging}/${bdir}/diagnostics/install_phase.txt"
    else
        printf '(file not found: %s/.install_phase)\n' "${INSTALL_DIR}" \
            > "${staging}/${bdir}/diagnostics/install_phase.txt"
    fi

    # ── README.txt ────────────────────────────────────────────────────────────
    cat > "${staging}/${bdir}/README.txt" <<BUNDLE_README
AGmind Support Bundle — ${ts}
Hostname: ${_hostname}
AGmind version: ${_agmind_ver}

Contents (sanitized — credentials removed):
  meta.json              — bundle metadata
  versions.env           — pinned image:tag list (no secrets)
  env.sanitized          — .env with all secrets redacted
  compose.sanitized      — docker compose config with secrets redacted
  doctor.json            — agmind doctor --json output
  docker-ps.txt          — docker ps -a
  docker-images.txt      — docker images
  docker-df.txt          — docker system df -v
  docker-inspect.txt     — docker inspect agmind-* (secrets redacted)
  nvidia-smi.txt         — nvidia-smi -q (if available)
  system/                — uname, OS release, meminfo, sysctl, df, cluster.json
  logs/                  — install.log (sanitized), journalctl tails
  diagnostics/           — run_diagnostics output, .install_phase
  BUNDLE_MANIFEST.txt    — sha256 checksums of all files

ВАЖНО: содержимое очищено от credentials, но ПРОВЕРЬТЕ перед отправкой.
Команда проверки: tar tzf <bundle.tar.gz> (просмотр файлов)
BUNDLE_README

    # ── BUNDLE_MANIFEST.txt (written last, before self-test) ──────────────────
    find "${staging}/${bdir}" -type f -exec sha256sum {} \; \
        | sed "s|${staging}/||" \
        > "${staging}/${bdir}/BUNDLE_MANIFEST.txt" 2>/dev/null \
        || printf '(manifest generation failed)\n' \
           > "${staging}/${bdir}/BUNDLE_MANIFEST.txt"

    # ── DEFENSIVE BLACKLIST CHECK ──────────────────────────────────────────────
    # WHY T-01-10: belt-and-suspenders — whitelist approach shouldn't produce these,
    #   but check anyway (D-14.1).
    local _bl_hits
    _bl_hits="$(find "$staging" -type f \
        \( -name 'credentials.txt' \
        -o -name '.admin_password' \
        -o -name '*.key' \
        -o -name '*.pem' \
        -o -name '*.p12' \
        -o -name 'age.key' \) 2>/dev/null | head -5 || true)"
    if [[ -n "$_bl_hits" ]]; then
        log_error "ABORT: blacklisted файл обнаружен в staging: ${_bl_hits}"
        # rm -rf handled by trap
        return 2
    fi

    # ── FINAL SELF-TEST GATE (D-14.3 — HARD GATE, run BEFORE tar) ─────────────
    # WHY T-01-09: abort BEFORE creating the tar if any secret survived sanitization.
    # Print only FILE names, NEVER the matching lines or values (security: never expose credential values).
    if grep -rEiq \
        '(password|secret|token|bearer|api[_-]?key)[[:space:]]*[=:][[:space:]]*[a-zA-Z0-9]{8,}' \
        "${staging}/" 2>/dev/null; then
        local _hit_files
        _hit_files="$(grep -rEil \
            '(password|secret|token|bearer|api[_-]?key)[[:space:]]*[=:][[:space:]]*[a-zA-Z0-9]{8,}' \
            "${staging}/" 2>/dev/null | head -3 || true)"
        log_error "ABORT: возможные credentials выжили после санитизации: ${_hit_files}"
        log_error "Tar НЕ создан. Проверьте _sanitize_text и повторите."
        # rm -rf handled by trap
        return 2
    fi

    # ── FINISH — create archive ────────────────────────────────────────────────
    set -e
    local out="${INSTALL_DIR}/${bdir}.tar.gz"

    # Validate output path (T-01-11: path traversal guard)
    validate_path "$out" >/dev/null 2>&1 || {
        log_error "bundle: path rejected by validate_path: ${out}"
        return 2
    }

    tar czf "$out" -C "$staging" "${bdir}/" 2>/dev/null || {
        log_error "bundle: tar czf не удался"
        return 2
    }

    # WHY T-01-14: chmod 600 immediately after tar — no world-readable bundle
    chmod 600 "$out"

    # rm -rf staging handled by trap on RETURN

    log_success "support bundle: ${out} ($(du -h "$out" 2>/dev/null | cut -f1))"
    log_info "проверьте содержимое перед отправкой: tar tzf ${out}"
    return 0
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# doctor_run [--preflight|--full] [--json] [--fix [--dry-run]] [--bundle] [--peer]
# Exit codes (D-05): 0 = all OK/SKIP, 1 = WARN, 2 = FAIL.
doctor_run() {
    local output_json=false
    local do_fix=false
    local dry_run=false
    local do_bundle=false
    local mode="full"
    local peer_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --preflight)       mode="preflight" ;;
            --full)            mode="full" ;;
            --json)            output_json=true ;;
            --fix)             do_fix=true ;;
            --dry-run)         dry_run=true ;;
            --bundle)          do_bundle=true ;;
            --peer)            peer_only=true ;;
            # --check-registry: parsed but body not implemented until Phase 4
            --check-registry)  log_warn "doctor: --check-registry не реализован (Phase 4)" ;;
            *)
                log_warn "doctor: неизвестный флаг '${1}' (проигнорирован)"
                ;;
        esac
        shift
    done

    # Reset registry for idempotent invocations (Pitfall 4 from RESEARCH.md)
    _registry_reset

    # Bundle shortcut — delegates to _doctor_bundle (01-03 body implemented)
    if [[ "$do_bundle" == "true" ]]; then
        _doctor_bundle "$dry_run"
        return $?
    fi

    # --peer mode: only peer section then exit
    if [[ "$peer_only" == "true" ]]; then
        doctor_check_peer
        _registry_count
        if [[ "$output_json" == "true" ]]; then
            _registry_render_json
        else
            _registry_render_human
            echo ""
            if [[ "$DOCTOR_ERRORS" -gt 0 ]]; then
                echo -e "  ${RED}${DOCTOR_ERRORS} ошибок, ${DOCTOR_WARNINGS} предупреждений${NC}"
            elif [[ "$DOCTOR_WARNINGS" -gt 0 ]]; then
                echo -e "  ${YELLOW}${DOCTOR_WARNINGS} предупреждений${NC}"
            else
                echo -e "  ${GREEN}Peer: все проверки пройдены${NC}"
            fi
        fi
        if [[ "$DOCTOR_ERRORS" -gt 0 ]]; then return 2
        elif [[ "$DOCTOR_WARNINGS" -gt 0 ]]; then return 1
        else return 0; fi
    fi

    # Run checks in D-04 category order
    if [[ "$mode" == "preflight" ]]; then
        # Preflight subset: install-time checks (no container/service/install-state checks)
        doctor_check_arch_driver
        doctor_check_docker
        doctor_check_kernel
        doctor_check_dns_mdns
        doctor_check_gpu
        doctor_check_resources
        doctor_check_ports
    else
        # Full mode (default): all 13 checks in D-04 order
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
    fi

    # Auto-fix pass (D-08/D-09/D-10): implemented in 01-03
    if [[ "$do_fix" == "true" ]]; then
        local _fix_rc=0
        _registry_fix_all "$dry_run" || _fix_rc=$?
        # Root gate returns 2 — propagate immediately (no checks to re-run)
        if [[ $_fix_rc -eq 2 && "$dry_run" != "true" ]]; then
            return 2
        fi
        # After a real fix pass, re-run all checks so registry reflects the new state
        # (sysctl/systemctl changes are now visible). Dry-run: no re-run needed.
        if [[ "$dry_run" != "true" ]]; then
            _registry_reset
            if [[ "$mode" == "preflight" ]]; then
                doctor_check_arch_driver
                doctor_check_docker
                doctor_check_kernel
                doctor_check_dns_mdns
                doctor_check_gpu
                doctor_check_resources
                doctor_check_ports
            else
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
            fi
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
        if [[ "$DOCTOR_ERRORS" -gt 0 ]]; then
            echo -e "  ${RED}${DOCTOR_ERRORS} ошибок, ${DOCTOR_WARNINGS} предупреждений${NC}"
        elif [[ "$DOCTOR_WARNINGS" -gt 0 ]]; then
            echo -e "  ${YELLOW}${DOCTOR_WARNINGS} предупреждений${NC}"
        else
            echo -e "  ${GREEN}Все проверки пройдены${NC}"
        fi
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
