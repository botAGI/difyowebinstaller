#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_ragflow_url_alias.sh
# Regression for RAGFLOW-URL-01 — `agmind status` must report
# `http://agmind-rag.local` (the name nginx vhost actually serves and
# avahi-mdns-publish actually advertises), not the stale `agmind-ragflow.local`.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

pass=0; fail=0

echo "## test_ragflow_url_alias"
echo ""

# Test 1: lib/status.sh references the correct hostname
if grep -q 'http://agmind-rag\.local' "${REPO_ROOT}/lib/status.sh"; then
    pass=$((pass + 1))
    echo "  [PASS] lib/status.sh references agmind-rag.local"
else
    fail=$((fail + 1))
    echo "  [FAIL] lib/status.sh missing agmind-rag.local reference"
fi

# Test 2: no stale agmind-ragflow.local in lib/status.sh
if grep -q 'agmind-ragflow\.local' "${REPO_ROOT}/lib/status.sh"; then
    fail=$((fail + 1))
    echo "  [FAIL] lib/status.sh still references stale agmind-ragflow.local:"
    grep -n 'agmind-ragflow\.local' "${REPO_ROOT}/lib/status.sh" | sed 's/^/        /'
else
    pass=$((pass + 1))
    echo "  [PASS] no stale agmind-ragflow.local in lib/status.sh"
fi

# Test 3: nginx template + status.sh agree on the name. The nginx template
# uses marker-comment form (`#__RAGFLOW__ server_name agmind-rag.local;`)
# that lib/config.sh::generate_nginx_config uncomments via sed; matching
# either form works for this static check.
if grep -qE 'server_name agmind-rag\.local' "${REPO_ROOT}/templates/nginx.conf.template"; then
    pass=$((pass + 1))
    echo "  [PASS] nginx vhost serves agmind-rag.local"
else
    fail=$((fail + 1))
    echo "  [FAIL] nginx vhost for agmind-rag.local not found"
fi

# Test 4: repo-wide gate — no stale refs in lib/scripts (allowlist docs+fixtures)
violations=$(grep -rE 'agmind-ragflow\.local' "${REPO_ROOT}/lib" "${REPO_ROOT}/scripts" "${REPO_ROOT}/templates" 2>/dev/null \
    | grep -v 'docs/findings/' \
    | grep -v 'tests/fixtures/' \
    || true)
if [[ -z "$violations" ]]; then
    pass=$((pass + 1))
    echo "  [PASS] no stale agmind-ragflow.local in production code"
else
    fail=$((fail + 1))
    echo "  [FAIL] stale refs:"
    echo "$violations" | sed 's/^/        /'
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
