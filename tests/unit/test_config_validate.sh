#!/usr/bin/env bash
# tests/unit/test_config_validate.sh — RED unit tests for config_validate (Phase 4 Plan 02).
# Tests FAIL until lib/config.sh::config_validate is implemented (Wave-0 / Plan 04-01).
# Cases: all_checks_pass · env_placeholders_fail · env_required_keys_fail
#        versions_manifest_desync_fail · no_unstable_tags_fail · compose_schema_fail
#        compose_schema_skip_when_docker_down · exit2_no_installdir · exit2_no_env
#        json_output · json_output_no_secrets · wrapper_dispatch
# Exit: 0=PASS 1=FAIL 77=SKIP
set -uo pipefail  # NOT -e — capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
FIXTURES="${REPO_ROOT}/tests/fixtures/config_validate"
export PATH="${MOCK_DIR}:${PATH}"

# Null colors for plain-text output
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_config_validate"

# Check fixtures exist; skip if absent
if [[ ! -d "$FIXTURES/good" ]]; then
    echo "SKIP: fixtures not found at $FIXTURES"
    exit 77
fi

# ── Shared tmpdir ─────────────────────────────────────────────────────────────
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# ── Helper: build a clean INSTALL_DIR from good fixtures ─────────────────────
# Mirrors real deploy layout:
#   ${INSTALL_DIR}/docker/.env
#   ${INSTALL_DIR}/docker/docker-compose.yml
#   ${INSTALL_DIR}/versions.env
#   ${INSTALL_DIR}/release-manifest.json
_mk_install_dir() {
    local dir="$1"
    mkdir -p "${dir}/docker"
    cp "${FIXTURES}/good/env.good"          "${dir}/docker/.env"
    cp "${FIXTURES}/good/docker-compose.yml" "${dir}/docker/docker-compose.yml"
    cp "${FIXTURES}/good/versions.env"      "${dir}/versions.env"
    cp "${FIXTURES}/good/release-manifest.json" "${dir}/release-manifest.json"
}

# ── TC1: all_checks_pass ──────────────────────────────────────────────────────
# Good fixtures + compose mock exit 0 → config_validate exits 0
(
    set +e
    d="${TMP_ROOT}/tc1"
    _mk_install_dir "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=0
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/docker-compose.yml"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    config_validate
    rc=$?
    [[ "$rc" -eq 0 ]]
) && pass "TC1 all_checks_pass: good fixtures → config_validate exits 0" \
  || fail "TC1 all_checks_pass: expected rc=0 (RED until Plan 02 implements config_validate)"

# ── TC2: env_placeholders_fail ────────────────────────────────────────────────
# .env has __SECRET_KEY__ placeholder → exit 1, output mentions placeholder+SECRET_KEY
(
    set +e
    d="${TMP_ROOT}/tc2"
    _mk_install_dir "$d"
    cp "${FIXTURES}/bad/.env-placeholder" "${d}/docker/.env"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=0
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/.env"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate 2>&1)"
    rc=$?
    [[ "$rc" -eq 1 ]] \
        && echo "$out" | grep -qi 'placeholder\|__SECRET_KEY__' \
        && echo "$out" | grep -q 'SECRET_KEY'
) && pass "TC2 env_placeholders_fail: placeholder in .env → rc=1, output mentions placeholder+SECRET_KEY" \
  || fail "TC2 env_placeholders_fail: expected rc=1 + placeholder mention (RED until Plan 02)"

# ── TC3: env_required_keys_fail ───────────────────────────────────────────────
# .env missing SECRET_KEY → exit 1, output mentions SECRET_KEY, does NOT print values
(
    set +e
    d="${TMP_ROOT}/tc3"
    _mk_install_dir "$d"
    cp "${FIXTURES}/bad/.env-missingkey" "${d}/docker/.env"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=0
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/.env"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate 2>&1)"
    rc=$?
    # Must fail AND mention key name AND NOT leak password values
    [[ "$rc" -eq 1 ]] \
        && echo "$out" | grep -q 'SECRET_KEY' \
        && ! echo "$out" | grep -q 'fixturepw'
) && pass "TC3 env_required_keys_fail: missing key → rc=1, key name in output, no value leak" \
  || fail "TC3 env_required_keys_fail: expected rc=1 + key name, no value (RED until Plan 02)"

# ── TC4: versions_manifest_desync_fail ───────────────────────────────────────
# release-manifest.json has DIFY_VERSION=1.12.0, versions.env has 1.13.3 → exit 1
(
    set +e
    d="${TMP_ROOT}/tc4"
    _mk_install_dir "$d"
    cp "${FIXTURES}/bad/release-manifest-desync.json" "${d}/release-manifest.json"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=0
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/docker-compose.yml"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate 2>&1)"
    rc=$?
    [[ "$rc" -eq 1 ]] && echo "$out" | grep -q 'DIFY_VERSION'
) && pass "TC4 versions_manifest_desync_fail: desynced manifest → rc=1, mentions DIFY_VERSION" \
  || fail "TC4 versions_manifest_desync_fail: expected rc=1 + DIFY_VERSION mention (RED until Plan 02)"

# ── TC5: no_unstable_tags_fail ────────────────────────────────────────────────
# docker-compose.yml has :latest → exit 1, output mentions 'latest'
(
    set +e
    d="${TMP_ROOT}/tc5"
    _mk_install_dir "$d"
    cp "${FIXTURES}/bad/docker-compose-latest.yml" "${d}/docker/docker-compose.yml"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=0
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/docker-compose.yml"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate 2>&1)"
    rc=$?
    [[ "$rc" -eq 1 ]] && echo "$out" | grep -qi 'latest'
) && pass "TC5 no_unstable_tags_fail: :latest in compose → rc=1, mentions 'latest'" \
  || fail "TC5 no_unstable_tags_fail: expected rc=1 + 'latest' mention (RED until Plan 02)"

