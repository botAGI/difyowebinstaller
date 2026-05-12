#!/usr/bin/env bash
# tests/unit/test_install_report.sh — RED unit tests for _build_install_report (Phase 4 Plan 04).
# Tests FAIL until install.sh implements _build_install_report + AGMIND_LIB_ONLY=1 guard.
# Cases: report_ok_valid_json · report_failed_path · report_handles_missing_jsonl
#        report_no_env_values · report_empty_services
# Exit: 0=PASS 1=FAIL 77=SKIP
set -uo pipefail  # NOT -e — capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
FIXTURES="${REPO_ROOT}/tests/fixtures/install_report"
export PATH="${MOCK_DIR}:${PATH}"

# Null colors
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_install_report"

# Check install.sh and fixtures exist
if [[ ! -f "${REPO_ROOT}/install.sh" ]]; then
    echo "SKIP: install.sh not found"
    exit 77
fi
if [[ ! -d "$FIXTURES" ]]; then
    echo "SKIP: fixtures not found at $FIXTURES"
    exit 77
fi

# ── Shared tmpdir ─────────────────────────────────────────────────────────────
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# ── Helper: source install.sh in lib-only mode ────────────────────────────────
# Plan 04-04 implements the AGMIND_LIB_ONLY=1 guard in install.sh.
# Until then: sourcing will either run the installer (aborted by subshell exit)
# or _build_install_report won't exist. Either way → RED.
_source_install_lib() {
    # shellcheck source=/dev/null
    AGMIND_LIB_ONLY=1 source "${REPO_ROOT}/install.sh" 2>/dev/null || true
}

# ── TC1: report_ok_valid_json ─────────────────────────────────────────────────
# Copy 3-phase jsonl, call _build_install_report ok "" →
# install-report.json is valid JSON with all schema keys
(
    set +e
    d="${TMP_ROOT}/tc1"
    mkdir -p "$d"
    cp "${FIXTURES}/.install-phases.jsonl" "${d}/.install-phases.jsonl"
    export INSTALL_DIR="$d"
    export VERSION="v3.1.0-test"
    export AGMIND_MODE="single"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=two_running
    export MOCK_DOCKER_HEALTH_FIXTURE=default
    _source_install_lib
    _build_install_report "ok" "" 2>/dev/null
    # Report must exist and be valid JSON
    [[ -f "${d}/install-report.json" ]] || { false; exit; }
    python3 -m json.tool < "${d}/install-report.json" > /dev/null 2>&1 || { false; exit; }
    # Schema validation
    python3 -c "
import json, sys
with open('${d}/install-report.json') as f:
    d = json.load(f)
assert d.get('schema_version') == 1, f'schema_version wrong: {d.get(\"schema_version\")}'
assert d.get('agmind_version') == 'v3.1.0-test', f'agmind_version wrong: {d.get(\"agmind_version\")}'
assert d.get('mode') == 'single', f'mode wrong: {d.get(\"mode\")}'
assert d.get('status') == 'ok', f'status wrong: {d.get(\"status\")}'
assert 'started' in d, 'missing started'
assert 'ended' in d, 'missing ended'
assert isinstance(d.get('duration_s'), int), 'duration_s not int'
assert d.get('failed_phase') is None, f'failed_phase should be null: {d.get(\"failed_phase\")}'
assert isinstance(d.get('phases'), list), 'phases not list'
assert len(d['phases']) == 3, f'expected 3 phases, got {len(d[\"phases\"])}'
for ph in d['phases']:
    for k in ('n','name','status','started','ended','duration_s'):
        assert k in ph, f'phase missing key {k}'
assert isinstance(d.get('services'), list), 'services not list'
assert isinstance(d.get('errors'), list), 'errors not list'
print('schema OK')
" 2>&1 | grep -q 'schema OK'
) && pass "TC1 report_ok_valid_json: _build_install_report ok → valid JSON with all schema keys" \
  || fail "TC1 report_ok_valid_json: missing/invalid JSON or wrong schema (RED until Plan 04)"

# ── TC2: report_failed_path ───────────────────────────────────────────────────
# 2-phase failed jsonl, call _build_install_report failed 2 →
# JSON has status=failed, failed_phase=2, non-empty errors[]
(
    set +e
    d="${TMP_ROOT}/tc2"
    mkdir -p "$d"
    cp "${FIXTURES}/.install-phases-failed.jsonl" "${d}/.install-phases.jsonl"
    export INSTALL_DIR="$d"
    export VERSION="v3.1.0-test"
    export AGMIND_MODE="single"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=two_running
    _source_install_lib
    _build_install_report "failed" "2" 2>/dev/null || true
    [[ -f "${d}/install-report.json" ]] || { false; exit; }
    python3 -m json.tool < "${d}/install-report.json" > /dev/null 2>&1 || { false; exit; }
    python3 -c "
import json, sys
with open('${d}/install-report.json') as f:
    d = json.load(f)
assert d.get('status') == 'failed', f'status should be failed: {d.get(\"status\")}'
fp = d.get('failed_phase')
assert str(fp) == '2' or fp == 2, f'failed_phase should be 2: {fp}'
assert len(d.get('errors', [])) > 0, 'errors[] should be non-empty on failed status'
print('failed path OK')
" 2>&1 | grep -q 'failed path OK'
) && pass "TC2 report_failed_path: status=failed, failed_phase=2, errors non-empty" \
  || fail "TC2 report_failed_path: wrong status/failed_phase/errors (RED until Plan 04)"

