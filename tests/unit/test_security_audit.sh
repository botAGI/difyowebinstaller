#!/usr/bin/env bash
# tests/unit/test_security_audit.sh — RED tests for Phase 7 SC2: agmind security audit.
# All 8 cases FAIL until lib/security.sh::security_audit() is implemented (07-03).
# Mirrors tests/unit/test_doctor.sh harness + mock conventions.
# Exit: 0=PASS 1=FAIL 77=SKIP
#
# Cases:
#   audit_clean_exit0           — clean fixture → exit 0, no high/critical findings
#   audit_finds_exposed_port    — compose with portainer on 0.0.0.0 → severity=critical, exit 1
#   audit_finds_rw_sock         — docker mock returns rw socket mount → severity=high, exit 1
#   audit_finds_weak_env        — .env.weak fixture → high finding; value NOT in output (SC2 invariant)
#   audit_finds_bad_perms       — MOCK_STAT_FIXTURE=644 on credentials.txt → high, exit 1
#   audit_json_valid            — --json output parseable; has findings[] + summary{block_severity}
#   audit_block_severity_env    — AGMIND_SECURITY_BLOCK=critical + high-only findings → exit 0
#   audit_no_docker_graceful    — docker unavailable → docker checks skip, no crash
set -uo pipefail   # NOT -e — capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"

# Null out colors so test output is plain text
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_security_audit"

# Require python3 for JSON validation test
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 77
fi

# ── _run_audit helper ──────────────────────────────────────────────────────────
# Runs security_audit in a clean subshell with mocks on PATH.
# Callers export MOCK_* + INSTALL_DIR before calling. Args passed to security_audit.
# Captures combined stdout+stderr and appends RC=<n> on the last line.
_run_audit() {
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/doctor.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/security.sh"
        security_audit "$@"
        echo "RC=$?"
    ) 2>&1
}

# Helper: extract RC value from _run_audit output
_rc_of() { grep -oE 'RC=[0-9]+' <<< "$1" | tail -1 | cut -d= -f2; }

# Helper: extract JSON object from output (starts with '{')
_strip_rc() { grep '^{' <<< "$1" | tail -1; }

# Fake weak sentinel values present in .env.weak — used in SC2 invariant assertions
FAKE_WEAK_VALUE_1="changeme"
FAKE_WEAK_VALUE_2="abc123"

# ── Case: audit_clean_exit0 — clean fixture → exit 0 ─────────────────────────
# A compose with admin port bound to 127.0.0.1, no weak env, stat=640 → exit 0.
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    mkdir -p "${_tmp}/docker"
    # Clean compose: portainer bound to 127.0.0.1 (not 0.0.0.0)
    cat > "${_tmp}/docker/docker-compose.yml" <<'COMPOSE'
version: "3.8"
services:
  portainer:
    image: portainer/portainer-ce:2.41.1
    ports:
      - "127.0.0.1:9443:9443"
COMPOSE
    # Clean .env: no weak values
    cat > "${_tmp}/docker/.env" <<'DOTENV'
SECRET_KEY=SomeLongSecureRandomStringWith32chars1234
REDIS_PASSWORD=AnotherLongSecurePassword5678
DOTENV
    export INSTALL_DIR="$_tmp"
    # Stat mock: credentials.txt perm = 640 (OK)
    export MOCK_STAT_FIXTURE=640
    export MOCK_DOCKER_FIXTURE=healthy
    out="$(_run_audit 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 0 ]] || { echo "exit=$rc (want 0); out=${out}" >&2; exit 1; }
    exit 0
) && pass "audit_clean_exit0: exit 0 on clean fixture" \
  || fail "audit_clean_exit0: want exit 0 (security_audit not yet implemented)"

# ── Case: audit_finds_exposed_port — 0.0.0.0-bound admin UI → critical, exit 1 ─
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    mkdir -p "${_tmp}/docker"
    # Use the fixture compose with portainer on 0.0.0.0:9443
    cp "${REPO_ROOT}/tests/fixtures/security_audit/docker-compose.yml" \
       "${_tmp}/docker/docker-compose.yml"
    cat > "${_tmp}/docker/.env" <<'DOTENV'
SECRET_KEY=SomeLongSecureRandomStringWith32chars1234
REDIS_PASSWORD=AnotherLongSecurePassword5678
DOTENV
    export INSTALL_DIR="$_tmp"
    export MOCK_STAT_FIXTURE=640
    export MOCK_DOCKER_FIXTURE=healthy
    out="$(_run_audit 2>&1)"
    rc="$(_rc_of "$out")"
    # Expect exit 1 (findings ≥ block_severity) and a critical/high finding
    [[ "$rc" -eq 1 ]] || { echo "exit=$rc (want 1); out=${out}" >&2; exit 1; }
    echo "$out" | grep -qiE 'critical|high' || { echo "no critical/high in output; out=$out" >&2; exit 1; }
    exit 0
) && pass "audit_finds_exposed_port: exit 1 + critical/high finding" \
  || fail "audit_finds_exposed_port: want exit 1 with critical/high finding (security_audit not yet implemented)"

