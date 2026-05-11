#!/usr/bin/env bash
# tests/unit/test_status.sh — unit coverage for Phase 2 agmind status (lib/status.sh).
# SC1/SC2/SC3 + edge cases. Runs without root. Uses tests/mocks/ via PATH. Exit 77=SKIP 0=PASS 1=FAIL.
# Cases: table_rows_per_state disabled_not_fail init_container_done distroless_running
#        json_valid service_detail service_detail_fail service_url_derivation
#        watch_non_tty watch_interval_parse not_installed_skip wrapper_dispatch
set -uo pipefail   # NOT -e — capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"

# Null out colors so test output is plain text (no escape sequences in diffs)
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_status"

# ── Shared test directory ─────────────────────────────────────────────────────
# A temp INSTALL_DIR with a fake docker/.env — _status_installed() returns true.
# Tests override ENV_FILE / INSTALL_DIR as needed per case.
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

_make_env() {
    local mode="${1:-none}"   # MONITORING_MODE value
    local dir="${2:-$TEST_TMPDIR}"
    mkdir -p "${dir}/docker"
    cat > "${dir}/docker/.env" <<EOF
VECTOR_STORE=weaviate
LLM_PROVIDER=vllm
LLM_ON_PEER=false
EMBED_PROVIDER=vllm-embed
MONITORING_MODE=${mode}
ENABLE_LITELLM=false
ENABLE_RAGFLOW=false
ENABLE_OPENWEBUI=false
ENABLE_SEARXNG=false
ENABLE_NOTEBOOK=false
REDIS_PASSWORD=mock_pw_not_real
ETL_TYPE=docling
EOF
}

_make_env none "$TEST_TMPDIR"

# ── _run_status helper ────────────────────────────────────────────────────────
# Runs status_run in a clean subshell with mocks on PATH.
# Callers export MOCK_* + INSTALL_DIR before calling. Args passed to status_run.
# Captures combined stdout+stderr and appends RC=<n> on last line.
_run_status() {
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        # Source dependencies in order (mirrors cmd_status source chain)
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/detect.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/service-map.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/health.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/doctor.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/status.sh"
        status_run "$@"
        echo "RC=$?"
    ) 2>&1
}

# _rc_of <output> — extract the RC=N value appended by _run_status
_rc_of() { grep -oE 'RC=[0-9]+' <<< "$1" | tail -1 | cut -d= -f2; }

# _json_of <output> — extract the first JSON object line from output
_json_of() { grep '^{' <<< "$1" | tail -1; }

# _run_state helper — echo the STATE string for one service (no table rendering)
_run_state() {
    local _svc="$1"
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/detect.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/service-map.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/health.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/doctor.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/status.sh"
        _status_docker_state "$_svc" 2>/dev/null
        echo "RC=$?"
    ) 2>&1 | grep -v '^RC=' | tr -d '\n'
}

# _run_url helper — echo the URL string for one service
_run_url() {
    local _svc="$1"
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/service-map.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/health.sh"    2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/status.sh"
        _status_service_url "$_svc"
    ) 2>/dev/null
}

