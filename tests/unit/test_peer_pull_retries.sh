#!/usr/bin/env bash
# test_peer_pull_retries.sh — `lib/peer.sh::_deploy_image_to_peer` must wrap
# BOTH the peer-side pull AND the master-fallback pull in 3-attempt retry
# loops with backoff. GHCR rate-limit + peer wifi flakes are common; one-shot
# pull is too brittle and aborts phase 8 on transient failure.
#
# Precedent (2026-05-15, bug-report 3 phase-7/8 cascades):
#   peer-side pull failed with `context deadline exceeded` (wifi flake), then
#   master fallback also failed with same error (GHCR transient) → phase 8
#   aborted, install bailed. Fix in b86b7f1: 3-attempt retry on both paths
#   with 15s/75s backoff. This test ensures the retry loops remain in place
#   if someone refactors the function.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PEER_SH="${REPO_ROOT}/lib/peer.sh"

if [[ ! -f "$PEER_SH" ]]; then
    echo "SKIP: ${PEER_SH} not found"
    exit 77
fi

echo "## test_peer_pull_retries"

PASS=0; FAIL=0

# Extract just the _deploy_image_to_peer function body (between its `()` and
# the next top-level function definition).
fn_body="$(awk '
    /^_deploy_image_to_peer\(\) \{/ { in_fn=1; next }
    in_fn && /^[a-z_][a-z0-9_]*\(\) \{/ { exit }
    in_fn && /^}$/ { exit }
    in_fn { print }
' "$PEER_SH")"

if [[ -z "$fn_body" ]]; then
    echo "  [FAIL] could not locate _deploy_image_to_peer function in $PEER_SH"
    echo ""
    echo "=== Summary: 0 passed, 1 failed ==="
    exit 1
fi

# Check 1: at least 2 retry loops (one for peer-side pull, one for master pull).
retry_loops="$(grep -cE 'for[[:space:]]+_attempt[[:space:]]+in[[:space:]]+1[[:space:]]+2[[:space:]]+3' <<< "$fn_body")"
if [[ "$retry_loops" -ge 2 ]]; then
    echo "  [PASS] _deploy_image_to_peer has ≥2 retry loops (found ${retry_loops})"
    PASS=$((PASS+1))
else
    echo "  [FAIL] _deploy_image_to_peer has only ${retry_loops} retry loop(s) — expected ≥2 (peer-side + master-fallback)"
    FAIL=$((FAIL+1))
fi

# Check 2: backoff sleep present (delay between attempts).
sleeps="$(grep -cE 'sleep[[:space:]]+"?\$_delay"?' <<< "$fn_body")"
if [[ "$sleeps" -ge 2 ]]; then
    echo "  [PASS] _deploy_image_to_peer has ≥2 backoff sleeps (found ${sleeps})"
    PASS=$((PASS+1))
else
    echo "  [FAIL] _deploy_image_to_peer has only ${sleeps} backoff sleep(s) — expected ≥2"
    FAIL=$((FAIL+1))
fi

# Check 3: peer-side ssh-pull attempt mentions `sudo -n docker pull`.
if grep -qE 'docker[[:space:]]+pull[[:space:]]+\$\{image\}' <<< "$fn_body"; then
    echo "  [PASS] _deploy_image_to_peer still attempts peer-side direct pull (saves 10+ GB SSH transfer when peer has WAN)"
    PASS=$((PASS+1))
else
    echo "  [FAIL] _deploy_image_to_peer no longer attempts peer-side ssh pull — would force always-master-transfer path"
    FAIL=$((FAIL+1))
fi

# Check 4: master fallback uses `docker pull` (local, after peer-side fails).
if grep -qE '^[[:space:]]*if[[:space:]]+docker[[:space:]]+pull|docker[[:space:]]+pull[[:space:]]+"\$\{image\}"' <<< "$fn_body"; then
    echo "  [PASS] _deploy_image_to_peer keeps master-side fallback (docker pull) path"
    PASS=$((PASS+1))
else
    echo "  [FAIL] _deploy_image_to_peer missing master-side fallback docker pull"
    FAIL=$((FAIL+1))
fi

# Check 5: docker save | ssh docker load transfer present (final master→peer step).
if grep -qE 'docker[[:space:]]+save[[:space:]]+"\$\{image\}"' <<< "$fn_body"; then
    echo "  [PASS] _deploy_image_to_peer keeps save|load transfer for master→peer"
    PASS=$((PASS+1))
else
    echo "  [FAIL] _deploy_image_to_peer missing docker save|load transfer"
    FAIL=$((FAIL+1))
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