# ── TC3: report_handles_missing_jsonl ────────────────────────────────────────
# No jsonl file at all → report still valid JSON with phases=[]
(
    set +e
    d="${TMP_ROOT}/tc3"
    mkdir -p "$d"
    # Do NOT copy any jsonl file
    export INSTALL_DIR="$d"
    export VERSION="v3.1.0-test"
    export AGMIND_MODE="single"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=two_running
    _source_install_lib
    _build_install_report "failed" "1" 2>/dev/null || true
    [[ -f "${d}/install-report.json" ]] || { false; exit; }
    python3 -m json.tool < "${d}/install-report.json" > /dev/null 2>&1 || { false; exit; }
    python3 -c "
import json
with open('${d}/install-report.json') as f:
    d = json.load(f)
assert d.get('phases') == [], f'phases should be [] when jsonl absent: {d.get(\"phases\")}'
assert d.get('status') == 'failed', 'status should be failed'
print('missing jsonl OK')
" 2>&1 | grep -q 'missing jsonl OK'
) && pass "TC3 report_handles_missing_jsonl: no jsonl → valid JSON with phases=[]" \
  || fail "TC3 report_handles_missing_jsonl: missing jsonl not handled gracefully (RED until Plan 04)"

# ── TC4: report_no_env_values ─────────────────────────────────────────────────
# services[] built from docker ps Names+State only — no env values in JSON output
(
    set +e
    d="${TMP_ROOT}/tc4"
    mkdir -p "$d"
    cp "${FIXTURES}/.install-phases.jsonl" "${d}/.install-phases.jsonl"
    # Put a "secret" in env so we can detect leakage
    cat > "${d}/.env" <<'ENVEOF'
DB_PASSWORD=supersecret_fixture_leak_test
SECRET_KEY=anothersecret_fixture
ENVEOF
    export INSTALL_DIR="$d"
    export VERSION="v3.1.0-test"
    export AGMIND_MODE="single"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=two_running
    _source_install_lib
    _build_install_report "ok" "" 2>/dev/null
    [[ -f "${d}/install-report.json" ]] || { false; exit; }
    # Assert no secret values in output
    ! grep -q 'supersecret_fixture_leak_test' "${d}/install-report.json" \
        && ! grep -q 'anothersecret_fixture' "${d}/install-report.json"
) && pass "TC4 report_no_env_values: install-report.json contains no .env secret values" \
  || fail "TC4 report_no_env_values: secret value leaked into install-report.json (RED until Plan 04)"

# ── TC5: report_empty_services ────────────────────────────────────────────────
# MOCK_DOCKER_INFO_EXIT=1 (docker daemon down) → services=[], report still valid JSON
# Also assert started == first jsonl line started field
(
    set +e
    d="${TMP_ROOT}/tc5"
    mkdir -p "$d"
    cp "${FIXTURES}/.install-phases.jsonl" "${d}/.install-phases.jsonl"
    export INSTALL_DIR="$d"
    export VERSION="v3.1.0-test"
    export AGMIND_MODE="single"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_INFO_EXIT=1
    unset MOCK_DOCKER_PS_FIXTURE 2>/dev/null || true
    _source_install_lib
    _build_install_report "ok" "" 2>/dev/null
    [[ -f "${d}/install-report.json" ]] || { false; exit; }
    python3 -m json.tool < "${d}/install-report.json" > /dev/null 2>&1 || { false; exit; }
    python3 -c "
import json
with open('${d}/install-report.json') as f:
    d = json.load(f)
assert d.get('services') == [], f'services should be [] when docker down: {d.get(\"services\")}'
# started should equal first jsonl line started field
assert d.get('started') == '2026-05-12T10:00:00Z', f'started mismatch: {d.get(\"started\")}'
print('empty services OK')
" 2>&1 | grep -q 'empty services OK'
) && pass "TC5 report_empty_services: docker down → services=[], started==first-jsonl-started" \
  || fail "TC5 report_empty_services: services not empty or started mismatch (RED until Plan 04)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "## test_install_report: ${PASS} PASS, ${FAIL} FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