# ── Case 1: table_rows_per_state (SC1) ───────────────────────────────────────
# multi_state mock → table contains rows with distinct STATE strings
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=multi_state
    export MOCK_DOCKER_HEALTH_FIXTURE=unhealthy_worker   # worker=unhealthy, vllm=starting (from ps), loki/alloy=distroless
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    out="$(_run_status)"
    rc="$(_rc_of "$out")"
    # Table always exits 0 (D-07)
    [[ "$rc" -eq 0 ]] || { echo "FAIL: rc=$rc want 0; out=${out}" >&2; exit 1; }
    # Header columns present
    echo "$out" | grep -q "SERVICE" || { echo "FAIL: no SERVICE column header; out=${out}" >&2; exit 1; }
    echo "$out" | grep -q "STATE"   || { echo "FAIL: no STATE column header"   >&2; exit 1; }
    echo "$out" | grep -q "URL"     || { echo "FAIL: no URL column header"     >&2; exit 1; }
    echo "$out" | grep -q "NOTES"   || { echo "FAIL: no NOTES column header"   >&2; exit 1; }
    # Core service rows present
    echo "$out" | grep -q "api"   || { echo "FAIL: no api row"   >&2; exit 1; }
    echo "$out" | grep -q "nginx" || { echo "FAIL: no nginx row" >&2; exit 1; }
    # Group headers present (SERVICE_GROUPS: core, dify, etc.)
    echo "$out" | grep -q "core" || { echo "FAIL: no core group header" >&2; exit 1; }
    echo "$out" | grep -q "dify" || { echo "FAIL: no dify group header" >&2; exit 1; }
    # State tokens present (from multi_state fixture)
    echo "$out" | grep -q "unhealthy" || { echo "FAIL: no unhealthy state in output; out=${out}" >&2; exit 1; }
    echo "$out" | grep -q "starting"  || { echo "FAIL: no starting state in output"  >&2; exit 1; }
    exit 0
) && pass "table_rows_per_state: SC1 table renders rows with STATE tokens" \
  || fail "table_rows_per_state: table output missing expected content"

# ── Case 2: disabled_not_fail (SC3) ──────────────────────────────────────────
# MONITORING_MODE=none → grafana/loki/prometheus not in active set → STATE=disabled
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=multi_state
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    # Verify _status_docker_state directly for monitoring services
    st_grafana="$(_run_state grafana)"
    st_loki="$(_run_state loki)"
    st_prometheus="$(_run_state prometheus)"
    [[ "$st_grafana"    == "disabled" ]] || { echo "FAIL: grafana state='${st_grafana}' want disabled"    >&2; exit 1; }
    [[ "$st_loki"       == "disabled" ]] || { echo "FAIL: loki state='${st_loki}' want disabled"          >&2; exit 1; }
    [[ "$st_prometheus" == "disabled" ]] || { echo "FAIL: prometheus state='${st_prometheus}' want disabled" >&2; exit 1; }
    # Full table output: grafana row must NOT contain unhealthy/exited/FAIL
    out="$(_run_status)"
    echo "$out" | grep "grafana" | grep -qiE 'unhealthy|exited|FAIL' \
        && { echo "FAIL: grafana row shows red state in table; out=${out}" >&2; exit 1; }
    # Grafana row should show disabled
    echo "$out" | grep -q "grafana" \
        && { echo "$out" | grep "grafana" | grep -q "disabled" \
             || { echo "FAIL: grafana row does not show disabled in table" >&2; exit 1; }; }
    exit 0
) && pass "disabled_not_fail: SC3 profile-off services show disabled not red" \
  || fail "disabled_not_fail: SC3 monitoring services should be disabled not red"

# ── Case 3: init_container_done (SC3) ────────────────────────────────────────
# init_exited mock → redis-lock-cleaner Exited(0) → STATE=done (not exited/red)
# Tests the ordering fix: init-container check BEFORE disabled-check in _status_docker_state.
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=init_exited
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    # Direct state check — should be "done" thanks to 02-02 ordering fix
    st_cleaner="$(_run_state redis-lock-cleaner)"
    st_k6="$(_run_state k6)"
    [[ "$st_cleaner" == "done" ]] \
        || { echo "FAIL: redis-lock-cleaner state='${st_cleaner}' want done (ordering fix needed)" >&2; exit 1; }
    [[ "$st_k6" == "done" ]] \
        || { echo "FAIL: k6 state='${st_k6}' want done" >&2; exit 1; }
    exit 0
) && pass "init_container_done: SC3 init containers Exited(0) show done not exited" \
  || fail "init_container_done: SC3 init-container ordering bug — expected done, got something else"

