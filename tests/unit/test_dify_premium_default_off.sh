#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_dify_premium_default_off.sh
#
# Regression test for LIC-DIFY-01.
# Spec: docs/AGmind-Autofix-Architecture-Spec-v1.0.2.md §3.1 LIC-DIFY-01
#
# Asserts that the archive default for ENABLE_DIFY_PREMIUM is `false`, not
# `true`. Three sites must agree:
#   - lib/wizard.sh line ~90
#   - lib/wizard.sh line ~1801
#   - lib/config.sh line ~510
#
# Why: ENABLE_DIFY_PREMIUM=true causes install.sh to run
# scripts/patch_dify_features.sh unattended. Until the patch content is
# classified by legal/policy review (Track-C, LIC-DIFY-01 Step 2), the
# default must require explicit opt-in.
# ============================================================================
set -Eeuo pipefail

# Resolve repo root from test location
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"

passed=0
failed=0

_pass() { echo "  ✓ $*"; passed=$((passed + 1)); }
_fail() { echo "  ✗ $*"; failed=$((failed + 1)); }

# ---------------------------------------------------------------------------
# 1. Static check: each target site has :-false (not :-true)
#    FOUR sites total: lib/wizard.sh ×3 (lines ~90, ~1801, ~1854), lib/config.sh ×1
# ---------------------------------------------------------------------------
echo "Test 1: All four sites use ':-false' default..."

declare -a SITES=(
    "lib/wizard.sh|ENABLE_DIFY_PREMIUM=\"\${ENABLE_DIFY_PREMIUM:-false}\""
    "lib/wizard.sh|[[ \"\${ENABLE_DIFY_PREMIUM:-false}\" == \"true\" ]]"
    "lib/config.sh|escape_sed \"\${ENABLE_DIFY_PREMIUM:-false}\""
)
for spec in "${SITES[@]}"; do
    IFS='|' read -r file pattern <<< "$spec"
    if grep -qF "$pattern" "${REPO_ROOT}/${file}"; then
        _pass "${file}: contains '${pattern}'"
    else
        _fail "${file}: missing expected '${pattern}'"
    fi
done

# Three occurrences of the `${VAR:-false}` form across all `:-false` patterns in wizard.sh
# (two assignment-form lines 90/1801, one [[ ]]-form line 1854)
wizard_count="$( { grep -oF '${ENABLE_DIFY_PREMIUM:-false}' "${REPO_ROOT}/lib/wizard.sh" || true; } | wc -l | tr -d ' ' )"
if [[ "$wizard_count" -ge 3 ]]; then
    _pass "lib/wizard.sh: ${wizard_count} occurrences of ':-false' (≥3 expected — assignment ×2 + [[ ]] ×1)"
else
    _fail "lib/wizard.sh: only ${wizard_count} occurrences of ':-false' (≥3 expected)"
fi

# ---------------------------------------------------------------------------
# 2. Negative check: no stale ':-true' default in production code
#    Use a while-loop, not a piped wc -l: pipelines under `set -o pipefail`
#    fail the parent shell when grep finds nothing (exit 1). Loop is safer.
# ---------------------------------------------------------------------------
echo "Test 2: Negative — no ':-true' default in production code..."

stale_count=0
stale_lines=""
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == *"docs/findings/"* ]] && continue
    [[ "$line" == *"tests/fixtures/"* ]] && continue
    [[ "$line" == *"scripts/gsd/"* ]] && continue
    [[ "$line" == *"tests/unit/test_dify_premium_default_off.sh"* ]] && continue
    stale_count=$((stale_count + 1))
    stale_lines+="      ${line}"$'\n'
done < <(grep -rnE 'ENABLE_DIFY_PREMIUM:-true' "${REPO_ROOT}" \
            --exclude-dir=.git --exclude-dir=.gsd --exclude-dir=gsd 2>/dev/null || true)

if [[ "$stale_count" -eq 0 ]]; then
    _pass "No stale ':-true' references in production code"
else
    _fail "${stale_count} stale ':-true' reference(s) found:"
    printf '%s' "$stale_lines"
fi

# ---------------------------------------------------------------------------
# 3. Functional check: sourcing wizard.sh with no env override yields false
# ---------------------------------------------------------------------------
echo "Test 3: Functional — default with no env override..."

# Run in subshell with unset to ensure no inherited value pollutes the result.
default_value="$(
    unset ENABLE_DIFY_PREMIUM
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/wizard.sh" 2>/dev/null || true
    printf '%s' "${ENABLE_DIFY_PREMIUM:-UNSET}"
)"
case "$default_value" in
    false|UNSET)
        _pass "Default resolves to '${default_value}' (acceptable: false or unset)"
        ;;
    true)
        _fail "Default resolves to 'true' — LIC-DIFY-01 regression"
        ;;
    *)
        _fail "Default resolves to unexpected value: '${default_value}'"
        ;;
esac

# ---------------------------------------------------------------------------
# 4. install.sh check: _apply_dify_patches still respects the env
# ---------------------------------------------------------------------------
echo "Test 4: install.sh _apply_dify_patches guard remains intact..."

# This check confirms install.sh:425 still has its own ':-false' guard, so
# even if some future code-path injects ENABLE_DIFY_PREMIUM=true without
# wizard validation, _apply_dify_patches still requires explicit truthy value.
if grep -qE 'ENABLE_DIFY_PREMIUM:-false.*==.*"true"' "${REPO_ROOT}/install.sh"; then
    _pass "install.sh: secondary guard intact"
else
    _fail "install.sh: secondary guard missing/changed — may need re-review"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${passed} passed, ${failed} failed"
echo "═══════════════════════════════════════════════════════════"

[[ $failed -eq 0 ]]
