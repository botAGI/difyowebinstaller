#!/usr/bin/env bash
# test_compose_yaml_valid.sh — статическая валидация всех docker-compose YAML.
# Ловит:
#   1. Битый YAML (отступы, незакрытые блоки, copy-paste ошибки)
#   2. service без image (compose accept'ит, но контейнер не поднимется)
#   3. дубли container_name
#   4. profiles non-list — типичная регрессия при добавлении новой услуги
#
# Не использует `docker compose config` — на CI и локально без docker daemon
# работает через `python3 yaml.safe_load`. Это static check, не requires
# полную compose-семантику.
#
# Exit: 0 = pass, 1 = fail, 77 = skip (no python3 yaml).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_compose_yaml_valid"

fail=0
pass=0

# Find all compose files
mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

if [[ ${#compose_files[@]} -eq 0 ]]; then
    echo "  FAIL: no compose files found in templates/"
    exit 1
fi

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    # Check 1: YAML schema valid
    if python3 -c "import yaml; yaml.safe_load(open('${f}'))" 2>/dev/null; then
        echo "  PASS: ${relpath} — valid YAML"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — invalid YAML"
        python3 -c "import yaml; yaml.safe_load(open('${f}'))" 2>&1 | head -3 | sed 's/^/        /'
        fail=$((fail+1))
        continue
    fi

    # Check 2: every service has image
    missing_images="$(python3 - "$f" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
services = data.get('services', {}) if isinstance(data, dict) else {}
missing = []
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    if 'image' not in svc and 'build' not in svc:
        missing.append(name)
print(','.join(missing) if missing else '')
PY
)"
    if [[ -z "$missing_images" ]]; then
        echo "  PASS: ${relpath} — every service has image/build"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — services missing image/build: ${missing_images}"
        fail=$((fail+1))
    fi

    # Check 3: container_name unique within file
    dup_names="$(python3 - "$f" <<'PY'
import sys, yaml
from collections import Counter
data = yaml.safe_load(open(sys.argv[1]))
services = data.get('services', {}) if isinstance(data, dict) else {}
names = [svc.get('container_name') for svc in services.values()
         if isinstance(svc, dict) and svc.get('container_name')]
dups = [n for n, c in Counter(names).items() if c > 1]
print(','.join(dups) if dups else '')
PY
)"
    if [[ -z "$dup_names" ]]; then
        echo "  PASS: ${relpath} — no duplicate container_name"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — duplicate container_name: ${dup_names}"
        fail=$((fail+1))
    fi

    # Check 4: profiles is list (not string), if present
    bad_profiles="$(python3 - "$f" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
services = data.get('services', {}) if isinstance(data, dict) else {}
bad = []
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    p = svc.get('profiles')
    if p is not None and not isinstance(p, list):
        bad.append(name)
print(','.join(bad) if bad else '')
PY
)"
    if [[ -z "$bad_profiles" ]]; then
        echo "  PASS: ${relpath} — profiles always list"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — profiles not list in services: ${bad_profiles}"
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
