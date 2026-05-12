#!/usr/bin/env bash
# estimate.sh — `agmind profiles` / `agmind estimate` backing logic.
# Provides:  profiles_list [--json]                      — table of 8 named profiles + active
#            estimate_resources [<profile>] [--json]     — RAM/disk/GPU estimate vs host resources
# Dependencies: lib/service-map.sh (NAMED_PROFILE_EXPANSION/DESC), python3 (mem_limit
#               regex parsing + JSON output), nvidia-smi/free/df (host resources).
# Expects:   INSTALL_DIR (default /opt/agmind). Read-only — no root. Never reads .env secrets.
# CLAUDE.md §6/§8: GB10 unified memory; NVML returns N/A for `memory.used`; budget 121→85 GiB.
set -euo pipefail

[[ -n "${_ESTIMATE_LOADED:-}" ]] && return 0
_ESTIMATE_LOADED=1

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# FALLBACK SHIMS (chain may not source common.sh / health.sh)
# ============================================================================

# shellcheck disable=SC2317
type log_info  >/dev/null 2>&1 || log_info()  { echo "$*"; }
# shellcheck disable=SC2317
type log_warn  >/dev/null 2>&1 || log_warn()  { echo "WARN: $*" >&2; }
# shellcheck disable=SC2317
type log_error >/dev/null 2>&1 || log_error() { echo "ERROR: $*" >&2; }

# ============================================================================
# GUARD-SOURCE service-map.sh (NAMED_PROFILE_EXPANSION / NAMED_PROFILE_DESC)
# ============================================================================

if [[ -z "${_SERVICE_MAP_LOADED:-}" ]]; then
    _SM_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    source "${_SM_SELF_DIR}/service-map.sh" 2>/dev/null || true
fi

# Canonical profile order (display + validation allowlist)
_NAMED_PROFILE_ORDER="core rag ragflow observability security agents full dev"

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

# Return the compose file to analyse: installed copy → repo template fallback.
_est_compose_file() {
    if [[ -f "${INSTALL_DIR}/docker/docker-compose.yml" ]]; then
        echo "${INSTALL_DIR}/docker/docker-compose.yml"
    else
        # Fallback: repo template (when AGmind not yet installed)
        local _selfdir; _selfdir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        echo "${_selfdir}/templates/docker-compose.yml"
    fi
}

# Read DEPLOY_PROFILE from .env only — no other key.
_est_active_profile() {
    local _envf="${INSTALL_DIR}/docker/.env"
    [[ -f "$_envf" ]] || { echo ""; return 0; }
    grep -E '^DEPLOY_PROFILE=' "$_envf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || echo ""
}

# Read a single boolean-ish flag key from .env (used only for LLM_ON_PEER).
_est_env_flag() {
    local _key="$1" _envf="${INSTALL_DIR}/docker/.env"
    [[ -f "$_envf" ]] || { echo ""; return 0; }
    grep -E "^${_key}=" "$_envf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || echo ""
}

