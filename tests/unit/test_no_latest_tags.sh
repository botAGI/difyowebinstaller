#!/usr/bin/env bash
# test_no_latest_tags.sh — CLAUDE.md §6 правило:
#
# > Все Docker-образы привязаны к конкретным версиям через `versions.env`.
# > Запрещено использовать `:latest` или нестабильные тэги.
#
# Mutating-теги (latest/edge/main/master/stable/nightly/dev) дают:
#   1. Не-reproducible install — два пользователя получают разные образы
#   2. Невозможность rollback — старый tag перезаписан новым SHA
#   3. Skip image_tags_exist валидации (тест-скрипт думает «есть же tag»)
#
# Запрещены явные tag'и:
#   - latest, stable, edge, main, master, develop, dev, nightly
#   - v0-latest, v1-latest и подобные семантически-мутирующие
#   - :без_tag (= implicit :latest)
#
# Проверяем:
#   1. Все image: в compose файлах имеют explicit tag
#   2. Tag не в blacklist
#   3. Также: значения VAR= в versions.env (не только fallback)
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_no_latest_tags"

fail=0
pass=0

# Mutating tag patterns (case-insensitive)
FORBIDDEN_TAGS=(latest stable edge main master develop dev nightly)

# Compose files check
mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    bad="$(python3 - "$f" "${FORBIDDEN_TAGS[@]}" <<'PY'
import sys, yaml, re

path = sys.argv[1]
forbidden = set(t.lower() for t in sys.argv[2:])

data = yaml.safe_load(open(path)) or {}
services = data.get('services', {}) if isinstance(data, dict) else {}

violations = []
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    image = svc.get('image', '')
    if not image:
        continue
    # Resolve ${VAR:-fallback} pattern → use fallback (worst-case static value)
    m = re.search(r'\$\{[A-Z_][A-Z0-9_]*:-([^\}]+)\}', image)
    if m:
        # extract from inside ${VAR:-...} — could be tag or full image:tag
        resolved = m.group(1)
        # if image is "registry/repo:${VAR:-tag}", combine
        prefix = image.split('${', 1)[0]
        if prefix.endswith(':'):
            tag = resolved
        else:
            # full-image substitution → split by last :
            full = prefix + resolved
            tag = full.rsplit(':', 1)[1] if ':' in full.rsplit('/', 1)[-1] else ''
    else:
        # no substitution — split by last :
        # Split tag: only if last : is in last segment (not registry:port)
        last_seg = image.rsplit('/', 1)[-1]
        if ':' in last_seg:
            tag = last_seg.rsplit(':', 1)[1]
        elif '@sha256:' in image:
            tag = 'sha256-pinned'  # OK, immutable
        else:
            tag = ''  # implicit :latest = bad

    if tag == '':
        violations.append(f"{name} (image={image}): no tag = implicit :latest")
    elif tag.lower() in forbidden:
        violations.append(f"{name} (image={image}): tag '{tag}' is mutating")
    elif '-latest' in tag.lower():
        violations.append(f"{name} (image={image}): tag '{tag}' contains '-latest' (mutating)")

print('\n'.join(violations))
PY
)"

    if [[ -z "$bad" ]]; then
        echo "  PASS: ${relpath} — no :latest/mutating tags in image fallbacks"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — mutating tags detected:"
        echo "$bad" | head -10 | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

# versions.env check — VALUES сами не должны содержать mutating tags.
# Кроме комментариев / placeholder для динамических SHA tags.
versions="${REPO_ROOT}/templates/versions.env"
if [[ -f "$versions" ]]; then
    # Word-boundary check — `_edge` в "6.6-24.04_edge" (Ubuntu LTS edge variant,
    # immutable Squid tag) НЕ должен ловиться. Запрещаем только когда mutating
    # token стоит standalone (=latest, :latest, -latest суффикс) или = всё VALUE.
    bad_versions="$(grep -nE '^[A-Z_]+=(latest|nightly|edge|stable|main|master|develop|dev|.*[:=-]latest$|.*-(latest|nightly|edge|stable))$' "$versions" \
        | grep -vE '^\s*#' \
        | grep -vE '^\s*[0-9]+:[A-Z_]+_(SHA|DIGEST|HASH)=' \
        || true)"

    if [[ -z "$bad_versions" ]]; then
        echo "  PASS: templates/versions.env — no mutating tag VALUES"
        pass=$((pass+1))
    else
        echo "  FAIL: templates/versions.env — mutating tag values detected:"
        echo "$bad_versions" | head -5 | sed 's/^/        /'
        fail=$((fail+1))
    fi
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