# ── Case: audit_finds_rw_sock — docker inspect → rw docker.sock → high, exit 1 ─
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    mkdir -p "${_tmp}/docker"
    cat > "${_tmp}/docker/docker-compose.yml" <<'COMPOSE'
version: "3.8"
services:
  portainer:
    image: portainer/portainer-ce:2.41.1
    ports:
      - "127.0.0.1:9443:9443"
COMPOSE
    cat > "${_tmp}/docker/.env" <<'DOTENV'
SECRET_KEY=SomeLongSecureRandomStringWith32chars1234
REDIS_PASSWORD=AnotherLongSecurePassword5678
DOTENV
    export INSTALL_DIR="$_tmp"
    export MOCK_STAT_FIXTURE=640
    # Mock docker inspect to return a container with rw docker.sock mount
    export MOCK_DOCKER_FIXTURE=sock_rw
    out="$(_run_audit 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 1 ]] || { echo "exit=$rc (want 1); out=${out}" >&2; exit 1; }
    echo "$out" | grep -qiE 'high|docker\.sock|rw' \
        || { echo "no high/docker.sock/rw mention; out=$out" >&2; exit 1; }
    exit 0
) && pass "audit_finds_rw_sock: exit 1 + high finding for rw docker.sock" \
  || fail "audit_finds_rw_sock: want exit 1 with high severity (security_audit not yet implemented)"

# ── Case: audit_finds_weak_env — .env.weak → high; VALUES not in output (SC2) ─
# SC2 invariant: grep -F "$FAKE_WEAK_VALUE" <output> MUST be empty.
# The assertion below (grep -qF) is the explicit SC2 contract in this test file.
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    mkdir -p "${_tmp}/docker"
    cat > "${_tmp}/docker/docker-compose.yml" <<'COMPOSE'
version: "3.8"
services:
  portainer:
    image: portainer/portainer-ce:2.41.1
    ports:
      - "127.0.0.1:9443:9443"
COMPOSE
    # Use the .env.weak fixture (has SECRET_KEY=changeme, SOME_PASSWORD=abc123)
    cp "${REPO_ROOT}/tests/fixtures/security_audit/.env.weak" \
       "${_tmp}/docker/.env"
    export INSTALL_DIR="$_tmp"
    export MOCK_STAT_FIXTURE=640
    export MOCK_DOCKER_FIXTURE=healthy
    out="$(_run_audit 2>&1)"
    rc="$(_rc_of "$out")"
    # Expect exit 1 (weak secrets found, high severity)
    [[ "$rc" -eq 1 ]] || { echo "exit=$rc (want 1); out=${out}" >&2; exit 1; }
    # SC2 invariant: secret VALUES must NOT appear in output
    if grep -qF "${FAKE_WEAK_VALUE_1}" <<< "$out"; then
        echo "FAIL: secret value '${FAKE_WEAK_VALUE_1}' appeared in audit output (SC2 violation)" >&2
        exit 1
    fi
    if grep -qF "${FAKE_WEAK_VALUE_2}" <<< "$out"; then
        echo "FAIL: secret value '${FAKE_WEAK_VALUE_2}' appeared in audit output (SC2 violation)" >&2
        exit 1
    fi
    # Must mention the key name (not value) and severity=high
    echo "$out" | grep -qiE 'SECRET_KEY|SOME_PASSWORD' \
        || { echo "no key name in output; out=$out" >&2; exit 1; }
    echo "$out" | grep -qiE 'high|weak' \
        || { echo "no high/weak in output; out=$out" >&2; exit 1; }
    exit 0
) && pass "audit_finds_weak_env: exit 1 + high; values NOT in output (SC2 invariant)" \
  || fail "audit_finds_weak_env: SC2 invariant violation or wrong exit (security_audit not yet implemented)"

# ── Case: audit_finds_bad_perms — stat=644 on credentials.txt → high, exit 1 ──
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    mkdir -p "${_tmp}/docker"
    cat > "${_tmp}/docker/docker-compose.yml" <<'COMPOSE'
version: "3.8"
services:
  portainer:
    image: portainer/portainer-ce:2.41.1
    ports:
      - "127.0.0.1:9443:9443"
COMPOSE
    cat > "${_tmp}/docker/.env" <<'DOTENV'
