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
# WHY: aarch64-only since v3.1; driver 580 HOLD mandatory (CLAUDE.md §6/§8)
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
    # WHY FAIL ≥590 (CLAUDE.md §8): три регрессии на GB10 UMA — CUDAGraph deadlock,
    #   UMA memory leak, Blackwell TMA bug. NVIDIA staff: not supported past 580.126.09.
    if [[ "${drv_major:-0}" -ge 590 ]] 2>/dev/null; then
        _registry_add "driver_version" "arch-driver" "FAIL" \
            "NVIDIA driver ${drv} — FAIL: ≥590 сломан на DGX Spark GB10 (CUDAGraph deadlock / UMA leak / TMA bug)" \
            "Downgrade: sudo apt install nvidia-driver-580-open; sudo reboot — NVIDIA не поддерживает >580.126.09 на Spark (CLAUDE.md §8)"
    elif [[ "${drv_major:-0}" -ge 580 ]] 2>/dev/null; then
        _registry_add "driver_version" "arch-driver" "OK" \
            "NVIDIA driver ${drv} (580.x — golden для DGX Spark)"
    else
        _registry_add "driver_version" "arch-driver" "WARN" \
            "NVIDIA driver ${drv} — версия ниже 580.x, ожидается 580.142 на DGX Spark"
    fi

    # Driver pin check (apt-mark showhold)
    # WHY: driver 580 must be held to prevent unattended-upgrades pulling 590+ (CLAUDE.md §8)
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
            # WHY WARN fixable: unattended-upgrades may pull 590+ which breaks Spark (CLAUDE.md §8)
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
# WHY WARN/FAIL: ES bootstrap hard-fails if < 262144 (CLAUDE.md §8)
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
        # WHY FAIL if RAGFlow active: ES requires this for bootstrap (CLAUDE.md §8)
        local ragflow_active
        ragflow_active="$(_doctor_read_env_safe ENABLE_RAGFLOW false)"
        if [[ "$ragflow_active" == "true" ]]; then
            _registry_add "vm_max_map_count" "kernel-params" "FAIL" \
                "vm.max_map_count=${mmc} — FAIL: <262144 и ENABLE_RAGFLOW=true (ES не запустится)" \
                "sudo agmind doctor --fix (sysctl + /etc/sysctl.d/99-agmind-es.conf) — ES требует ≥262144 (CLAUDE.md §8)" \
                true "_ensure_es_sysctl"
        else
            _registry_add "vm_max_map_count" "kernel-params" "WARN" \
                "vm.max_map_count=${mmc} — <262144 (нужно для Elasticsearch/RAGFlow)" \
                "sudo agmind doctor --fix (sysctl + /etc/sysctl.d/99-agmind-es.conf) — ES требует ≥262144 (CLAUDE.md §8)" \
                true "_ensure_es_sysctl"
        fi
    fi
}

# ----------------------------------------------------------------------------
# doctor_check_dns_mdns — DNS resolve, mDNS status, foreign :5353 responder
# WHY: dead mDNS / foreign responder are known §8 failure classes (CLAUDE.md §8)
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
                # WHY: dead mDNS while avahi is alive = agmind-mdns.service failed (CLAUDE.md §8)
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
    # WHY: second mDNS responder on :5353 breaks avahi and all agmind-*.local aliases (CLAUDE.md §8)
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
            "NoMachine: EnableLocalNetworkBroadcast 0 в /etc/NX/server/localhost/server.cfg; systemctl restart nxserver (CLAUDE.md §8)"
    fi
    rm -f "$_foreign_tmp"
}

