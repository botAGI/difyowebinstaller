#!/usr/bin/env bash
# tests/golden/_commit_msg_guard.sh
# Phase 13 D-15 commit-msg hook: require `golden-accept-reason: <text≥10>` trailer
# when commit touches tests/golden/expected/.
#
# Invoked by pre-commit `stages: [commit-msg]` with $1 = commit-msg file path
# (pre-commit convention). Also standalone-testable: pass any text file as $1.
# For tests, override staged set via GOLDEN_GUARD_STAGED_PATHS (newline-separated).
set -uo pipefail

msg_file="${1:-}"
if [[ -z "$msg_file" || ! -f "$msg_file" ]]; then
    echo "ERROR: _commit_msg_guard.sh: invalid msg file path: '${msg_file}'" >&2
    exit 2
fi

# Detect: are we touching tests/golden/expected/**? Use git diff --cached when
# inside a real commit (pre-commit invokes us between `git add` and commit creation).
# Fallback: if not in a git index context, treat staged_paths as empty (no enforcement).
staged=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    staged="$(git diff --cached --name-only 2>/dev/null || true)"
fi

# Allow override for testing: GOLDEN_GUARD_STAGED_PATHS=<paths> simulates staged set.
if [[ -n "${GOLDEN_GUARD_STAGED_PATHS:-}" ]]; then
    staged="${GOLDEN_GUARD_STAGED_PATHS}"
fi

if ! echo "$staged" | grep -q '^tests/golden/expected/'; then
    exit 0   # no expected/ touch — no trailer required
fi

# Trailer required. Regex: line starts with `golden-accept-reason: ` then a
# non-whitespace char (first content char must be [[:graph:]] — printable, no space)
# then at least 9 more chars of any kind = ≥10 total reason chars.
if grep -qE '^golden-accept-reason: [[:graph:]].{9,}' "$msg_file"; then
    exit 0
fi

cat >&2 <<'EOF'
✗ Commit touches tests/golden/expected/** but commit message lacks a
  'golden-accept-reason: <reason>' trailer (≥10 non-space chars).

Add a trailer line at the bottom of the commit message, e.g.:
  golden-accept-reason: postgres bump 17.2 → 17.3 — verified compat in changelog
  golden-accept-reason: nginx upstream rename to vllm-peer per LLM_ON_PEER refactor

See tests/golden/UPDATE.md for the runbook.
EOF
exit 1