# ── Case 4: distroless_running (SC3) ─────────────────────────────────────────
# loki has no healthcheck (distroless) → STATE=running, not unhealthy
# Use MONITORING_MODE=local so loki/alloy ARE in the active set
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=multi_state
    export MOCK_DOCKER_HEALTH_FIXTURE=default  # default: loki/alloy → empty health
    # Create a local-monitoring .env
    _dist_dir="$(mktemp -d)"
    trap 'rm -rf "$_dist_dir"' EXIT
    mkdir -p "${_dist_dir}/docker"
    cat > "${_dist_dir}/docker/.env" <<EOF2
VECTOR_STORE=weaviate
LLM_PROVIDER=vllm
LLM_ON_PEER=false
EMBED_PROVIDER=vllm-embed
MONITORING_MODE=local
ENABLE_LITELLM=false
ENABLE_RAGFLOW=false
ENABLE_OPENWEBUI=false
ENABLE_SEARXNG=false
ENABLE_NOTEBOOK=false
REDIS_PASSWORD=mock_pw_not_real
ETL_TYPE=docling
EOF2
    export INSTALL_DIR="$_dist_dir"
    export ENV_FILE="${_dist_dir}/docker/.env"
    # loki: multi_state fixture → "Up 30 minutes" (no "(healthy)" suffix)
    # health format → empty (distroless) → must resolve to "running"
    st_loki="$(_run_state loki)"
    [[ "$st_loki" == "running" ]] \
        || { echo "FAIL: loki state='${st_loki}' want running (distroless — no healthcheck)" >&2; exit 1; }
    # alloy: "Up 1 hour" → also distroless → running
    st_alloy="$(_run_state alloy)"
    [[ "$st_alloy" == "running" ]] \
        || { echo "FAIL: alloy state='${st_alloy}' want running (distroless)" >&2; exit 1; }
    # Full table: loki row must not contain "unhealthy"
    out="$(_run_status)"
    echo "$out" | grep "loki" | grep -q "unhealthy" \
        && { echo "FAIL: loki row shows unhealthy in table; out=${out}" >&2; exit 1; }
    exit 0
) && pass "distroless_running: SC3 distroless containers with no healthcheck show running" \
  || fail "distroless_running: SC3 distroless should be running not unhealthy"

# ── Case 5: json_valid (SC2) ─────────────────────────────────────────────────
# --json output must be valid JSON with .services array and .overall field
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=multi_state
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    if ! command -v python3 >/dev/null 2>&1; then
        echo "  [SKIP] json_valid (no python3 in PATH)"
        exit 0
    fi
    out="$(_run_status --json)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 0 ]] || { echo "FAIL: --json rc=$rc want 0" >&2; exit 1; }
    j="$(_json_of "$out")"
    [[ -n "$j" ]] || { echo "FAIL: no JSON line found in output; out=${out}" >&2; exit 1; }
    printf '%s' "$j" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert isinstance(d.get('services'), list), 'services not a list'
assert len(d['services']) > 0, 'services array is empty'
assert d.get('overall') in ('ok','warn','fail'), 'overall not ok/warn/fail: %r' % d.get('overall')
assert 'generated_at' in d, 'missing generated_at'
assert 'hostname' in d, 'missing hostname'
" 2>&1 || { echo "FAIL: JSON validation failed; json=${j}" >&2; exit 1; }
    exit 0
) && pass "json_valid: SC2 --json output is valid JSON with services array and overall" \
  || fail "json_valid: SC2 --json failed validation"

