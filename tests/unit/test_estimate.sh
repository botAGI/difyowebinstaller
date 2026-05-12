#!/usr/bin/env bash
# test_estimate.sh — RED (Wave-0) tests for Phase 9 agmind estimate / lib/estimate.sh.
#
# Covers:
#   SC3: agmind estimate [<profile>] [--json] — RAM/disk/GPU estimate from mem_limit values,
#        comparison with available resources, --json output, LLM_ON_PEER exclusion, etc.
#
# These tests FAIL initially (RED) because:
#   • agmind estimate is not yet dispatched in scripts/agmind.sh (09-04 adds it).
#   • lib/estimate.sh does not exist yet (09-04 creates it).
#
# Mocking: prepend tests/mocks/ to PATH; set MOCK_FREE_FIXTURE / MOCK_DF_FIXTURE /
#   MOCK_NVIDIA_SMI_FIXTURE env vars. Fixture compose: tests/fixtures/estimate/
# Install dir: a tmpdir with docker/docker-compose.yml (fixture copy) + docker/.env (per-case).
#
# Template: tests/unit/test_status.sh (PATH-prepend mocks + tmpdir INSTALL_DIR pattern).
# Exit: 0 = all PASS, non-zero = ≥1 FAIL, 77 = SKIP.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/estimate"
AGMIND_SH="${REPO_ROOT}/scripts/agmind.sh"

# Skip if agmind.sh missing
if [[ ! -f "$AGMIND_SH" ]]; then
    echo "SKIP: ${AGMIND_SH} not found"
    exit 77
fi
# Skip if python3 missing (--json validation requires it)
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not found (required for JSON assertion)"
    exit 77
fi
# Skip if fixture missing
if [[ ! -f "${FIXTURE_DIR}/docker-compose.yml" ]]; then
    echo "SKIP: fixture ${FIXTURE_DIR}/docker-compose.yml not found"
    exit 77
fi

echo "## test_estimate"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

