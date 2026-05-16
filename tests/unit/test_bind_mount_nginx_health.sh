#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_bind_mount_nginx_health.sh
# Regression for NGINX-HEALTH-01 — `ensure_bind_mount_files` and
# `preflight_bind_mount_check` must reference `nginx/health/health.json`
# (directory-based mount), not the legacy `nginx/health.json` file path.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
set +e  # we test return codes

pass=0; fail=0

echo "## test_bind_mount_nginx_health"
echo ""

# ----------------------------------------------------------------------------
# Test 1: ensure_bind_mount_files creates `nginx/health/health.json` as a file
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INSTALL_DIR="$TMP" ensure_bind_mount_files >/dev/null 2>&1

if [[ -f "${TMP}/docker/nginx/health/health.json" ]]; then
    pass=$((pass + 1))
    echo "  [PASS] creates nginx/health/health.json as a regular file"
else
    fail=$((fail + 1))
    echo "  [FAIL] nginx/health/health.json missing or not a file"
    ls -la "${TMP}/docker/nginx/" 2>&1 | head -5
fi

# ----------------------------------------------------------------------------
# Test 2: legacy nginx/health.json path is NOT in ensure_bind_mount_files array
# ----------------------------------------------------------------------------
if grep -q '"nginx/health/health.json"' "${REPO_ROOT}/lib/common.sh"; then
    pass=$((pass + 1))
    echo "  [PASS] common.sh references nginx/health/health.json"
else
    fail=$((fail + 1))
    echo "  [FAIL] common.sh does NOT reference nginx/health/health.json"
fi

# Negative: should NOT have the bare legacy path "nginx/health.json" listed
# in either array. (Allowlisted: the # LEGACY_NGINX_HEALTH_CLEANUP_OK line in
# install.sh — only a cleanup of a stale artifact.)
legacy_hits=$(grep -nE '"nginx/health\.json"' "${REPO_ROOT}/lib/common.sh" | wc -l)
if [[ "$legacy_hits" -eq 0 ]]; then
    pass=$((pass + 1))
    echo "  [PASS] no legacy 'nginx/health.json' literal in lib/common.sh"
else
    fail=$((fail + 1))
    echo "  [FAIL] legacy 'nginx/health.json' literal still present in lib/common.sh:"
    grep -nE '"nginx/health\.json"' "${REPO_ROOT}/lib/common.sh"
fi

# ----------------------------------------------------------------------------
# Test 3: preflight_bind_mount_check declares the new path in all_bind_files
# ----------------------------------------------------------------------------
# Grep for the all_bind_files array entry — must include nginx/health/health.json
preflight_block="$(awk '/^preflight_bind_mount_check\(\) \{/,/^\}/' "${REPO_ROOT}/lib/common.sh")"
if echo "$preflight_block" | grep -q '"nginx/health/health.json"'; then
    pass=$((pass + 1))
    echo "  [PASS] preflight_bind_mount_check includes nginx/health/health.json"
else
    fail=$((fail + 1))
    echo "  [FAIL] preflight_bind_mount_check missing nginx/health/health.json"
fi

# ----------------------------------------------------------------------------
# Test 4: install.sh legacy cleanup carries allowlist marker
# ----------------------------------------------------------------------------
if grep -q 'LEGACY_NGINX_HEALTH_CLEANUP_OK' "${REPO_ROOT}/install.sh"; then
    pass=$((pass + 1))
    echo "  [PASS] install.sh legacy cleanup has allowlist marker"
else
    fail=$((fail + 1))
    echo "  [FAIL] install.sh missing # LEGACY_NGINX_HEALTH_CLEANUP_OK marker"
fi

# ----------------------------------------------------------------------------
# Test 5: repo-wide gate — no bare 'nginx/health.json' refs outside allowlist
# ----------------------------------------------------------------------------
violations=$(grep -rE 'nginx/health\.json' "${REPO_ROOT}/lib" "${REPO_ROOT}/install.sh" "${REPO_ROOT}/scripts" 2>/dev/null \
    | grep -v '# LEGACY_NGINX_HEALTH_CLEANUP_OK' \
    | grep -v 'docs/findings/' \
    | grep -v 'tests/fixtures/' \
    || true)
if [[ -z "$violations" ]]; then
    pass=$((pass + 1))
    echo "  [PASS] no stale 'nginx/health.json' references in production code"
else
    fail=$((fail + 1))
    echo "  [FAIL] stale 'nginx/health.json' refs (un-allowlisted):"
    echo "$violations" | sed 's/^/        /'
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
