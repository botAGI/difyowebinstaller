#!/usr/bin/env bash
# scripts/codegen/registry-to-indexed.sh — REG-03 build-time codegen.
#
# Reads templates/services/registry.yaml, produces lib/_registry.indexed.sh
# (bash assoc-arrays + scalar strings for fast runtime). Deterministic:
# stable sort + identical re-run output (for CI drift detection).
#
# DEV/CI ONLY — never runs on customer install (lib/_registry.indexed.sh
# is shipped pre-built in repo + copied via install.sh::_copy_runtime_files).
#
# Single backend: python3+PyYAML — yq would work too but PyYAML cross-platform
# string formatting is more predictable and we always have python3 available.
#
# Alias handling: NAME_TO_VERSION_KEY + NAME_TO_SERVICES emit one row per
# service name AND one row per alias listed under `services.<svc>.aliases`.
# This preserves the `agmind update <name>` CLI contract for v3.1.x users
# (dify-api, postgres, squid, plugin-daemon, openwebui, tei-embed, etc).
#
# Usage:
#   bash scripts/codegen/registry-to-indexed.sh           # writes lib/_registry.indexed.sh
#   OUT=/tmp/out.sh bash scripts/codegen/registry-to-indexed.sh   # override for drift test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REGISTRY="${REGISTRY:-${REPO_ROOT}/templates/services/registry.yaml}"
OUT="${OUT:-${REPO_ROOT}/lib/_registry.indexed.sh}"

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: python3+PyYAML required for codegen" >&2
    exit 2
fi

if [[ ! -r "$REGISTRY" ]]; then
    echo "ERROR: registry file unreadable: $REGISTRY" >&2
    exit 1
fi

# Source SHA-12 for header debug clue (NOT for security)
SOURCE_SHA="$(sha256sum "$REGISTRY" | cut -c1-12)"

tmp="$(mktemp "${TMPDIR:-/tmp}/registry-codegen.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

python3 - "$REGISTRY" "$SOURCE_SHA" > "$tmp" <<'PY'
import sys, yaml

reg_file, src_sha = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(reg_file)) or {}

schema_version = data.get('schema_version', 0)
services = data.get('services') or {}
profile_exp = data.get('profile_expansions') or {}
profile_desc = data.get('profile_descriptions') or {}
profile_imp = data.get('profile_implied') or {}
group_order = data.get('group_order') or []
all_compose_profiles = data.get('all_compose_profiles') or []

# === Header ===
print("#!/usr/bin/env bash")
print("# _registry.indexed.sh — DO NOT HAND-EDIT")
print("# Generated from templates/services/registry.yaml (schema_version={})".format(schema_version))
print("# Source SHA-12: {}".format(src_sha))
print("# Regenerate via: make registry-codegen")
print("# CI gate: tests/integration/test_registry_codegen_drift.sh fails on stale artifact.")
print("#")
print("# Provides these public symbols (mirrors lib/service-map.sh pre-Phase-12 contract):")
print("#   NAME_TO_VERSION_KEY  NAME_TO_SERVICES  SERVICE_GROUPS  SERVICE_GROUP_ORDER")
print("#   ALL_COMPOSE_PROFILES  NAMED_PROFILE_EXPANSION  NAMED_PROFILE_DESC")
print("#   NAMED_PROFILE_IMPLIED")
print("#")
print("# NAME_TO_VERSION_KEY + NAME_TO_SERVICES contain one row per compose")
print("# service AND one row per declared alias (see services.<svc>.aliases in")
print("# registry.yaml). Aliases preserve the `agmind update <name>` CLI contract.")
print()
print("set -euo pipefail")
print('if [[ -n "${_REGISTRY_INDEXED_LOADED:-}" ]]; then return 0; fi')
print("_REGISTRY_INDEXED_LOADED=1")
print()

# === NAME_TO_VERSION_KEY (services + aliases) ===
print("# shellcheck disable=SC2034")
print("declare -A NAME_TO_VERSION_KEY=(")
for svc in sorted(services.keys()):
    sd = services[svc] or {}
    key = sd.get('image_key', '')
    if not key:
        continue
    print("    [{}]={}".format(svc, key))
    # Emit alias rows immediately after the parent service for readability
    # (codegen output is still deterministic because alias lists are sorted).
    for alias in sorted(sd.get('aliases') or []):
        print("    [{}]={}".format(alias, key))
print(")")
print()

# === NAME_TO_SERVICES (services + aliases) ===
# Default: services_for_restart = [svc] (i.e. just itself).
# Aliases inherit their parent service's services_for_restart list.
print("# shellcheck disable=SC2034")
print("declare -A NAME_TO_SERVICES=(")
for svc in sorted(services.keys()):
    sd = services[svc] or {}
    sfr = sd.get('services_for_restart') or [svc]
    if not isinstance(sfr, list):
        sfr = [str(sfr)]
    joined = " ".join(sfr)
    print('    [{}]="{}"'.format(svc, joined))
    for alias in sorted(sd.get('aliases') or []):
        print('    [{}]="{}"'.format(alias, joined))
print(")")
print()

# === SERVICE_GROUPS ===
# Aggregate services by group, sort group names + member names for determinism.
# Aliases are NOT emitted into SERVICE_GROUPS — that table drives
# `agmind status` which renders compose service names verbatim.
print("# shellcheck disable=SC2034")
print("declare -A SERVICE_GROUPS=(")
groups = {}
for svc, sd in services.items():
    g = (sd or {}).get('group', 'optional')
    groups.setdefault(g, []).append(svc)
for g in sorted(groups.keys()):
    names = ' '.join(sorted(groups[g]))
    print('    [{}]="{}"'.format(g, names))
print(")")
print()

# === SERVICE_GROUP_ORDER (scalar string) ===
print("# shellcheck disable=SC2034")
print('SERVICE_GROUP_ORDER="{}"'.format(" ".join(group_order)))
print()

# === ALL_COMPOSE_PROFILES (scalar CSV string) ===
print("# shellcheck disable=SC2034")
print('ALL_COMPOSE_PROFILES="{}"'.format(",".join(all_compose_profiles)))
print()

# === NAMED_PROFILE_EXPANSION ===
print("# shellcheck disable=SC2034")
print("declare -A NAMED_PROFILE_EXPANSION=(")
for p in sorted(profile_exp.keys()):
    val = profile_exp[p]
    print('    [{}]="{}"'.format(p, val))
print(")")
print()

# === NAMED_PROFILE_DESC ===
print("# shellcheck disable=SC2034")
print("declare -A NAMED_PROFILE_DESC=(")
for p in sorted(profile_desc.keys()):
    desc = (profile_desc[p] or '').replace('\\', '\\\\').replace('"', '\\"')
    print('    [{}]="{}"'.format(p, desc))
print(")")
print()

# === NAMED_PROFILE_IMPLIED ===
print("# shellcheck disable=SC2034")
print("declare -A NAMED_PROFILE_IMPLIED=(")
for p in sorted(profile_imp.keys()):
    val = (profile_imp[p] or '').replace('\\', '\\\\').replace('"', '\\"')
    print('    [{}]="{}"'.format(p, val))
print(")")
PY

# Atomic write
mv "$tmp" "$OUT"
chmod 0644 "$OUT"

# Operator hint (non-CI only)
if [[ -z "${CI:-}" ]]; then
    if (cd "$REPO_ROOT" && git status --porcelain "$OUT" 2>/dev/null | grep -q .); then
        echo "  -> ${OUT#"$REPO_ROOT"/} changed. Stage and commit it alongside registry.yaml." >&2
    fi
fi
