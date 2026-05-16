#!/usr/bin/env bash
# ============================================================================
# scripts/gsd/verify/HEALTH-01.sh
# Verify HEALTH-01 fix applied correctly.
# Spec: §3.1 HEALTH-01.
# ============================================================================
set -Eeuo pipefail
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT"

echo "→ Regression test (mock docker)..." >&2
if ! ./tests/unit/test_health_check_container.sh; then
    echo "  ✗ test_health_check_container.sh failed" >&2
    exit 1
fi
echo "  ✓ test_health_check_container.sh passed" >&2

echo "→ Shellcheck lib/scripts health.sh..." >&2
if ! shellcheck -S warning lib/health.sh scripts/health.sh; then
    echo "  ✗ shellcheck failed" >&2
    exit 1
fi
echo "  ✓ shellcheck clean" >&2

echo "→ Byte-identical between lib/ and scripts/ health.sh..." >&2
if ! diff -q lib/health.sh scripts/health.sh >/dev/null; then
    echo "  ✗ lib/health.sh and scripts/health.sh diverged" >&2
    exit 1
fi
echo "  ✓ byte-identical" >&2

echo "→ Repo-wide gate: no stale 'up|healthy' or 'up|starting' patterns..." >&2
# Excludes docs/findings (registry can reference) and tests/fixtures.
if grep -rE 'grep -qi "up\\\|healthy"' lib/ scripts/ \
    --exclude-dir=fixtures 2>/dev/null \
    | grep -v 'docs/findings/' \
    | grep -v 'tests/fixtures/' ; then
    echo "  ✗ stale 'up|healthy' pattern present" >&2
    exit 1
fi
if grep -rE 'grep -qi "up\\\|starting"' lib/ scripts/ \
    --exclude-dir=fixtures 2>/dev/null \
    | grep -v 'docs/findings/' \
    | grep -v 'tests/fixtures/' ; then
    echo "  ✗ stale 'up|starting' pattern present" >&2
    exit 1
fi
echo "  ✓ no stale grep patterns" >&2

echo "✓ HEALTH-01 verification PASSED" >&2
exit 0
