#!/usr/bin/env bash
# tests/unit/test_mdns_status.sh — unit coverage for MDNS-04 (agmind mdns-status CLI)
# Runs without root; uses mocks for ss, avahi-resolve, systemctl, ip, hostname, ping.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"
export AGMIND_DIR="${REPO_ROOT}"

# Ping mock shim for CI sandboxes without raw ICMP privileges
TMP_BIN="$(mktemp -d)"
trap 'rm -rf "$TMP_BIN"' EXIT
cat > "${TMP_BIN}/ping" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP_BIN}/ping"
export PATH="${TMP_BIN}:${PATH}"

_tests_run=0
_tests_failed=0

_pass() { _tests_run=$((_tests_run+1)); echo "  [PASS] $1"; }
_fail() { _tests_run=$((_tests_run+1)); _tests_failed=$((_tests_failed+1)); echo "  [FAIL] $1"; }

_check() {
    local label="$1"; shift
    if "$@"; then _pass "$label"; else _fail "$label"; fi
}

echo "## test_mdns_status"

# Case A: all green → rc=0
rc=0
MOCK_IP_FIXTURE=primary \
MOCK_HOSTNAME_FIXTURE=primary_first \
MOCK_AVAHI_FIXTURE=primary \
MOCK_SYSTEMCTL_FIXTURE=active \
MOCK_SS_FIXTURE=clean \
    bash "${REPO_ROOT}/scripts/mdns-status.sh" >/dev/null 2>&1 || rc=$?
_check "A: all green → rc=0" [ "$rc" = "0" ]

# Case B: --json valid JSON + issues=0
json_out=""
json_out="$(MOCK_IP_FIXTURE=primary \
            MOCK_HOSTNAME_FIXTURE=primary_first \
            MOCK_AVAHI_FIXTURE=primary \
            MOCK_SYSTEMCTL_FIXTURE=active \
            MOCK_SS_FIXTURE=clean \
            bash "${REPO_ROOT}/scripts/mdns-status.sh" --json 2>/dev/null)"
_check "B: --json valid JSON" python3 -c "import sys,json;json.loads(sys.argv[1])" "$json_out"
_check "B: --json issues=0" bash -c 'echo "$1" | grep -q "\"issues\":0"' -- "$json_out"

# Case C: unit inactive → rc>=1
rc=0
MOCK_IP_FIXTURE=primary \
MOCK_HOSTNAME_FIXTURE=primary_first \
MOCK_AVAHI_FIXTURE=primary \
MOCK_SYSTEMCTL_FIXTURE=inactive \
MOCK_SS_FIXTURE=clean \
    bash "${REPO_ROOT}/scripts/mdns-status.sh" >/dev/null 2>&1 || rc=$?
_check "C: unit inactive → rc>=1" [ "$rc" -ge "1" ]

# Case D: avahi resolves wrong IP → rc>=1
rc=0
MOCK_IP_FIXTURE=primary \
MOCK_HOSTNAME_FIXTURE=primary_first \
MOCK_AVAHI_FIXTURE=wrong_ip \
MOCK_SYSTEMCTL_FIXTURE=active \
MOCK_SS_FIXTURE=clean \
    bash "${REPO_ROOT}/scripts/mdns-status.sh" >/dev/null 2>&1 || rc=$?
_check "D: avahi resolves wrong_ip → rc>=1" [ "$rc" -ge "1" ]

# Case E: human output contains 4 section headers
human_out=""
human_out="$(MOCK_IP_FIXTURE=primary \
             MOCK_HOSTNAME_FIXTURE=primary_first \
             MOCK_AVAHI_FIXTURE=primary \
             MOCK_SYSTEMCTL_FIXTURE=active \
             MOCK_SS_FIXTURE=clean \
             bash "${REPO_ROOT}/scripts/mdns-status.sh" 2>&1 || true)"
_check "E: human has (a) section" grep -q '(a) Published'    <<< "$human_out"
_check "E: human has (b) section" grep -q '(b) agmind-mdns'  <<< "$human_out"
_check "E: human has (c) section" grep -q '(c) UDP/5353'     <<< "$human_out"
_check "E: human has (d) section" grep -q '(d) Primary uplink' <<< "$human_out"

# Case F: --help exits 0 and mentions Usage
help_out=""
rc=0
help_out="$(bash "${REPO_ROOT}/scripts/mdns-status.sh" --help 2>&1)" || rc=$?
_check "F: --help exits 0" [ "$rc" = "0" ]
_check "F: --help mentions Usage" grep -q 'Usage: agmind mdns-status' <<< "$help_out"

# Case G: avahi-resolve timeout → rc>=1 (fail on name not resolving)
rc=0
MOCK_IP_FIXTURE=primary \
MOCK_HOSTNAME_FIXTURE=primary_first \
MOCK_AVAHI_FIXTURE=timeout \
MOCK_SYSTEMCTL_FIXTURE=active \
MOCK_SS_FIXTURE=clean \
    bash "${REPO_ROOT}/scripts/mdns-status.sh" >/dev/null 2>&1 || rc=$?
_check "G: avahi timeout → rc>=1" [ "$rc" -ge "1" ]

echo ""
echo "## Summary: ${_tests_run} run, ${_tests_failed} failed"
[[ "$_tests_failed" -eq 0 ]]