SECRET_KEY=SomeLongSecureRandomStringWith32chars1234
REDIS_PASSWORD=AnotherLongSecurePassword5678
DOTENV
    # Plant a fake credentials.txt so the file_perms check has something to stat
    cp "${REPO_ROOT}/tests/fixtures/security_audit/credentials.txt" \
       "${_tmp}/credentials.txt"
    export INSTALL_DIR="$_tmp"
    # MOCK_STAT_FIXTURE=644 → file_perms check sees 644 (world-readable)
    export MOCK_STAT_FIXTURE=644
    export MOCK_DOCKER_FIXTURE=healthy
    out="$(_run_audit 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 1 ]] || { echo "exit=$rc (want 1); out=${out}" >&2; exit 1; }
    echo "$out" | grep -qiE 'high|perm|chmod|644' \
        || { echo "no high/perm/chmod/644 in output; out=$out" >&2; exit 1; }
    exit 0
) && pass "audit_finds_bad_perms: exit 1 + high finding for 644 credentials.txt" \
  || fail "audit_finds_bad_perms: want exit 1 with high perm finding (security_audit not yet implemented)"

# ── Case: audit_json_valid — --json output is valid JSON with required keys ────
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    mkdir -p "${_tmp}/docker"
    cp "${REPO_ROOT}/tests/fixtures/security_audit/docker-compose.yml" \
       "${_tmp}/docker/docker-compose.yml"
    cp "${REPO_ROOT}/tests/fixtures/security_audit/.env.weak" \
       "${_tmp}/docker/.env"
    export INSTALL_DIR="$_tmp"
    export MOCK_STAT_FIXTURE=640
    export MOCK_DOCKER_FIXTURE=healthy
    jout="$(_run_audit --json 2>&1)"
    jdata="$(_strip_rc "$jout")"
    echo "$jdata" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert isinstance(d.get('findings'), list), 'findings must be a list; got: %r' % type(d.get('findings'))
assert 'summary' in d, 'missing summary key; keys: %r' % list(d.keys())
assert 'block_severity' in d['summary'], 'summary missing block_severity; summary keys: %r' % list(d['summary'].keys())
print('OK: %d findings, block_severity=%s' % (len(d['findings']), d['summary']['block_severity']))
" 2>&1 || { echo "JSON validation failed; jdata=${jdata}" >&2; exit 1; }
    exit 0
) && pass "audit_json_valid: --json is valid JSON with findings[] + summary{block_severity}" \
  || fail "audit_json_valid: --json validation failed (security_audit not yet implemented)"

# ── Case: audit_block_severity_env — AGMIND_SECURITY_BLOCK=critical → exit 0 ──
# When block threshold is critical and worst finding is only high → exit 0.
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    mkdir -p "${_tmp}/docker"
    cp "${REPO_ROOT}/tests/fixtures/security_audit/docker-compose.yml" \
       "${_tmp}/docker/docker-compose.yml"
    cp "${REPO_ROOT}/tests/fixtures/security_audit/.env.weak" \
       "${_tmp}/docker/.env"
    export INSTALL_DIR="$_tmp"
    export MOCK_STAT_FIXTURE=640
    export MOCK_DOCKER_FIXTURE=healthy
    # With block=critical: high findings are listed but do NOT cause exit 1
    export AGMIND_SECURITY_BLOCK=critical
    out="$(_run_audit 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 0 ]] || { echo "exit=$rc (want 0 with block=critical); out=${out}" >&2; exit 1; }
    exit 0
) && pass "audit_block_severity_env: AGMIND_SECURITY_BLOCK=critical + high-only → exit 0" \
  || fail "audit_block_severity_env: want exit 0 (security_audit not yet implemented)"

# ── Case: audit_no_docker_graceful — docker down → docker checks skip, no crash ─
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    mkdir -p "${_tmp}/docker"
    cat > "${_tmp}/docker/docker-compose.yml" <<'COMPOSE'
version: "3.8"
services:
  portainer:
    image: portainer/portainer-ce:2.41.1
    ports:
      - "127.0.0.1:9443:9443"
COMPOSE
    cat > "${_tmp}/docker/.env" <<'DOTENV'
SECRET_KEY=SomeLongSecureRandomStringWith32chars1234
REDIS_PASSWORD=AnotherLongSecurePassword5678
DOTENV
    export INSTALL_DIR="$_tmp"
    export MOCK_STAT_FIXTURE=640
    # Simulate docker daemon down
    export MOCK_DOCKER_FIXTURE=no_daemon
    out="$(_run_audit 2>&1)"
    rc="$(_rc_of "$out")"
    # Must NOT crash (rc=127 = command not found, segfault = bad; 0/1/2 = ok)
    [[ "$rc" -eq 0 || "$rc" -eq 1 || "$rc" -eq 2 ]] \
        || { echo "crash rc=$rc (want 0/1/2); out=${out}" >&2; exit 1; }
    # Docker-dependent checks should be skipped (some skip/info line expected)
    echo "$out" | grep -qiE 'skip|docker.*unavail|docker.*down|не.*доступен' \
        || { echo "no skip/unavail mention for docker down; out=$out" >&2; exit 1; }
    exit 0
) && pass "audit_no_docker_graceful: docker down → docker checks skip, no crash" \
  || fail "audit_no_docker_graceful: crash or no skip msg (security_audit not yet implemented)"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
