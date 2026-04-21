#!/usr/bin/env bash
# tests/unit/test_foreign_mdns_assert.sh — unit coverage for MDNS-02 (_assert_no_foreign_mdns)
# Runs without root; uses tests/mocks/ss via PATH prepend.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/detect.sh"

_tests_run=0
_tests_failed=0

_assert_rc() {
    _tests_run=$((_tests_run+1))
    local label="$1" expected_rc="$2" actual_rc="$3"
    if [[ "$expected_rc" == "$actual_rc" ]]; then
        echo "  [PASS] ${label} (rc=${actual_rc})"
    else
        echo "  [FAIL] ${label}: expected_rc=${expected_rc} actual_rc=${actual_rc}"
        _tests_failed=$((_tests_failed+1))
    fi
}

_assert_stderr_contains() {
    _tests_run=$((_tests_run+1))
    local label="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo "  [PASS] ${label}"
    else
        echo "  [FAIL] ${label}: needle='${needle}' not in stderr"
        echo "    stderr was: ${haystack}"
        _tests_failed=$((_tests_failed+1))
    fi
}

echo "## test_foreign_mdns_assert"

# IMPORTANT: tests run under 'set -euo pipefail'. _assert_no_foreign_mdns returns 1
# on foreign responder — without 'set +e' guard this would abort the whole test script.
# Pattern: set +e; call function once; rc=$?; set -e  — ONE invocation per case.
# This avoids dual-invocation (which would produce duplicate output) and SC2181.

# Case 1: clean system (only avahi) → rc=0
export MOCK_SS_FIXTURE=clean
set +e
_assert_no_foreign_mdns >/dev/null 2>&1
rc=$?
set -e
_assert_rc "clean (avahi only) → rc=0" 0 "$rc"

# Case 2: NoMachine nxserver.bin squatting → rc=1 + stderr mentions nxserver + NoMachine fix
export MOCK_SS_FIXTURE=foreign_nx
set +e
stderr_out="$(_assert_no_foreign_mdns 2>&1 >/dev/null)"
rc=$?
set -e
_assert_rc "foreign_nx → rc=1" 1 "$rc"
_assert_stderr_contains "foreign_nx stderr mentions nxserver.bin" "nxserver.bin" "$stderr_out"
_assert_stderr_contains "foreign_nx stderr mentions NoMachine fix" "EnableLocalNetworkBroadcast" "$stderr_out"

# Case 3: systemd-resolved squatting → rc=1 + stderr mentions MulticastDNS fix
export MOCK_SS_FIXTURE=foreign_resolved
set +e
stderr_out="$(_assert_no_foreign_mdns 2>&1 >/dev/null)"
rc=$?
set -e
_assert_rc "foreign_resolved → rc=1" 1 "$rc"
_assert_stderr_contains "resolved stderr mentions MulticastDNS" "MulticastDNS" "$stderr_out"

# Case 4: empty ss output (nothing on 5353 — e.g. avahi stopped) → rc=0
export MOCK_SS_FIXTURE=empty
set +e
_assert_no_foreign_mdns >/dev/null 2>&1
rc=$?
set -e
_assert_rc "empty 5353 → rc=0" 0 "$rc"

echo ""
echo "## Summary: ${_tests_run} run, ${_tests_failed} failed"
[[ "$_tests_failed" -eq 0 ]]
