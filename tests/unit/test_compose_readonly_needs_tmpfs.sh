#!/usr/bin/env bash
# test_compose_readonly_needs_tmpfs.sh — Every service with `read_only: true`
# in templates/docker-compose.yml MUST have at least one writable mount
# declared — either `tmpfs:` (in-memory) OR `volumes:` (anonymous or named,
# Docker copy-up brings image-shipped content into the mount on first start).
#
# Precedent 2026-05-15 (b86b7f1): docker-socket-proxy got `read_only: true`
# without ANY writable mount → entrypoint's haproxy.cfg write failed → restart
# loop. Added tmpfs. 2026-05-16: tmpfs *shadowed* the image-shipped
# haproxy.cfg.template → entrypoint fails differently. Fix: anonymous volume
# (copy-up keeps the template, container writes the rendered cfg next to it).
#
# This test enforces the contract going forward: if you flip read_only:true on
# a service, declare a writable mount where the entrypoint needs to write —
# `tmpfs:` for fully in-memory paths, `volumes:` for image-shipped content that
# the entrypoint reads + augments. If the image truly writes nothing, add the
# service to WHITELIST_NO_WRITABLE with a one-line rationale.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_compose_readonly_needs_tmpfs"

PASS=0; FAIL=0

# Services that legitimately need no writable paths (verified by reading image
# entrypoint). Empty today — every current read_only service has a writable mount.
# Add entries with a one-line "why" comment if a future bump truly needs nothing.
WHITELIST_NO_WRITABLE=()

mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    # Per-service walk: find services with read_only:true, check for tmpfs key.
    result="$(python3 - "$f" "${WHITELIST_NO_WRITABLE[@]}" <<'PY'
import sys, yaml

path = sys.argv[1]
whitelist = set(sys.argv[2:])

data = yaml.safe_load(open(path)) or {}
services = data.get('services', {}) if isinstance(data, dict) else {}

for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    if svc.get('read_only') is not True:
        continue
    has_writable = bool(svc.get('tmpfs')) or bool(svc.get('volumes'))
    if has_writable:
        print(f"OK\t{name}")
    elif name in whitelist:
        print(f"WHITELIST\t{name}")
    else:
        print(f"FAIL\t{name}")
PY
)"

    [[ -z "$result" ]] && continue

    while IFS=$'\t' read -r status svc; do
        case "$status" in
            OK)
                echo "  [PASS] ${svc} (in ${relpath}): read_only:true + writable mount declared (tmpfs or volumes)"
                PASS=$((PASS+1))
                ;;
            WHITELIST)
                echo "  [PASS] ${svc} (in ${relpath}): in WHITELIST_NO_WRITABLE (no writes expected)"
                PASS=$((PASS+1))
                ;;
            FAIL)
                echo "  [FAIL] ${svc} (in ${relpath}): read_only:true WITHOUT a writable mount — entrypoint writes will fail"
                echo "         Fix: declare \`tmpfs:\` for in-memory paths, OR \`volumes:\` for image-shipped content that the entrypoint reads + augments, OR add to WHITELIST_NO_WRITABLE."
                FAIL=$((FAIL+1))
                ;;
        esac
    done <<< "$result"
done

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
