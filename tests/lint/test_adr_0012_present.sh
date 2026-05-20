#!/usr/bin/env bash
# tests/lint/test_adr_0012_present.sh — REG-09 CI gate.
#
# Asserts:
#   1. docs/adr/0012-service-registry-codegen.md exists
#   2. Required MADR-lite sections present (Context / Decision / Consequences / References)
#   3. Status: Accepted
#   4. Key content tokens present (registry-codegen, drift, distroless-no-health,
#      schema_version, mikefarah, PyYAML, air-gap, _registry.indexed.sh, aliases,
#      8-named-profile sweep)
#   5. Cross-references to prior ADRs (ADR-0009, ADR-0011)
#   6. docs/adr/INDEX.md has the [0012](0012-service-registry-codegen.md) row
#      (canonical catalogue moved from docs/adr/README.md to docs/adr/INDEX.md in Phase 15)
#
# Exit: 0 = pass, 1 = fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_adr_0012_present"

ADR="${REPO_ROOT}/docs/adr/0012-service-registry-codegen.md"
INDEX="${REPO_ROOT}/docs/adr/INDEX.md"

pass=0; fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# 1. ADR file exists
if [[ -f "$ADR" ]]; then
    _ok "${ADR##*/} exists"
else
    _fail "ADR-0012 missing"
    echo "## test_adr_0012_present: FAIL"
    exit 1
fi

# 2. Required MADR-lite headings
for heading in \
    '^# 0012\. Service Registry' \
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

# 4. Required content tokens (Phase 12 architectural decisions)
# Note: grep -iF for tokens that may appear with mixed capitalisation (e.g. "Air-gap").
for token in \
    'registry-codegen' \
    'drift' \
    'distroless-no-health' \
    'schema_version' \
    'mikefarah' \
    'PyYAML' \
    'air-gap' \
    '_registry.indexed.sh' \
    'aliases' \
    '8-named-profile sweep' \
; do
    if grep -qiF "$token" "$ADR"; then
        _ok "token: ${token}"
    else
        _fail "missing token: ${token}"
    fi
done

# 5. Cross-references to prior ADRs (match either "ADR-NNNN" or "NNNN-" filename prefix)
for ref in '0009' '0011'; do
    if grep -qE "ADR-${ref}|${ref}-" "$ADR"; then
        _ok "cross-ref: ADR-${ref}"
    else
        _fail "missing cross-ref: ADR-${ref}"
    fi
done

# 6. README index cross-link
if grep -qF '[0012](0012-service-registry-codegen.md)' "$INDEX"; then
    _ok "README has [0012](...) link row"
else
    _fail "README missing [0012](...) row"
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ "$fail" -eq 0 ]]
