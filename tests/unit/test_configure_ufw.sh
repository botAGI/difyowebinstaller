#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_configure_ufw.sh
# Regression for SEC-UFW-01 + SEC-UFW-02 — configure_ufw must:
#   - NEVER `ufw --force reset` unless AGMIND_UFW_RESET=true (preserves
#     admin rules).
#   - On already-active UFW, NOT touch default policies.
#   - Each LAN allow must be narrowed to specific port + proto (no
#     "ufw allow from $SUBNET" with no port).
#   - Monitoring ports (Grafana, Portainer) gated behind EXPOSE_*_LAN.
#   - Helper _ufw_add_or_keep skips when an agmind-tagged rule exists.
#   - uninstall_agmind_ufw_rules extracts only agmind-* rule numbers in
#     reverse-numeric order.
#
# Mocks `ufw`, `systemctl`, `mkdir`, `date` on PATH.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_DIR"' EXIT

# UFW mock — logs every invocation to $MOCK_DIR/ufw.log, returns canned
# `status` output controlled via $MOCK_UFW_STATUS_FILE.
cat > "${MOCK_DIR}/ufw" <<'MOCK'
#!/usr/bin/env bash
echo "ufw $*" >> "${MOCK_DIR}/ufw.log"
case "$1" in
    status)
        if [[ -f "${MOCK_UFW_STATUS_FILE:-}" ]]; then
            cat "$MOCK_UFW_STATUS_FILE"
        fi
        ;;
esac
exit 0
MOCK
# systemctl mock — pretend docker isn't active so we skip the restart block.
cat > "${MOCK_DIR}/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "${MOCK_DIR}/ufw" "${MOCK_DIR}/systemctl"

# Inject MOCK_DIR variable into mock so they can find log file.
export MOCK_DIR
export PATH="${MOCK_DIR}:${PATH}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/security.sh"
set +e

pass=0; fail=0

_clear_log() { : > "${MOCK_DIR}/ufw.log"; }
_log_has() { grep -qF "$1" "${MOCK_DIR}/ufw.log"; }
_log_count() { grep -c "$1" "${MOCK_DIR}/ufw.log" 2>/dev/null || echo 0; }

echo "## test_configure_ufw"
echo ""

# ----------------------------------------------------------------------------
# TC1: ENABLE_UFW=false → no ufw calls at all
# ----------------------------------------------------------------------------
echo "--- TC1: ENABLE_UFW=false → no-op ---"
_clear_log
ENABLE_UFW=false configure_ufw >/dev/null 2>&1
if [[ ! -s "${MOCK_DIR}/ufw.log" ]]; then
    pass=$((pass + 1)); echo "  [PASS] no ufw invocation"
else
    fail=$((fail + 1)); echo "  [FAIL] unexpected ufw calls:"
    cat "${MOCK_DIR}/ufw.log" | sed 's/^/        /'
fi

# ----------------------------------------------------------------------------
# TC2: inactive UFW + default config → enable + base rules added
# ----------------------------------------------------------------------------
echo ""
echo "--- TC2: inactive UFW → defaults set + rules appended + enable ---"
echo "Status: inactive" > "${MOCK_DIR}/status-inactive.txt"
_clear_log
ENABLE_UFW=true MOCK_UFW_STATUS_FILE="${MOCK_DIR}/status-inactive.txt" \
    LAN_SUBNET="192.168.1.0/24" configure_ufw >/dev/null 2>&1
if _log_has "ufw default deny incoming" && _log_has "ufw --force enable"; then
    pass=$((pass + 1)); echo "  [PASS] defaults + enable on inactive UFW"
else
    fail=$((fail + 1)); echo "  [FAIL] expected default+enable, log:"
    sed 's/^/        /' "${MOCK_DIR}/ufw.log"
fi
if _log_has "allow 80/tcp comment agmind-http" \
    && _log_has "allow 443/tcp comment agmind-https" \
    && _log_has "allow ssh comment agmind-ssh"; then
    pass=$((pass + 1)); echo "  [PASS] core ssh/http/https rules added"
else
    fail=$((fail + 1)); echo "  [FAIL] core rules missing"
fi

# ----------------------------------------------------------------------------
# TC3: SEC-UFW-01 — active UFW with no reset → no `ufw --force reset`
# ----------------------------------------------------------------------------
echo ""
echo "--- TC3: active UFW, no reset opt-in → reset NOT called ---"
echo "Status: active" > "${MOCK_DIR}/status-active.txt"
_clear_log
ENABLE_UFW=true MOCK_UFW_STATUS_FILE="${MOCK_DIR}/status-active.txt" \
    LAN_SUBNET="192.168.1.0/24" configure_ufw >/dev/null 2>&1
if ! _log_has "ufw --force reset"; then
    pass=$((pass + 1)); echo "  [PASS] no ufw --force reset on active UFW"
else
    fail=$((fail + 1)); echo "  [FAIL] reset called even without opt-in"
fi
if ! _log_has "ufw --force enable"; then
    pass=$((pass + 1)); echo "  [PASS] no redundant enable on already-active UFW"
else
    fail=$((fail + 1)); echo "  [FAIL] redundant enable called"
fi

# ----------------------------------------------------------------------------
# TC4: AGMIND_UFW_RESET=true → reset DOES happen
# ----------------------------------------------------------------------------
echo ""
echo "--- TC4: AGMIND_UFW_RESET=true → reset called ---"
_clear_log
ENABLE_UFW=true AGMIND_UFW_RESET=true \
    MOCK_UFW_STATUS_FILE="${MOCK_DIR}/status-active.txt" \
    LAN_SUBNET="192.168.1.0/24" configure_ufw >/dev/null 2>&1
