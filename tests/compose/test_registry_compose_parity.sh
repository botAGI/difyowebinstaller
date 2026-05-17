#!/usr/bin/env bash
# tests/compose/test_registry_compose_parity.sh — REG-07 gate.
#
# Asserts 1:1 match between templates/services/registry.yaml and
# templates/docker-compose.yml `services:` block + `profiles:` tags + healthcheck enum.
#
# Pure PyYAML parse — no daemon-dependent config expansion needed
# (hermetic: no secrets, no network, works in CI air-gap). Mirrors the
# pattern in lib/estimate.sh::_est_services_for_profiles (production code).
#
# FIVE checks (Blocker #2 added Check 5):
#   1. Services set 1:1
#   2. Per-service profile set match
#   3. Healthcheck enum sanity
#   4. mem_limit declaration consistency (informational)
#   5. 8-named-profile sweep (catches expansion drift)
#
# Exit: 0 = parity, 1 = drift detected, 77 = SKIP (PyYAML missing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_registry_compose_parity"

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "  SKIP: python3+PyYAML required"
    exit 77
fi

REGISTRY="${REPO_ROOT}/templates/services/registry.yaml"
COMPOSE="${REPO_ROOT}/templates/docker-compose.yml"

if [[ ! -f "$REGISTRY" ]]; then
    echo "  FAIL: $REGISTRY missing"
    exit 1
fi
if [[ ! -f "$COMPOSE" ]]; then
    echo "  FAIL: $COMPOSE missing"
    exit 1
fi

python3 - "$REGISTRY" "$COMPOSE" <<'PY'
import sys, yaml, re
from pathlib import Path

reg_path = Path(sys.argv[1])
compose_path = Path(sys.argv[2])

try:
    reg = yaml.safe_load(open(reg_path)) or {}
except Exception as e:
    print(f"  FAIL: cannot parse {reg_path}: {e}")
    sys.exit(1)

# Compose has ${VAR:-default} placeholders that PyYAML doesn't expand.
# Replace them with literal string before parse (lib/estimate.sh pattern).
try:
    compose_text = open(compose_path).read()
    compose_text = re.sub(r'\$\{[^}]+\}', 'placeholder', compose_text)
    compose = yaml.safe_load(compose_text) or {}
except Exception as e:
    print(f"  FAIL: cannot parse {compose_path}: {e}")
    sys.exit(1)

reg_services = set((reg.get('services') or {}).keys())
compose_services = set((compose.get('services') or {}).keys())

errors = []
ok_count = 0

# === Check 1: Same service set ===
only_in_registry = reg_services - compose_services
only_in_compose = compose_services - reg_services
if only_in_registry:
    errors.append(f"services in registry but NOT in compose: {sorted(only_in_registry)}")
if only_in_compose:
    errors.append(f"services in compose but NOT in registry: {sorted(only_in_compose)}")
if not only_in_registry and not only_in_compose:
    ok_count += 1
    print(f"  ok: {len(reg_services)} services 1:1 match between registry and compose")

# === Check 2: Per-service profile set match ===
profile_drift = 0
for svc in sorted(reg_services & compose_services):
    reg_profs = set((reg['services'][svc] or {}).get('profiles') or [])
    compose_profs = set(((compose['services'][svc] or {}).get('profiles') or []))
    if reg_profs != compose_profs:
        errors.append(
            f"{svc}: profiles drift — registry={sorted(reg_profs)} compose={sorted(compose_profs)}"
        )
        profile_drift += 1
if profile_drift == 0:
    ok_count += 1
    print(f"  ok: all per-service profile sets match ({len(reg_services & compose_services)} services x profiles)")

