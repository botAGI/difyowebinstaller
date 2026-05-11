#!/usr/bin/env bash
# test_gpu_env_caps.sh — §8 правило про NVIDIA Container Toolkit.
#
# > GPU-контейнерам нужен NVIDIA_DRIVER_CAPABILITIES=compute,utility.
# > В compose deploy.resources.reservations.devices.capabilities: [gpu] —
# > это только docker-compose device request, НЕ NVIDIA runtime capability.
# > Без env var nvidia-container-toolkit даёт контейнеру только `graphics`:
# > NVML/libcuda отсутствуют → torch.cuda.is_available()=False → ML-нагрузки
# > валятся на CPU **молча** (контейнер healthy, просто в 10× медленнее).
#
# Прецедент: docling на CPU `Fall back to 'CPU'`, GPU idle, перформанс 10×
# хуже. Контейнер был "healthy" — багу не видно из docker ps.
#
# Тест: каждый service в compose, требующий GPU (определяется по наличию
# `runtime: nvidia` ИЛИ `deploy.resources.reservations.devices` с capabilities
# содержащим "gpu") МУСТ иметь `NVIDIA_DRIVER_CAPABILITIES` в environment.
#
# Известные исключения: НЕТ. Каждый GPU-сервис нуждается в этом env.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_gpu_env_caps"

fail=0
pass=0

mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    result="$(python3 - "$f" <<'PY'
import sys, yaml

data = yaml.safe_load(open(sys.argv[1])) or {}
services = data.get('services', {}) if isinstance(data, dict) else {}

violations = []
gpu_services_found = 0

for name, svc in services.items():
    if not isinstance(svc, dict):
        continue

    # Detect GPU service
    is_gpu = False

    # Path 1: runtime: nvidia (legacy)
    if svc.get('runtime') == 'nvidia':
        is_gpu = True

    # Path 2: deploy.resources.reservations.devices contains capabilities=[gpu]
    deploy = svc.get('deploy', {}) or {}
    res = deploy.get('resources', {}) or {}
    rsv = res.get('reservations', {}) or {}
    for dev in rsv.get('devices', []) or []:
        if isinstance(dev, dict):
            caps = dev.get('capabilities', []) or []
            if any('gpu' in str(c).lower() for c in caps):
                is_gpu = True
                break

    # Path 3: explicit env DRIVER (already correct OR override case)
    env = svc.get('environment', {}) or {}
    if isinstance(env, list):
        # Convert list-form ENV to dict
        env = dict(item.split('=', 1) for item in env if '=' in str(item))
    elif not isinstance(env, dict):
        env = {}

    if not is_gpu:
        continue

    gpu_services_found += 1

    # Check NVIDIA_DRIVER_CAPABILITIES present and contains compute,utility
    cap_value = env.get('NVIDIA_DRIVER_CAPABILITIES', '')
    cap_value_str = str(cap_value)
    # Allow ${VAR:-default} where default is correct
    if 'compute' not in cap_value_str or 'utility' not in cap_value_str:
        violations.append(f"{name}: NVIDIA_DRIVER_CAPABILITIES missing or incomplete (got {cap_value!r})")

print(f"GPU_SERVICES_FOUND={gpu_services_found}")
for v in violations:
    print(v)
PY
)"

    gpu_count="$(echo "$result" | grep '^GPU_SERVICES_FOUND=' | cut -d'=' -f2)"
    violations="$(echo "$result" | grep -v '^GPU_SERVICES_FOUND=' | grep -v '^$' || true)"

    if [[ "${gpu_count:-0}" -eq 0 ]]; then
        echo "  PASS: ${relpath} — no GPU services (nothing to check)"
        pass=$((pass+1))
        continue
    fi

    if [[ -z "$violations" ]]; then
        echo "  PASS: ${relpath} — all ${gpu_count} GPU services have NVIDIA_DRIVER_CAPABILITIES=compute,utility"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — GPU services missing NVIDIA_DRIVER_CAPABILITIES (silently CPU fallback §8):"
        echo "$violations" | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
