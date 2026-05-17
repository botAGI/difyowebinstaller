#!/usr/bin/env bash
# tests/lint/test_no_raw_generate_random_in_config.sh
# Phase 13 D-09 anti-regression: ensure no raw `$(generate_random ...)` exists
# in config/openwebui/authelia after the 28-callsite migration to
# `generate_random_named <SLUG> ...`. lib/common.sh is whitelisted because it
# hosts both functions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to ${REPO_ROOT}"; exit 1; }

# Files that must NOT contain raw `$(generate_random ` (trailing space —
# distinguishes from `generate_random_named`).
TARGETS=(
    lib/config.sh
    lib/openwebui.sh
    lib/authelia.sh
)

fail=0
for f in "${TARGETS[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "SKIP: $f not found"
        continue
    fi
    # Pattern: literal `$(generate_random ` (with trailing space) — matches
    # `$(generate_random 32)` but NOT `$(generate_random_named SLUG 32)`.
    # Skip comment-only lines starting with optional whitespace + '#'.
    if grep -nE '^[[:space:]]*[^#]*\$\(generate_random ' "$f"; then
        echo "FAIL: $f contains raw \$(generate_random ...) callsite — must use generate_random_named <SLUG> ..."
        fail=1
    fi
done

if [[ "$fail" -eq 0 ]]; then
    echo "PASS: no raw generate_random callsites in lib/config.sh, lib/openwebui.sh, lib/authelia.sh"
    exit 0
fi
exit 1