# List compose service names whose `profiles:` tag matches any element of the
# given comma-separated raw-profile set, plus always-on services (no profiles: tag).
# Uses python3 to parse the YAML-ish file structure; handles both inline
#   profiles: ["a","b"]  and block  profiles:\n  - a  forms.
# Never uses Python's yaml module — the compose file contains ${VAR:-x} shell expansions
# that break the YAML parser (RESEARCH Pitfall 4). Pure regex line-scanner instead.
_est_services_for_profiles() {  # args: compose_file raw_csv
    local _cf="$1" _raw="$2"
    python3 - "$_cf" "$_raw" <<'PY'
import sys, re
cf, raw = sys.argv[1], sys.argv[2]
wanted = set(p.strip() for p in raw.split(",") if p.strip())
wanted.add("_always")
svc = None
svc_profiles = {}
lines = open(cf, encoding="utf-8", errors="replace").read().splitlines()
in_services = False
for i, l in enumerate(lines):
    # Top-level section headers (no leading whitespace, end with colon)
    if re.match(r'^[A-Za-z0-9_.-]+:\s*$', l) or re.match(r'^x-', l):
        if l.startswith('services:'):
            in_services = True
        else:
            in_services = False  # left services section (volumes/networks/etc)
        svc = None
        continue
    if not in_services:
        continue
    # Service definition: exactly two-space indent + identifier + colon
    m = re.match(r'^  ([A-Za-z0-9_.@-]+):\s*$', l)
    if m:
        svc = m.group(1)
        svc_profiles[svc] = set()
        continue
    if svc is None:
        continue
    # Inline form: profiles: ["a", "b"]
    m = re.match(r'^\s{4,}profiles:\s*\[(.*)\]\s*$', l)
    if m:
        for p in re.findall(r'["\']?([A-Za-z0-9_.@-]+)["\']?', m.group(1)):
            if p:
                svc_profiles[svc].add(p)
        continue
    # Block form: profiles:\n  - a
    if re.match(r'^\s{4,}profiles:\s*$', l):
        j = i + 1
        while j < len(lines) and re.match(r'^\s+-\s', lines[j]):
            p = lines[j].strip()[1:].strip().strip('"\'')
            if p:
                svc_profiles[svc].add(p)
            j += 1
        continue
out = []
for s, profs in svc_profiles.items():
    if not profs:
        if "_always" in wanted:
            out.append(s)
    elif profs & wanted:
        out.append(s)
print(" ".join(sorted(set(out))))
PY
}

# Return mem_limit GiB (float string) for one service, parsing raw lines.
# Handles literal values (96g, 256m) and ${VAR:-Ng} shell-expansion defaults.
_est_mem_for_service() {  # args: compose_file service
    local _cf="$1" _svc="$2"
    python3 - "$_cf" "$_svc" <<'PY'
import sys, re
cf, svc = sys.argv[1], sys.argv[2]
lines = open(cf, encoding="utf-8", errors="replace").read().splitlines()
in_svc = False
val = None
for l in lines:
    m = re.match(r'^  ([A-Za-z0-9_.@-]+):\s*$', l)
    if m:
        in_svc = (m.group(1) == svc)
        continue
    if not in_svc:
        continue
    m = re.match(r'^\s+mem_limit:\s*(.+?)\s*$', l)
    if m:
        raw = m.group(1).strip().strip('"\'')
        # Extract default value from ${VAR:-Ng} or ${VAR:-N}
        mm = re.search(r'\$\{[^}]*:-?\s*([0-9]+(?:\.[0-9]+)?[gGmMkK]?)\s*\}', raw)
        if mm:
            raw = mm.group(1)
        m2 = re.match(r'^([0-9]+(?:\.[0-9]+)?)\s*([gGmMkK]?)$', raw)
        if m2:
            n = float(m2.group(1))
            u = m2.group(2).lower()
            if u == 'm':
                n = n / 1024
            elif u == 'k':
                n = n / 1024 / 1024
            # 'g' or '' treated as GiB
            val = n
        break
print(f"{val if val is not None else 0:.4f}")
PY
}

# Extract gpu_memory_utilization from the compose file for vllm (best-effort).
_est_vllm_gpu_util() {
    local _cf="$1"
    grep -oE 'gpu.memory.utilization[^0-9]*([0-9]\.[0-9]+)' "$_cf" 2>/dev/null \
        | grep -oE '[0-9]\.[0-9]+' | head -1 \
        || echo "0.60"
}

# ============================================================================
# PUBLIC: estimate_resources [<profile>] [--json]
# ============================================================================
#
# Exit codes: 0 = normal display; 1 = RAM estimate exceeds available; 2 = bad arg.
# CLAUDE.md §8: GPU budget note (121→85 GiB usable after core/buffer/swap headroom);
# NVML returns N/A for memory.used on GB10 — use memory.total + budget note.

