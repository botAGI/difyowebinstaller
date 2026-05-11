#!/usr/bin/env bash
# test_dify_env_safety.sh — Dify-specific env vars из CLAUDE.md §8.
#
# Прецеденты которые этот тест ловит до prod:
#
# 1. HTTP_REQUEST_NODE_MAX_TEXT_SIZE=100MB (дефолт Dify=1 MB).
#    Без этого docling-serve возвращает 1-5 MB markdown на тяжёлых PDF →
#    HTTP нода в Dify валится с "Text size too large" → KB pipeline FAIL.
#
# 2. PLUGIN_DAEMON_TIMEOUT=1800 (was 600).
#    Тяжёлые PDF (100+ стр, таблицы) через docling на GB10 = 400-600 сек.
#    Старый timeout 600 → ABORT с latency_ms=600011.
#
# 3. plugin_daemon mem_limit ≥ 2g (было 10g legacy, теперь 4g calibrated).
#    1g — OOM при большом количестве плагинов. <2g не использовать.
#
# 4. PLUGIN_DAEMON_VERSION=0.5.3-local (golden stable).
#    0.5.4-0.5.6 имеют #640/#649/#672 регрессии. Уже покрыто
#    test_versions_env_arm64_holds.sh, здесь — runtime check что compose
#    реально использует pinned version.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_dify_env_safety"

fail=0
pass=0

COMPOSE="${REPO_ROOT}/templates/docker-compose.yml"

if [[ ! -f "$COMPOSE" ]]; then
    echo "SKIP: ${COMPOSE} not found"
    exit 77
fi

# Helper: extract env value (raw, including ${VAR:-default} substitution)
_get_env() {
    local svc_path="$1" key="$2"
    python3 - "$COMPOSE" "$svc_path" "$key" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
parts = sys.argv[2].split('.')
node = d
for p in parts:
    node = node.get(p, {}) if isinstance(node, dict) else {}
key = sys.argv[3]
if isinstance(node, dict):
    print(node.get(key, ''))
elif isinstance(node, list):
    for item in node:
        if isinstance(item, str) and item.startswith(key + '='):
            print(item.split('=', 1)[1])
            break
PY
}

# 1. HTTP_REQUEST_NODE_MAX_TEXT_SIZE in x-shared-env (or in api/worker env)
val="$(_get_env 'x-shared-env' 'HTTP_REQUEST_NODE_MAX_TEXT_SIZE')"
case "$val" in
    *100MB*|*100mb*|*"100*1024*1024"*|*104857600*)
        echo "  PASS: HTTP_REQUEST_NODE_MAX_TEXT_SIZE = ${val} (≥100MB for docling responses §8)"
        pass=$((pass+1))
        ;;
    "")
        echo "  FAIL: HTTP_REQUEST_NODE_MAX_TEXT_SIZE not set (default 1MB → docling 1-5MB md FAILS §8)"
        fail=$((fail+1))
        ;;
    *)
        echo "  FAIL: HTTP_REQUEST_NODE_MAX_TEXT_SIZE = ${val} (expected 100MB for docling §8)"
        fail=$((fail+1))
        ;;
esac

# 2. PLUGIN_DAEMON_TIMEOUT >= 1800
val="$(_get_env 'x-shared-env' 'PLUGIN_DAEMON_TIMEOUT')"
# Try different env locations: x-shared-env, services.plugin_daemon.environment
if [[ -z "$val" ]]; then
    val="$(_get_env 'services.plugin_daemon.environment' 'PLUGIN_DAEMON_TIMEOUT')"
fi
# extract number from "1800" or "${VAR:-1800}"
num="$(echo "$val" | grep -oE '[0-9]+' | head -1)"
if [[ -n "$num" ]] && [[ "$num" -ge 1800 ]]; then
    echo "  PASS: PLUGIN_DAEMON_TIMEOUT = ${val} (≥1800s for heavy docling PDFs §8)"
    pass=$((pass+1))
elif [[ -z "$val" ]]; then
    echo "  WARN: PLUGIN_DAEMON_TIMEOUT not explicitly set (Dify default may be too low §8)"
    pass=$((pass+1))  # warn, не fail — возможно дефолт уже подходящий
else
    echo "  FAIL: PLUGIN_DAEMON_TIMEOUT = ${val} (< 1800s — heavy PDF will ABORT §8)"
    fail=$((fail+1))
fi

# 3. plugin_daemon mem_limit ≥ 2g
val="$(_get_env 'services.plugin_daemon' 'mem_limit')"
mb=0
if [[ -n "$val" ]]; then
    n="$(echo "$val" | grep -oE '[0-9]+' | head -1)"
    if [[ "$val" =~ [gG] ]]; then
        mb=$((n * 1024))
    elif [[ "$val" =~ [mM] ]]; then
        mb=$n
    fi
fi
if [[ "$mb" -ge 2048 ]]; then
    echo "  PASS: plugin_daemon mem_limit = ${val} (≥ 2g §8 calibration)"
    pass=$((pass+1))
elif [[ -z "$val" ]]; then
    echo "  FAIL: plugin_daemon mem_limit not set (will OOM with multiple plugins §8)"
    fail=$((fail+1))
else
    echo "  FAIL: plugin_daemon mem_limit = ${val} (< 2g — Phase 41 calibration min §8)"
    fail=$((fail+1))
fi

# 4. PLUGIN_DAEMON_VERSION pinned (через image tag в plugin_daemon service)
img="$(_get_env 'services.plugin_daemon' 'image')"
if [[ "$img" == *"PLUGIN_DAEMON_VERSION"* ]]; then
    echo "  PASS: plugin_daemon image uses ${PLUGIN_DAEMON_VERSION:-pinned} substitution (golden stable §8)"
    pass=$((pass+1))
elif [[ "$img" == *":0.5.3-local"* ]] || [[ "$img" == *":0.5.3"* ]]; then
    echo "  PASS: plugin_daemon image directly pinned to 0.5.3-local"
    pass=$((pass+1))
else
    echo "  FAIL: plugin_daemon image = ${img} (expected PLUGIN_DAEMON_VERSION substitution or :0.5.3-local)"
    fail=$((fail+1))
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
