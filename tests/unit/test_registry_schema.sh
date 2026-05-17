#!/usr/bin/env bash
# tests/unit/test_registry_schema.sh — REG-01 smoke validation.
#
# Asserts:
#   1. templates/services/registry.yaml exists and PyYAML can load it
#   2. schema_version = 1
#   3. services dict has exactly 50 entries
#   4. Each service has required keys: image_key, group, profiles (list), healthcheck (enum)
#   5. healthcheck enum ∈ {present, absent, distroless-no-health}
#   6. profile_expansions / profile_descriptions / profile_implied each have 8 keys
#   7. profile_expansions keys == {core, rag, ragflow, observability, security, agents, full, dev}
#   8. group_order list has 7 entries
#   9. all_compose_profiles list has ≥20 entries
#  10. `aliases:` field (when present) is a list[str]
#  11. Backward-compat CLI aliases present (8 entries — agmind update <name> contract)
#
# Exit: 0 = pass, 1 = fail, 77 = SKIP (PyYAML missing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_registry_schema"

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "  SKIP: python3+PyYAML required (not installed)"
    exit 77
fi

REGISTRY="${REPO_ROOT}/templates/services/registry.yaml"
if [[ ! -f "$REGISTRY" ]]; then
    echo "  FAIL: $REGISTRY does not exist"
    exit 1
fi

python3 - "$REGISTRY" <<'PY'
import sys
import yaml

reg_file = sys.argv[1]
try:
    data = yaml.safe_load(open(reg_file))
except Exception as e:
    print(f"  FAIL: PyYAML cannot parse {reg_file}: {e}")
    sys.exit(1)

fail = 0

def ok(msg):
    print(f"  ok: {msg}")

def bad(msg):
    global fail
    print(f"  FAIL: {msg}")
    fail += 1

# 1. Schema version
if data.get('schema_version') == 1:
    ok("schema_version=1")
else:
    bad(f"schema_version != 1 (got {data.get('schema_version')!r})")

# 2. Services count
services = data.get('services') or {}
if len(services) == 50:
    ok("services count = 50")
else:
    bad(f"services count != 50 (got {len(services)})")

# 3. Required top-level keys
required_top = [
    'schema_version', 'services', 'profile_expansions',
    'profile_descriptions', 'profile_implied', 'group_order',
    'all_compose_profiles',
]
for k in required_top:
    if k in data:
        ok(f"top-level key present: {k}")
    else:
        bad(f"missing top-level key: {k}")

# 4. Per-service required fields + optional aliases shape
HC_ENUM = {'present', 'absent', 'distroless-no-health'}
for svc in sorted(services.keys()):
    sd = services[svc] or {}
    for req in ('image_key', 'group', 'profiles', 'healthcheck'):
        if req not in sd:
            bad(f"{svc}: missing required field '{req}'")
    if not isinstance(sd.get('profiles'), list):
        bad(f"{svc}: profiles must be a list")
    hc = sd.get('healthcheck')
    if hc not in HC_ENUM:
        bad(f"{svc}: healthcheck '{hc}' not in {sorted(HC_ENUM)}")
    if 'aliases' in sd:
        if not isinstance(sd['aliases'], list):
            bad(f"{svc}: aliases must be a list (got {type(sd['aliases']).__name__})")
        else:
            for a in sd['aliases']:
                if not (isinstance(a, str) and a):
                    bad(f"{svc}: alias must be non-empty string (got {a!r})")

# 5. Named profile structures
EXPECTED_PROFILES = {'core', 'rag', 'ragflow', 'observability', 'security', 'agents', 'full', 'dev'}
for key in ('profile_expansions', 'profile_descriptions', 'profile_implied'):
    v = data.get(key) or {}
    if len(v) == 8:
        ok(f"{key}: 8 entries")
    else:
        bad(f"{key}: expected 8 entries, got {len(v)}")
    if set(v.keys()) == EXPECTED_PROFILES:
        ok(f"{key}: keys correct")
    else:
        bad(f"{key}: keys {sorted(v.keys())} != expected {sorted(EXPECTED_PROFILES)}")

# 6. group_order
go = data.get('group_order') or []
if len(go) == 7:
    ok(f"group_order has 7 entries: {go}")
else:
    bad(f"group_order: expected 7 entries, got {len(go)}")

# 7. all_compose_profiles
acp = data.get('all_compose_profiles') or []
if len(acp) >= 20:
    ok(f"all_compose_profiles has {len(acp)} entries (>=20)")
else:
    bad(f"all_compose_profiles: expected >=20 entries, got {len(acp)}")

# 8. Backward-compat CLI aliases — agmind update <name> contract (see docs/adr/0012)
EXPECTED_ALIASES = {
    'api': 'dify-api',
    'worker': 'dify-worker',
    'web': 'dify-web',
    'db': 'postgres',
    'ssrf_proxy': 'squid',
    'plugin_daemon': 'plugin-daemon',
    'open-webui': 'openwebui',
    'tei': 'tei-embed',
}
for svc, alias in EXPECTED_ALIASES.items():
    sd = services.get(svc) or {}
    aliases = sd.get('aliases') or []
    if alias in aliases:
        ok(f"alias {svc} -> {alias}")
    else:
        bad(f"backward-compat alias missing: services.{svc}.aliases must contain '{alias}' (CLI contract)")

print()
if fail == 0:
    print("=== test_registry_schema: PASS ===")
    sys.exit(0)
else:
    print(f"=== test_registry_schema: FAIL ({fail} errors) ===")
    sys.exit(1)
PY
