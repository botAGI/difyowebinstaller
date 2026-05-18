#!/usr/bin/env bash
# tests/lint/test_phase15_artifacts_present.sh — GO-01..GO-06 CI gate (Phase 15).
#
# Asserts every Phase 15 deliverable exists with required content:
#   1. cmd/agmind/.gitkeep + ROADMAP-GO.md ref + ADR-0010 ref + "No Go code" (GO-01)
#   2. internal/.gitkeep + ROADMAP-GO.md ref + ADR-0010 ref + "No Go code" (GO-02)
#   3. docs/ROADMAP-GO.md + Stage 0.5/0.7/1/6 + runtime.GOARCH + zero-Go disclaimer (GO-03)
#   4. docs/adr/0010-go-migration-staged-port.md + MADR-lite sections + key tokens (GO-04)
#   5. docs/adr/0013-go-single-binary-internal-packages.md + MADR-lite + Q-07 token (GO-05)
#   6. README.md disclaimer (EN + RU parity, both link to ROADMAP-GO.md + ADR-0010) (GO-06)
#   7. docs/adr/INDEX.md with exactly 13 ADR rows incl. 0010 and 0013
#   8. docs/adr/README.md redirects to INDEX.md and preserves MADR-lite spec
#
# Exit: 0 = pass, 1 = fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_phase15_artifacts_present"

pass=0
fail=0