# === Check 3: Healthcheck enum sanity ===
hc_drift = 0
for svc in sorted(reg_services & compose_services):
    reg_hc = (reg['services'][svc] or {}).get('healthcheck', 'absent')
    cs = (compose['services'][svc] or {})
    compose_hc_block = cs.get('healthcheck')
    compose_hc_block_disabled = False
    if isinstance(compose_hc_block, dict):
        test_val = compose_hc_block.get('test')
        if test_val == ['NONE'] or test_val == 'NONE':
            compose_hc_block_disabled = True

    if reg_hc == 'present':
        # Compose must have healthcheck block AND it must not be disabled
        if compose_hc_block is None or compose_hc_block_disabled:
            errors.append(f"{svc}: registry healthcheck='present' but compose has no active healthcheck")
            hc_drift += 1
    elif reg_hc == 'absent':
        # Compose must NOT have healthcheck block (or it must be test:[NONE])
        if compose_hc_block is not None and not compose_hc_block_disabled:
            errors.append(f"{svc}: registry healthcheck='absent' but compose has active healthcheck block")
            hc_drift += 1
    elif reg_hc == 'distroless-no-health':
        # Compose may have any value — distroless rule allows test:[NONE] disable
        pass
    else:
        errors.append(f"{svc}: invalid registry healthcheck enum '{reg_hc}'")
        hc_drift += 1
if hc_drift == 0:
    ok_count += 1
    print(f"  ok: healthcheck enum consistent for {len(reg_services & compose_services)} services")

# === Check 4: mem_limit declaration consistency (informational) ===
mem_drift = 0
for svc in sorted(reg_services & compose_services):
    reg_mem = (reg['services'][svc] or {}).get('mem_limit')
    compose_mem = (compose['services'][svc] or {}).get('mem_limit')
    if reg_mem is not None and compose_mem is None:
        errors.append(f"{svc}: registry declares mem_limit='{reg_mem}' but compose has no mem_limit")
        mem_drift += 1
if mem_drift == 0:
    ok_count += 1
    print(f"  ok: mem_limit declarations consistent (registry -> compose subset)")

# === Check 5: 8-named-profile sweep (Blocker #2) ===
# For each named meta-profile, expand to raw profiles via profile_expansions,
# then for each raw profile assert that the set of services tagged with it in
# registry equals the set tagged with it in compose. This catches drift even
# when per-service profile sets (Check 2) appear consistent on the surface
# (e.g. someone reordered the profile_expansions CSV).
NAMED_PROFILES = ['core', 'rag', 'ragflow', 'observability',
                  'security', 'agents', 'full', 'dev']
expansions = (reg.get('profile_expansions') or {})
sweep_drift = 0
raw_profiles_checked = set()
for np in NAMED_PROFILES:
    csv = expansions.get(np, '')
    if not isinstance(csv, str) or not csv:
        errors.append(f"named={np}: profile_expansions missing or empty")
        sweep_drift += 1
        continue
    raw_profiles = [p.strip() for p in csv.split(',') if p.strip()]
    for rp in raw_profiles:
        raw_profiles_checked.add(rp)
        reg_set = {s for s, sd in (reg.get('services') or {}).items()
                   if rp in (((sd or {}).get('profiles')) or [])}
        compose_set = {s for s, sd in (compose.get('services') or {}).items()
                       if rp in (((sd or {}).get('profiles')) or [])}
        if reg_set != compose_set:
            diff_only_reg = sorted(reg_set - compose_set)
            diff_only_compose = sorted(compose_set - reg_set)
            errors.append(
                f"named={np} raw={rp}: registry-only={diff_only_reg} compose-only={diff_only_compose}"
            )
            sweep_drift += 1
        else:
            # Verbose per-raw-profile trace (enables grep-based adversarial tests and CI diagnostics)
            print(f"  ok: named={np} raw={rp}: {sorted(reg_set)}")
if sweep_drift == 0:
    ok_count += 1
    print(f"  ok: 8-named-profile sweep -- {len(raw_profiles_checked)} raw profiles consistent across registry/compose")

# === Report ===
print()
if errors:
    print(f"  FAIL: {len(errors)} parity violations:")
    for e in errors:
        print(f"    - {e}")
    sys.exit(1)

print(f"=== test_registry_compose_parity: PASS ({ok_count}/5 checks ok) ===")
sys.exit(0)
PY
