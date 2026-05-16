#!/usr/bin/env bash
# test_compose_readonly_needs_tmpfs.sh — Every service with `read_only: true`
# in templates/docker-compose.yml MUST have a `tmpfs:` block (or be in the
# documented WHITELIST_NO_TMPFS for services that genuinely write nothing).
#
# Precedent (2026-05-15, bug-report 3 phase-7/8 cascades):
#   docker-socket-proxy had `read_only: true` but no tmpfs → its entrypoint
#   tried to write a generated haproxy.cfg to /usr/local/etc/haproxy/
#   → `can't create haproxy.cfg: Read-only file system` → restart loop →
#   blocked monitoring profile. Fix: add tmpfs:/usr/local/etc/haproxy.
#
# This test enforces the contract going forward: if you bump an image whose
# entrypoint writes to ANY path, you must either (a) declare a tmpfs for that
# path, (b) add the service to WHITELIST_NO_TMPFS with a one-line rationale,
# or (c) remove read_only:true (degrades SC1 hardening — last resort).
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
# entrypoint). Empty today — every current read_only service has tmpfs. Add
# entries with a one-line "why" comment if a future bump truly needs nothing.
WHITELIST_NO_TMPFS=()

mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    # Per-service walk: find services with read_only:true, check for tmpfs key.
    result="$(python3 - "$f" "${WHITELIST_NO_TMPFS[@]}" <<'PY'
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
    has_tmpfs = 'tmpfs' in svc and svc['tmpfs']
    if has_tmpfs:
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
                echo "  [PASS] ${svc} (in ${relpath}): read_only:true + tmpfs declared"
                PASS=$((PASS+1))
                ;;
            WHITELIST)
                echo "  [PASS] ${svc} (in ${relpath}): in WHITELIST_NO_TMPFS (no writes expected)"
                PASS=$((PASS+1))
                ;;
            FAIL)
                echo "  [FAIL] ${svc} (in ${relpath}): read_only:true WITHOUT tmpfs — entrypoint writes will fail"
                echo "         Fix: declare \`tmpfs:\` for the writable path(s), OR add to WHITELIST_NO_TMPFS."
                FAIL=$((FAIL+1))
                ;;
        esac
    done <<< "$result"
done

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
