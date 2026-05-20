#!/usr/bin/env python3
"""
generate-adr-index.py — regenerate docs/adr/INDEX.md table from ADR frontmatter.

Parses every ``docs/adr/NNNN-slug.md`` file, extracts ``# NNNN. Title``,
``**Date:**`` and ``**Status:**`` fields, and emits a markdown table sorted
ascending by ADR number. The table is spliced between the sentinel markers
``<!-- ADR-INDEX:BEGIN ... -->`` and ``<!-- ADR-INDEX:END -->`` in
``docs/adr/INDEX.md``; the editorial preamble and "Cross-cutting ADR groups"
section live outside the markers and are preserved across regenerations.

Usage:
  python3 scripts/generate-adr-index.py            # in-place rewrite
  python3 scripts/generate-adr-index.py --check    # CI gate: exit 1 on drift, prints unified diff
  python3 scripts/generate-adr-index.py --pre-commit
        # like default rewrite but exits 1 (with re-commit instructions) when
        # the file was actually modified, so the pre-commit hook fails loudly
        # and auto-stages the regenerated INDEX.md.

Exit codes:
  0 — success (no drift in --check; nothing written in --pre-commit; rewrite OK)
  1 — drift detected, marker error, parse error, or pre-commit autostaged a regen
  2 — invalid command-line arguments
"""

import argparse
import re
import sys
from difflib import unified_diff
from pathlib import Path

ADR_DIR = Path(__file__).resolve().parent.parent / "docs" / "adr"
INDEX_PATH = ADR_DIR / "INDEX.md"

BEGIN_MARKER = "<!-- ADR-INDEX:BEGIN — auto-generated, do not edit by hand -->"
END_MARKER = "<!-- ADR-INDEX:END -->"

ADR_FILENAME_RE = re.compile(r"^(\d{4})-(.+)\.md$")
TITLE_RE = re.compile(r"^# (\d{4})\.\s+(.+?)\s*$", re.MULTILINE)
DATE_RE = re.compile(r"^\*\*Date:\*\*\s+(\d{4}-\d{2}-\d{2})\s*$", re.MULTILINE)
STATUS_RE = re.compile(r"^\*\*Status:\*\*\s+(\S+)\s*$", re.MULTILINE)


def parse_adr(path: Path) -> dict:
    """Extract NNNN/slug/title/date/status from a single ADR file."""
    m = ADR_FILENAME_RE.match(path.name)
    if not m:
        raise ValueError(f"filename does not match NNNN-slug.md pattern: {path.name}")
    number, slug = m.group(1), m.group(2)

    text = path.read_text(encoding="utf-8")

    title_match = TITLE_RE.search(text)
    if not title_match:
        raise ValueError(f"Missing frontmatter in {path.name}: # NNNN. <title>")
    if title_match.group(1) != number:
        raise ValueError(
            f"ADR number mismatch in {path.name}: "
            f"filename={number}, heading={title_match.group(1)}"
        )

    date_match = DATE_RE.search(text)
    if not date_match:
        raise ValueError(f"Missing frontmatter in {path.name}: **Date:** YYYY-MM-DD")

    status_match = STATUS_RE.search(text)
    if not status_match:
        raise ValueError(f"Missing frontmatter in {path.name}: **Status:** <word>")

    return {
        "number": number,
        "slug": slug,
        "filename": path.name,
        "title": title_match.group(2),
        "date": date_match.group(1),
        "status": status_match.group(1),
    }


def collect_adrs() -> list[dict]:
    """Glob and parse all ADR files under docs/adr/."""
    adrs = []
    for p in sorted(ADR_DIR.glob("[0-9][0-9][0-9][0-9]-*.md")):
        adrs.append(parse_adr(p))
    adrs.sort(key=lambda a: a["number"])
    return adrs