# ----------------------------------------------------------------------------
# doctor_check_gpu — host nvidia-smi, nvidia runtime, GPU-in-container visibility
# WHY: NVIDIA_DRIVER_CAPABILITIES=compute,utility mandatory on Spark (CLAUDE.md §8)
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
    set +e
    docker info 2>/dev/null | grep -qi "nvidia"
    local _nr_rc=$?
    set -e
    if [[ $_nr_rc -eq 0 ]]; then
        _registry_add "nvidia_runtime" "gpu" "OK" "NVIDIA Container Toolkit: настроен"
    else
        _registry_add "nvidia_runtime" "gpu" "WARN" \
            "NVIDIA runtime не зарегистрирован в docker info" \
            "Настройте nvidia-container-toolkit: nvidia-ctk runtime configure --runtime=docker"
    fi

    # GPU-in-container visibility for vllm and docling
    local llm_on_peer
    llm_on_peer="$(_doctor_read_env_safe LLM_ON_PEER false)"
    for svc in vllm docling; do
        local cname="agmind-${svc}"
        # WHY: vLLM on peer node (LLM_ON_PEER=true) — skip local GPU check (CLAUDE.md §6)
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
                        "Добавить NVIDIA_DRIVER_CAPABILITIES=compute,utility в compose env (CLAUDE.md §8)"
                elif [[ "$torch_out" == "nopython" ]]; then
                    _registry_add "gpu_in_${svc}" "gpu" "SKIP" \
                        "${cname}: nvidia-smi -L failed но python3 недоступен для torch-check"
                else
                    _registry_add "gpu_in_${svc}" "gpu" "OK" \
                        "${cname}: torch.cuda.is_available()=True"
                fi
            else
                # WHY FAIL: NVIDIA_DRIVER_CAPABILITIES=compute,utility обязательно на Spark (CLAUDE.md §8)
                _registry_add "gpu_in_${svc}" "gpu" "FAIL" \
                    "${cname}: NVIDIA_DRIVER_CAPABILITIES=compute отсутствует в env контейнера — GPU недоступен" \
                    "Добавить NVIDIA_DRIVER_CAPABILITIES=compute,utility в compose env (CLAUDE.md §8)"
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
    for port in 80 443; do
        local pp
        pp="$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 || true)"
        if [[ -z "$pp" ]]; then
            _registry_add "port_${port}" "ports" "OK" "Port ${port}: свободен"
        elif echo "$pp" | grep -q "agmind\|nginx\|docker"; then
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
# WHY: catches images not yet pulled before docker compose up fails (CLAUDE.md §8)
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
                    # WHY: report as set/unset only — never the value (THREAT T-01-04 / CLAUDE.md §5)
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
# WHY: read-only subset of Phase 7 security audit (CLAUDE.md §8)
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
# WHY: missing loadtest scripts = _copy_runtime_files script_subdirs regression (CLAUDE.md §8)
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
    # WHY: missing scripts/loadtest = _copy_runtime_files script_subdirs whitelist regression (CLAUDE.md §8)
    local ld_dir="${MOCK_LOADTEST_DIR:-${INSTALL_DIR}/scripts/loadtest}"
    if [[ -d "$ld_dir" && -n "$(ls -A "$ld_dir" 2>/dev/null)" ]]; then
        _registry_add "loadtest_scripts" "install-state" "OK" \
            "loadtest скрипты присутствуют в ${ld_dir}"
    else
        _registry_add "loadtest_scripts" "install-state" "WARN" \
            "loadtest dir пуст или отсутствует (${ld_dir}) — регрессия _copy_runtime_files script_subdirs whitelist" \
            "sudo bash install.sh (CLAUDE.md §8)"
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
# FIX + BUNDLE (--fix body stub until 01-03, --bundle stub until 01-03)
# ============================================================================

# _registry_fix_all [--dry-run] — iterate fixable=true records, apply fix_cmd.
# WHY D-08: only idempotent, non-destructive fixes: sysctl, mDNS restart, driver pin.
# Body stub: plan 01-03 fills the --fix implementation.
_registry_fix_all() {
    local dry_run=false
    [[ "${1:-}" == "--dry-run" ]] && dry_run=true
    log_warn "agmind doctor --fix не реализован (Phase 1 plan 01-03)"
    return 1
}

# _doctor_bundle — create sanitized support archive.
# WHY D-13/D-14/D-15: tar.gz with whitelist + post-collection scrub + self-test gate.
_doctor_bundle() {
    log_error "agmind doctor --bundle не реализован (Phase 1 plan 01-03)"
    return 2
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

    # Bundle shortcut — delegates to _doctor_bundle (01-03 fills body)
    if [[ "$do_bundle" == "true" ]]; then
        _doctor_bundle
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

    # Auto-fix pass — stub until 01-03
    if [[ "$do_fix" == "true" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            _registry_fix_all --dry-run || true
        else
            _registry_fix_all || true
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