# ── Case 6: service_detail (SC2) ─────────────────────────────────────────────
# --service vllm with RUNNING mocks → shows model id + RestartCount + logs section
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=running       # vllm = "Up 3 hours (healthy)" → healthy → rc 0
    export MOCK_DOCKER_INSPECT_FIXTURE=ok
    export MOCK_DOCKER_STATS_FIXTURE=ok
    export MOCK_CURL_RESPONSE='{"data":[{"id":"qwen3.5-test-model"}]}'
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    out="$(_run_status --service vllm)"
    rc="$(_rc_of "$out")"
    # Should show the loaded model id from MOCK_CURL_RESPONSE
    echo "$out" | grep -q "qwen3.5-test-model" \
        || { echo "FAIL: model id not in output; out=${out}" >&2; exit 1; }
    # Should show RestartCount
    echo "$out" | grep -q "RestartCount" \
        || { echo "FAIL: RestartCount not in output; out=${out}" >&2; exit 1; }
    # Should show log section header
    echo "$out" | grep -qi "Logs" \
        || { echo "FAIL: Logs section not in output; out=${out}" >&2; exit 1; }
    # RC=0 (healthy)
    [[ "$rc" -eq 0 ]] || { echo "FAIL: --service vllm rc=$rc want 0 (healthy); out=${out}" >&2; exit 1; }
    # Also test: name with agmind- prefix is accepted
    out2="$(_run_status --service agmind-vllm)"
    echo "$out2" | grep -q "qwen3.5-test-model" \
        || { echo "FAIL: agmind-vllm prefix not stripped; out=${out2}" >&2; exit 1; }
    exit 0
) && pass "service_detail: SC2 --service vllm shows model id + RestartCount + logs" \
  || fail "service_detail: SC2 --service vllm missing expected detail output"

# ── Case 7: service_detail_fail (SC2) ────────────────────────────────────────
# --service worker (unhealthy) → exit 1; unknown service → exit 1
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=multi_state   # worker = "Up 5 minutes (unhealthy)"
    export MOCK_DOCKER_HEALTH_FIXTURE=unhealthy_worker  # inspect returns unhealthy for worker
    export MOCK_DOCKER_INSPECT_FIXTURE=ok
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    out_worker="$(_run_status --service worker)"
    rc_worker="$(_rc_of "$out_worker")"
    [[ "$rc_worker" -eq 1 ]] \
        || { echo "FAIL: --service worker rc=$rc_worker want 1 (unhealthy); out=${out_worker}" >&2; exit 1; }

    # Unknown service: docker inspect agmind-no-such-svc → MOCK_DOCKER_INSPECT_FIXTURE=missing → exit 1
    export MOCK_DOCKER_INSPECT_FIXTURE=missing
    out_unknown="$(_run_status --service no-such-svc)"
    rc_unknown="$(_rc_of "$out_unknown")"
    [[ "$rc_unknown" -eq 1 ]] \
        || { echo "FAIL: --service no-such-svc rc=$rc_unknown want 1; out=${out_unknown}" >&2; exit 1; }
    echo "$out_unknown" | grep -qi "not found\|does not exist\|No such" \
        || { echo "FAIL: no 'not found' in unknown-service output; out=${out_unknown}" >&2; exit 1; }
    export MOCK_DOCKER_INSPECT_FIXTURE=ok  # reset
    exit 0
) && pass "service_detail_fail: SC2 --service unhealthy/unknown → exit 1 with message" \
  || fail "service_detail_fail: SC2 expected rc=1 for unhealthy/unknown service"

