#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_adr_index_consistent.sh — DOCS-03 regression
#
# Verifies:
#   1. scripts/generate-adr-index.py --check exits 0 against committed
#      docs/adr/INDEX.md (catches drift between ADR frontmatter and the
#      auto-generated table).
#   2. Every [NNNN](NNNN-slug.md) link inside the editorial "Cross-cutting
#      ADR groups" section resolves to an existing file under docs/adr/
#      (catches dangling links after an ADR rename or delete that touched
#      the editorial section instead of the auto-generated table).
#
# Exit: 0 = PASS, 77 = SKIP (script missing), else = FAIL.
# Auto-discovered by tests/run_all.sh via the tests/unit/*.sh glob.
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

SCRIPT="scripts/generate-adr-index.py"
INDEX="docs/adr/INDEX.md"

if [[ ! -f "$SCRIPT" ]]; then
    echo "SKIP: $SCRIPT not present"
    exit 77
fi

# Gate 1: --check exit 0 against committed INDEX.md
if ! python3 "$SCRIPT" --check; then
    echo "FAIL: docs/adr/INDEX.md is stale. Run \`make adr-index\`."
    exit 1
fi

# Gate 2: every NNNN-slug.md reference inside Cross-cutting ADR groups exists.
# Section spans from `## Cross-cutting ADR groups` to the next blank line OR
# end-of-file — awk's range pattern handles both. We extract markdown link
# targets shaped `(NNNN-slug.md)` from the slice.
cross_section="$(awk '/^## Cross-cutting ADR groups/,/^$/' "$INDEX"; awk '/^## Cross-cutting ADR groups/,0' "$INDEX")"

missing=0
while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    file="docs/adr/${ref}"
    if [[ ! -f "$file" ]]; then
        echo "FAIL: dangling link in Cross-cutting groups: $file"
        missing=$((missing + 1))
    fi
done < <(echo "$cross_section" | grep -oE '\(([0-9]{4}-[a-z0-9.-]+\.md)\)' | tr -d '()' | sort -u)

if (( missing > 0 )); then
    echo "FAIL: $missing dangling cross-cutting-group link(s)"
    exit 1
fi

adr_rows="$(grep -cE '^\| \[[0-9]{4}\]\(' "$INDEX" || true)"
echo "PASS: ADR-INDEX consistent + Cross-cutting links resolve (${adr_rows} ADRs)"
exit 0