def generate_table(adrs: list[dict]) -> str:
    """Emit the markdown table block between the sentinel markers (markers excluded)."""
    lines = [
        "",
        "| ADR | Title | Status | Date |",
        "|-----|-------|--------|------|",
    ]
    for a in adrs:
        lines.append(
            f"| [{a['number']}]({a['filename']}) | {a['title']} | {a['status']} | {a['date']} |"
        )
    lines.extend(
        [
            "",
            f"**Total: {len(adrs)} ADRs.**",
            "",
        ]
    )
    return "\n".join(lines)


def splice_between_sentinels(text: str, new_table: str) -> str:
    """Replace content strictly between BEGIN/END markers; preserve markers + outer text."""
    begin_count = text.count(BEGIN_MARKER)
    end_count = text.count(END_MARKER)
    if begin_count == 0 or end_count == 0:
        raise ValueError(
            f"ADR-INDEX markers missing in {INDEX_PATH.name} "
            f"(BEGIN={begin_count}, END={end_count}). "
            f"Expected exactly one BEGIN and one END marker."
        )
    if begin_count > 1 or end_count > 1:
        raise ValueError(
            f"ADR-INDEX markers duplicated in {INDEX_PATH.name} "
            f"(BEGIN={begin_count}, END={end_count}). "
            f"Expected exactly one BEGIN and one END marker."
        )

    begin_idx = text.index(BEGIN_MARKER)
    end_idx = text.index(END_MARKER)
    if begin_idx > end_idx:
        raise ValueError(
            f"ADR-INDEX markers inverted in {INDEX_PATH.name} "
            f"(BEGIN at {begin_idx} > END at {end_idx})."
        )

    before = text[: begin_idx + len(BEGIN_MARKER)]
    after = text[end_idx:]
    return before + "\n" + new_table + "\n" + after


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Regenerate docs/adr/INDEX.md table from ADR frontmatter."
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--check",
        action="store_true",
        help="exit 1 on drift, print unified diff (no file write)",
    )
    group.add_argument(
        "--pre-commit",
        action="store_true",
        help="rewrite + exit 1 if file was modified (hook auto-stages and asks re-commit)",
    )
    args = parser.parse_args()

    if not INDEX_PATH.exists():
        print(f"FAIL: {INDEX_PATH} not found", file=sys.stderr)
        return 1

    try:
        adrs = collect_adrs()
    except ValueError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    if not adrs:
        print(f"FAIL: no ADR files found under {ADR_DIR}", file=sys.stderr)
        return 1

    current_text = INDEX_PATH.read_text(encoding="utf-8")
    try:
        new_text = splice_between_sentinels(current_text, generate_table(adrs))
    except ValueError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    if args.check:
        if current_text == new_text:
            print(f"OK: docs/adr/INDEX.md is up to date ({len(adrs)} ADRs)")
            return 0
        diff = unified_diff(
            current_text.splitlines(keepends=True),
            new_text.splitlines(keepends=True),
            fromfile="docs/adr/INDEX.md (committed)",
            tofile="docs/adr/INDEX.md (regenerated)",
        )
        sys.stdout.writelines(diff)
        print(
            f"FAIL: docs/adr/INDEX.md is stale ({len(adrs)} ADRs). "
            f"Run `make adr-index`.",
            file=sys.stderr,
        )
        return 1

    if current_text == new_text:
        if args.pre_commit:
            print(f"OK: docs/adr/INDEX.md already up to date ({len(adrs)} ADRs)")
            return 0
        print(f"OK: docs/adr/INDEX.md already up to date ({len(adrs)} ADRs)")
        return 0

    INDEX_PATH.write_text(new_text, encoding="utf-8")

    if args.pre_commit:
        print(
            f"REGEN: docs/adr/INDEX.md was regenerated ({len(adrs)} ADRs). "
            f"Please review and re-commit.",
            file=sys.stderr,
        )
        return 1

    print(f"OK: docs/adr/INDEX.md regenerated ({len(adrs)} ADRs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
