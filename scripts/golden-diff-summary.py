#!/usr/bin/env python3
"""scripts/golden-diff-summary.py — categorized colored summary of a golden diff.

Reads a unified-diff file produced by `tests/golden/run.sh`, categorizes hunks by
content patterns (image bumps, mem_limit drift, gpu_memory_utilization changes,
generic), and cross-references against tests/lint/LANDMINES.tsv to flag landmine
touches via ⚠️ marker.

Usage:
    python3 scripts/golden-diff-summary.py [path-to-diff-file]

Default diff path: tests/golden/.last-update.diff
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DIFF = REPO_ROOT / "tests" / "golden" / ".last-update.diff"
LANDMINES_TSV = REPO_ROOT / "tests" / "lint" / "LANDMINES.tsv"

ANSI = {
    "red": "\033[0;31m",
    "green": "\033[0;32m",
    "yellow": "\033[1;33m",
    "bold": "\033[1m",
    "reset": "\033[0m",
}
if not sys.stdout.isatty():
    ANSI = {k: "" for k in ANSI}


# POSIX ERE character class → Python regex translation table.
# LANDMINES.tsv uses POSIX ERE patterns (designed for `grep -E`). Python `re`
# does not understand `[[:space:]]` etc. natively (treats them as nested sets,
# silent semantic drift + FutureWarning). Translate up-front to a Python-regex
# equivalent that preserves match semantics.
_POSIX_CLASSES = {
    "[[:space:]]": r"\s",
    "[[:digit:]]": r"\d",
    "[[:alpha:]]": r"[A-Za-z]",
    "[[:alnum:]]": r"[A-Za-z0-9]",
    "[[:upper:]]": r"[A-Z]",
    "[[:lower:]]": r"[a-z]",
    "[[:graph:]]": r"[\x21-\x7e]",
    "[[:print:]]": r"[\x20-\x7e]",
    "[[:xdigit:]]": r"[0-9A-Fa-f]",
}


def _posix_to_python(pattern):
    """Replace POSIX ERE character-class shortcuts with Python-regex equivalents."""
    for posix, py in _POSIX_CLASSES.items():
        pattern = pattern.replace(posix, py)
    return pattern


def load_landmines():
    """Return list of (lid, compiled_regex, severity, anchor). Empty list on missing file."""
    patterns = []
    if not LANDMINES_TSV.exists():
        return patterns
    with LANDMINES_TSV.open(encoding="utf-8") as f:
        # skip header
        f.readline()
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5:
                continue
            lid, pat, _glob, sev, anchor = parts[:5]
            py_pat = _posix_to_python(pat)
            try:
                cre = re.compile(py_pat)
            except re.error:
                continue
            patterns.append((lid, cre, sev, anchor))
    return patterns


def categorize(line):
    """Return category for a +/- diff line content."""
    s = line.lstrip("+-")
    if re.search(r"^\s*image:", s):
        return "image"
    if re.search(r"^\s*mem_limit:", s):
        return "mem_limit"
    if "gpu_memory_utilization" in s:
        return "gpu"
    return "generic"


def summarize(diff_path):
    if not diff_path.exists():
        print(f"{ANSI['yellow']}No diff file at {diff_path} — nothing to summarize{ANSI['reset']}")
        return 0

    landmines = load_landmines()
    counts = {"image": 0, "mem_limit": 0, "gpu": 0, "generic": 0}
    landmine_hits = []  # (line_text, [(lid, sev, anchor), ...])

    with diff_path.open(encoding="utf-8", errors="replace") as f:
        for raw in f:
            # Skip file-header markers (`+++`, `---`) and hunk-header `@@`
            if raw.startswith(("+++", "---", "@@")):
                continue
            if not raw.startswith(("+", "-")):
                continue
            cat = categorize(raw)
            counts[cat] += 1
            hits = [(lid, sev, anchor) for (lid, cre, sev, anchor) in landmines if cre.search(raw)]
            if hits:
                landmine_hits.append((raw.rstrip(), hits))

    total = sum(counts.values())
    print(f"{ANSI['bold']}== Golden Diff Summary ({total} changed lines) =={ANSI['reset']}")
    print(f"  image bumps      : {counts['image']}")
    print(f"  mem_limit drift  : {counts['mem_limit']}")
    print(f"  GPU memory ratio : {counts['gpu']}")
    print(f"  other            : {counts['generic']}")

    if landmine_hits:
        print()
        print(f"{ANSI['red']}{ANSI['bold']}⚠️  LANDMINE-touching changes:{ANSI['reset']}")
        for line, hits in landmine_hits:
            for lid, sev, anchor in hits:
                tag = "critical" if sev == "critical" else "warning"
                color = ANSI["red"] if sev == "critical" else ANSI["yellow"]
                print(f"  {color}[{lid} {tag}]{ANSI['reset']} {anchor}")
                print(f"    {line[:160]}")
        print()
        print(f"{ANSI['yellow']}Read tests/golden/UPDATE.md — landmine-touch needs explicit `golden-accept-reason:` justification.{ANSI['reset']}")
    else:
        print()
        print(f"{ANSI['green']}No landmine-touching changes detected.{ANSI['reset']}")

    print()
    print(f"Full unified diff: {diff_path}")
    return 0


if __name__ == "__main__":
    diff_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DIFF
    sys.exit(summarize(diff_path))
