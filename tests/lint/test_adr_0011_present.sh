#!/usr/bin/env bash
# tests/lint/test_adr_0011_present.sh — STATE-09 CI gate.
#
# Asserts:
#   1. docs/adr/0011-state-store-architecture.md exists
#   2. Required MADR-lite sections present (Context / Decision / Consequences / References)
#   3. Status: Accepted
#   4. Q-01 + Q-10 + "Schema Marker Contract" + "File Mode Contract" + "Q-Locking Contract" present
#   5. docs/adr/README.md has the [0011](0011-state-store-architecture.md) row
#
# Exit: 0 = pass, 1 = fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_adr_0011_present"

ADR="${REPO_ROOT}/docs/adr/0011-state-store-architecture.md"
INDEX="${REPO_ROOT}/docs/adr/README.md"

pass=0; fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# 1. ADR file exists
if [[ -f "$ADR" ]]; then
    _ok "${ADR##*/} exists"
else
    _fail "ADR-0011 missing"
    echo "## test_adr_0011_present: FAIL"
    exit 1
fi

# 2. Required MADR-lite headings
for heading in \
    '^# 0011\. State Store' \
    '^## Context and Problem Statement' \
    '^## Decision Outcome' \
    '^## Consequences' \
    '^## References' \
; do
    if grep -qE "$heading" "$ADR"; then
        _ok "section: ${heading}"
    else
        _fail "missing section: ${heading}"
    fi
done

# 3. Status: Accepted
if grep -q '^\*\*Status:\*\* Accepted' "$ADR"; then
    _ok "Status: Accepted"
else
    _fail "Status: Accepted missing or different"
fi

# 4. Required content tokens (per Phase 11 RESEARCH §6 ADR outline)
for token in \
    'Q-01' \
    'Q-10' \
    'Schema Marker Contract' \
    'File Mode Contract' \
    'Q-Locking Contract' \
    '0600' \
    '0700' \
    'flock' \
; do
    if grep -qF "$token" "$ADR"; then
        _ok "token: ${token}"
    else
        _fail "missing token: ${token}"
    fi
done

# 5. README index cross-link
if grep -qF '[0011](0011-state-store-architecture.md)' "$INDEX"; then
    _ok "README has [0011](...) link row"
else
    _fail "README missing [0011](...) row"
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ "$fail" -eq 0 ]]