# ── Case 8: service_url_derivation ───────────────────────────────────────────
# _status_service_url derives correct mDNS URLs and — for internal-only services
(
    set +e
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    _trim() { printf '%s' "$*" | sed 's/^ *//; s/ *$//'; }
    u_api="$(_trim "$(_run_url api)")"
    u_grafana="$(_trim "$(_run_url grafana)")"
    u_webui="$(_trim "$(_run_url open-webui)")"
    u_portainer="$(_trim "$(_run_url portainer)")"
    u_ragflow="$(_trim "$(_run_url ragflow)")"
    u_vllm="$(_trim "$(_run_url vllm)")"
    u_db="$(_trim "$(_run_url db)")"
    u_weaviate="$(_trim "$(_run_url weaviate)")"

    [[ "$u_api"      == "http://agmind-dify.local" ]]          || { echo "FAIL: api url='${u_api}'"      >&2; exit 1; }
    [[ "$u_grafana"  == "http://agmind-grafana.local" ]]       || { echo "FAIL: grafana url='${u_grafana}'" >&2; exit 1; }
    [[ "$u_webui"    == "http://agmind-chat.local" ]]          || { echo "FAIL: open-webui url='${u_webui}'" >&2; exit 1; }
    [[ "$u_portainer" == "https://agmind-portainer.local:9443" ]] || { echo "FAIL: portainer url='${u_portainer}'" >&2; exit 1; }
    [[ "$u_ragflow"  == "http://agmind-ragflow.local" ]]       || { echo "FAIL: ragflow url='${u_ragflow}'" >&2; exit 1; }
    [[ "$u_vllm"     == "—" ]]  || { echo "FAIL: vllm url='${u_vllm}' want —"     >&2; exit 1; }
    [[ "$u_db"       == "—" ]]  || { echo "FAIL: db url='${u_db}' want —"          >&2; exit 1; }
    [[ "$u_weaviate" == "—" ]]  || { echo "FAIL: weaviate url='${u_weaviate}' want —" >&2; exit 1; }
    exit 0
) && pass "service_url_derivation: mDNS URLs correct + — for internal-only services" \
  || fail "service_url_derivation: URL derivation incorrect"

# ── Case 9: watch_non_tty (SC2) ──────────────────────────────────────────────
# --watch on non-TTY (stdout is pipe from command substitution) → prints once and exits
# No ANSI cursor-home \e[H in output; no infinite loop; rc=0; completes in <10s
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=multi_state
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    out="$(timeout 10 bash -c "
        set +e
        export PATH=\"${MOCK_DIR}:\${PATH}\"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export MOCK_DOCKER_FIXTURE=healthy MOCK_DOCKER_PS_FIXTURE=multi_state
        export INSTALL_DIR='${TEST_TMPDIR}' ENV_FILE='${TEST_TMPDIR}/docker/.env'
        source '${REPO_ROOT}/lib/common.sh'    2>/dev/null || true
        source '${REPO_ROOT}/lib/detect.sh'    2>/dev/null || true
        source '${REPO_ROOT}/lib/service-map.sh' 2>/dev/null || true
        source '${REPO_ROOT}/lib/health.sh'    2>/dev/null || true
        source '${REPO_ROOT}/lib/doctor.sh'    2>/dev/null || true
        source '${REPO_ROOT}/lib/status.sh'
        status_run --watch
        echo RC=\$?
    " 2>&1)"
    # Command must have completed (not timeout=124)
    [[ "${out}" != *"RC=124"* ]] || { echo "FAIL: --watch timed out (infinite loop?)" >&2; exit 1; }
    # Table rendered at least once
    echo "$out" | grep -q "SERVICE" || { echo "FAIL: no SERVICE header in watch output; out=${out}" >&2; exit 1; }
    # No ANSI cursor-home escape \e[H in output (non-TTY path skips ANSI)
    if printf '%s' "$out" | grep -qP '\e\[H'; then
        echo "FAIL: ANSI cursor-home \\e[H found in non-TTY output" >&2; exit 1
    fi
    rc_out="$(echo "$out" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)"
    [[ "$rc_out" -eq 0 ]] || { echo "FAIL: --watch rc=$rc_out want 0" >&2; exit 1; }
    exit 0
) && pass "watch_non_tty: SC2 --watch on non-TTY prints once and exits cleanly" \
  || fail "watch_non_tty: SC2 --watch on non-TTY should not loop or emit ANSI"

