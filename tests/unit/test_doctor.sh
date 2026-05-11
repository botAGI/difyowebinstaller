#!/usr/bin/env bash
# tests/unit/test_doctor.sh — unit coverage for Phase 1 `agmind doctor` (lib/doctor.sh).
# Runs without root. Uses tests/mocks/ via PATH prepend. Exit 77 = SKIP; 0 = PASS; 1 = FAIL.
# SC1: happy_path (all-healthy mocks → exit 0).
# SC2: driver_590, mdns_dead, foreign_5353, missing_loadtest, gpu_caps_missing, mapcount_low.
# SC4: json_valid.
set -uo pipefail   # NOT -e — we capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"

# Null out colors so test output is plain text (no escape sequences in diffs)
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_doctor"

# ── _run_doctor helper ────────────────────────────────────────────────────────
# Runs doctor_run in a clean subshell with mocks on PATH.
# Callers export MOCK_* + INSTALL_DIR before calling. Args passed to doctor_run.
# Captures combined stdout+stderr and appends RC=<n> on the last line.
_run_doctor() {
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/detect.sh"  2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/health.sh"  2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/doctor.sh"
        doctor_run "$@"
        echo "RC=$?"
    ) 2>&1
}

# Helper: extract the RC value from _run_doctor output
_rc_of() { grep -oE 'RC=[0-9]+' <<< "$1" | tail -1 | cut -d= -f2; }

# Helper: extract just the JSON object from _run_doctor output.
# The JSON line starts with '{' — grep for it explicitly so that
# ZSH_VERSION/stderr noise (captured via 2>&1) doesn't reach json.load.
_strip_rc() { grep '^{' <<< "$1" | tail -1; }

# ── Case: _registry_add / _registry_count round-trip ─────────────────────────
# WHY: registry helpers must tally WARN and FAIL correctly for exit-code D-05.
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/doctor.sh"
    _registry_reset
    _registry_add "t1" "docker" "WARN" "test warn" "" false ""
    _registry_add "t2" "docker" "FAIL" "test fail" "" false ""
    _registry_add "t3" "docker" "OK"   "test ok"   "" false ""
    _registry_count
    [[ "$DOCTOR_ERRORS"   -eq 1 ]] || { echo "DOCTOR_ERRORS=$DOCTOR_ERRORS want 1" >&2; exit 1; }
    [[ "$DOCTOR_WARNINGS" -eq 1 ]] || { echo "DOCTOR_WARNINGS=$DOCTOR_WARNINGS want 1" >&2; exit 1; }
) && pass "_registry_count: WARN+FAIL tallied correctly" \
  || fail "_registry_count: incorrect tally"

# ── Case: _registry_reset clears DOCTOR_REGISTRY ─────────────────────────────
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/doctor.sh"
    _registry_add "x" "gpu" "FAIL" "pre-existing fail" "" false ""
    _registry_reset
    [[ "${#DOCTOR_REGISTRY[@]}" -eq 0 ]] \
        || { echo "registry not empty after reset: ${#DOCTOR_REGISTRY[@]}" >&2; exit 1; }
    [[ "$DOCTOR_ERRORS"   -eq 0 ]] \
        || { echo "DOCTOR_ERRORS not zero after reset" >&2; exit 1; }
) && pass "_registry_reset clears registry and counters" \
  || fail "_registry_reset did not clear registry"

# ── SC1: happy_path — all-healthy mocks → exit 0, no [FAIL] ─────────────────
# WHY SC1: on a healthy system doctor must exit 0 (D-05).
# Mocks: dgx_spark (580.142 driver), healthy docker (nvidia runtime present),
#        ok sysctl (262144), active systemctl, clean ss (avahi only on :5353),
#        held apt-mark (driver pin set).
(
    set +eu
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_SYSCTL_FIXTURE=ok
    export MOCK_SYSTEMCTL_FIXTURE=active
    export MOCK_SS_FIXTURE=clean
    export MOCK_APTMARK_FIXTURE=held
    export INSTALL_DIR=/tmp/doctor-test-happy-$$
    out="$(_run_doctor 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 0 ]] || { echo "exit=$rc (want 0); out=${out}" >&2; exit 1; }
    echo "$out" | grep -qiE '\[FAIL\]' && { echo "FAIL record found in happy path" >&2; exit 1; }
    exit 0
) && pass "happy_path: exit 0 no [FAIL]" \
  || fail "happy_path: want exit 0 and no [FAIL]"

