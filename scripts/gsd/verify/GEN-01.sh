#!/usr/bin/env bash
# ============================================================================
# scripts/gsd/verify/GEN-01.sh
# Verify GEN-01 fix is applied correctly.
# Spec: §3.1 GEN-01.
# ============================================================================
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT"

echo "→ Running regression test..." >&2
if ! ./tests/unit/test_generate_random_length.sh; then
    echo "  ✗ test_generate_random_length.sh failed" >&2
    exit 1
fi
echo "  ✓ test_generate_random_length.sh passed" >&2

echo "→ Shellcheck on lib/common.sh..." >&2
if ! shellcheck -S warning lib/common.sh; then
    echo "  ✗ shellcheck failed" >&2
    exit 1
fi
echo "  ✓ lib/common.sh clean" >&2

echo "→ Repo-wide gate: old broken pipeline pattern gone..." >&2
if grep -rE 'head -c 256 /dev/urandom \| LC_ALL=C tr' lib/ install.sh 2>/dev/null; then
    echo "  ✗ Stale broken pattern still present" >&2
    exit 1
fi
echo "  ✓ No stale broken pipeline" >&2

echo "→ Single definition of generate_random in lib/common.sh..." >&2
defs="$(grep -cE '^generate_random\(\) \{' lib/common.sh)"
if [[ "$defs" -ne 1 ]]; then
    echo "  ✗ generate_random defined ${defs} times (expected 1)" >&2
    exit 1
fi
echo "  ✓ exactly 1 definition" >&2

echo "✓ GEN-01 verification PASSED" >&2
exit 0
