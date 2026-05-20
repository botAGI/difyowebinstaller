#!/usr/bin/env bash
# tests/integration/test_registry_codegen_drift.sh — REG-03 drift gate.
#
# Re-runs scripts/codegen/registry-to-indexed.sh into a temp file and compares
# against committed lib/_registry.indexed.sh byte-for-byte. Fails if developer
# edited templates/services/registry.yaml but forgot to regenerate the artifact.
#
# Exit: 0 = no drift, 1 = drift detected, 77 = SKIP (PyYAML missing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

echo "## test_registry_codegen_drift"

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "  SKIP: python3+PyYAML required"
    exit 77
fi

CODEGEN="${REPO_ROOT}/scripts/codegen/registry-to-indexed.sh"
COMMITTED="${REPO_ROOT}/lib/_registry.indexed.sh"

if [[ ! -x "$CODEGEN" ]]; then
    echo "  FAIL: $CODEGEN not executable or missing"
    exit 1
fi
if [[ ! -f "$COMMITTED" ]]; then
    echo "  FAIL: $COMMITTED missing — run \`bash scripts/codegen/registry-to-indexed.sh\` first"
    exit 1
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/registry-drift.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

OUT="$tmp" bash "$CODEGEN" >/dev/null
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "  FAIL: codegen returned non-zero exit code $rc"
    exit 1
fi

if diff -q "$COMMITTED" "$tmp" >/dev/null 2>&1; then
    echo "  PASS: lib/_registry.indexed.sh matches registry.yaml"
    exit 0
fi

echo "  FAIL: lib/_registry.indexed.sh is STALE — re-run \`make registry-codegen\` and commit the result"
echo ""
echo "  --- diff (committed vs freshly generated) ---"
diff "$COMMITTED" "$tmp" | head -30
echo "  --- end diff (max 30 lines) ---"
exit 1
