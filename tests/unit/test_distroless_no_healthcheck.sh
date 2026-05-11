#!/usr/bin/env bash
# test_distroless_no_healthcheck.sh — §8 правило: distroless образы не имеют
# `/bin/sh` или `wget`, поэтому `CMD-SHELL wget ...` healthcheck выдаёт
# `-1: stat /bin/sh: no such file or directory` → контейнер навечно unhealthy
# даже если сервис работает.
#
# DISTROLESS образы в нашем стеке (verified `docker run --entrypoint sh X -c echo`):
#   - grafana/loki — distroless ✅ (нет /bin/sh)
#   - oliver006/redis_exporter — distroless ✅
#   - nginx/nginx-prometheus-exporter — distroless ✅
#   - grafana/alloy — distroless ✅
#
# НЕ distroless (busybox-based, есть /bin/sh + wget — CMD-SHELL работает):
#   - prom/prometheus — busybox ✅ может CMD-SHELL
#   - prom/alertmanager — busybox ✅
#   - prometheuscommunity/postgres-exporter — busybox ✅
#   (verified 2026-05-11 после ложного срабатывания: эти 3 ОШИБОЧНО считались
#    distroless, их рабочие healthcheck'и были заменены на ["NONE"] и сломали
#    grafana.depends_on.prometheus: service_healthy — откачено.)
#
# Если для DISTROLESS image определён CMD-SHELL healthcheck → FAIL.
# Допустимые альтернативы для distroless:
#   - test: ["NONE"] (отключить — но тогда depends_on на них только service_started)
#   - test: ["CMD", "/binary", "--health-flag"] (если binary поддерживает)
#   - не указывать healthcheck, мониторинг через Prometheus up{}.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_distroless_no_healthcheck"

fail=0
pass=0

# Image-prefix'ы которые verified-distroless (нет /bin/sh).
# НЕ включать prom/prometheus, prom/alertmanager, prometheuscommunity/postgres-exporter —
# они busybox-based, CMD-SHELL у них работает (см. шапку файла).
DISTROLESS_PATTERNS=(
    "grafana/loki"
    "oliver006/redis_exporter"
    "nginx/nginx-prometheus-exporter"
    "grafana/alloy"
)

mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    # Каждый distroless service: проверяем что healthcheck.test НЕ начинается с
    # CMD-SHELL (это требует /bin/sh которого в distroless нет).
    bad="$(python3 - "$f" "${DISTROLESS_PATTERNS[@]}" <<'PY'
import sys, yaml

path = sys.argv[1]
patterns = sys.argv[2:]

data = yaml.safe_load(open(path)) or {}
services = data.get('services', {}) if isinstance(data, dict) else {}

violations = []
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    image = svc.get('image', '')
    is_distroless = any(p in image for p in patterns)
    if not is_distroless:
        continue
    hc = svc.get('healthcheck')
    if not hc or not isinstance(hc, dict):
        continue
    test = hc.get('test')
    if test is None:
        continue
    # test может быть list или string
    if isinstance(test, list):
        test_str = ' '.join(str(x) for x in test)
    else:
        test_str = str(test)
    if 'CMD-SHELL' in test_str or test_str.startswith('CMD-SHELL'):
        violations.append(f"{name} (image={image}): {test}")

print('\n'.join(violations))
PY
)"

    if [[ -z "$bad" ]]; then
        echo "  PASS: ${relpath} — no distroless service has CMD-SHELL healthcheck"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — distroless services with CMD-SHELL healthcheck:"
        echo "$bad" | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
