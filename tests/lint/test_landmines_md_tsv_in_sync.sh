#!/usr/bin/env bash
# tests/lint/test_landmines_md_tsv_in_sync.sh
# Phase 13 D-10 anti-drift: regenerate TSV from LANDMINES.md to a tempfile,
# diff against committed LANDMINES.tsv. Non-empty diff → md/tsv out of sync → fail.
#
# Re-implements the sync logic inline (mirrors scripts/landmines-sync.sh) so the
# test does not mutate the committed TSV on disk.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to $REPO_ROOT" >&2; exit 1; }

MD="tests/lint/LANDMINES.md"
TSV="tests/lint/LANDMINES.tsv"
SYNC="scripts/landmines-sync.sh"

if [[ ! -f "$MD" ]]; then
    echo "FAIL: $MD missing" >&2; exit 1
fi
if [[ ! -f "$TSV" ]]; then
    echo "FAIL: $TSV missing — run: bash $SYNC" >&2; exit 1
fi
if [[ ! -x "$SYNC" ]]; then
    echo "FAIL: $SYNC missing or not executable" >&2; exit 1
fi

tmp_tsv="$(mktemp -t landmines-sync-test.XXXXXX)"
diff_out="$(mktemp -t landmines-sync-diff.XXXXXX)"
trap 'rm -f "$tmp_tsv" "$diff_out"' EXIT

python3 - "$MD" "$tmp_tsv" <<'PY'
import sys
md_path, tsv_path = sys.argv[1], sys.argv[2]
with open(md_path, 'r', encoding='utf-8') as f:
    text = f.read()

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
        break
    if not line.startswith('|'):
        continue
    safe = line.replace('\\|', SENTINEL)
    cells_raw = safe.strip().strip('|').split('|')
    cells = [c.replace(SENTINEL, '|').strip() for c in cells_raw]
    if not cells or not cells[0]:
        continue
    if cells[0].lower() == 'id':
        continue
    if set(cells[0]) <= set('-'):
        continue
    if len(cells) < 7:
        continue
    cells[1] = cells[1].strip('`')
    rows.append(cells[:7])

with open(tsv_path, 'w', encoding='utf-8') as f:
    f.write('id\tpattern\tfile_glob\tseverity\tclaude_md_anchor\trationale\tintroduced_at\n')
    for r in rows:
        f.write('\t'.join(r) + '\n')
PY

if ! diff -u "$TSV" "$tmp_tsv" > "$diff_out" 2>&1; then
    echo "FAIL: LANDMINES.tsv out of sync with LANDMINES.md" >&2
    echo "  Run: bash $SYNC" >&2
    echo "Drift:" >&2
    cat "$diff_out" >&2
    exit 1
fi

echo "PASS: LANDMINES.md and LANDMINES.tsv in sync"
exit 0