# ── TC6: compose_schema_fail ─────────────────────────────────────────────────
# docker compose config -q exits non-zero → config_validate exits 1, mentions compose
(
    set +e
    d="${TMP_ROOT}/tc6"
    _mk_install_dir "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=1
    export MOCK_DOCKER_COMPOSE_CONFIG_OUTPUT="services.web Additional property bogus is not allowed"
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/docker-compose.yml"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate 2>&1)"
    rc=$?
    [[ "$rc" -eq 1 ]] && echo "$out" | grep -qi 'compose'
) && pass "TC6 compose_schema_fail: compose config -q fails → rc=1, mentions compose" \
  || fail "TC6 compose_schema_fail: expected rc=1 + compose mention (RED until Plan 02)"

# ── TC7: compose_schema_skip_when_docker_down ─────────────────────────────────
# docker info fails (MOCK_DOCKER_INFO_EXIT=1) → compose check skipped, overall rc=0
(
    set +e
    d="${TMP_ROOT}/tc7"
    _mk_install_dir "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_INFO_EXIT=1
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=0
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/docker-compose.yml"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate 2>&1)"
    rc=$?
    # All other checks pass → rc=0; compose check skipped → output mentions skip near compose
    [[ "$rc" -eq 0 ]] && echo "$out" | grep -qi 'skip'
) && pass "TC7 compose_schema_skip_when_docker_down: docker down → compose skipped, overall rc=0" \
  || fail "TC7 compose_schema_skip_when_docker_down: expected rc=0 + skip (RED until Plan 02)"

# ── TC8: exit2_no_installdir ─────────────────────────────────────────────────
# Empty INSTALL_DIR (no docker/ subdir) → config_validate exits 2
(
    set +e
    d="${TMP_ROOT}/tc8"
    mkdir -p "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate 2>&1)"
    rc=$?
    [[ "$rc" -eq 2 ]] && echo "$out" | grep -qi 'not installed\|no.*docker\|missing'
) && pass "TC8 exit2_no_installdir: no docker/ subdir → rc=2, mentions not installed" \
  || fail "TC8 exit2_no_installdir: expected rc=2 (RED until Plan 02)"

# ── TC9: exit2_no_env ────────────────────────────────────────────────────────
# INSTALL_DIR has docker/ but no .env → config_validate exits 2
(
    set +e
    d="${TMP_ROOT}/tc9"
    mkdir -p "${d}/docker"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate 2>&1)"
    rc=$?
    [[ "$rc" -eq 2 ]]
) && pass "TC9 exit2_no_env: docker/ dir but no .env → rc=2" \
  || fail "TC9 exit2_no_env: expected rc=2 (RED until Plan 02)"

# ── TC10: json_output ────────────────────────────────────────────────────────
# Good fixtures + --json → valid JSON with checks[], summary{}, exit keys; 5 checks
(
    set +e
    d="${TMP_ROOT}/tc10"
    _mk_install_dir "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=0
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/docker-compose.yml"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate --json 2>&1)"
    rc=$?
    # Valid JSON
    echo "$out" | python3 -m json.tool > /dev/null 2>&1 || { false; exit; }
    # Schema: checks[], summary{total,failed}, exit
    python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'checks' in d, 'missing checks'
assert 'summary' in d, 'missing summary'
assert 'exit' in d, 'missing exit'
assert isinstance(d['checks'], list), 'checks not a list'
assert len(d['checks']) == 5, f'expected 5 checks, got {len(d[\"checks\"])}'
assert 'total' in d['summary'], 'missing summary.total'
assert 'failed' in d['summary'], 'missing summary.failed'
" <<<"$out"
) && pass "TC10 json_output: --json → valid JSON with checks[5], summary, exit keys" \
  || fail "TC10 json_output: invalid JSON or missing schema keys (RED until Plan 02)"

# ── TC11: json_output_no_secrets ─────────────────────────────────────────────
# Bad .env-missingkey + --json → output does NOT contain env values like fixturepw
(
    set +e
    d="${TMP_ROOT}/tc11"
    _mk_install_dir "$d"
    cp "${FIXTURES}/bad/.env-missingkey" "${d}/docker/.env"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_COMPOSE_CONFIG_EXIT=0
    export MOCK_DOCKER_COMPOSE_CONFIG_RENDERED_FILE="${d}/docker/.env"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/config.sh"
    out="$(config_validate --json 2>&1)"
    rc=$?
    # Security: values must NOT appear in output
    ! echo "$out" | grep -q 'fixturepw'
) && pass "TC11 json_output_no_secrets: --json output contains no env values (fixturepw absent)" \
  || fail "TC11 json_output_no_secrets: secret value leaked in JSON output (RED until Plan 02)"

# ── TC12: wrapper_dispatch ────────────────────────────────────────────────────
# Static: scripts/agmind.sh has config) branch + config_validate call
(
    set +e
    grep -q 'config)' "${REPO_ROOT}/scripts/agmind.sh" \
        && grep -q 'config_validate' "${REPO_ROOT}/scripts/agmind.sh"
) && pass "TC12 wrapper_dispatch: agmind.sh has config) branch and config_validate call" \
  || fail "TC12 wrapper_dispatch: agmind.sh missing config) dispatch or config_validate (RED until Plan 02)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "## test_config_validate: ${PASS} PASS, ${FAIL} FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
