#!/usr/bin/env bash
# tests/unit/test_get_primary_ip.sh — unit coverage for MDNS-01 (_mdns_get_primary_ip)
# Runs without root. Uses tests/mocks/ via PATH prepend.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
[[ -d "$MOCK_DIR" ]] || { echo "FAIL: mocks dir missing: $MOCK_DIR" >&2; exit 1; }

export PATH="${MOCK_DIR}:${PATH}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/detect.sh"

_tests_run=0
_tests_failed=0

_assert_eq() {
    _tests_run=$((_tests_run+1))
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] ${label}"
    else
        echo "  [FAIL] ${label}: expected='${expected}' actual='${actual}'"
        _tests_failed=$((_tests_failed+1))
    fi
}

echo "## test_get_primary_ip"

# NOTE: inline `VAR=val func` syntax applies env ONLY to external commands, not bash functions.
# Since _mdns_get_primary_ip is a sourced function (not external), we must export fixtures first.

# Case 1: primary default route — returns default-iface IP (not docker bridge first in hostname -I)
export MOCK_IP_FIXTURE=primary MOCK_HOSTNAME_FIXTURE=docker_first
_assert_eq "default route → enP7s7 IP (ignores docker bridge first in hostname -I)" \
           "192.168.1.45" "$(_mdns_get_primary_ip)"

# Case 2: no default route — fallback skips 172.x, returns non-docker IP from hostname -I
export MOCK_IP_FIXTURE=no_route MOCK_HOSTNAME_FIXTURE=docker_first
_assert_eq "no default route → fallback skips 172.17.0.1" \
           "192.168.1.45" "$(_mdns_get_primary_ip)"

# Case 3: no route AND only docker bridge in hostname -I → empty (refuse wrong IP)
export MOCK_IP_FIXTURE=no_route MOCK_HOSTNAME_FIXTURE=only_docker
_assert_eq "no route + only docker → empty (refuse wrong IP)" \
           "" "$(_mdns_get_primary_ip)"

# Case 4: no route + empty hostname -I → empty
export MOCK_IP_FIXTURE=no_route MOCK_HOSTNAME_FIXTURE=empty
_assert_eq "no route + empty hostname → empty" \
           "" "$(_mdns_get_primary_ip)"

# Case 5: primary IP first in hostname -I — route takes precedence, still correct
export MOCK_IP_FIXTURE=primary MOCK_HOSTNAME_FIXTURE=primary_first
_assert_eq "primary first hostname + route → primary IP" \
           "192.168.1.45" "$(_mdns_get_primary_ip)"

echo ""
echo "## Summary: ${_tests_run} run, ${_tests_failed} failed"
[[ "$_tests_failed" -eq 0 ]]
