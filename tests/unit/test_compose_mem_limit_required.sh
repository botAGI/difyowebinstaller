#!/usr/bin/env bash
# test_compose_mem_limit_required.sh — DGX Spark unified memory budget guard.
#
# §8: «Unified memory = один пул 121 GiB. CPU процессы едят VRAM:
# Postgres shared_buffers=8G → -8 GiB для GPU workloads. Все контейнеры
# (GPU или не-GPU) считаются в бюджете через mem_limit. cgroup OOM-killer
# работает независимо от CUDA OOM — mem_limit перехватит до cudaMalloc fail.»
#
# Без mem_limit на любом контейнере — он может съесть всю память и убить
# vLLM/RAGFlow OOM. Это случилось с docling shared GPU (мы нашли через бенч).
#
# Тест: каждый service в compose ИМЕЕТ `mem_limit` (с дефолтом или без).
# Допустимы исключения для one-shot init контейнеров (entrypoint завершается
# моментально — milvus-init, certbot и т.п.).
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_compose_mem_limit_required"

fail=0
pass=0

# Whitelist services без mem_limit (one-shot или non-resident)
EXEMPT_SERVICES=(
    "milvus-init"     # one-shot bucket creation, exits immediately
    "certbot"         # one-shot SSL renew via cron
    "redis-lock-cleaner"  # short-lived periodic
)

mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    result="$(python3 - "$f" "${EXEMPT_SERVICES[@]}" <<'PY'
import sys, yaml

path = sys.argv[1]
exempt = set(sys.argv[2:])

data = yaml.safe_load(open(path)) or {}
services = data.get('services', {}) if isinstance(data, dict) else {}

violations = []
checked = 0

for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    if name in exempt:
        continue
    checked += 1
    mem = svc.get('mem_limit')
    if not mem:
        # Also check deploy.resources.limits.memory (compose v3 alt syntax)
        deploy = svc.get('deploy', {}) or {}
        res = deploy.get('resources', {}) or {}
        limits = res.get('limits', {}) or {}
        mem = limits.get('memory')
    if not mem:
        violations.append(f"{name}: no mem_limit (will eat unbounded RAM, breaks 121 GiB budget §8)")

print(f"CHECKED={checked}")
for v in violations:
    print(v)
PY
)"

    checked_count="$(echo "$result" | grep '^CHECKED=' | cut -d'=' -f2)"
    violations="$(echo "$result" | grep -v '^CHECKED=' | grep -v '^$' || true)"

    if [[ -z "$violations" ]]; then
        echo "  PASS: ${relpath} — all ${checked_count} services have mem_limit (one-shots exempt)"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — services without mem_limit (memory budget breach §8):"
        echo "$violations" | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