estimate_resources() {
    local _profile="" _json=false _a
    for _a in "$@"; do
        case "$_a" in
            --json) _json=true ;;
            -*)     ;;  # ignore other flags silently
            *)      [[ -z "$_profile" ]] && _profile="$_a" ;;
        esac
    done

    # Resolve target profile: arg → active DEPLOY_PROFILE → full
    [[ -z "$_profile" ]] && _profile="$(_est_active_profile)"
    # 'custom' / 'lan' / empty → fall back to full
    case " ${_profile:-} " in
        " custom "| " lan "| "  ") _profile="full" ;;
    esac

    # Validate against allowlist (security: reject unknown profile names)
    case " $_NAMED_PROFILE_ORDER " in
        *" $_profile "*) : ;;
        *) log_error "Unknown profile '$_profile' — valid: $_NAMED_PROFILE_ORDER"; return 2 ;;
    esac

    # Resolve compose file
    local _cf; _cf="$(_est_compose_file)"
    if [[ ! -f "$_cf" ]]; then
        log_error "Compose file not found: $_cf"
        return 1
    fi

    # Expand named profile → raw compose profile CSV
    local _raw="${NAMED_PROFILE_EXPANSION[$_profile]:-}"

    # LLM_ON_PEER flag (from .env only — security: no other .env key read)
    local _on_peer; _on_peer="$(_est_env_flag LLM_ON_PEER)"
    # Allow env override for testing
    [[ -n "${LLM_ON_PEER:-}" ]] && _on_peer="${LLM_ON_PEER}"

    # Enumerate services in the profile set
    local _svc_list; _svc_list="$(_est_services_for_profiles "$_cf" "$_raw")"

    # ── Per-service accumulation ──
    local _total=0 _gpu_approx=0
    local -a _rows=() _warnings=()
    local _s _mem _isgpu

    for _s in $_svc_list; do
        # Exclude vllm from master estimate when running on peer
        if [[ "$_s" == "vllm" && "$_on_peer" == "true" ]]; then
            continue
        fi

        _mem="$(_est_mem_for_service "$_cf" "$_s")"
        _isgpu="no"
        case "$_s" in vllm|docling|ragflow) _isgpu="yes" ;; esac

        _rows+=("${_s}|${_mem}|${_isgpu}")
        _total="$(python3 -c "print(f'{${_total} + ${_mem}:.4f}')")"

        if [[ "$_isgpu" == "yes" ]]; then
            if [[ "$_s" == "vllm" ]]; then
                local _util; _util="$(_est_vllm_gpu_util "$_cf")"
                _gpu_approx="$(python3 -c "print(f'{${_gpu_approx} + 124*${_util}:.1f}')")"
            else
                # docling/ragflow: ~8 GiB peak on GB10 unified memory
                _gpu_approx="$(python3 -c "print(f'{${_gpu_approx} + 8:.1f}')")"
            fi
        fi
    done

    # Rough disk estimate: ~0.3 GiB per service image + 55 GiB for vllm model cache
    local _nsvc; _nsvc="$(echo "$_svc_list" | wc -w)"
    local _has_local_vllm="no"
    [[ " $_svc_list " == *" vllm "* && "$_on_peer" != "true" ]] && _has_local_vllm="yes"
    local _disk_approx
    _disk_approx="$(python3 -c "print(round(${_nsvc}*0.3 + (55 if '${_has_local_vllm}'=='yes' else 0)))")"

    # ── Host resources ──
    local _ram_avail _disk_avail _gpu_total_raw _gpu_total_gib _gpu_note

    # Use /proc/meminfo for RAM (locale-independent; `free -g` returns localised headers
    # on some systems, e.g. Russian 'Память:' instead of 'Mem:').
    # Report GiB (integer) of total RAM for comparison with mem_limit sum.
    _ram_avail="$(awk '/^MemTotal:/{print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    # Also try the mock (MOCK_FREE_FIXTURE) path so unit tests work as expected:
    # the free mock outputs 'Mem: <total>' — honour it if it returns a value.
    local _free_val; _free_val="$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')"
    [[ -n "$_free_val" ]] && _ram_avail="$_free_val"

    _disk_avail="$(df -BG / 2>/dev/null | tail -1 | awk '{val=$4; gsub(/G/,"",val); print val}' || echo 0)"
    [[ -z "$_disk_avail" ]] && _disk_avail=0

    _gpu_total_raw="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
        | head -1 | tr -d ' ' || true)"

    if [[ -z "$_gpu_total_raw" || "$_gpu_total_raw" == *"N/A"* ]]; then
        # CLAUDE.md §8: GB10 unified memory — NVML returns N/A for memory.used;
        # use /proc/meminfo MemTotal as the unified pool size.
        _gpu_total_gib="$(awk '/^MemTotal:/{print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
        _gpu_note="unified memory — NVML returns N/A for used (CLAUDE.md §8); ~${_gpu_total_gib} GiB total, ~85 GiB usable after core/buffer/swap headroom"
    else
        _gpu_total_gib="$(python3 -c "print(int(${_gpu_total_raw}/1024))")"
        _gpu_note="unified memory — ~${_gpu_total_gib} GiB total, ~85 GiB usable after core/buffer/swap headroom (CLAUDE.md §8)"
    fi

    # ── Warnings + exit code ──
    local _rc=0
    if python3 -c "import sys; sys.exit(0 if ${_total} > ${_ram_avail} else 1)" 2>/dev/null; then
        _warnings+=("RAM estimate (${_total} GiB) exceeds available (${_ram_avail} GiB)")
        _rc=1
    fi
    if python3 -c "import sys; sys.exit(0 if ${_disk_approx} > ${_disk_avail} else 1)" 2>/dev/null; then
        _warnings+=("Disk estimate (~${_disk_approx} GiB) exceeds free (${_disk_avail} GiB)")
    fi

    # ── Output ──
    if [[ "$_json" == "true" ]]; then
        local _active; _active="$(_est_active_profile)"
        ESTIMATE_PROFILE="$_profile" \
        ESTIMATE_TOTAL="$_total" \
        ESTIMATE_DISK="$_disk_approx" \
        ESTIMATE_GPU="$_gpu_approx" \
        ESTIMATE_RAM_AVAIL="$_ram_avail" \
        ESTIMATE_DISK_AVAIL="$_disk_avail" \
        ESTIMATE_GPU_AVAIL="$_gpu_total_gib" \
        ESTIMATE_ROWS="$(printf '%s\n' "${_rows[@]+"${_rows[@]}"}")" \
        ESTIMATE_WARN="$(printf '%s\n' "${_warnings[@]+"${_warnings[@]}"}")" \
        python3 - <<'PY'
