#!/usr/bin/env bash
# tests/lint/test_mocks_readme_lists_all.sh
# Phase 13 TEST-08 anti-drift gate (bi-directional):
#   1. Every executable in tests/mocks/ MUST have a row in tests/mocks/README.md
#      inventory table.
#   2. Every row in the inventory table MUST point to an actual mock file
#      (no orphan documentation rows for deleted mocks).
#
# Tolerant POSIX-ERE `^\|[[:space:]]*\`<name>\`` allows optional leading
# whitespace in markdown table cells (some authors align column 1 visually
# with extra spaces). Uses POSIX classes — GNU grep -E does not understand
# PCRE `\s` shortcut, only `grep -P` does (RHEL minimal builds may lack -P).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to repo root '$REPO_ROOT'"; exit 1; }

README="tests/mocks/README.md"
if [[ ! -f "$README" ]]; then
    echo "FAIL: $README missing"
    exit 1
fi

fail=0

# Direction 1: every actual mock must have a README row.
for mock in tests/mocks/*; do
    base="$(basename "$mock")"
    [[ "$base" == "README.md" ]] && continue
    [[ "$base" == "_passthrough" ]] && continue
    [[ -f "$mock" ]] || continue
    if ! grep -qE "^\|[[:space:]]*\`${base}\`" "$README"; then
        echo "FAIL: tests/mocks/${base} not listed in $README inventory table"
        fail=1
    fi
done

# Direction 2: every README row must point to an actual mock file.
# Extract base names from markdown rows that start with `| \`name\``
# (column 1 of the inventory table).
while IFS= read -r base; do
    [[ -z "$base" ]] && continue
    if [[ ! -f "tests/mocks/${base}" ]]; then
        echo "FAIL: README documents '${base}' but tests/mocks/${base} doesn't exist"
        fail=1
    fi
done < <(grep -oE "^\|[[:space:]]*\`[A-Za-z0-9._-]+\`" "$README" | sed -E 's/^\|[[:space:]]*`//; s/`$//')

# Informational: actual mock count on disk.
actual_count="$(find tests/mocks/ -mindepth 1 -maxdepth 1 \
    -not -name 'README.md' -not -name '_passthrough' | wc -l)"
echo "Mock files on disk: ${actual_count}"

if [[ "$fail" -eq 0 ]]; then
    echo "PASS: all tests/mocks/* entries documented in README.md (and vice versa)"
    exit 0
fi
echo ""
echo "Fix: align tests/mocks/README.md inventory table with actual tests/mocks/ files."
exit 1
