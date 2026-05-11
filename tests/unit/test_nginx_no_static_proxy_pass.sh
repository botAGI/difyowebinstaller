#!/usr/bin/env bash
# test_nginx_no_static_proxy_pass.sh — §8 правило про docker DNS:
#
# > nginx `upstream { server name; }` запирает IP при старте — не использовать
# > для docker DNS. `resolver 127.0.0.11 valid=10s` влияет ТОЛЬКО на
# > `proxy_pass $variable`, не на upstream блоки и не на статический
# > `proxy_pass http://name`.
# >
# > Симптом: docker compose up -d --force-recreate api даёт новый IP
# > контейнеру → nginx держит старый → 502 → Dify UI висит на загрузке.
#
# Правило §8: «в templates/nginx.conf.template НИ ОДНОГО `proxy_pass http://<name>`
# без `$` — ревью-чеклист перед merge». Этот тест автоматизирует ревью-чеклист.
#
# Запрещено:
#   - upstream { server <name>; } блоки на docker hostnames
#   - proxy_pass http://<hostname> (без $)
#
# Разрешено:
#   - set $u_var http://<name>; proxy_pass $u_var;
#   - proxy_pass $variable;
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_nginx_no_static_proxy_pass"

fail=0
pass=0

mapfile -t nginx_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -type f \
    \( -name "nginx*.conf*" -o -name "*.nginx" \) 2>/dev/null | sort)

if [[ ${#nginx_files[@]} -eq 0 ]]; then
    echo "SKIP: no nginx config templates found"
    exit 77
fi

for f in "${nginx_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    # Check 1: статические proxy_pass http://<name> без $ — запрещены.
    # Patterns исключаемые из проверки:
    #   - комментарии (#)
    #   - строки с $variable
    #   - external URLs (https://, IP-литералы, localhost — они стабильны)
    static_pp="$(grep -nE 'proxy_pass\s+https?://' "$f" \
        | grep -v '^\s*[0-9]\+:\s*#' \
        | grep -vE 'proxy_pass\s+https?://\$' \
        | grep -vE 'proxy_pass\s+https?://(localhost|127\.0\.0\.1|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' \
        || true)"

    if [[ -z "$static_pp" ]]; then
        echo "  PASS: ${relpath} — no static proxy_pass to docker hostnames"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — static proxy_pass without \$variable (docker DNS trap §8):"
        echo "$static_pp" | head -10 | sed 's/^/        /'
        fail=$((fail+1))
    fi

    # Check 2: upstream { server <hostname>; } блоки на docker DNS — запрещены.
    # IP literals и localhost можно. Хостнеймы (typically docker container names)
    # вроде `server api`, `server worker` — нельзя.
    bad_upstream="$(awk '
        /^\s*upstream\s+\w+\s*\{/ {in_block=1; block_start=NR; next}
        in_block && /^\s*\}/ {in_block=0; next}
        in_block && /^\s*server\s+/ {
            line=$0
            # extract server target (next token after "server")
            sub(/^\s*server\s+/, "", line)
            sub(/[\s;].*$/, "", line)
            sub(/:[0-9]+$/, "", line)  # strip :port
            # allow IP literals and localhost
            if (line !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && line != "localhost" && line !~ /^\$/) {
                print "line " NR ": upstream@" block_start " server " line
            }
        }
    ' "$f")"

    if [[ -z "$bad_upstream" ]]; then
        echo "  PASS: ${relpath} — no upstream{} blocks with docker hostnames"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — upstream{} block with docker hostname (§8 IP-cache bug):"
        echo "$bad_upstream" | head -10 | sed 's/^/        /'
        fail=$((fail+1))
    fi

    # Check 3: если в файле есть proxy_pass на docker DNS — должен быть
    # `resolver 127.0.0.11` (Docker embedded DNS) с valid= TTL.
    has_dynamic_pp="$(grep -E 'proxy_pass\s+\$' "$f" | head -1 || true)"
    if [[ -n "$has_dynamic_pp" ]]; then
        if grep -qE '^\s*resolver\s+127\.0\.0\.11' "$f"; then
            echo "  PASS: ${relpath} — has dynamic proxy_pass + resolver 127.0.0.11"
            pass=$((pass+1))
        else
            echo "  FAIL: ${relpath} — dynamic proxy_pass present but no 'resolver 127.0.0.11' directive"
            fail=$((fail+1))
        fi
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
