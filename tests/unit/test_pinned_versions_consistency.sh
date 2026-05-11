#!/usr/bin/env bash
# test_pinned_versions_consistency.sh — Каждый ${VAR:-fallback} в compose файлах
# ДОЛЖЕН совпадать с VAR=value в versions.env. Иначе fresh install без .env
# возьмёт fallback (старую версию) и поведёт себя по-другому, чем install через
# install.sh где versions.env загружается в .env.
#
# Прецедент: MinIO fallback в docker-compose.yml = RELEASE.2024-11-07 (Nov 2024),
# но pin в versions.env = RELEASE.2025-09-07 (Sep 2025). 11 месяцев расхождения.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERSIONS="${REPO_ROOT}/templates/versions.env"

if [[ ! -f "$VERSIONS" ]]; then
    echo "SKIP: ${VERSIONS} not found"
    exit 77
fi

echo "## test_pinned_versions_consistency"

fail=0
pass=0

# Собираем VAR=VALUE из versions.env (только не-комментарии и не-пустые)
declare -A pinned
while IFS='=' read -r key val; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    pinned["$key"]="$val"
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$VERSIONS")

# Все compose файлы
mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

# Парсим ${VAR:-fallback} паттерны в compose. Только из строк image:.
# Игнорируем ${VAR} без fallback и ${VAR:-} с пустым (intentional secret stub).
for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"
    while IFS= read -r line; do
        # extract ${VAR:-FALLBACK} from image: line
        if [[ "$line" =~ \$\{([A-Z_][A-Z0-9_]*):-([^\}]+)\} ]]; then
            var="${BASH_REMATCH[1]}"
            fallback="${BASH_REMATCH[2]}"
            # Skip empty fallbacks (e.g. ${SECRET_KEY:-}) and tag-less placeholders
            [[ -z "$fallback" ]] && continue
            # Skip nested substitution patterns ${X:-${Y:-default}} — regex
            # captures only outer var, fallback contains '${' which means inner
            # variable will resolve at runtime. Cannot statically validate.
            if [[ "$fallback" == *'${'* ]]; then
                echo "  SKIP: ${var} — uses nested variable substitution"
                continue
            fi

            # Lookup pinned value
            pinned_val="${pinned[$var]:-}"
            if [[ -z "$pinned_val" ]]; then
                echo "  SKIP: ${var} in ${relpath} — not declared in versions.env"
                continue
            fi
            # Skip values containing variable substitution (e.g. RAGFLOW_IMAGE
            # = "ar2r223/ragflow-spark@${RAGFLOW_DIGEST}"). Those resolve at
            # runtime through .env loading, can't be statically compared.
            if [[ "$pinned_val" == *'${'* ]]; then
                echo "  SKIP: ${var} — uses runtime variable substitution"
                continue
            fi
            if [[ "$fallback" == "$pinned_val" ]]; then
                echo "  PASS: ${var} fallback == versions.env (${pinned_val})"
                pass=$((pass+1))
            else
                echo "  FAIL: ${var} fallback DRIFT in ${relpath}"
                echo "        compose fallback:  ${fallback}"
                echo "        versions.env pin:  ${pinned_val}"
                fail=$((fail+1))
            fi
        fi
    done < <(grep -E '^\s*image:' "$f")
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
