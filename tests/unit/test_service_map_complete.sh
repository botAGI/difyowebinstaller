#!/usr/bin/env bash
# test_service_map_complete.sh — каждая *_VERSION переменная из docker-compose
# `image:` строк ДОЛЖНА быть в lib/service-map.sh::NAME_TO_VERSION_KEY values.
#
# Зачем: `agmind update --check` (scripts/update.sh) и health-report используют
# NAME_TO_VERSION_KEY чтобы знать какие версии отслеживать. Если в compose
# появился новый `image: foo:${FOO_VERSION:-...}` но FOO_VERSION нет ни в одном
# NAME_TO_VERSION_KEY value → update --check молча его пропустит, компонент
# не отслеживается, bit rot.
#
# Whitelist: версии которые НЕ должны быть в NAME_TO_VERSION_KEY:
#   - RAGFLOW_* (digest-pinned, self-built — custom update flow)
#   - MILVUS_* (experimental profile, lib-интеграция в backlog)
#   - MC_VERSION (mc client — bumps with MinIO server, не отдельно)
#   - MILVUS_ETCD_VERSION (часть milvus experimental)
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SERVICE_MAP="${REPO_ROOT}/lib/service-map.sh"

if [[ ! -f "$SERVICE_MAP" ]]; then
    echo "SKIP: lib/service-map.sh not found"
    exit 77
fi

echo "## test_service_map_complete"

fail=0
pass=0

# Whitelist — version vars intentionally NOT in NAME_TO_VERSION_KEY
WHITELIST_REGEX='^(RAGFLOW_|MILVUS_|MC_VERSION$|REDIS_EXPORTER_VERSION$|POSTGRES_EXPORTER_VERSION$|NGINX_EXPORTER_VERSION$|ELASTICSEARCH_EXPORTER_VERSION$|SOPS_VERSION$|K6_VERSION$|CRAWL4AI_VERSION$|PROMETHEUS_VERSION$|VLLM_NGC_VERSION$|VLLM_SPARK|PORTAINER_AGENT_VERSION$)'
# Notes:
#   - per-service exporters / k6 / sops / crawl4ai / prometheus: may or may not
#     be in NAME_TO_VERSION_KEY — whitelist generously; test's value is catching
#     a genuinely NEW unmapped *_VERSION, not 100% coverage enforcement.
#   - PORTAINER_AGENT_VERSION: lives in env.lan.template (cluster-only worker.yml),
#     must always equal PORTAINER_VERSION (§8 TLS handshake) — tracked implicitly
#     via portainer. (If ever moved to versions.env, drop from this whitelist.)

# Collect *_VERSION vars referenced in compose image: lines
mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)
mapfile -t version_vars < <(grep -hoE '\$\{[A-Z_]+_VERSION' "${compose_files[@]}" 2>/dev/null | sed 's/^\${//' | sort -u)

# Collect NAME_TO_VERSION_KEY values from service-map.sh
mapfile -t mapped_keys < <(grep -oE '\]=[A-Z_]+_VERSION' "$SERVICE_MAP" 2>/dev/null | sed 's/^\]=//' | sort -u)

unmapped=()
for v in "${version_vars[@]}"; do
    # skip whitelist
    if echo "$v" | grep -qE "$WHITELIST_REGEX"; then continue; fi
    # is it in mapped_keys?
    found=0
    for m in "${mapped_keys[@]}"; do
        [[ "$v" == "$m" ]] && { found=1; break; }
    done
    [[ $found -eq 0 ]] && unmapped+=("$v")
done

if [[ ${#unmapped[@]} -eq 0 ]]; then
    echo "  PASS: all non-whitelisted *_VERSION vars in compose are mapped in service-map.sh NAME_TO_VERSION_KEY"
    echo "        (checked ${#version_vars[@]} version vars, ${#mapped_keys[@]} mapped keys)"
    pass=$((pass+1))
else
    echo "  FAIL: *_VERSION var(s) in compose NOT in service-map.sh — 'agmind update --check' will skip these:"
    for v in "${unmapped[@]}"; do echo "        \${${v}}"; done
    echo "        Add to NAME_TO_VERSION_KEY in lib/service-map.sh, or whitelist in this test if intentional."
    fail=$((fail+1))
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