import os, json
rows = []
for line in os.environ.get("ESTIMATE_ROWS", "").splitlines():
    if not line.strip():
        continue
    parts = line.split("|")
    if len(parts) < 3:
        continue
    n, m, g = parts[0], parts[1], parts[2]
    rows.append({"name": n, "mem_limit_gib": float(m), "gpu": (g == "yes")})
warn = [w for w in os.environ.get("ESTIMATE_WARN", "").splitlines() if w.strip()]
print(json.dumps({
    "profile": os.environ["ESTIMATE_PROFILE"],
    "services": rows,
    "total": {
        "ram_gib": float(os.environ["ESTIMATE_TOTAL"]),
        "disk_gib_approx": float(os.environ["ESTIMATE_DISK"]),
        "gpu_gib_approx": float(os.environ["ESTIMATE_GPU"]),
    },
    "available": {
        "ram_gib": float(os.environ["ESTIMATE_RAM_AVAIL"]),
        "disk_gib": float(os.environ["ESTIMATE_DISK_AVAIL"]),
        "gpu_gib": float(os.environ["ESTIMATE_GPU_AVAIL"]),
    },
    "warnings": warn,
}, indent=2))
PY
    else
        # Human-readable table
        local _active; _active="$(_est_active_profile)"
        local _active_mark=""; [[ "$_profile" == "$_active" ]] && _active_mark=" (active)"
        echo "Profile: ${_profile}${_active_mark}"
        [[ "$_on_peer" == "true" ]] && \
            echo "Cluster: LLM_ON_PEER=true — vllm excluded from this (master) estimate (runs on peer)"
        [[ "$_cf" != "${INSTALL_DIR}/docker/docker-compose.yml" ]] && \
            echo "Note: AGmind not installed — using repo template for estimate"
        echo
        printf '%-22s %10s %5s\n' "SERVICE" "MEM_LIMIT" "GPU"
        printf '%-22s %10s %5s\n' "----------------------" "----------" "-----"
        local _row _n _m _g
        for _row in "${_rows[@]+"${_rows[@]}"}"; do
            IFS='|' read -r _n _m _g <<< "$_row"
            printf '%-22s %9sg %5s\n' "$_n" "$_m" "$( [[ "$_g" == "yes" ]] && echo '●' || echo '' )"
        done
        echo
        local _over=""; python3 -c "import sys; sys.exit(0 if ${_total} > ${_ram_avail} else 1)" 2>/dev/null \
            && _over=" [⚠ OVER]"
        echo "TOTAL RAM:   ~${_total} GiB / ${_ram_avail} GiB available${_over}"
        echo "DISK:        ~${_disk_approx} GiB needed / ${_disk_avail} GiB free  (±30% estimate)"
        echo "GPU:         ~${_gpu_approx} GiB claimed / ${_gpu_total_gib} GiB ${_gpu_note}"
        if [[ ${#_warnings[@]+"${#_warnings[@]}"} -gt 0 ]]; then
            echo
            echo "Warnings:"
            printf '  - %s\n' "${_warnings[@]+"${_warnings[@]}"}"
        fi
    fi

    return $_rc
}

# ============================================================================
# PUBLIC: profiles_list [--json]
# ============================================================================
#
# Always exits 0 (display-only). Graceful when AGmind not installed.

profiles_list() {
    local _json=false _a
    for _a in "$@"; do [[ "$_a" == "--json" ]] && _json=true; done

    local _active; _active="$(_est_active_profile)"

    if [[ "$_json" == "true" ]]; then
        local _names_data
        _names_data="$(for _p in $_NAMED_PROFILE_ORDER; do
            printf '%s\t%s\t%s\n' \
                "$_p" \
                "${NAMED_PROFILE_DESC[$_p]:-}" \
                "${NAMED_PROFILE_EXPANSION[$_p]:-}"
        done)"
        ESTIMATE_ACTIVE="$_active" ESTIMATE_NAMES="$_names_data" python3 - <<'PY'
import os, json, datetime
out = {
    "generated_at": datetime.datetime.utcnow().isoformat() + "Z",
    "active": os.environ.get("ESTIMATE_ACTIVE", "") or None,
    "profiles": [],
}
for line in os.environ.get("ESTIMATE_NAMES", "").splitlines():
    if not line.strip():
        continue
    parts = (line.split("\t") + ["", "", ""])[:3]
    name, desc, raw = parts[0], parts[1], parts[2]
    out["profiles"].append({
        "name": name,
        "description": desc,
        "raw_profiles": [r for r in raw.split(",") if r],
    })
print(json.dumps(out, indent=2))
PY
    else
        if [[ ! -f "${INSTALL_DIR}/docker/.env" ]]; then
            echo "AGmind not installed — run 'sudo bash install.sh'"
        fi
        printf '%-14s %-55s %s\n' "PROFILE" "INCLUDES (raw compose profiles)" "ACTIVE"
        printf '%-14s %-55s %s\n' "-------" "-------------------------------" "------"
        local _p _mark
        for _p in $_NAMED_PROFILE_ORDER; do
            _mark=""
            [[ -n "$_active" && "$_p" == "$_active" ]] && _mark="<-- active"
            printf '%-14s %-55s %s\n' \
                "$_p" \
                "${NAMED_PROFILE_EXPANSION[$_p]:-}" \
                "$_mark"
        done
        if [[ -n "$_active" && " $_NAMED_PROFILE_ORDER " != *" $_active "* ]]; then
            echo
            echo "(active: ${_active} — see COMPOSE_PROFILES in .env for the raw profile list)"
        fi
    fi
    return 0
}
