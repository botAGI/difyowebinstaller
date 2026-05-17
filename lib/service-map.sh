#!/usr/bin/env bash
# lib/service-map.sh — Canonical service mapping definitions.
#
# As of Phase 12 (REG-04/05/06), this is a thin shim that sources the
# generated lib/_registry.indexed.sh artifact. Hand-edited assoc-array
# blocks are gone — edit templates/services/registry.yaml + run
# `make registry-codegen` to regenerate.
#
# Public API (preserved for backward compat with all consumers):
#   NAME_TO_VERSION_KEY       (assoc -- short name -> versions.env key)
#                             Contains both compose service names AND
#                             backward-compat aliases (dify-api, postgres,
#                             squid, plugin-daemon, openwebui, tei-embed, ...)
#                             for `agmind update <name>` CLI contract.
#   NAME_TO_SERVICES          (assoc -- short name -> compose service(s) for update.sh)
#   SERVICE_GROUPS            (assoc -- group label -> space-sep service names)
#   SERVICE_GROUP_ORDER       (scalar -- display order for `agmind status`)
#   ALL_COMPOSE_PROFILES      (scalar CSV -- all profiles for compose down)
#   NAMED_PROFILE_EXPANSION   (assoc -- meta-profile -> raw profiles CSV)
#   NAMED_PROFILE_DESC        (assoc -- human one-liner per meta-profile)
#   NAMED_PROFILE_IMPLIED     (assoc -- implied ENABLE_*/<X>_PROVIDER=)
#
# Sourced by: lib/compose.sh, lib/status.sh, lib/estimate.sh, scripts/update.sh,
#             scripts/agmind.sh (indirectly).
# See docs/adr/0012-service-registry-codegen.md for design rationale.
set -euo pipefail

# Guard against double-sourcing.
if [[ -n "${_SERVICE_MAP_LOADED:-}" ]]; then return 0; fi
_SERVICE_MAP_LOADED=1

# Resolve path: development repo (lib/) -> installed runtime (scripts/).
# In dev: lib/service-map.sh sources lib/_registry.indexed.sh (same dir).
# In runtime: install.sh copies BOTH files into ${INSTALL_DIR}/scripts/ --
# lib/service-map.sh becomes scripts/service-map.sh, lib/_registry.indexed.sh
# becomes scripts/_registry.indexed.sh. Same-directory source works.
_SM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${_SM_DIR}/_registry.indexed.sh" ]]; then
    # shellcheck source=_registry.indexed.sh
    source "${_SM_DIR}/_registry.indexed.sh"
elif [[ -f "${_SM_DIR}/../lib/_registry.indexed.sh" ]]; then
    # Edge case: someone moved scripts/service-map.sh out of scripts/ dir.
    # shellcheck source=../lib/_registry.indexed.sh
    source "${_SM_DIR}/../lib/_registry.indexed.sh"
else
    echo "ERROR: lib/service-map.sh -- _registry.indexed.sh not found near ${_SM_DIR}." >&2
    echo "       Run \`make registry-codegen\` or re-run install.sh." >&2
    return 1
fi

# All 8 public symbols (NAME_TO_VERSION_KEY, NAME_TO_SERVICES, SERVICE_GROUPS,
# SERVICE_GROUP_ORDER, ALL_COMPOSE_PROFILES, NAMED_PROFILE_EXPANSION,
# NAMED_PROFILE_DESC, NAMED_PROFILE_IMPLIED) are now defined by the sourced
# indexed file. Consumers see the same names + types as before Phase 12.

# ============================================================================
# RESOLVE_ACTIVE_SERVICES session cache (Plan 14-01 / RESOLVER-01 / D-03)
# ============================================================================
# Memoization keys for resolve_active_services() in lib/health.sh.
# Cache key = "${env_file}:$(stat -c %Y "$env_file")"; invalidated on mtime change.
# In-memory only — dies between install.sh invocations. NOT persisted to disk.
# See PITFALLS.md "Pitfall 4" (resolver perf collapse) for rationale.
: "${_AGMIND_SVC_CACHE_KEY:=}"
: "${_AGMIND_SVC_CACHE_VAL:=}"
export _AGMIND_SVC_CACHE_KEY _AGMIND_SVC_CACHE_VAL