if _log_has "ufw --force reset"; then
    pass=$((pass + 1)); echo "  [PASS] explicit reset honored"
else
    fail=$((fail + 1)); echo "  [FAIL] reset NOT called with opt-in"
fi

# ----------------------------------------------------------------------------
# TC5: SEC-UFW-02 — LAN allows are port-specific, no bare subnet wildcard
# ----------------------------------------------------------------------------
echo ""
echo "--- TC5: LAN allows are narrowed to specific ports ---"
_clear_log
ENABLE_UFW=true MOCK_UFW_STATUS_FILE="${MOCK_DIR}/status-inactive.txt" \
    LAN_SUBNET="192.168.1.0/24" configure_ufw >/dev/null 2>&1
if grep -q 'ufw allow from 192\.168\.1\.0/24 comment ' "${MOCK_DIR}/ufw.log"; then
    fail=$((fail + 1)); echo "  [FAIL] bare 'allow from \$SUBNET' rule still present"
else
    pass=$((pass + 1)); echo "  [PASS] no bare subnet wildcard"
fi
if _log_has "to any port 80 proto tcp comment agmind-http-lan" \
    && _log_has "to any port 443 proto tcp comment agmind-https-lan"; then
    pass=$((pass + 1)); echo "  [PASS] LAN allows narrowed to :80 / :443"
else
    fail=$((fail + 1)); echo "  [FAIL] narrowed LAN rules missing"
fi

# ----------------------------------------------------------------------------
# TC6: SEC-UFW-02 — Grafana LAN exposure off by default
# ----------------------------------------------------------------------------
echo ""
echo "--- TC6: Grafana LAN exposure default OFF ---"
_clear_log
ENABLE_UFW=true MONITORING_MODE=local \
    MOCK_UFW_STATUS_FILE="${MOCK_DIR}/status-inactive.txt" \
    LAN_SUBNET="192.168.1.0/24" configure_ufw >/dev/null 2>&1
if ! _log_has "agmind-grafana-lan"; then
    pass=$((pass + 1)); echo "  [PASS] no agmind-grafana-lan rule without opt-in"
else
    fail=$((fail + 1)); echo "  [FAIL] grafana-lan added without opt-in"
fi
# Now with explicit opt-in
_clear_log
ENABLE_UFW=true MONITORING_MODE=local EXPOSE_GRAFANA_LAN=true \
    MOCK_UFW_STATUS_FILE="${MOCK_DIR}/status-inactive.txt" \
    LAN_SUBNET="192.168.1.0/24" configure_ufw >/dev/null 2>&1
if _log_has "agmind-grafana-lan"; then
    pass=$((pass + 1)); echo "  [PASS] EXPOSE_GRAFANA_LAN=true opens :3001"
else
    fail=$((fail + 1)); echo "  [FAIL] grafana rule missing with opt-in"
fi

# ----------------------------------------------------------------------------
# TC7: _ufw_add_or_keep skips when agmind-tagged rule already exists
# ----------------------------------------------------------------------------
echo ""
echo "--- TC7: _ufw_add_or_keep idempotent ---"
cat > "${MOCK_DIR}/status-with-rule.txt" <<EOF
Status: active
[ 1] 22/tcp                ALLOW IN    Anywhere                   # agmind-ssh
EOF
_clear_log
MOCK_UFW_STATUS_FILE="${MOCK_DIR}/status-with-rule.txt" \
    _ufw_add_or_keep agmind-ssh allow ssh comment agmind-ssh
# Mock log will record the `ufw status` call but NOT the `allow ssh`.
if ! _log_has "allow ssh"; then
    pass=$((pass + 1)); echo "  [PASS] existing rule preserved (no re-add)"
else
    fail=$((fail + 1)); echo "  [FAIL] rule re-added despite existing"
fi

# ----------------------------------------------------------------------------
# TC8: uninstall_agmind_ufw_rules extracts only agmind-* nums in reverse order
# ----------------------------------------------------------------------------
echo ""
echo "--- TC8: uninstall_agmind_ufw_rules — reverse-numeric, only agmind-* ---"
cat > "${MOCK_DIR}/status-mixed.txt" <<EOF
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere                   # agmind-ssh
[ 2] 80/tcp                     ALLOW IN    Anywhere                   # agmind-http
[ 3] 9000/tcp                   ALLOW IN    Anywhere                   # custom-app
[ 4] 443/tcp                    ALLOW IN    Anywhere                   # agmind-https
[12] 192.168.1.0/24 80/tcp      ALLOW IN    192.168.1.0/24             # agmind-http-lan
EOF
_clear_log
MOCK_UFW_STATUS_FILE="${MOCK_DIR}/status-mixed.txt" uninstall_agmind_ufw_rules
expected_seq="$(grep "ufw --force delete" "${MOCK_DIR}/ufw.log" | awk '{print $4}' | tr '\n' ' ')"
if [[ "$expected_seq" == "12 4 2 1 " ]]; then
    pass=$((pass + 1)); echo "  [PASS] deleted 12,4,2,1 (reverse order, agmind-* only)"
else
    fail=$((fail + 1)); echo "  [FAIL] expected '12 4 2 1 ' got '${expected_seq}'"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
