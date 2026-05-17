#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_all_profiles_synced.sh
# Regression for PROFILES-ALL-01 — ALL_COMPOSE_PROFILES in lib/service-map.sh
# must be a superset of all `profiles:` keys actually declared in
# templates/docker-compose.yml, and contain no stale entries that compose
# no longer references.
#
# Exit: 0 = pass, 1 = fail, 77 = skip (yaml module unavailable).
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_all_profiles_synced"
echo ""

if python3 - "$REPO_ROOT" <<'PY'
import sys, yaml, re, pathlib
root = pathlib.Path(sys.argv[1])
compose = yaml.safe_load(open(root / 'templates/docker-compose.yml'))
compose_profiles = set()
for svc in (compose.get('services') or {}).values():
    for p in (svc.get('profiles') or []):
        compose_profiles.add(p)

# Post ADR-0012: ALL_COMPOSE_PROFILES is auto-generated in lib/_registry.indexed.sh
# and re-exported via lib/service-map.sh. Inspect the in-memory contract by sourcing
# service-map.sh in a bash subshell — that is what consumers actually use.
import subprocess
res = subprocess.run(
    ['bash', '-c', f"source '{root}/lib/service-map.sh' && printf '%s' \"$ALL_COMPOSE_PROFILES\""],
    capture_output=True, text=True
)
if res.returncode != 0 or not res.stdout.strip():
    print("  [FAIL] ALL_COMPOSE_PROFILES not exported by lib/service-map.sh")
    print(f"    stderr: {res.stderr.strip()}")
    sys.exit(1)
var_profiles = set(p.strip() for p in res.stdout.split(',') if p.strip())

missing = compose_profiles - var_profiles
stale = var_profiles - compose_profiles

if not missing and not stale:
    print(f"  [PASS] {len(compose_profiles)} compose profiles == {len(var_profiles)} var profiles")
    sys.exit(0)
print(f"  [FAIL] DRIFT")
if missing:
    print(f"    missing from var (compose has, var doesn't): {sorted(missing)}")
if stale:
    print(f"    stale in var (var has, compose doesn't): {sorted(stale)}")
sys.exit(1)
PY
then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Summary: 1 passed, 0 failed"
    echo "═══════════════════════════════════════════════════════════"
    exit 0
else
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Summary: 0 passed, 1 failed"
    echo "═══════════════════════════════════════════════════════════"
    exit 1
fi