# ── Shared tmpdir + fake runtime root ────────────────────────────────────────
# agmind.sh sources "${AGMIND_DIR}/scripts/health.sh" at startup (SCRIPTS_DIR override
# is ineffective — agmind.sh resets SCRIPTS_DIR="${AGMIND_DIR}/scripts" on line 11).
# Mirror the wrapper_dispatch approach from test_status.sh: build a fake AGMIND_DIR with
# scripts/ symlinked to lib/, so agmind.sh finds health.sh et al. without root install.
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Build fake runtime root: AGMIND_DIR layout after install
FAKE_AGMIND_DIR="${TEST_TMPDIR}/agmind_runtime"
mkdir -p "${FAKE_AGMIND_DIR}/scripts"
# Symlink all lib/*.sh into scripts/ so agmind.sh can source them
for _lib in "${REPO_ROOT}"/lib/*.sh; do
    ln -sf "$_lib" "${FAKE_AGMIND_DIR}/scripts/$(basename "$_lib")"
done

# _make_install_dir <tmpbase> <env_content_string>
# Creates $tmpbase/docker/ with docker-compose.yml (from fixture) and a per-case .env.
_make_install_dir() {
    local base="$1" env_content="$2"
    mkdir -p "${base}/docker"
    cp "${FIXTURE_DIR}/docker-compose.yml" "${base}/docker/docker-compose.yml"
    printf '%s\n' "$env_content" > "${base}/docker/.env"
}

# _run_estimate <install_dir> [args...]
# Runs agmind.sh estimate with mocks on PATH, AGMIND_DIR=fake runtime, INSTALL_DIR set.
# Captures combined stdout+stderr; appends RC=<n> on last line.
_run_estimate() {
    local install_dir="$1"; shift
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export INSTALL_DIR="${install_dir}"
        export AGMIND_DIR="${FAKE_AGMIND_DIR}"
        # Null out colors so output is plain text
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        bash "${AGMIND_SH}" estimate "$@"
        echo "RC=$?"
    ) 2>&1
}

# _rc_of <output>
_rc_of() { printf '%s\n' "$1" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2; }

# _json_of <output> — extract first line starting with {
_json_of() { printf '%s\n' "$1" | grep '^{' | tail -1; }

# ── Fixture mem-math (mirrored from fixture comments) ──────────────────────────
# Always-on: api(2) + worker(2) + db(4) + redis(1) + nginx(0.25) = 9.25 GiB
# rag set: vllm(96) + litellm(1) + weaviate(4) + docling(8) + vllm-embed(3) = 112 GiB
# rag total: 9.25 + 112 = 121.25 GiB
# rag + LLM_ON_PEER: 9.25 + 1 + 4 + 8 + 3 = 25.25 GiB (no vllm)
# core set: vllm(96) + litellm(1) = 97 GiB
# core total: 9.25 + 97 = 106.25 GiB
# core + LLM_ON_PEER: 9.25 + 1 = 10.25 GiB

# ── Case 1: estimate_sums_mem_limits ──────────────────────────────────────────
# agmind estimate rag --json against the fixture → RAM total ≈ 121.25 GiB
# RED: agmind estimate not implemented yet.
(
    set +e
    CASE_DIR="$(mktemp -d)"
    _make_install_dir "$CASE_DIR" "DEPLOY_PROFILE=rag
LLM_ON_PEER=false
COMPOSE_PROFILES=vllm,litellm,weaviate,docling,vllm-embed"
    export MOCK_FREE_FIXTURE=spark
    export MOCK_DF_FIXTURE=plenty
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    out="$(_run_estimate "$CASE_DIR" rag --json)"
    rc="$(_rc_of "$out")"
    j="$(_json_of "$out")"
    [[ -n "$j" ]] || { echo "  FAIL: no JSON in output; out=${out}" >&2; exit 1; }
    # Assert: total.ram_gib is in range [121, 122] (rag sum = 121.25 GiB)
    python3 -c "
import json, sys
d = json.loads('''${j}''')
ram = d['total']['ram_gib']
# rag fixture sum: always-on 9.25 + rag-set 112 = 121.25 GiB
assert 121 <= ram <= 122, 'ram_gib=%r expected in [121,122]' % ram
print('  PASS: total.ram_gib=%r in [121,122]' % ram)
" 2>&1 || { echo "  FAIL: RAM sum assertion failed; json=${j}" >&2; exit 1; }
    rm -rf "$CASE_DIR"
    exit 0
) && pass "estimate_sums_mem_limits: rag RAM total ≈ 121.25 GiB from fixture mem_limit values" \
  || fail "estimate_sums_mem_limits: expected total.ram_gib ≈ 121 (RED — agmind estimate not implemented)"

# ── Case 2: estimate_json_valid ───────────────────────────────────────────────
# agmind estimate rag --json → valid JSON with required top-level keys.
# RED: agmind estimate not implemented.
(
    set +e
    CASE_DIR="$(mktemp -d)"
    _make_install_dir "$CASE_DIR" "DEPLOY_PROFILE=rag
LLM_ON_PEER=false"
    export MOCK_FREE_FIXTURE=spark
    export MOCK_DF_FIXTURE=plenty
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    out="$(_run_estimate "$CASE_DIR" rag --json)"
    j="$(_json_of "$out")"
    [[ -n "$j" ]] || { echo "  FAIL: no JSON in output; out=${out}" >&2; exit 1; }
    python3 -c "
import json, sys
d = json.loads('''${j}''')
required = {'profile', 'services', 'total', 'available', 'warnings'}
missing = required - set(d.keys())
assert not missing, 'missing keys: %s' % missing
assert isinstance(d['services'], list), 'services must be a list'
assert isinstance(d['warnings'], list), 'warnings must be a list'
assert isinstance(d['total'], dict), 'total must be a dict'
assert 'ram_gib' in d['total'], 'total.ram_gib missing'
assert 'ram_gib' in d['available'], 'available.ram_gib missing'
print('  PASS: JSON has all required keys with correct types')
" 2>&1 || { echo "  FAIL: JSON structure invalid; json=${j}" >&2; exit 1; }
    rm -rf "$CASE_DIR"
    exit 0
) && pass "estimate_json_valid: --json output has profile/services/total/available/warnings" \
  || fail "estimate_json_valid: JSON structure invalid (RED — agmind estimate not implemented)"

# ── Case 3: estimate_warns_over ───────────────────────────────────────────────
# Fixture rag sum (121 GiB) > mocked 32 GiB available → warnings non-empty + exit 1.
# RED: agmind estimate not implemented.
(
    set +e
    CASE_DIR="$(mktemp -d)"
    _make_install_dir "$CASE_DIR" "DEPLOY_PROFILE=rag
LLM_ON_PEER=false"
    export MOCK_FREE_FIXTURE=over   # 32 GiB total < 121 GiB needed
    export MOCK_DF_FIXTURE=plenty
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    out="$(_run_estimate "$CASE_DIR" rag --json)"
    rc="$(_rc_of "$out")"
    j="$(_json_of "$out")"
    [[ -n "$j" ]] || { echo "  FAIL: no JSON; out=${out}" >&2; exit 1; }
    python3 -c "
import json, sys
d = json.loads('''${j}''')
warnings = d.get('warnings', [])
assert len(warnings) > 0, 'warnings empty but RAM 121 GiB > available 32 GiB'
print('  PASS: warnings non-empty:', warnings)
" 2>&1 || { echo "  FAIL: warnings should be non-empty; json=${j}" >&2; exit 1; }
    # Also assert exit 1 when over
    [[ "$rc" -eq 1 ]] || { echo "  FAIL: rc=${rc} want 1 (RAM over limit)"; exit 1; }
    rm -rf "$CASE_DIR"
    exit 0
) && pass "estimate_warns_over: 32 GiB available < 121 GiB needed → warnings + exit 1" \
  || fail "estimate_warns_over: expected warnings+exit-1 when RAM over (RED — not implemented)"

# ── Case 4: estimate_active_default ──────────────────────────────────────────
# No profile arg → reads DEPLOY_PROFILE=core from .env → estimates core.
# RED: agmind estimate not implemented.
(
    set +e
    CASE_DIR="$(mktemp -d)"
    _make_install_dir "$CASE_DIR" "DEPLOY_PROFILE=core
LLM_ON_PEER=false"
    export MOCK_FREE_FIXTURE=spark
    export MOCK_DF_FIXTURE=plenty
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    # Run with NO profile arg — should default to DEPLOY_PROFILE from .env
    out="$(_run_estimate "$CASE_DIR" --json)"
    j="$(_json_of "$out")"
    [[ -n "$j" ]] || { echo "  FAIL: no JSON; out=${out}" >&2; exit 1; }
    python3 -c "
import json, sys
d = json.loads('''${j}''')
profile = d.get('profile', '')
assert profile == 'core', 'profile=%r want core' % profile
print('  PASS: profile=%r (read from .env DEPLOY_PROFILE)' % profile)
" 2>&1 || { echo "  FAIL: expected profile=core from .env; json=${j}" >&2; exit 1; }
    rm -rf "$CASE_DIR"
    exit 0
) && pass "estimate_active_default: no arg → reads DEPLOY_PROFILE=core from .env" \
  || fail "estimate_active_default: expected profile=core from .env (RED — not implemented)"

# ── Case 5: estimate_not_installed_fallback ───────────────────────────────────
# INSTALL_DIR has no docker/ → falls back to templates/docker-compose.yml, exit 0.
# RED: agmind estimate not implemented.
(
    set +e
    CASE_DIR="$(mktemp -d)"
    # NO docker/ subdir — estimate must fall back to templates/
    export MOCK_FREE_FIXTURE=spark
    export MOCK_DF_FIXTURE=plenty
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    out="$(_run_estimate "$CASE_DIR" full --json)"
    rc="$(_rc_of "$out")"
    j="$(_json_of "$out")"
    # Should exit 0 (graceful fallback) and return valid JSON
    [[ "$rc" -eq 0 ]] || { echo "  FAIL: rc=${rc} want 0 (graceful fallback); out=${out}" >&2; exit 1; }
    [[ -n "$j" ]] || { echo "  FAIL: no JSON in fallback output; out=${out}" >&2; exit 1; }
    python3 -c "
import json, sys
d = json.loads('''${j}''')
profile = d.get('profile', '')
assert profile == 'full', 'profile=%r want full' % profile
print('  PASS: fallback to templates; profile=%r' % profile)
" 2>&1 || { echo "  FAIL: fallback JSON invalid; json=${j}" >&2; exit 1; }
    rm -rf "$CASE_DIR"
    exit 0
) && pass "estimate_not_installed_fallback: no docker/ → fallback to templates/, exit 0" \
  || fail "estimate_not_installed_fallback: expected graceful fallback (RED — not implemented)"

# ── Case 6: estimate_excludes_peer_vllm ──────────────────────────────────────
# LLM_ON_PEER=true → vllm service excluded from master RAM total.
# Fixture core: always-on(9.25) + vllm(96) + litellm(1) = 106.25 GiB without peer exclusion.
# With LLM_ON_PEER=true: always-on(9.25) + litellm(1) = 10.25 GiB.
# RED: agmind estimate not implemented.
(
    set +e
    CASE_DIR="$(mktemp -d)"
    _make_install_dir "$CASE_DIR" "DEPLOY_PROFILE=core
LLM_ON_PEER=true"
    export MOCK_FREE_FIXTURE=spark
    export MOCK_DF_FIXTURE=plenty
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    out="$(_run_estimate "$CASE_DIR" core --json)"
    j="$(_json_of "$out")"
    [[ -n "$j" ]] || { echo "  FAIL: no JSON; out=${out}" >&2; exit 1; }
    python3 -c "
import json, sys
d = json.loads('''${j}''')
services = d.get('services', [])
service_names = [s.get('name','') for s in services]
# vllm must NOT appear in master estimate when LLM_ON_PEER=true
assert 'vllm' not in service_names, 'vllm should be excluded on master with LLM_ON_PEER=true; got: %s' % service_names
# RAM total must be < 50 GiB (without 96g vllm: 9.25 + 1 = 10.25 GiB)
ram = d['total']['ram_gib']
assert ram < 50, 'ram_gib=%r should be <50 when vllm excluded (LLM_ON_PEER=true)' % ram
print('  PASS: vllm excluded; total.ram_gib=%r < 50' % ram)
" 2>&1 || { echo "  FAIL: vllm exclusion failed; json=${j}" >&2; exit 1; }
    rm -rf "$CASE_DIR"
    exit 0
) && pass "estimate_excludes_peer_vllm: LLM_ON_PEER=true → no vllm in master total" \
  || fail "estimate_excludes_peer_vllm: expected vllm excluded (RED — not implemented)"

# ── Case 7: estimate_no_secrets_in_json ──────────────────────────────────────
# .env with a fake REDIS_PASSWORD → JSON output must NOT contain the password value.
# RED: agmind estimate not implemented.
(
    set +e
    CASE_DIR="$(mktemp -d)"
    _make_install_dir "$CASE_DIR" "DEPLOY_PROFILE=core
LLM_ON_PEER=false
REDIS_PASSWORD=topsecret_fixture_xzq7"
    export MOCK_FREE_FIXTURE=spark
    export MOCK_DF_FIXTURE=plenty
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    out="$(_run_estimate "$CASE_DIR" core --json)"
    j="$(_json_of "$out")"
    [[ -n "$j" ]] || { echo "  FAIL: no JSON; out=${out}" >&2; exit 1; }
    # Secret must NOT appear in JSON output
    if printf '%s' "$j" | grep -q 'topsecret_fixture_xzq7'; then
        echo "  FAIL: secret value leaked into JSON output" >&2; exit 1
    fi
    echo "  PASS: secret not in JSON output"
    rm -rf "$CASE_DIR"
    exit 0
) && pass "estimate_no_secrets_in_json: .env REDIS_PASSWORD not leaked into --json output" \
  || fail "estimate_no_secrets_in_json: secret leaked (RED — not implemented)"

# ── Case 8: estimate_invalid_profile_arg ────────────────────────────────────
# agmind estimate notaprofile → rc != 0 or output mentions a valid profile name.
# RED: agmind estimate not implemented (rc=1 from unknown command anyway).
(
    set +e
    CASE_DIR="$(mktemp -d)"
    _make_install_dir "$CASE_DIR" "DEPLOY_PROFILE=core
LLM_ON_PEER=false"
    export MOCK_FREE_FIXTURE=spark
    export MOCK_DF_FIXTURE=plenty
    export MOCK_NVIDIA_SMI_FIXTURE=dgx_spark
    out="$(_run_estimate "$CASE_DIR" notaprofile)"
    rc="$(_rc_of "$out")"
    # Either: rc != 0 (input validation), OR output mentions valid profiles
    if [[ "$rc" -ne 0 ]]; then
        echo "  PASS: invalid profile arg → rc=${rc} (non-zero = validation error or not implemented)"
    else
        # rc=0: must at least mention a valid profile name in output
        if printf '%s\n' "$out" | grep -qiE 'core|rag|full|observability|valid profile'; then
            echo "  PASS: invalid profile arg → rc=0 but output mentions valid profiles"
        else
            echo "  FAIL: invalid profile arg → rc=0 and no guidance; out=${out}" >&2; exit 1
        fi
    fi
    rm -rf "$CASE_DIR"
    exit 0
) && pass "estimate_invalid_profile_arg: notaprofile → non-zero exit or guidance message" \
  || fail "estimate_invalid_profile_arg: expected validation (RED — not implemented)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