_ok()   { echo "  ok: $*";   pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# Helper: file exists
_check_file() {
    local path="$1"
    if [[ -f "${REPO_ROOT}/${path}" ]]; then
        _ok "exists: ${path}"
    else
        _fail "missing: ${path}"
    fi
}

# Helper: grep fixed-string token in file
_check_grep() {
    local path="$1"
    local pattern="$2"
    local desc="${3:-${pattern}}"
    if [[ -f "${REPO_ROOT}/${path}" ]] && grep -qF "${pattern}" "${REPO_ROOT}/${path}" 2>/dev/null; then
        _ok "${path}: ${desc}"
    else
        _fail "${path}: missing token: ${desc}"
    fi
}

# Helper: grep extended-regex pattern in file
_check_grep_e() {
    local path="$1"
    local pattern="$2"
    local desc="${3:-${pattern}}"
    if [[ -f "${REPO_ROOT}/${path}" ]] && grep -qE "${pattern}" "${REPO_ROOT}/${path}" 2>/dev/null; then
        _ok "${path}: ${desc}"
    else
        _fail "${path}: missing pattern: ${desc}"
    fi
}

# ── 1. GO-01 cmd/agmind/.gitkeep ──────────────────────────────────────────────
_check_file "cmd/agmind/.gitkeep"
_check_grep "cmd/agmind/.gitkeep" "ROADMAP-GO.md"
_check_grep "cmd/agmind/.gitkeep" "No Go code in v3.2.0"
_check_grep "cmd/agmind/.gitkeep" "0010"

# ── 2. GO-02 internal/.gitkeep ────────────────────────────────────────────────
_check_file "internal/.gitkeep"
_check_grep "internal/.gitkeep" "ROADMAP-GO.md"
_check_grep "internal/.gitkeep" "No Go code in v3.2.0"
_check_grep "internal/.gitkeep" "0010"

# ── 3. GO-03 docs/ROADMAP-GO.md ───────────────────────────────────────────────
_check_file "docs/ROADMAP-GO.md"
_check_grep_e "docs/ROADMAP-GO.md" "^# Go Migration Roadmap" "title"
for token in "Stage 0.5" "Stage 0.7" "Stage 1" "Stage 6" \
             "runtime.GOARCH" "CGO_ENABLED=0"; do
    _check_grep "docs/ROADMAP-GO.md" "${token}"
done
# Zero-Go disclaimer (appears in Anti-Recommendations section)
_check_grep "docs/ROADMAP-GO.md" "no Go code in v3.2.0" "zero-Go disclaimer"
# Stack pin coverage
for pin in "cobra" "yaml.v3" "compose-go" "goldie" "jsonschema"; do
    _check_grep "docs/ROADMAP-GO.md" "${pin}" "stack pin: ${pin}"
done
# Cross-references to ADR files
_check_grep "docs/ROADMAP-GO.md" "0010-go-migration-staged-port.md"
_check_grep "docs/ROADMAP-GO.md" "0013-go-single-binary-internal-packages.md"
# Anti-recommendations / scope-creep wall
_check_grep "docs/ROADMAP-GO.md" "Anti-Recommendations" "Anti-Recommendations section"
# Pitfall 10 cited
_check_grep_e "docs/ROADMAP-GO.md" "Pitfall [[:space:]]?10" "Pitfall 10 cited"

# ── 4. GO-04 ADR-0010 ─────────────────────────────────────────────────────────
ADR10="docs/adr/0010-go-migration-staged-port.md"
_check_file "${ADR10}"
_check_grep_e "${ADR10}" "^# 0010\." "title format"
_check_grep_e "${ADR10}" "^\*\*Status:\*\* Accepted" "Status: Accepted"
for section in \
    "^## Context and Problem Statement" \
    "^## Decision Outcome" \
    "^## Consequences" \
    "^## References"; do
    _check_grep_e "${ADR10}" "${section}" "MADR-lite section: ${section}"
done
for token in "equivalence" "arm64" "Stage" "ROADMAP-GO.md" "goldie" \
             "runtime.GOARCH" "0001-arm64-only.md"; do
    _check_grep "${ADR10}" "${token}"
done

# ── 5. GO-05 ADR-0013 ─────────────────────────────────────────────────────────
ADR13="docs/adr/0013-go-single-binary-internal-packages.md"
_check_file "${ADR13}"
_check_grep_e "${ADR13}" "^# 0013\." "title format"
_check_grep_e "${ADR13}" "^\*\*Status:\*\* Accepted" "Status: Accepted"
for section in \
    "^## Context and Problem Statement" \
    "^## Decision Outcome" \
    "^## Consequences" \
    "^## References"; do
    _check_grep_e "${ADR13}" "${section}" "MADR-lite section: ${section}"
done
for token in "Q-07" "cmd/agmind" "internal/" \
             "0010-go-migration-staged-port.md" "ROADMAP-GO.md"; do
    _check_grep "${ADR13}" "${token}"
done

# ── 6. GO-06 README.md disclaimer (EN + RU parity) ───────────────────────────
_check_grep "README.md" "no Go code in v3.2.0" "EN disclaimer phrase"
_check_grep "README.md" "в v3.2.0 Go кода нет" "RU disclaimer phrase"
# Both sections must link to ROADMAP-GO.md and ADR-0010 (>= 2 refs each for EN+RU parity)
roadmap_refs=$(grep -c 'docs/ROADMAP-GO.md' "${REPO_ROOT}/README.md" 2>/dev/null || echo 0)
if [[ "${roadmap_refs}" -ge 2 ]]; then
    _ok "README.md: docs/ROADMAP-GO.md referenced >= 2 times (EN + RU parity)"
else
    _fail "README.md: docs/ROADMAP-GO.md referenced only ${roadmap_refs} times (expect >= 2 for EN + RU parity)"
fi
adr10_refs=$(grep -c 'docs/adr/0010-go-migration-staged-port.md' "${REPO_ROOT}/README.md" 2>/dev/null || echo 0)
if [[ "${adr10_refs}" -ge 2 ]]; then
    _ok "README.md: ADR-0010 referenced >= 2 times (EN + RU parity)"
else
    _fail "README.md: ADR-0010 referenced only ${adr10_refs} times (expect >= 2)"
fi

# ── 7. docs/adr/INDEX.md — 13 ADR rows ───────────────────────────────────────
INDEX="docs/adr/INDEX.md"
_check_file "${INDEX}"
row_count=$(grep -c '^| \[0' "${REPO_ROOT}/${INDEX}" 2>/dev/null || echo 0)
if [[ "${row_count}" -eq 13 ]]; then
    _ok "${INDEX}: exactly 13 ADR rows"
else
    _fail "${INDEX}: expected 13 ADR rows, found ${row_count}"
fi
# Spot-check critical ADRs present in the index
for adr_num in "0001" "0010" "0011" "0012" "0013"; do
    _check_grep "${INDEX}" "[${adr_num}]" "row for ADR-${adr_num}"
done

# ── 8. docs/adr/README.md redirects to INDEX.md ──────────────────────────────
_check_grep "docs/adr/README.md" "INDEX.md" "redirect to INDEX.md"
_check_grep "docs/adr/README.md" "MADR-lite" "format spec preserved"

echo ""
echo "## test_phase15_artifacts_present: PASS=${pass} FAIL=${fail}"
[[ "${fail}" -eq 0 ]] && exit 0 || exit 1
