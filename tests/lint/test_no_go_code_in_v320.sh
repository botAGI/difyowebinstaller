#!/usr/bin/env bash
# tests/lint/test_no_go_code_in_v320.sh — zero-Go-in-v3.2.0 safety net (permanent CI gate).
#
# Asserts that no Go source artifacts exist in the repository tree:
#   1. No .go files anywhere (excluding .git/, node_modules/, vendor/)
#   2. No go.mod at repo root or up to depth 3
#   3. No go.sum at repo root or up to depth 3
#   4. No go.work at repo root or up to depth 3
#
# This gate is PERMANENT — it persists in CI until the v4.0 milestone formally
# allows Go code (per docs/adr/0010-go-migration-staged-port.md). Until then any
# .go/.mod/.sum/.work file accidentally landing in develop or main fails the build.
#
# Exit: 0 = no Go code (pass), 1 = Go code found (fail).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_no_go_code_in_v320"

fail=0

# Check 1: No .go files anywhere (exclude vendor caches and .git/)
go_files=$(find "${REPO_ROOT}" -type f -name '*.go' \
    -not -path "${REPO_ROOT}/.git/*" \
    -not -path "${REPO_ROOT}/node_modules/*" \
    -not -path "${REPO_ROOT}/vendor/*" \
    2>/dev/null)
if [[ -z "${go_files}" ]]; then
    echo "  ok: no .go files found"
else
    echo "  FAIL: .go files found (zero-Go-in-v3.2.0 policy violated — see docs/adr/0010-go-migration-staged-port.md):"
    echo "${go_files}" | sed 's/^/    /'
    fail=$((fail+1))
fi

# Check 2: No go.mod
go_mod_files=$(find "${REPO_ROOT}" -maxdepth 3 -type f -name 'go.mod' \
    -not -path "${REPO_ROOT}/.git/*" \
    -not -path "${REPO_ROOT}/node_modules/*" \
    -not -path "${REPO_ROOT}/vendor/*" \
    2>/dev/null)
if [[ -z "${go_mod_files}" ]]; then
    echo "  ok: no go.mod found"
else
    echo "  FAIL: go.mod found (zero-Go-in-v3.2.0 policy violated — see docs/ROADMAP-GO.md):"
    echo "${go_mod_files}" | sed 's/^/    /'
    fail=$((fail+1))
fi

# Check 3: No go.sum
go_sum_files=$(find "${REPO_ROOT}" -maxdepth 3 -type f -name 'go.sum' \
    -not -path "${REPO_ROOT}/.git/*" \
    -not -path "${REPO_ROOT}/node_modules/*" \
    -not -path "${REPO_ROOT}/vendor/*" \
    2>/dev/null)
if [[ -z "${go_sum_files}" ]]; then
    echo "  ok: no go.sum found"
else
    echo "  FAIL: go.sum found (zero-Go-in-v3.2.0 policy violated):"
    echo "${go_sum_files}" | sed 's/^/    /'
    fail=$((fail+1))
fi

# Check 4: No go.work (Go workspace file)
go_work_files=$(find "${REPO_ROOT}" -maxdepth 3 -type f -name 'go.work' \
    -not -path "${REPO_ROOT}/.git/*" \
    -not -path "${REPO_ROOT}/node_modules/*" \
    -not -path "${REPO_ROOT}/vendor/*" \
    2>/dev/null)
if [[ -z "${go_work_files}" ]]; then
    echo "  ok: no go.work found"
else
    echo "  FAIL: go.work found (zero-Go-in-v3.2.0 policy violated):"
    echo "${go_work_files}" | sed 's/^/    /'
    fail=$((fail+1))
fi

echo ""
echo "## test_no_go_code_in_v320: FAIL=${fail}"
[[ "${fail}" -eq 0 ]] && exit 0 || exit 1
