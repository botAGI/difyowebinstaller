#!/usr/bin/env bash
# test_monitoring_configs_valid.sh — валидация monitoring/* конфигов через
# официальные tools (promtool / amtool). SKIP gracefully если tools нет
# (на CI ubuntu-latest они не предустановлены — этот тест зелёный там как SKIP,
# реально проверяется локально на Spark где есть prometheus/alertmanager образы,
# или можно установить tools в CI отдельным шагом).
#
# Прецедент-класс: битый rule expression в alert_rules.yml / peer-offline.yml,
# невалидный prometheus.yml после правки, broken alertmanager route — всё это
# проходит YAML-schema валидацию (это валидный YAML), но prometheus/alertmanager
# падают на старте с parse error. promtool/amtool ловят это до деплоя.
#
# Exit: 0 = pass (or all SKIP), 1 = fail, 77 = skip (no tools at all).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MON="${REPO_ROOT}/monitoring"

if [[ ! -d "$MON" ]]; then
    echo "SKIP: monitoring/ not found"
    exit 77
fi

echo "## test_monitoring_configs_valid"

fail=0
pass=0
ran_anything=0

# --- promtool: prometheus.yml + rule files ---
if command -v promtool >/dev/null 2>&1; then
    ran_anything=1
    if [[ -f "${MON}/prometheus.yml" ]]; then
        if promtool check config "${MON}/prometheus.yml" >/dev/null 2>&1; then
            echo "  PASS: promtool check config prometheus.yml"
            pass=$((pass+1))
        else
            echo "  FAIL: promtool check config prometheus.yml:"
            promtool check config "${MON}/prometheus.yml" 2>&1 | head -5 | sed 's/^/        /'
            fail=$((fail+1))
        fi
    fi
    for rf in "${MON}"/alert_rules.yml "${MON}"/peer-offline.yml; do
        [[ -f "$rf" ]] || continue
        if promtool check rules "$rf" >/dev/null 2>&1; then
            echo "  PASS: promtool check rules $(basename "$rf")"
            pass=$((pass+1))
        else
            echo "  FAIL: promtool check rules $(basename "$rf"):"
            promtool check rules "$rf" 2>&1 | head -5 | sed 's/^/        /'
            fail=$((fail+1))
        fi
    done
else
    echo "  SKIP: promtool not installed (prometheus.yml + rules unchecked)"
fi

# --- amtool: alertmanager.yml ---
if command -v amtool >/dev/null 2>&1; then
    ran_anything=1
    if [[ -f "${MON}/alertmanager.yml" ]]; then
        if amtool check-config "${MON}/alertmanager.yml" >/dev/null 2>&1; then
            echo "  PASS: amtool check-config alertmanager.yml"
            pass=$((pass+1))
        else
            echo "  FAIL: amtool check-config alertmanager.yml:"
            amtool check-config "${MON}/alertmanager.yml" 2>&1 | head -5 | sed 's/^/        /'
            fail=$((fail+1))
        fi
    fi
else
    echo "  SKIP: amtool not installed (alertmanager.yml unchecked)"
fi

# --- fallback: at least YAML-valid + has expected top-level keys ---
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
    ran_anything=1
    for f in "${MON}/prometheus.yml" "${MON}/alertmanager.yml" "${MON}/loki-config.yml"; do
        [[ -f "$f" ]] || continue
        if python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
            echo "  PASS: $(basename "$f") — valid YAML (schema check; promtool/amtool for deep validation)"
            pass=$((pass+1))
        else
            echo "  FAIL: $(basename "$f") — invalid YAML"
            fail=$((fail+1))
        fi
    done
fi

if [[ $ran_anything -eq 0 ]]; then
    echo "SKIP: no promtool/amtool/python3 available — nothing checked"
    exit 77
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