# ── Case 10: watch_interval_parse (SC2) ──────────────────────────────────────
# --watch 5 must parse 5 as interval (not treat it as unknown flag → rc 2)
# On non-TTY the one-shot path runs immediately; the "5" arg must be consumed cleanly.
(
    set +e
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_PS_FIXTURE=running
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    out="$(_run_status --watch 5)"
    rc="$(_rc_of "$out")"
    # --watch 5 should succeed (5 consumed as interval, not as unknown flag)
    [[ "$rc" -eq 0 ]] \
        || { echo "FAIL: --watch 5 rc=$rc want 0 (interval parsed cleanly); out=${out}" >&2; exit 1; }
    echo "$out" | grep -qi "unknown flag" \
        && { echo "FAIL: --watch 5 produced 'unknown flag' error; out=${out}" >&2; exit 1; }
    # --watch with non-numeric arg: abc is not consumed as interval → should be ignored
    # (status_run's parser: if next arg after --watch doesn't match ^[0-9]+$, it's not shifted)
    # Since abc is not ^[0-9]+$, the parser leaves it; the '*' catch-all in status_run shifts it.
    # Either way, it should not crash fatally. Accept rc 0 or 2.
    out2="$(_run_status --watch abc)"
    rc2="$(_rc_of "$out2")"
    # Key: --watch 5 works (rc=0). --watch abc behavior is implementation-defined; just assert no crash.
    [[ -n "$rc2" ]] || { echo "FAIL: --watch abc produced no RC" >&2; exit 1; }
    exit 0
) && pass "watch_interval_parse: SC2 --watch 5 parses interval=5 cleanly (rc=0, no unknown-flag error)" \
  || fail "watch_interval_parse: SC2 --watch 5 should not error with unknown-flag"

# ── Case 11: not_installed_skip ──────────────────────────────────────────────
# INSTALL_DIR points to nonexistent path → status_run exits 0 + "not installed" message
(
    set +e
    _fake_id="/nonexistent-agmind-$$"
    export INSTALL_DIR="$_fake_id"
    export ENV_FILE="${_fake_id}/docker/.env"
    out="$(_run_status)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 0 ]] \
        || { echo "FAIL: not-installed rc=$rc want 0; out=${out}" >&2; exit 1; }
    echo "$out" | grep -qiE 'not installed|install\.sh' \
        || { echo "FAIL: no 'not installed' message in output; out=${out}" >&2; exit 1; }
    # --json path: must also exit 0 and emit JSON
    out_j="$(_run_status --json)"
    rc_j="$(_rc_of "$out_j")"
    [[ "$rc_j" -eq 0 ]] \
        || { echo "FAIL: not-installed --json rc=$rc_j want 0" >&2; exit 1; }
    if command -v python3 >/dev/null 2>&1; then
        j="$(_json_of "$out_j")"
        [[ -n "$j" ]] \
            || { echo "FAIL: no JSON in not-installed --json output; out=${out_j}" >&2; exit 1; }
        printf '%s' "$j" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('error')=='not-installed'" 2>&1 \
            || { echo "FAIL: not-installed JSON missing error=not-installed; json=${j}" >&2; exit 1; }
    fi
    # Reset
    export INSTALL_DIR="$TEST_TMPDIR"
    export ENV_FILE="${TEST_TMPDIR}/docker/.env"
    exit 0
) && pass "not_installed_skip: INSTALL_DIR absent → exit 0 with not-installed message" \
  || fail "not_installed_skip: expected graceful exit 0 with not-installed message"

# ── Case 12: wrapper_dispatch — DEFERRED TO PLAN 02-03 ───────────────────────
# TODO 02-03: scripts/agmind.sh cmd_status → status_run wiring.
# Plan 02-03 will promote this to a real assertion once cmd_status thin-wrapper is wired.
(
    echo "  [SKIP] wrapper_dispatch (deferred to Plan 02-03 — cmd_status thin-wrapper not wired yet)"
    exit 0
) && pass "wrapper_dispatch: SKIP (deferred to 02-03)" \
  || fail "wrapper_dispatch: unexpected failure"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
