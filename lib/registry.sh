#!/usr/bin/env bash
# lib/registry.sh — read-only API over templates/services/registry.yaml (REG-02).
#
# Dual backend: yq (mikefarah v4+) preferred → python3+PyYAML fallback for airgap/CI.
# Phase 12 lands this DORMANT — no live consumers call it. Phase 14 RESOLVER-02
# migrates lib/health.sh::resolve_active_services to use this API.
#
# Public API:
#   reg_list_services           → prints sorted service names, one per line
#   reg_get_profiles <svc>      → prints comma-joined profiles, empty if always-on
#   reg_get_group <svc>         → prints group name (default "optional")
#   reg_get_healthcheck <svc>   → prints enum (present|absent|distroless-no-health)
#
# Exit codes per public fn:
#   0 = ok + output emitted
#   1 = service unknown OR registry unreadable
#   2 = no backend available (neither yq mikefarah v4 nor python3+PyYAML)
#
# Path resolution: REGISTRY_FILE env var overrides default. Default resolves both
# dev layout (lib/registry.sh → ../templates/services/registry.yaml) and installed
# runtime (scripts/registry.sh → ../templates/services/registry.yaml — same relpath).
#
# Backend override: REG_BACKEND can be set to "yq" or "python" BEFORE first API call
# to skip auto-detection. Used by unit tests to deterministically exercise both
# branches independent of host yq/PyYAML availability.
#
# See docs/adr/0012-service-registry-codegen.md
set -euo pipefail

# Guard against double-sourcing (mirror lib/service-map.sh:10-11)
if [[ -n "${_REGISTRY_LOADED:-}" ]]; then return 0; fi
_REGISTRY_LOADED=1

# Path resolution — support dev (lib/) and installed (scripts/) layouts.
_REG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REGISTRY_FILE:=${_REG_DIR}/../templates/services/registry.yaml}"

# Fallback log_* shims if caller didn't source lib/common.sh first.
if ! declare -F log_error >/dev/null; then
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F log_warn >/dev/null; then
    log_warn() { printf '[WARN] %s\n' "$*" >&2; }
fi

# Backend cache (set on first _reg_load call OR honored from caller override)
: "${REG_BACKEND:=}"

# _reg_load — detect backend, cache in REG_BACKEND.
# If REG_BACKEND is already set to "yq" or "python", respects the override
# (allows tests to force a specific branch).
# Returns: 0 on success (REG_BACKEND in {yq, python}), 2 if no backend.
_reg_load() {
    # Test override path: caller pre-set REG_BACKEND to a valid backend.
    case "$REG_BACKEND" in
        yq|python) return 0 ;;
    esac

    # Prefer yq mikefarah v4+ (fast bash queries)
    if command -v yq >/dev/null 2>&1; then
        # python-yq (Ubuntu apt) identifies as "yq 3.x" — wrong tool.
        # Mikefarah identifies as `yq (https://github.com/mikefarah/yq/) version v4...`
        if yq --version 2>&1 | grep -qE 'mikefarah|version v?4\.'; then
            REG_BACKEND=yq
            return 0
        fi
    fi
    # Fall back to python3 + PyYAML
    if python3 -c "import yaml" 2>/dev/null; then
        REG_BACKEND=python
        return 0
    fi
    log_error "registry: neither yq (mikefarah v4+) nor python3+PyYAML available"
    return 2
}

# _reg_check_file — emit error + return 1 if REGISTRY_FILE not readable.
_reg_check_file() {
    if [[ ! -r "$REGISTRY_FILE" ]]; then
        log_error "registry: $REGISTRY_FILE unreadable"
        return 1
    fi
    return 0
}

# reg_list_services — print all service names, one per line, sorted.
reg_list_services() {
    _reg_load || return $?
    _reg_check_file || return $?
    case "$REG_BACKEND" in
        yq)
            yq -r '.services | keys | .[]' "$REGISTRY_FILE" | sort
            ;;
        python)
            python3 - "$REGISTRY_FILE" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
for s in sorted((data.get('services') or {}).keys()):
    print(s)
PY
            ;;
        *)
            return 2
            ;;
    esac
}

# reg_get_profiles <svc> — print comma-joined profile names; empty string = always-on.
# Exit 1 if service unknown.
reg_get_profiles() {
    local svc="${1:-}"
    if [[ -z "$svc" ]]; then
        log_error "reg_get_profiles: service name required"
        return 1
    fi
    _reg_load || return $?
    _reg_check_file || return $?
    case "$REG_BACKEND" in
        yq)
            if ! yq -e ".services | has(\"$svc\")" "$REGISTRY_FILE" >/dev/null 2>&1; then
                return 1
            fi
            yq -r ".services.\"$svc\".profiles // [] | join(\",\")" "$REGISTRY_FILE"
            ;;
        python)
            python3 - "$REGISTRY_FILE" "$svc" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
svcs = data.get('services') or {}
svc = sys.argv[2]
if svc not in svcs:
    sys.exit(1)
print(','.join((svcs[svc] or {}).get('profiles') or []))
PY
            ;;
        *)
            return 2
            ;;
    esac
}

# reg_get_group <svc> — print group name. Defaults to "optional" if absent.
# Exit 1 if service unknown.
reg_get_group() {
    local svc="${1:-}"
    if [[ -z "$svc" ]]; then
        log_error "reg_get_group: service name required"
        return 1
    fi
    _reg_load || return $?
    _reg_check_file || return $?
    case "$REG_BACKEND" in
        yq)
            if ! yq -e ".services | has(\"$svc\")" "$REGISTRY_FILE" >/dev/null 2>&1; then
                return 1
            fi
            yq -r ".services.\"$svc\".group // \"optional\"" "$REGISTRY_FILE"
            ;;
        python)
            python3 - "$REGISTRY_FILE" "$svc" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
svcs = data.get('services') or {}
svc = sys.argv[2]
if svc not in svcs:
    sys.exit(1)
print((svcs[svc] or {}).get('group') or 'optional')
PY
            ;;
        *)
            return 2
            ;;
    esac
}

# reg_get_healthcheck <svc> — print enum (present|absent|distroless-no-health).
# Default = "absent" if field absent in registry entry.
# Exit 1 if service unknown.
reg_get_healthcheck() {
    local svc="${1:-}"
    if [[ -z "$svc" ]]; then
        log_error "reg_get_healthcheck: service name required"
        return 1
    fi
    _reg_load || return $?
    _reg_check_file || return $?
    case "$REG_BACKEND" in
        yq)
            if ! yq -e ".services | has(\"$svc\")" "$REGISTRY_FILE" >/dev/null 2>&1; then
                return 1
            fi
            yq -r ".services.\"$svc\".healthcheck // \"absent\"" "$REGISTRY_FILE"
            ;;
        python)
            python3 - "$REGISTRY_FILE" "$svc" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
svcs = data.get('services') or {}
svc = sys.argv[2]
if svc not in svcs:
    sys.exit(1)
print((svcs[svc] or {}).get('healthcheck') or 'absent')
PY
            ;;
        *)
            return 2
            ;;
    esac
}
