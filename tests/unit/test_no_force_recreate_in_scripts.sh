#!/usr/bin/env bash
# test_no_force_recreate_in_scripts.sh — §8 anti-pattern detector.
#
# > НИКОГДА `docker compose up -d --force-recreate worker/api` посреди активной
# > RAG-индексации. Recreate = новый контейнер с новым `hostname celery@XXX`,
# > но в Redis остаются stale generate_task_belong:* и pub/sub channels привязаны
# > к старому hostname → новый worker их не читает → tasks висят навечно.
#
# Этот тест ловит когда кто-то добавил `--force-recreate` для worker/api/db
# в скрипты автоматизации. Допустимы только:
#   - docker restart <name>            (env reload)
#   - docker stop X && docker rm X && docker compose up -d X  (controlled)
#   - --force-recreate для GPU/standalone сервисов БЕЗ shared celery state
#     (vllm, qdrant, weaviate, milvus, etc — они не держат celery hostname)
#
# Forbidden tokens в лоб:
#   - "compose up -d --force-recreate worker"
#   - "compose up -d --force-recreate api"
#   - "compose up -d --force-recreate plugin_daemon"
#   - generic "--force-recreate" в скриптах = warning (не fail), документировать
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_no_force_recreate_in_scripts"

fail=0
pass=0

# Сервисы с celery hostname / Redis pub-sub state: запрещены force-recreate.
FORBIDDEN_SERVICES=(worker api plugin_daemon)

mapfile -t scripts < <(find "${REPO_ROOT}/lib" "${REPO_ROOT}/scripts" -maxdepth 2 \
    -name "*.sh" -type f 2>/dev/null | sort)
scripts+=("${REPO_ROOT}/install.sh")

for svc in "${FORBIDDEN_SERVICES[@]}"; do
    # Pattern: --force-recreate <args>* <svc> на одной строке (compose up -d ...).
    # Также --force-recreate в multi-arg list — `docker compose up -d --force-recreate api worker`.
    matches="$(grep -nHE "force-recreate.*\\b${svc}\\b|\\b${svc}\\b.*force-recreate" "${scripts[@]}" 2>/dev/null \
        | grep -v '^\s*[^:]*:[0-9]\+:\s*#' \
        | grep -vE '^\s*[^:]*:[0-9]\+:.*\b(test_|#|//)' \
        || true)"

    if [[ -z "$matches" ]]; then
        echo "  PASS: no '--force-recreate ${svc}' in scripts (Redis celery state §8)"
        pass=$((pass+1))
    else
        echo "  FAIL: --force-recreate ${svc} found (breaks Redis celery state §8):"
        echo "$matches" | sed 's|^'"$REPO_ROOT/"'||' | head -10 | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

# Bonus: count generic --force-recreate usages (не fail, информационно)
generic_count="$(grep -hE 'force-recreate' "${scripts[@]}" 2>/dev/null | grep -v '^\s*#' | wc -l | tr -d ' ')"
echo "  INFO: ${generic_count} total '--force-recreate' usages in scripts (review periodically)"

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