# ── SC2: driver_590 — NVIDIA driver ≥590 → FAIL with 580 downgrade advice ────
# WHY SC2: driver 590+ breaks DGX Spark GB10 (CLAUDE.md §8 Driver 580 HOLD).
(
    set +eu
    export MOCK_NVIDIA_SMI_FIXTURE=driver_590
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_SYSCTL_FIXTURE=ok
    export MOCK_SS_FIXTURE=clean
    export INSTALL_DIR=/tmp/doctor-test-drv-$$
    out="$(_run_doctor 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 2 ]] || { echo "exit=$rc (want 2)"; exit 1; }
    echo "$out" | grep -qiE '\[FAIL\].*590' || { echo "no FAIL mentioning 590; out=$out" >&2; exit 1; }
    echo "$out" | grep -qi '580' || { echo "no mention of 580 in output; out=$out" >&2; exit 1; }
    exit 0
) && pass "driver_590: exit 2, [FAIL] mentions 590 and 580" \
  || fail "driver_590: want exit 2 and [FAIL] with 590+580"

# ── SC2: mdns_dead — failed systemctl + avahi-resolve timeout → WARN dns-mdns ─
# WHY SC2: dead mDNS = agmind-mdns.service failed while avahi is alive (CLAUDE.md §8).
# Mock limitation: systemctl mock returns same fixture for all is-active args —
# both avahi-daemon and agmind-mdns.service get "failed"; doctor reports the
# agmind-mdns path and emits WARN/FAIL for dns-mdns.
(
    set +eu
    export MOCK_AVAHI_FIXTURE=timeout
    export MOCK_SYSTEMCTL_FIXTURE=failed
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_SYSCTL_FIXTURE=ok
    export MOCK_SS_FIXTURE=clean
    export MOCK_APTMARK_FIXTURE=held
    export INSTALL_DIR=/tmp/doctor-test-mdns-$$
    out="$(_run_doctor 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -ge 1 ]] || { echo "exit=$rc (want ≥1); out=$out" >&2; exit 1; }
    echo "$out" | grep -qiE '\[WARN\]|\[FAIL\]' || { echo "no WARN/FAIL in output" >&2; exit 1; }
    # Assert fixable=true on a dns-mdns check via --json
    jout="$(_run_doctor --json 2>&1)"
    jdata="$(_strip_rc "$jout")"
    echo "$jdata" | python3 -c "
import json,sys
d=json.load(sys.stdin)
mdns=[c for c in d['checks'] if c['category']=='dns-mdns' and c['fixable']]
assert mdns, 'no fixable dns-mdns check found; checks=%r' % [(c['id'],c['severity'],c['fixable']) for c in d['checks'] if c['category']=='dns-mdns']
" 2>&1 || { echo "no fixable dns-mdns record in JSON" >&2; exit 1; }
    exit 0
) && pass "mdns_dead: exit ≥1, dns-mdns WARN/FAIL with fixable=true" \
  || fail "mdns_dead: want exit ≥1 and fixable dns-mdns record"

# ── SC2: foreign_5353 — non-avahi on :5353 → FAIL dns-mdns with NoMachine hint ─
# WHY SC2: second mDNS responder breaks avahi and all agmind-*.local aliases (CLAUDE.md §8).
(
    set +eu
    export MOCK_SS_FIXTURE=foreign_nx
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_SYSCTL_FIXTURE=ok
    export MOCK_APTMARK_FIXTURE=held
    export INSTALL_DIR=/tmp/doctor-test-foreign-$$
    out="$(_run_doctor 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 2 ]] || { echo "exit=$rc (want 2); out=$out" >&2; exit 1; }
    echo "$out" | grep -qiE '\[FAIL\]' || { echo "no [FAIL] in output" >&2; exit 1; }
    echo "$out" | grep -qiE 'nxserver|NoMachine|EnableLocalNetworkBroadcast' \
        || { echo "no NoMachine/nxserver mention; out=$out" >&2; exit 1; }
    exit 0
) && pass "foreign_5353: exit 2, [FAIL] mentions nxserver/NoMachine/EnableLocalNetworkBroadcast" \
  || fail "foreign_5353: want exit 2 and [FAIL] with NoMachine hint"

# ── SC2: missing_loadtest — absent loadtest dir → WARN install-state ─────────
# WHY SC2: missing scripts/loadtest = _copy_runtime_files whitelist regression (CLAUDE.md §8).
tmpinst="$(mktemp -d)"
echo "11" > "${tmpinst}/.install_phase"
(
    set +eu
    export INSTALL_DIR="$tmpinst"
    export MOCK_LOADTEST_DIR="${tmpinst}/scripts/loadtest"  # does not exist → WARN
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_SYSCTL_FIXTURE=ok
    export MOCK_SS_FIXTURE=clean
    export MOCK_APTMARK_FIXTURE=held
    out="$(_run_doctor 2>&1)"
    echo "$out" | grep -qiE '\[WARN\].*loadtest' \
        || { echo "no [WARN] mentioning loadtest; out=$out" >&2; exit 1; }
    exit 0
) && pass "missing_loadtest: [WARN] mentions loadtest" \
  || fail "missing_loadtest: want [WARN] mentioning loadtest"
