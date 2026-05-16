#!/usr/bin/env bash
# ============================================================================
# scripts/gsd/apply/LIC-DIFY-01.sh
# Apply the LIC-DIFY-01 Step 1 fix: flip ENABLE_DIFY_PREMIUM default to false.
# Spec: docs/AGmind-Autofix-Architecture-Spec-v1.0.2.md §3.1 LIC-DIFY-01
# Track: A (mechanical, default flip in four sites)
#
# Exit codes:
#   0  — fix applied; ready for verify step
#   1  — pre-condition not met (default already false, or pattern absent)
#   2  — apply failed; repo is in a partially-modified state, see audit log
# ============================================================================
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
AUDIT_LOG="${AUDIT_LOG:-${REPO_ROOT}/.gsd/audit.jsonl}"
mkdir -p "$(dirname "$AUDIT_LOG")"

_audit() {
    local action="$1"; shift
    printf '{"ts":"%s","finding":"LIC-DIFY-01","action":"%s",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action" "$*" >> "$AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# Target sites (verified in archive 2026-05-16; FOUR sites — fourth was
# caught by post-condition gate during initial dry-run, see spec v1.0.2)
# ---------------------------------------------------------------------------
declare -a SITES=(
    "lib/wizard.sh|90|ENABLE_DIFY_PREMIUM=\"\${ENABLE_DIFY_PREMIUM:-true}\""
    "lib/wizard.sh|1801|ENABLE_DIFY_PREMIUM=\"\${ENABLE_DIFY_PREMIUM:-true}\""
    "lib/wizard.sh|1854|[[ \"\${ENABLE_DIFY_PREMIUM:-true}\" == \"true\" ]]"
    "lib/config.sh|510|escape_sed \"\${ENABLE_DIFY_PREMIUM:-true}\""
)

# ---------------------------------------------------------------------------
# 1. PRE-CONDITION: confirm all four patterns are present
# ---------------------------------------------------------------------------
echo "→ Pre-condition: checking pattern presence..." >&2
missing=0
for site in "${SITES[@]}"; do
    IFS='|' read -r file line expected <<< "$site"
    if ! grep -nF "$expected" "${REPO_ROOT}/${file}" >/dev/null; then
        echo "  ✗ ${file}: expected pattern not found" >&2
        echo "    expected: ${expected}" >&2
        missing=$((missing + 1))
    fi
done
if [[ $missing -gt 0 ]]; then
    _audit "precondition_fail" "\"missing_sites\":${missing}"
    echo "FAIL: ${missing}/${#SITES[@]} site(s) missing expected pattern." >&2
    echo "Run \`git log --oneline -- lib/wizard.sh lib/config.sh\` to check prior fixes." >&2
    exit 1
fi
_audit "precondition_ok" "\"sites_total\":${#SITES[@]}"

# ---------------------------------------------------------------------------
# 2. APPLY: flip default true → false (sed-in-place; backup files for rollback)
# ---------------------------------------------------------------------------
echo "→ Applying patches..." >&2
declare -a BACKUPS=()

_rollback_from_backups() {
    local reason="${1:-unspecified}"
    echo "✗ Rollback (${reason}). Restoring backups..." >&2
    for b in "${BACKUPS[@]}"; do
        if [[ -f "$b" ]]; then
            mv "$b" "${b%.gsd-bak}"
            echo "  restored: ${b%.gsd-bak}" >&2
        fi
    done
    _audit "rollback" "\"reason\":\"${reason}\",\"backups_restored\":${#BACKUPS[@]}"
}

trap '_rollback_from_backups apply_error; exit 2' ERR

# Sites 1, 2, 3: lib/wizard.sh — three occurrences of the `:-true` pattern
# (lines ~90, ~1801 use the `="${VAR:-true}"` form; line ~1854 uses `${VAR:-true}` inside [[ ]]).
# Single substitution covers all three because the inner `${ENABLE_DIFY_PREMIUM:-true}` is identical.
wizard_file="${REPO_ROOT}/lib/wizard.sh"
cp "$wizard_file" "${wizard_file}.gsd-bak"
BACKUPS+=("${wizard_file}.gsd-bak")
perl -i -pe 's{\$\{ENABLE_DIFY_PREMIUM:-true\}}{\$\{ENABLE_DIFY_PREMIUM:-false\}}g' \
    "$wizard_file"

# Site 4: lib/config.sh
config_file="${REPO_ROOT}/lib/config.sh"
cp "$config_file" "${config_file}.gsd-bak"
BACKUPS+=("${config_file}.gsd-bak")
perl -i -pe 's{\$\{ENABLE_DIFY_PREMIUM:-true\}}{\$\{ENABLE_DIFY_PREMIUM:-false\}}g' \
    "$config_file"

trap - ERR
_audit "apply_ok" "\"files_changed\":2,\"sites_changed\":4"

# ---------------------------------------------------------------------------
# 3. POST-CONDITION: confirm four sites flipped, zero `:-true` left
# Important: BACKUPS are still on disk until this whole block passes. If any
# gate fails here, rollback unwinds the apply.
# ---------------------------------------------------------------------------
echo "→ Post-condition: verifying flip..." >&2

# Each target now has :-false at exact pattern
for site in "${SITES[@]}"; do
    IFS='|' read -r file line expected <<< "$site"
    new_expected="${expected//-true\}/-false\}}"
    if ! grep -nF "$new_expected" "${REPO_ROOT}/${file}" >/dev/null; then
        echo "  ✗ ${file}: post-condition NOT met (expected: ${new_expected})" >&2
        _audit "postcondition_fail" "\"file\":\"${file}\""
        _rollback_from_backups postcondition_fail
        exit 2
    fi
done

# Repo-wide gate: no `ENABLE_DIFY_PREMIUM:-true` left in production code
# (Excludes docs/findings/ — registry references old pattern; excludes
# tests/fixtures/ — fixtures may model legacy state; excludes scripts/gsd/ and
# this regression test because they intentionally contain the old pattern.)
if grep -rE 'ENABLE_DIFY_PREMIUM:-true' "${REPO_ROOT}" \
    --exclude-dir=.git --exclude-dir=.gsd --exclude-dir=gsd \
    | grep -v 'docs/findings/' \
    | grep -v 'tests/fixtures/' \
    | grep -v 'tests/unit/test_dify_premium_default_off.sh' \
    | grep -v '\.gsd-bak'; then
    echo "  ✗ Repo-wide gate: stale ':-true' default still present" >&2
    _audit "gate_fail" "\"gate\":\"repo_grep\""
    _rollback_from_backups gate_fail
    exit 2
fi

# All gates passed — clean up backups; git is rollback mechanism from here.
for b in "${BACKUPS[@]}"; do rm -f "$b"; done
_audit "postcondition_ok" "\"files_changed\":2,\"sites_changed\":4"

echo "✓ LIC-DIFY-01 applied: ENABLE_DIFY_PREMIUM default flipped to false at 4 sites." >&2
echo "  Next: scripts/gsd/verify/LIC-DIFY-01.sh" >&2
exit 0
