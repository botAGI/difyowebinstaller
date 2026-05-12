#!/usr/bin/env bash
# test_compose_mount_sources_exist.sh — каждый bind-mount source в compose
# (./templates/X, ./monitoring/X, ./conf.d/X и т.п.) ДОЛЖЕН существовать в репо.
#
# Прецеденты:
#   - init-dify-plugin-db.sql не копировался в /opt/agmind/templates/ →
#     mount fail при recreate agmind-db (memory: project_init_dify_plugin_db_copy_bug)
#   - scripts/loadtest/*.js не попадали в whitelist копирования →
#     `agmind loadtest` пустой (install.sh _copy_runtime_files whitelist regression)
#
# Тест проверяет: для каждого `- ./path:/container/path` в compose,
# исходный `./path` существует относительно templates/ ИЛИ относительно repo root
# (в зависимости от того где compose файл живёт при деплое — /opt/agmind/docker/).
#
# Файлы которые генерируются в runtime (volumes/, .env, *.generated) — пропускаем.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_compose_mount_sources_exist"

fail=0
pass=0

# Runtime-generated paths (created by install.sh / lib/config.sh, not in repo).
# Эти проверять бессмысленно — install.sh их создаёт во время phase_config.
RUNTIME_PREFIXES=(
    "./volumes/"             # docker bind-mount data dirs (created at install)
    "./.env"                 # generated from template
    "./monitoring/textfile"  # written by gpu-metrics.sh cron
    "./litellm-config.yaml"  # lib/config.sh::_generate_litellm_config (inline)
    "./nginx/"               # nginx.conf rendered from template + health/ mkdir'd by install.sh
    "./ragflow/"             # service_conf.yaml rendered from templates/ragflow/*.template
    "./conf.d/"              # generated config fragments
    "/var/run/docker.sock"   # host socket
    "/proc"                  # host
    "/sys"                   # host
    "/"                      # host root mount (node-exporter)
    "agmind_"                # named volumes (not paths)
)

mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    # Extract all bind-mount sources
    mounts="$(python3 - "$f" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for name, svc in d.get('services', {}).items():
    if not isinstance(svc, dict):
        continue
    for vol in svc.get('volumes', []) or []:
        if isinstance(vol, str):
            src = vol.split(':', 1)[0]
            print(f"{name}|{src}")
        elif isinstance(vol, dict) and vol.get('type') == 'bind':
            print(f"{name}|{vol.get('source','')}")
PY
)"

    file_violations=0
    while IFS='|' read -r svc src; do
        [[ -z "$src" ]] && continue
        # Skip runtime-generated / host paths
        skip=0
        for pref in "${RUNTIME_PREFIXES[@]}"; do
            if [[ "$src" == "$pref"* ]]; then skip=1; break; fi
        done
        [[ $skip -eq 1 ]] && continue
        # Skip absolute host paths (already covered above, but be safe)
        [[ "$src" == /* ]] && continue

        # Resolve ./path — compose runs from /opt/agmind/docker/, so ./templates/X
        # → /opt/agmind/docker/templates/X. In repo it's templates/X relative to
        # repo root. Strip leading ./ and check existence relative to:
        #   1. repo root (templates/, monitoring/, conf.d/)
        #   2. templates/ dir (in case path is relative to compose location)
        clean="${src#./}"
        bn="$(basename "$clean")"
        found=0
        # Layer 1: exact file in repo root or templates/
        for base in "$REPO_ROOT" "${REPO_ROOT}/templates"; do
            if [[ -e "${base}/${clean}" ]]; then found=1; break; fi
        done
        # Layer 2: ${path}.template variant (config rendered at install time)
        if [[ $found -eq 0 ]]; then
            for base in "$REPO_ROOT" "${REPO_ROOT}/templates"; do
                if [[ -e "${base}/${clean}.template" ]]; then found=1; break; fi
            done
        fi
        # Layer 3: basename.template anywhere in templates/ (e.g. nginx/nginx.conf
        # → templates/nginx.conf.template, ragflow/service_conf.yaml →
        # templates/ragflow/service_conf.yaml.template)
        if [[ $found -eq 0 ]]; then
            if find "${REPO_ROOT}/templates" -name "${bn}.template" -print -quit 2>/dev/null | grep -q .; then
                found=1
            fi
        fi
        # Layer 4: glob patterns — "at least one match exists"
        if [[ $found -eq 0 && "$clean" == *"*"* ]]; then
            for base in "$REPO_ROOT" "${REPO_ROOT}/templates"; do
                if compgen -G "${base}/${clean}" >/dev/null 2>&1; then found=1; break; fi
            done
        fi

        if [[ $found -eq 0 ]]; then
            echo "  FAIL: ${relpath} — service '${svc}' mounts '${src}' but source not in repo (mount FAIL at deploy §8)"
            file_violations=$((file_violations+1))
        fi
    done <<< "$mounts"

    if [[ $file_violations -eq 0 ]]; then
        echo "  PASS: ${relpath} — all bind-mount sources exist in repo"
        pass=$((pass+1))
    else
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
