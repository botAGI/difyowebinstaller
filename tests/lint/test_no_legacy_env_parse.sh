#!/usr/bin/env bash
# ============================================================================
# tests/lint/test_no_legacy_env_parse.sh
# ENV-05: forbid NEW `grep '^X=' | cut -d=` patterns in lib/* + scripts/* +
# install.sh. Existing callsites grandfathered until Phase 14 ENV-03b/03c
# migration. Baseline captured 2026-05-16 at HEAD; Phase 14 ratchets these
# down as callsites migrate.
#
# Detection:
#   FAIL  — baseline file's count > baseline (new legacy callsite added)
#   FAIL  — new file outside baseline introduces the pattern
#   INFO  — baseline file's count < baseline (Phase 14 ratchet candidate, NOT a CI failure)
#   PASS  — every baseline file's count == baseline AND no new files outside baseline
#
# Exit: 0 = pass, !=0 = fail count.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to ${REPO_ROOT}"; exit 1; }

# Per-file maximum allowed legacy `grep ^X=...cut -d=` callsites.
# Captured 2026-05-16 at HEAD (Phase 10 baseline = HEAD of v3.1.2 + Phase 10 changes).
# Phase 14 (ENV-03b canary + ENV-03c bulk) will ratchet these numbers DOWN
# as callsites migrate to _env_get / _env_get_raw from lib/common.sh.
declare -A BASELINE=(
    [lib/health.sh]=2
    [scripts/health.sh]=2
    [install.sh]=9
    [lib/config.sh]=9
    [scripts/agmind.sh]=7
    [lib/compose.sh]=1
    [scripts/backup.sh]=5
    [scripts/update.sh]=4
    [scripts/rotate_secrets.sh]=3
    [lib/authelia.sh]=1
    [lib/common.sh]=0
    [lib/openwebui.sh]=1
    [lib/restore.sh]=0
    [scripts/dr-drill.sh]=1
    [scripts/uninstall.sh]=1
    [scripts/import-dify-workflow.sh]=1
)

# Regex matches `grep '^KEY=...'  ... cut -d` (the legacy parse pattern).
# Word boundary `[[:space:]]+` after grep/cut to skip false positives like
# `grepm` or `gcut`. `.` after grep matches the opening quote.
PATTERN='grep[[:space:]]+.\^[A-Z_][A-Z0-9_]*=.*cut[[:space:]]+-d'

fail=0
ratchet_hits=0
echo "## test_no_legacy_env_parse"
echo ""

# ---- Check baseline files against expected counts -------------------------
for file in "${!BASELINE[@]}"; do
    expected="${BASELINE[$file]}"
    if [[ ! -f "$file" ]]; then
        echo "  [FAIL] baseline file missing: $file (expected count=$expected)"
        fail=$((fail+1)); continue
    fi
    actual=$(grep -cE "$PATTERN" "$file" 2>/dev/null || true)
    [[ -z "$actual" ]] && actual=0
    if [[ "$actual" -gt "$expected" ]]; then
        echo "  [FAIL] $file: $actual legacy callsite(s), baseline=$expected (+$((actual-expected)))"
        echo "         New code MUST use _env_get / _env_get_raw from lib/common.sh"
        fail=$((fail+1))
    elif [[ "$actual" -lt "$expected" ]]; then
        echo "  [INFO] $file: $actual ≤ baseline $expected (ratchet candidate, OK — Phase 14 will lower baseline)"
        ratchet_hits=$((ratchet_hits+1))
    fi
done

# ---- Detect NEW files outside baseline introducing the pattern ------------
scanned_files=()
while IFS= read -r f; do
    scanned_files+=("$f")
done < <(find lib scripts -type f -name "*.sh" 2>/dev/null; echo install.sh)

for file in "${scanned_files[@]}"; do
    [[ -f "$file" ]] || continue
    [[ -n "${BASELINE[$file]:-}" ]] && continue
    actual=$(grep -cE "$PATTERN" "$file" 2>/dev/null || true)
    [[ -z "$actual" ]] && actual=0
    if [[ "$actual" -gt 0 ]]; then
        echo "  [FAIL] $file: $actual callsite(s) — new file with legacy pattern"
        echo "         Either use _env_get / _env_get_raw, or add to BASELINE if grandfathered"
        fail=$((fail+1))
    fi
done

echo ""
if [[ $fail -eq 0 ]]; then
    if [[ $ratchet_hits -gt 0 ]]; then
        echo "  [PASS] no new legacy env-parse callsites ($ratchet_hits ratchet candidate(s) for Phase 14)"
    else
        echo "  [PASS] no new legacy env-parse callsites; baseline matches HEAD exactly"
    fi
fi
exit $fail
