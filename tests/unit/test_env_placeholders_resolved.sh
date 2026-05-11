#!/usr/bin/env bash
# test_env_placeholders_resolved.sh — каждый __PLACEHOLDER__ в env.lan.template
# ДОЛЖЕН иметь соответствующую замену в lib/config.sh или install.sh.
#
# Прецедент-класс: добавили `FOO=__FOO__` в template, забыли
# `-e "s|__FOO__|...|g"` в generate_config → install ставит .env с буквальным
# `FOO=__FOO__` → сервис читает мусорное значение → падает (или хуже — тихо
# работает не так). Static check ловит до деплоя.
#
# Также обратное: replace-паттерн в config.sh для placeholder которого НЕТ в
# template = dead code (warning, не fail — может быть для других файлов).
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE="${REPO_ROOT}/templates/env.lan.template"
CONFIG_SH="${REPO_ROOT}/lib/config.sh"
INSTALL_SH="${REPO_ROOT}/install.sh"

if [[ ! -f "$TEMPLATE" ]] || [[ ! -f "$CONFIG_SH" ]]; then
    echo "SKIP: env.lan.template or lib/config.sh not found"
    exit 77
fi

echo "## test_env_placeholders_resolved"

fail=0
pass=0

# Все __X__ placeholders в env.lan.template (uppercase, underscores)
mapfile -t placeholders < <(grep -oE '__[A-Z][A-Z0-9_]*__' "$TEMPLATE" | sort -u)

if [[ ${#placeholders[@]} -eq 0 ]]; then
    echo "  WARN: no __PLACEHOLDER__ patterns found in template (unexpected)"
    echo "=== Summary: 0 passed, 0 failed ==="
    exit 0
fi

# Где могут быть замены: config.sh (основные), install.sh (некоторые),
# lib/security.sh / lib/authelia.sh (специфичные)
SEARCH_FILES=("$CONFIG_SH" "$INSTALL_SH")
for f in "${REPO_ROOT}/lib/security.sh" "${REPO_ROOT}/lib/authelia.sh" "${REPO_ROOT}/lib/cluster_mode.sh"; do
    [[ -f "$f" ]] && SEARCH_FILES+=("$f")
done

unresolved=()
for ph in "${placeholders[@]}"; do
    # Ищем `s|__X__|` или `s/__X__/` или просто упоминание __X__ как target замены
    found=0
    for f in "${SEARCH_FILES[@]}"; do
        # match: s|__X__| или s#__X__# или s/__X__/ (sed substitution with __X__ as pattern)
        if grep -qE "s[|/#]${ph}[|/#]" "$f" 2>/dev/null; then found=1; break; fi
        # also match bare `__X__` appearing in a sed -e line (less strict fallback)
        if grep -qE "sed.*${ph}|${ph}.*=>" "$f" 2>/dev/null; then found=1; break; fi
    done
    if [[ $found -eq 0 ]]; then
        unresolved+=("$ph")
    fi
done

if [[ ${#unresolved[@]} -eq 0 ]]; then
    echo "  PASS: all ${#placeholders[@]} __PLACEHOLDER__ in env.lan.template have a replacement in config.sh/install.sh"
    pass=$((pass+1))
else
    echo "  FAIL: ${#unresolved[@]} placeholder(s) in env.lan.template with NO replacement (install ships literal __X__):"
    for ph in "${unresolved[@]}"; do echo "        ${ph}"; done
    fail=$((fail+1))
fi

# Reverse: replacement patterns for placeholders NOT in template — dead code warning
mapfile -t replace_patterns < <(grep -hoE 's[|/#]__[A-Z][A-Z0-9_]*__[|/#]' "$CONFIG_SH" 2>/dev/null | sed -E 's/^s[|/#](__[A-Z0-9_]+__)[|/#]$/\1/' | sort -u)
dead=()
for rp in "${replace_patterns[@]}"; do
    if ! printf '%s\n' "${placeholders[@]}" | grep -qx "$rp"; then
        # Could be for nginx.conf / ragflow / other templates — only warn
        dead+=("$rp")
    fi
done
if [[ ${#dead[@]} -gt 0 ]]; then
    echo "  INFO: ${#dead[@]} replacement pattern(s) in config.sh for placeholders not in env.lan.template"
    echo "        (may target nginx.conf/ragflow/other templates — review): ${dead[*]:0:8}"
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
