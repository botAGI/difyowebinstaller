#!/usr/bin/env bash
# scripts/landmines-sync.sh — Regenerate tests/lint/LANDMINES.tsv from LANDMINES.md.
# Atomic mktemp+mv. Idempotent. md is single source of truth.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
MD="${REPO_ROOT}/tests/lint/LANDMINES.md"
TSV="${REPO_ROOT}/tests/lint/LANDMINES.tsv"

[[ -f "$MD" ]] || { echo "ERROR: $MD not found" >&2; exit 1; }

tmp="$(mktemp -t landmines-tsv.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

python3 - "$MD" "$tmp" <<'PY'
import sys
md_path, tsv_path = sys.argv[1], sys.argv[2]

with open(md_path, 'r', encoding='utf-8') as f:
    text = f.read()

# Find table under '## Catalog' (skip header + separator rows).
# Markdown table parser: split on `|` BUT respect `\|` escape (literal pipe inside cell).
# Strategy: replace `\|` with sentinel before split, restore after.
SENTINEL = '\x00PIPE\x00'

rows = []
in_catalog = False
for line in text.splitlines():
    if line.strip().startswith('## Catalog'):
        in_catalog = True
        continue
    if not in_catalog:
        continue
    if line.strip().startswith('## ') and 'Catalog' not in line:
        break  # next ## section after catalog
    if not line.startswith('|'):
        continue
    # Replace escaped pipes BEFORE splitting on `|`, restore after.
    safe = line.replace('\\|', SENTINEL)
    cells_raw = safe.strip().strip('|').split('|')
    cells = [c.replace(SENTINEL, '|').strip() for c in cells_raw]
    if not cells or not cells[0]:
        continue
    # case-insensitive header detection (handles 'id' / 'ID' / 'Id' variants)
    if cells[0].lower() == 'id':
        continue
    # separator row like `|---|---|`
    if set(cells[0]) <= set('-'):
        continue
    if len(cells) < 7:
        continue
    # Strip backticks from pattern field (markdown formatting) — both leading and trailing.
    cells[1] = cells[1].strip('`')
    rows.append(cells[:7])

with open(tsv_path, 'w', encoding='utf-8') as f:
    f.write('id\tpattern\tfile_glob\tseverity\tclaude_md_anchor\trationale\tintroduced_at\n')
    for r in rows:
        f.write('\t'.join(r) + '\n')

print(f"Wrote {len(rows)} landmines to {tsv_path}", file=sys.stderr)
PY

mv -f "$tmp" "$TSV"
trap - EXIT
