#!/usr/bin/env bash
# Integration test for lib/ssh_trust.sh — LIVE peer required.
# Skipped automatically if INTEGRATION_PEER_IP not set OR peer unreachable.
# Does NOT install sshpass and does NOT prompt for password —
# assumes key bootstrap already done (manually or previous run) and verifies
# BatchMode end-to-end + ssh config entry.
#
# Usage:
#   bash tests/integration/test_ssh_trust.sh          # SKIP if no peer
#   INTEGRATION_PEER_IP=192.168.100.2 bash tests/integration/test_ssh_trust.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PEER_IP="${INTEGRATION_PEER_IP:-}"
PEER_USER="${INTEGRATION_PEER_USER:-agmind2}"
KEY_PATH="${INTEGRATION_PEER_SSH_KEY:-${HOME}/.ssh/agmind_peer_ed25519}"

if [[ -z "$PEER_IP" ]]; then
    echo "SKIP: INTEGRATION_PEER_IP not set — skipping live SSH trust test."
    echo "      Run with: INTEGRATION_PEER_IP=192.168.100.2 bash $0"
    exit 0
fi

echo "=== test_ssh_trust.sh (live peer=${PEER_USER}@${PEER_IP}) ==="

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

# Pre-flight: peer reachable?
if ! ping -c 1 -W 2 "$PEER_IP" >/dev/null 2>&1; then
    echo "SKIP: peer ${PEER_IP} not reachable — skipping."
    exit 0
fi

# Source dependencies
source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
source "${REPO_ROOT}/lib/tui.sh" 2>/dev/null || true
source "${REPO_ROOT}/lib/ssh_trust.sh"

export AGMIND_PEER_USER="$PEER_USER"
export AGMIND_PEER_SSH_KEY="$KEY_PATH"

# --- Scenario 1: key generation is idempotent ---
if [[ -f "$KEY_PATH" ]]; then
    existing_pub="$(cat "${KEY_PATH}.pub")"
    _ensure_ssh_trust "$PEER_IP" "$PEER_USER" >/dev/null 2>&1 || true
    new_pub="$(cat "${KEY_PATH}.pub")"
    if [[ "$existing_pub" == "$new_pub" ]]; then
        pass "key idempotency: existing key not regenerated"
    else
        fail "key regenerated on second call (pub changed)"
    fi
else
    # Generate fresh — first run (interactive password required)
    if _ensure_ssh_trust "$PEER_IP" "$PEER_USER" >/dev/null 2>&1; then
        if [[ -f "$KEY_PATH" && -f "${KEY_PATH}.pub" ]]; then
            pass "key generated on first call"
        else
            fail "key generation did not create files"
        fi
    else
        echo "SKIP: first-time bootstrap requires password prompt — run interactively once, then retest"
        exit 0
    fi
fi

# --- Scenario 2: BatchMode ssh works ---
if ssh -i "$KEY_PATH" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "${PEER_USER}@${PEER_IP}" true 2>/dev/null; then
    pass "BatchMode ssh to ${PEER_USER}@${PEER_IP} succeeds"
else
    fail "BatchMode ssh failed — key not installed on peer or sshd rejects"
fi

# --- Scenario 3: ~/.ssh/config entry present ---
if grep -qE "^\s*HostName\s+${PEER_IP}\s*$" "${HOME}/.ssh/config" 2>/dev/null; then
    pass "${HOME}/.ssh/config has HostName ${PEER_IP} entry"
else
    fail "${HOME}/.ssh/config missing entry for ${PEER_IP} — _add_ssh_config_entry issue"
fi

# --- Scenario 4: _agmind_peer_ssh_opts returns sane string ---
opts="$(_agmind_peer_ssh_opts)"
if [[ "$opts" == *"-i ${KEY_PATH}"* && "$opts" == *"BatchMode=yes"* ]]; then
    pass "_agmind_peer_ssh_opts returns expected flags"
else
    fail "_agmind_peer_ssh_opts output unexpected: $opts"
fi

# --- Scenario 5: ssh agmind-peer alias works ---
if ssh agmind-peer hostname >/dev/null 2>&1; then
    pass "ssh agmind-peer alias works (ssh config entry functional)"
else
    fail "ssh agmind-peer alias fails — check config entry Host block"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
