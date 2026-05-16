#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_peer_env_lockdown.sh
# Regression for SEC-PEER-01 — phase_deploy_peer must chmod 600 + chown
# root:root the worker .env on peer immediately after scp, otherwise the
# secrets (VLLM_IMAGE, PORTAINER_AGENT_SECRET, HF_TOKEN, …) stay 0644 and
# any unprivileged shell on the peer can read them.
#
# Live SSH stub is VM territory; this static test parses lib/peer.sh and
# asserts the chmod + chown commands appear in the same SSH call inside
# peer_deploy, immediately following the scp .env line.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PEER_SH="${REPO_ROOT}/lib/peer.sh"

pass=0; fail=0

echo "## test_peer_env_lockdown"
echo ""

# ----------------------------------------------------------------------------
# Test 1: lib/peer.sh contains the lock-down ssh call
# ----------------------------------------------------------------------------
if grep -qE 'sudo -n chmod 600 .*\.env.*sudo -n chown root:root .*\.env' "$PEER_SH"; then
    pass=$((pass + 1))
    echo "  [PASS] chmod 600 + chown root:root chained in single ssh call"
else
    fail=$((fail + 1))
    echo "  [FAIL] no chmod 600 + chown root:root chained ssh call found"
fi

# ----------------------------------------------------------------------------
# Test 2: lockdown ssh comes after the scp .env line (i.e. within peer_deploy)
# ----------------------------------------------------------------------------
scp_line=$(grep -nE 'scp \$ssh_opts.*master_worker_env_local' "$PEER_SH" | head -1 | cut -d: -f1)
chmod_line=$(grep -nE 'sudo -n chmod 600 .*\.env' "$PEER_SH" | head -1 | cut -d: -f1)
if [[ -n "$scp_line" && -n "$chmod_line" && "$chmod_line" -gt "$scp_line" ]]; then
    delta=$((chmod_line - scp_line))
    if [[ "$delta" -le 15 ]]; then
        pass=$((pass + 1))
        echo "  [PASS] chmod lock-down within ${delta} lines after scp"
    else
        fail=$((fail + 1))
        echo "  [FAIL] chmod lock-down too far from scp (${delta} lines)"
    fi
else
    fail=$((fail + 1))
    echo "  [FAIL] scp or chmod line not found (scp=${scp_line} chmod=${chmod_line})"
fi

# ----------------------------------------------------------------------------
# Test 3: lockdown has an error-handler block (return 1 on failure)
# ----------------------------------------------------------------------------
# Heuristic: between the chmod line and ~10 lines after, expect `return 1` and
# log_error message about lockdown.
window="$(sed -n "${chmod_line:-1},$((${chmod_line:-1} + 10))p" "$PEER_SH")"
if echo "$window" | grep -q "Failed to lock down peer .env permissions" \
   && echo "$window" | grep -q "return 1"; then
    pass=$((pass + 1))
    echo "  [PASS] lockdown failure exits with return 1 and clear log_error"
else
    fail=$((fail + 1))
    echo "  [FAIL] lockdown failure handling missing or weak"
fi

# ----------------------------------------------------------------------------
# Test 4: shellcheck still clean
# ----------------------------------------------------------------------------
if shellcheck -S warning "$PEER_SH" >/dev/null 2>&1; then
    pass=$((pass + 1))
    echo "  [PASS] shellcheck -S warning clean"
else
    fail=$((fail + 1))
    echo "  [FAIL] shellcheck failed for lib/peer.sh"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
