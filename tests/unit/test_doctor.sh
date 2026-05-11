#!/usr/bin/env bash
# tests/unit/test_doctor.sh — unit coverage for Phase 1 `agmind doctor` (lib/doctor.sh).
# Runs without root. Uses tests/mocks/ via PATH prepend. Exit 77 = SKIP; 0 = PASS; 1 = FAIL.
# Full SC2-class cases (driver_590, mdns_dead, foreign_5353, missing_loadtest,
# gpu_caps_missing, mapcount_low) added in 01-02/01-03.
set -uo pipefail   # NOT -e — we capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/detect.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/health.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/doctor.sh"

# Null out colors so test output is plain text (no escape sequences in diffs)
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_doctor"

# ── Case 1: skeleton happy path — doctor_run exits 0 ─────────────────────────
# WHY: Wave 0 requirement — skeleton must return 0 with all-SKIP records.
rc=0
(
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/doctor.sh"
    doctor_run >/dev/null 2>&1
) || rc=$?
[[ $rc -eq 0 ]] \
    && pass "skeleton: doctor_run exits 0" \
    || fail "skeleton: doctor_run exit=$rc (want 0)"

# ── Case 2: --json output is valid JSON ───────────────────────────────────────
# WHY: _registry_render_json must produce parseable JSON (D-03).
json_out=""
json_out="$(bash -c "
    source '${REPO_ROOT}/lib/doctor.sh'
    doctor_run --json
" 2>/dev/null)" || true
if python3 -c 'import json,sys; json.load(sys.stdin)' <<< "$json_out" 2>/dev/null; then
    pass "--json is valid JSON"
else
    fail "--json is not valid JSON (output: ${json_out:0:80})"
fi

# ── Case 3: --json errors=0 and warnings=0 on skeleton ───────────────────────
# WHY: all stubs add SKIP records — no FAIL or WARN expected.
if python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["errors"]==0 and d["warnings"]==0, \
    "errors=%d warnings=%d" % (d["errors"], d["warnings"])
' <<< "$json_out" 2>/dev/null; then
    pass "--json has errors=0 warnings=0"
else
    fail "--json has non-zero errors or warnings on skeleton"
fi

# ── Case 4: --json status=ok on skeleton ─────────────────────────────────────
if python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["status"]=="ok", "status=%s" % d["status"]
' <<< "$json_out" 2>/dev/null; then
    pass "--json status=ok"
else
    fail "--json status is not ok on skeleton"
fi

# ── Case 5: --json checks array contains 13 entries (one stub per category) ──
if python3 -c '
import json,sys
d=json.load(sys.stdin)
n=len(d["checks"])
assert n==13, "want 13 checks, got %d" % n
' <<< "$json_out" 2>/dev/null; then
    pass "--json has 13 check entries (one per category stub)"
else
    fail "--json does not have 13 check entries"
fi

# ── Case 6: all checks have severity=SKIP on skeleton ────────────────────────
if python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=[c for c in d["checks"] if c["severity"]!="SKIP"]
assert not bad, "non-SKIP checks: %r" % bad
' <<< "$json_out" 2>/dev/null; then
    pass "all skeleton checks have severity=SKIP"
else
    fail "some skeleton checks have non-SKIP severity"
fi

# ── Case 7: _registry_add / _registry_count round-trip ───────────────────────
# WHY: registry helpers must tally WARN and FAIL correctly for exit-code D-05.
(
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

# ── Case 8: _registry_reset clears DOCTOR_REGISTRY ───────────────────────────
(
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

# ── TODO: SC2 cases (01-02 fills these) ──────────────────────────────────────
# TODO: Case driver_590 — MOCK_NVIDIA_SMI_FIXTURE=driver_590 → FAIL arch-driver
# TODO: Case mdns_dead  — MOCK_AVAHI_FIXTURE=timeout MOCK_SYSTEMCTL_FIXTURE=failed → FAIL dns-mdns
# TODO: Case foreign_5353 — MOCK_SS_FIXTURE=foreign_nx → FAIL dns-mdns, fixable=false
# TODO: Case missing_loadtest — MOCK_LOADTEST_MISSING=true → WARN install-state
# TODO: Case gpu_caps_missing — MOCK_DOCKER_FIXTURE=gpu_caps_missing → FAIL gpu
# TODO: Case mapcount_low — MOCK_SYSCTL_FIXTURE=low → WARN kernel-params, fixable=true
# TODO: Case fix_dry_run — --fix --dry-run → MOCK_SYSCTL_CALLLOG empty (nothing written)
# TODO: Case fix_apply  — --fix → MOCK_SYSCTL_CALLLOG contains "sysctl -w ..."

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
