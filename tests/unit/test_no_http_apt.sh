#!/usr/bin/env bash
# test_no_http_apt.sh — §8 правило про HTTP truncation в этой сети.
#
# > HTTP с ports.ubuntu.com (и зеркал что синкаются через HTTP) молча режет
# > >600 MB файлы. curl/wget/apt-get принимают truncated body как успех
# > (HTTP 200 + Connection closed до конца Content-Length), SHA256 не совпадает,
# > dpkg -i валится с "неожиданный конец файла или потока".
# > Фикс: всегда HTTPS для больших deb/iso. TLS close_notify обязателен →
# > truncation ловится клиентом как ошибка.
#
# Прецедент: linux-firmware_*_arm64.deb (603 MB) режется на ~632 из 634 MB.
# Промежуточный прозрачный прокси/CDN между DGX Spark и upstream mirror.
#
# Тест: install.sh / lib/*.sh / scripts/*.sh не должны содержать
# `http://` (без s) на ubuntu mirrors (ports.ubuntu.com, archive.ubuntu.com,
# security.ubuntu.com, *.archive.ubuntu.com).
#
# Также: sources.list manipulation должна писать https:// scheme.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_no_http_apt"

fail=0
pass=0

mapfile -t scripts < <(find "${REPO_ROOT}/lib" "${REPO_ROOT}/scripts" -maxdepth 2 -name "*.sh" -type f 2>/dev/null | sort)
scripts+=("${REPO_ROOT}/install.sh")

# Pattern: http:// (без s) для ubuntu apt mirrors
# Известные: ports.ubuntu.com, archive.ubuntu.com, security.ubuntu.com,
#            *.archive.ubuntu.com, *.ports.ubuntu.com, deb.debian.org
APT_MIRROR_PATTERN='http://([a-z0-9.-]*\.)?(ports|archive|security)\.ubuntu\.com|http://deb\.debian\.org'

for s in "${scripts[@]}"; do
    [[ -f "$s" ]] || continue
    relpath="${s#${REPO_ROOT}/}"

    # Find http:// ubuntu mirror references (excluding comments)
    matches="$(grep -nE "$APT_MIRROR_PATTERN" "$s" 2>/dev/null \
        | grep -vE '^\s*[0-9]+:\s*#' \
        || true)"

    if [[ -z "$matches" ]]; then
        : # pass — accumulate at end per-file would be noisy, just count globally
    else
        echo "  FAIL: ${relpath} — http:// apt mirror (truncation bug §8):"
        echo "$matches" | head -5 | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

if [[ $fail -eq 0 ]]; then
    echo "  PASS: no http:// ubuntu apt mirrors in install.sh / lib / scripts (truncation §8)"
    pass=$((pass+1))
fi

# Additional check: если скрипты модифицируют sources.list — должна быть https
sources_writers="$(grep -rlnE 'sources\.list|/etc/apt/sources' "${scripts[@]}" 2>/dev/null || true)"
if [[ -n "$sources_writers" ]]; then
    bad_https=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # if file writes "http://" to sources context without s
        if grep -nE '(>>?|echo|sed).*http://([a-z0-9.-]*\.)?(ports|archive)\.ubuntu' "$f" 2>/dev/null | grep -vE '^\s*[0-9]+:\s*#' >/dev/null; then
            echo "  FAIL: ${f#${REPO_ROOT}/} — writes http:// to apt sources (use https §8)"
            bad_https=$((bad_https+1))
        fi
    done <<< "$sources_writers"
    if [[ $bad_https -eq 0 ]]; then
        echo "  PASS: scripts modifying apt sources use https:// scheme"
        pass=$((pass+1))
    else
        fail=$((fail+1))
    fi
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