rm -rf "$tmpinst"

# ── SC2: gpu_caps_missing — NVIDIA_DRIVER_CAPABILITIES absent → FAIL gpu ──────
# WHY SC2: without compute,utility caps GPU is invisible to CUDA (CLAUDE.md §8).
# MOCK strategy: exec fixture=gpu_fail → nvidia-smi -L inside container exits 1 →
#   doctor inspects env → finds only "graphics" (no "compute") → FAIL.
(
    set +eu
    export MOCK_DOCKER_FIXTURE=gpu_caps_missing
    export MOCK_DOCKER_EXEC_FIXTURE=gpu_fail
    export MOCK_DOCKER_PS_FIXTURE=running
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    export MOCK_SYSCTL_FIXTURE=ok
    export MOCK_SS_FIXTURE=clean
    export MOCK_APTMARK_FIXTURE=held
    export INSTALL_DIR=/tmp/doctor-test-gpu-$$
    out="$(_run_doctor 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 2 ]] || { echo "exit=$rc (want 2); out=$out" >&2; exit 1; }
    echo "$out" | grep -qi 'NVIDIA_DRIVER_CAPABILITIES' \
        || { echo "no NVIDIA_DRIVER_CAPABILITIES in output; out=$out" >&2; exit 1; }
    echo "$out" | grep -qiE '\[FAIL\]' || { echo "no [FAIL] in output" >&2; exit 1; }
    exit 0
) && pass "gpu_caps_missing: exit 2, [FAIL] mentions NVIDIA_DRIVER_CAPABILITIES" \
  || fail "gpu_caps_missing: want exit 2 and [FAIL] with NVIDIA_DRIVER_CAPABILITIES"

# ── SC2: mapcount_low — vm.max_map_count < 262144 → WARN kernel-params fixable ─
# WHY SC2: ES bootstrap hard-fails if vm.max_map_count < 262144 (CLAUDE.md §8).
(
    set +eu
    export MOCK_SYSCTL_FIXTURE=low
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_SS_FIXTURE=clean
    export MOCK_APTMARK_FIXTURE=held
    export INSTALL_DIR=/tmp/doctor-test-mmc-$$
    out="$(_run_doctor 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -ge 1 ]] || { echo "exit=$rc (want ≥1); out=$out" >&2; exit 1; }
    echo "$out" | grep -qiE '\[WARN\]|\[FAIL\]' || { echo "no WARN/FAIL for mapcount" >&2; exit 1; }
    # Assert fixable=true via --json
    jout="$(_run_doctor --json 2>&1)"
    jdata="$(_strip_rc "$jout")"
    echo "$jdata" | python3 -c "
import json,sys
d=json.load(sys.stdin)
kp=[c for c in d['checks'] if c['category']=='kernel-params' and c['fixable']]
assert kp, 'no fixable kernel-params check; checks=%r' % [(c['id'],c['severity'],c['fixable']) for c in d['checks'] if c['category']=='kernel-params']
" 2>&1 || { echo "no fixable kernel-params record" >&2; exit 1; }
    exit 0
) && pass "mapcount_low: exit ≥1, kernel-params WARN/FAIL with fixable=true" \
  || fail "mapcount_low: want exit ≥1 and fixable kernel-params record"

# ── SC4: json_valid — --json output parses correctly with all fields ──────────
# WHY SC4: structured JSON required for machine-readable consumption.
(
    set +eu
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_SYSCTL_FIXTURE=ok
    export MOCK_SS_FIXTURE=clean
    export MOCK_APTMARK_FIXTURE=held
    export INSTALL_DIR=/tmp/doctor-test-json-$$
    jout="$(_run_doctor --json 2>&1)"
    jdata="$(_strip_rc "$jout")"
    echo "$jdata" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'checks' in d, 'missing checks key'
assert 'status' in d, 'missing status key'
assert 'errors' in d, 'missing errors key'
assert 'warnings' in d, 'missing warnings key'
assert isinstance(d['checks'], list), 'checks not a list'
bad=[c for c in d['checks'] if not isinstance(c['fixable'], bool)]
assert not bad, 'fixable not bool in: %r' % bad
print('OK: %d checks, status=%s' % (len(d['checks']), d['status']))
" 2>&1 || exit 1
    exit 0
) && pass "json_valid: --json is valid JSON with checks/status/errors/warnings and bool fixable" \
  || fail "json_valid: --json failed validation"

# ── fix_dry_run / fix_apply: stubs (plan 01-03) ──────────────────────────────
# TODO: Case fix_dry_run — --fix --dry-run → MOCK_SYSCTL_CALLLOG empty (nothing written)
# TODO: Case fix_apply  — --fix → MOCK_SYSCTL_CALLLOG contains "sysctl -w ..."

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
