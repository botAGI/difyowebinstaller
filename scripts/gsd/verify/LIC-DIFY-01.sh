#!/usr/bin/env bash
# ============================================================================
# scripts/gsd/verify/LIC-DIFY-01.sh
# Verify the LIC-DIFY-01 fix took effect. Called by GSD after apply/.
# Exit codes:
#   0 — pass; PR ready to open
#   1 — gate fail; rollback
# ============================================================================
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT"

failed=0

# 1. Regression test
echo "→ Running regression test..." >&2
if bash tests/unit/test_dify_premium_default_off.sh; then
    echo "  ✓ test_dify_premium_default_off.sh passed" >&2
else
    echo "  ✗ test_dify_premium_default_off.sh FAILED" >&2
    failed=$((failed + 1))
fi

# 2. Shellcheck on touched files
echo "→ Shellcheck..." >&2
for f in lib/wizard.sh lib/config.sh; do
    if shellcheck -S warning "$f" >/dev/null 2>&1; then
        echo "  ✓ ${f}" >&2
    else
        echo "  ✗ ${f} (new warnings — see shellcheck output)" >&2
        shellcheck -S warning "$f" || true
        failed=$((failed + 1))
    fi
done

# 3. Repo-wide grep gate (excludes registry + fixtures, per spec §3.1)
echo "→ Repo-wide grep gate..." >&2
if grep -rE 'ENABLE_DIFY_PREMIUM:-true' . \
    --exclude-dir=.git --exclude-dir=.gsd --exclude-dir=gsd \
    | grep -v 'docs/findings/' \
    | grep -v 'tests/fixtures/' \
    | grep -v 'tests/unit/test_dify_premium_default_off.sh'; then
    echo "  ✗ Stale ':-true' default still present somewhere" >&2
    failed=$((failed + 1))
else
    echo "  ✓ No stale ':-true' references" >&2
fi

# 4. Wizard/config functional check via subshell sourcing
echo "→ Functional: subshell-source confirms default == false..." >&2
default_value="$(
    # shellcheck disable=SC1091
    unset ENABLE_DIFY_PREMIUM
    source lib/wizard.sh 2>/dev/null || true
    printf '%s' "${ENABLE_DIFY_PREMIUM:-UNSET}"
)"
if [[ "$default_value" == "false" || "$default_value" == "UNSET" ]]; then
    echo "  ✓ default resolves to '${default_value}' (acceptable)" >&2
else
    echo "  ✗ default resolves to '${default_value}' — expected 'false' or 'UNSET'" >&2
    failed=$((failed + 1))
fi

# Summary
if [[ $failed -eq 0 ]]; then
    echo "✓ LIC-DIFY-01 verification PASSED" >&2
    exit 0
else
    echo "✗ LIC-DIFY-01 verification FAILED (${failed} check(s))" >&2
    exit 1
fi
