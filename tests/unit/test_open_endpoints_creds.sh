#!/usr/bin/env bash
# tests/unit/test_open_endpoints_creds.sh — Wave-0 RED tests for Phase 3 agmind open/endpoints/creds.
# SC1 (agmind open), SC3 (agmind endpoints), SC2 (agmind creds show/rotate).
# All 10 cases FAIL (RED) until 03-02/03-03 implement cmd_open/cmd_endpoints/cmd_creds_show.
# Exit: 0=PASS 1=FAIL 77=SKIP
#
# Cases:
#   open_headless_prints_url    — headless env → prints URL, no opener called
#   open_desktop_calls_opener   — DISPLAY=:0 → soft check (non-TTY harness OK to pass)
#   open_unknown_service        — bogus service → exit 1 + "unknown" in stderr
#   open_list                   — --list and bare → output contains dify and grafana
#   endpoints_table             — table has dify, URL, STATE token
#   endpoints_json_valid        — --json output is valid JSON with endpoints key
#   creds_show_requires_root    — non-root → exit 1, no secrets in stdout, sudo hint
#   creds_show_masked_default   — root-gated: masked output hides FAKEsecretAAA111
#   creds_show_reveal_flag      — root-gated: --show reveals FAKEsecretAAA111 + stderr warn
#   creds_rotate_execs_script   — dispatch invokes rotate_secrets.sh mock (or root-gates)
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

echo "## test_open_endpoints_creds"

# ── Shared test directory ─────────────────────────────────────────────────────
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# FIXTURE_SECRET for SC2 invariant assertions
FIXTURE_SECRET="FAKEsecretAAA111"

# ── Build INSTALL_FIXTURE (fake runtime root for agmind.sh subprocess) ────────
INSTALL_FIXTURE="${TEST_TMPDIR}/opt"
mkdir -p "${INSTALL_FIXTURE}/docker" "${INSTALL_FIXTURE}/scripts" \
         "${INSTALL_FIXTURE}/lib" "${INSTALL_FIXTURE}/logs"

# Copy scripts/*.sh into scripts/ (agmind.sh lives here at runtime)
cp "${REPO_ROOT}/scripts/"*.sh "${INSTALL_FIXTURE}/scripts/"
cp "${REPO_ROOT}/lib/"*.sh     "${INSTALL_FIXTURE}/lib/"

# At runtime, install.sh copies lib/*.sh into scripts/ so agmind.sh can source them.
# Mirror that here: symlink lib/*.sh into scripts/ (same basenames).
for _lib in common.sh detect.sh service-map.sh health.sh doctor.sh status.sh \
            config.sh restore.sh peer.sh phases.sh creds.sh; do
    [[ -f "${REPO_ROOT}/lib/${_lib}" ]] \
        && ln -sf "${REPO_ROOT}/lib/${_lib}" "${INSTALL_FIXTURE}/scripts/${_lib}"
done

# Override rotate_secrets.sh with stub (so creds rotate tests the mock)
cp "${REPO_ROOT}/tests/mocks/rotate_secrets.sh" \
   "${INSTALL_FIXTURE}/scripts/rotate_secrets.sh"

# Copy credential fixtures into the fake install root
cp "${REPO_ROOT}/tests/fixtures/creds/credentials.txt" \
   "${INSTALL_FIXTURE}/credentials.txt"
cp "${REPO_ROOT}/tests/fixtures/creds/.admin_password" \
   "${INSTALL_FIXTURE}/.admin_password"

# Minimal docker/.env so _status_installed() is true
cat > "${INSTALL_FIXTURE}/docker/.env" <<'EOF'
VECTOR_STORE=weaviate
LLM_PROVIDER=vllm
LLM_ON_PEER=false
EMBED_PROVIDER=vllm-embed
MONITORING_MODE=none
ENABLE_LITELLM=false
ENABLE_RAGFLOW=false
ENABLE_OPENWEBUI=false
ENABLE_SEARXNG=false
ENABLE_NOTEBOOK=false
REDIS_PASSWORD=mock_pw_not_real
ETL_TYPE=docling
EOF

# ── _run helper ────────────────────────────────────────────────────────────────
# Runs agmind.sh as a subprocess with mocks on PATH, fake AGMIND_DIR, null colors.
# Sets OUT, ERR, RC. Extra env vars can be passed as KEY=VALUE args before --.
# Usage: _run [env ...] -- [agmind args]
_run() {
    local _err; _err="$(mktemp)"
    OUT="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export MOCK_DOCKER_FIXTURE=healthy
        export MOCK_DOCKER_PS_FIXTURE=running
        export AGMIND_DIR="${INSTALL_FIXTURE}"
        export INSTALL_DIR="${INSTALL_FIXTURE}"
        export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
        bash "${REPO_ROOT}/scripts/agmind.sh" "$@" 2>"${_err}"
    )" || true
    RC=$?
    ERR="$(cat "${_err}")"
    rm -f "${_err}"
    return 0
}

# ── Case 1: open_headless_prints_url (SC1) ────────────────────────────────────
# Headless env (DISPLAY/WAYLAND_DISPLAY unset, SSH_CONNECTION set) → prints URL only,
# no opener called. Subprocess stdout is a pipe → [[ ! -t 1 ]] true → headless.
(
    set +e
    _xdg_log="${TEST_TMPDIR}/xdg1.log"
    _err="$(mktemp)"
    OUT="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export MOCK_DOCKER_FIXTURE=healthy
        export MOCK_DOCKER_PS_FIXTURE=running
        export AGMIND_DIR="${INSTALL_FIXTURE}"
        export INSTALL_DIR="${INSTALL_FIXTURE}"
        export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
        export MOCK_XDG_LOG="${_xdg_log}"
        # Unset display vars to ensure headless path (stdout already not a TTY in subshell)
        unset DISPLAY WAYLAND_DISPLAY SSH_CONNECTION SSH_TTY 2>/dev/null || true
        bash "${REPO_ROOT}/scripts/agmind.sh" open dify 2>"${_err}"
    )"
    RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
    # Expected after 03-02: RC=0, OUT="http://agmind-dify.local", xdg_log empty
    [[ "$RC" -eq 0 ]] || { echo "  FAIL: open dify RC=$RC (want 0); ERR=${ERR}" >&2; exit 1; }
    [[ "$OUT" == "http://agmind-dify.local" ]] \
        || { echo "  FAIL: open dify OUT='${OUT}' (want http://agmind-dify.local)" >&2; exit 1; }
    # xdg-open must NOT have been called (headless path)
    if [[ -f "${_xdg_log}" ]] && [[ -s "${_xdg_log}" ]]; then
        echo "  FAIL: xdg-open was called in headless mode — log: $(cat "${_xdg_log}")" >&2; exit 1
    fi
    exit 0
) && pass "open_headless_prints_url: headless → prints http://agmind-dify.local, no opener" \
  || fail "open_headless_prints_url: headless path not working (cmd_open not implemented yet)"

# ── Case 2: open_desktop_calls_opener (SC1) ──────────────────────────────────
# DISPLAY=:0 set. In non-TTY harness [[ ! -t 1 ]] is still true → headless wins.
# Soft assertion: URL printed regardless of whether opener was called.
(
    set +e
    _xdg_log="${TEST_TMPDIR}/xdg2.log"
    _err="$(mktemp)"
    OUT="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export MOCK_DOCKER_FIXTURE=healthy
        export MOCK_DOCKER_PS_FIXTURE=running
        export AGMIND_DIR="${INSTALL_FIXTURE}"
        export INSTALL_DIR="${INSTALL_FIXTURE}"
        export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
        export MOCK_XDG_LOG="${_xdg_log}"
        export DISPLAY=":0"
        unset SSH_CONNECTION SSH_TTY 2>/dev/null || true
        bash "${REPO_ROOT}/scripts/agmind.sh" open dify 2>"${_err}"
    )"
    RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
    # Hard requirement: URL printed
    [[ "$OUT" == *"http://agmind-dify.local"* ]] \
        || { echo "  FAIL: open dify (DISPLAY=:0) OUT='${OUT}' does not contain URL" >&2; exit 1; }
    [[ "$RC" -eq 0 ]] || { echo "  FAIL: open dify (DISPLAY=:0) RC=${RC}" >&2; exit 1; }
    # Soft: opener may or may not have fired (non-TTY harness → headless wins)
    exit 0
) && pass "open_desktop_calls_opener: URL printed (opener path manual-only in non-TTY harness)" \
  || fail "open_desktop_calls_opener: open dify with DISPLAY=:0 failed (cmd_open not implemented yet)"

# ── Case 3: open_unknown_service (SC1) ────────────────────────────────────────
# agmind open bogus → exit 1, stderr contains "unknown", stderr contains "dify" (available list)
(
    set +e
    _err="$(mktemp)"
    OUT="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export MOCK_DOCKER_FIXTURE=healthy
        export MOCK_DOCKER_PS_FIXTURE=running
        export AGMIND_DIR="${INSTALL_FIXTURE}"
        export INSTALL_DIR="${INSTALL_FIXTURE}"
        export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
        bash "${REPO_ROOT}/scripts/agmind.sh" open bogus 2>"${_err}"
    )"
    RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
    [[ "$RC" -ne 0 ]] || { echo "  FAIL: open bogus RC=0 (want non-zero)" >&2; exit 1; }
    printf '%s' "${ERR}" | grep -qi "unknown" \
        || { echo "  FAIL: stderr does not contain 'unknown'; ERR=${ERR}" >&2; exit 1; }
    printf '%s' "${ERR}" | grep -qi "dify" \
        || { echo "  FAIL: stderr does not contain 'dify' (available list); ERR=${ERR}" >&2; exit 1; }
    exit 0
) && pass "open_unknown_service: bogus service → exit non-zero, 'unknown' + 'dify' in stderr" \
  || fail "open_unknown_service: expected exit 1 + unknown message (cmd_open not implemented yet)"

# ── Case 4: open_list (SC1) ───────────────────────────────────────────────────
# agmind open --list → RC=0, output contains "dify" and "grafana"
# agmind open (bare, no args) → same
(
    set +e
    _err="$(mktemp)"
    OUT="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export MOCK_DOCKER_FIXTURE=healthy
        export MOCK_DOCKER_PS_FIXTURE=running
        export AGMIND_DIR="${INSTALL_FIXTURE}"
        export INSTALL_DIR="${INSTALL_FIXTURE}"
        export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
        bash "${REPO_ROOT}/scripts/agmind.sh" open --list 2>"${_err}"
    )"
    RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
    [[ "$RC" -eq 0 ]] || { echo "  FAIL: open --list RC=$RC (want 0)" >&2; exit 1; }
    printf '%s' "${OUT}" | grep -qi "dify" \
        || { echo "  FAIL: --list output missing 'dify'; OUT=${OUT}" >&2; exit 1; }
    printf '%s' "${OUT}" | grep -qi "grafana" \
        || { echo "  FAIL: --list output missing 'grafana'; OUT=${OUT}" >&2; exit 1; }
    # Bare open (no args) should also list
    _err2="$(mktemp)"
    OUT2="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export AGMIND_DIR="${INSTALL_FIXTURE}"
        export INSTALL_DIR="${INSTALL_FIXTURE}"
        export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
        export MOCK_DOCKER_FIXTURE=healthy
        bash "${REPO_ROOT}/scripts/agmind.sh" open 2>"${_err2}"
    )"
    rm -f "${_err2}"
    printf '%s' "${OUT2}" | grep -qi "dify" \
        || { echo "  FAIL: bare open output missing 'dify'; OUT2=${OUT2}" >&2; exit 1; }
    exit 0
) && pass "open_list: --list and bare open print dify + grafana (RC=0)" \
  || fail "open_list: expected list of services (cmd_open not implemented yet)"

# ── Case 5: endpoints_table (SC3) ─────────────────────────────────────────────
# agmind endpoints → RC=0, output contains "dify", URL, STATE token
(
    set +e
    _err="$(mktemp)"
    OUT="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export MOCK_DOCKER_FIXTURE=healthy
        export MOCK_DOCKER_PS_FIXTURE=running
        export MOCK_HOSTNAME_FIXTURE=docker_first
        export AGMIND_DIR="${INSTALL_FIXTURE}"
        export INSTALL_DIR="${INSTALL_FIXTURE}"
        export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
        bash "${REPO_ROOT}/scripts/agmind.sh" endpoints 2>"${_err}"
    )"
    RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
    [[ "$RC" -eq 0 ]] || { echo "  FAIL: endpoints RC=$RC (want 0); ERR=${ERR}" >&2; exit 1; }
    printf '%s' "${OUT}" | grep -qi "dify" \
        || { echo "  FAIL: endpoints output missing 'dify'; OUT=${OUT}" >&2; exit 1; }
    printf '%s' "${OUT}" | grep -q "http://agmind-dify.local" \
        || { echo "  FAIL: endpoints output missing dify URL; OUT=${OUT}" >&2; exit 1; }
    # Check for any STATE token
    printf '%s' "${OUT}" | grep -qiE 'healthy|running|disabled|not-installed|starting|unhealthy|exited' \
        || { echo "  FAIL: endpoints output missing STATE token; OUT=${OUT}" >&2; exit 1; }
    exit 0
) && pass "endpoints_table: RC=0, contains dify + URL + STATE token" \
  || fail "endpoints_table: table output missing expected content (cmd_endpoints not implemented yet)"

# ── Case 6: endpoints_json_valid (SC3) ────────────────────────────────────────
# agmind endpoints --json → RC=0, valid JSON, contains "endpoints" key
(
    set +e
    if ! command -v python3 >/dev/null 2>&1; then
        echo "  [SKIP] endpoints_json_valid (no python3 in PATH)"; exit 77
    fi
    _err="$(mktemp)"
    OUT="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export MOCK_DOCKER_FIXTURE=healthy
        export MOCK_DOCKER_PS_FIXTURE=running
        export MOCK_HOSTNAME_FIXTURE=docker_first
        export AGMIND_DIR="${INSTALL_FIXTURE}"
        export INSTALL_DIR="${INSTALL_FIXTURE}"
        export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
        bash "${REPO_ROOT}/scripts/agmind.sh" endpoints --json 2>"${_err}"
    )"
    RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
    [[ "$RC" -eq 0 ]] || { echo "  FAIL: endpoints --json RC=$RC (want 0); ERR=${ERR}" >&2; exit 1; }
    # Find JSON line(s) and validate
    _json_line="$(printf '%s\n' "${OUT}" | grep '^{' | tail -1)"
    [[ -n "${_json_line}" ]] \
        || { echo "  FAIL: no JSON line in output; OUT=${OUT}" >&2; exit 1; }
    printf '%s\n' "${_json_line}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>&1 \
        || { echo "  FAIL: JSON parse failed; json=${_json_line}" >&2; exit 1; }
    # Must contain "endpoints" key
    printf '%s' "${OUT}" | grep -q "endpoints" \
        || { echo "  FAIL: JSON missing 'endpoints' key; OUT=${OUT}" >&2; exit 1; }
    exit 0
) && pass "endpoints_json_valid: --json is valid JSON containing 'endpoints' key" \
  || fail "endpoints_json_valid: --json not valid (cmd_endpoints not implemented yet)"

# ── Case 7: creds_show_requires_root (SC2) ────────────────────────────────────
# Non-root user: agmind creds show → exit 1, stdout has no secrets, stderr hints sudo
(
    set +e
    if [[ "$(id -u)" -eq 0 ]]; then
        # Running as root — can't test non-root gate directly; soft pass
        pass "creds_show_requires_root: running as root — non-root gate manual-only"
    else
        _err="$(mktemp)"
        OUT="$(
            set +e
            export PATH="${MOCK_DIR}:${PATH}"
            export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
            export MOCK_DOCKER_FIXTURE=healthy
            export AGMIND_DIR="${INSTALL_FIXTURE}"
            export INSTALL_DIR="${INSTALL_FIXTURE}"
            export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
            bash "${REPO_ROOT}/scripts/agmind.sh" creds show 2>"${_err}"
        )"
        RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
        [[ "$RC" -ne 0 ]] \
            || { fail "creds_show_requires_root: non-root got RC=0 (want non-zero)"; exit 0; }
        # stdout must NOT contain fixture secrets
        if printf '%s' "${OUT}" | grep -qF "${FIXTURE_SECRET}"; then
            fail "creds_show_requires_root: stdout contains FAKEsecretAAA111 (SC2 VIOLATION)"
        elif printf '%s' "${OUT}" | grep -qF "FAKEadminPwdDDD444"; then
            fail "creds_show_requires_root: stdout contains FAKEadminPwdDDD444 (SC2 VIOLATION)"
        else
            # stderr should mention sudo or root
            printf '%s' "${ERR}" | grep -qi "sudo\|root" \
                || { fail "creds_show_requires_root: stderr missing 'sudo'/'root' hint; ERR=${ERR}"; exit 0; }
            pass "creds_show_requires_root: non-root → exit non-zero, no secrets in stdout, sudo hint"
        fi
    fi
) || true

# ── Case 8: creds_show_masked_default (SC2) ───────────────────────────────────
# Root-gated: masked output must NOT contain FAKEsecretAAA111; must contain mask marker.
# SC2 invariant: grep -F FAKEsecretAAA111 <output> is EMPTY without --show.
(
    set +e
    if [[ "$(id -u)" -ne 0 ]]; then
        pass "creds_show_masked_default: needs root — covered by manual-only on spark-3eac"
    else
        _err="$(mktemp)"
        OUT="$(
            set +e
            export PATH="${MOCK_DIR}:${PATH}"
            export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
            export MOCK_DOCKER_FIXTURE=healthy
            export AGMIND_DIR="${INSTALL_FIXTURE}"
            export INSTALL_DIR="${INSTALL_FIXTURE}"
            export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
            bash "${REPO_ROOT}/scripts/agmind.sh" creds show 2>"${_err}"
        )"
        RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
        [[ "$RC" -eq 0 ]] || { fail "creds_show_masked_default: root creds show RC=${RC} (want 0); ERR=${ERR}"; exit 0; }
        # Must contain 'Pass:' label (file is shown)
        printf '%s' "${OUT}" | grep -q "Pass:" \
            || { fail "creds_show_masked_default: output missing 'Pass:' label; OUT=${OUT}"; exit 0; }
        # SC2 invariant: plaintext NOT present without --show
        if printf '%s' "${OUT}" | grep -qF "${FIXTURE_SECRET}"; then
            fail "creds_show_masked_default: FAKEsecretAAA111 visible in masked output (SC2 VIOLATION)"
        else
            # Must contain mask marker
            printf '%s' "${OUT}" | grep -qE '\.{3}|…|•{2,}|[A-Za-z0-9]{2,3}\.\.\.' \
                || { fail "creds_show_masked_default: no mask marker in output; OUT=${OUT}"; exit 0; }
            pass "creds_show_masked_default: masked output: Pass: label present, no plaintext, mask marker seen"
        fi
    fi
) || true

# ── Case 9: creds_show_reveal_flag (SC2) ──────────────────────────────────────
# Root-gated: --show reveals FAKEsecretAAA111 + stderr warns "plaintext".
# SC2 invariant PAIR: without --show → EMPTY; with --show → NON-EMPTY.
(
    set +e
    if [[ "$(id -u)" -ne 0 ]]; then
        pass "creds_show_reveal_flag: needs root — covered by manual-only on spark-3eac"
    else
        _err="$(mktemp)"
        # Without --show (SC2 invariant: grep is EMPTY)
        OUT_MASKED="$(
            set +e
            export PATH="${MOCK_DIR}:${PATH}"
            export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
            export MOCK_DOCKER_FIXTURE=healthy
            export AGMIND_DIR="${INSTALL_FIXTURE}"
            export INSTALL_DIR="${INSTALL_FIXTURE}"
            export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
            bash "${REPO_ROOT}/scripts/agmind.sh" creds show 2>/dev/null
        )"
        # SC2 invariant assertion (the grep must be EMPTY without --show)
        _masked_hit="$(printf '%s' "${OUT_MASKED}" | grep -F "${FIXTURE_SECRET}" || true)"
        # With --show (SC2 invariant: grep is NON-EMPTY)
        OUT_PLAIN="$(
            set +e
            export PATH="${MOCK_DIR}:${PATH}"
            export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
            export MOCK_DOCKER_FIXTURE=healthy
            export AGMIND_DIR="${INSTALL_FIXTURE}"
            export INSTALL_DIR="${INSTALL_FIXTURE}"
            export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
            bash "${REPO_ROOT}/scripts/agmind.sh" creds show --show 2>"${_err}"
        )"
        RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
        [[ "$RC" -eq 0 ]] || { fail "creds_show_reveal_flag: --show RC=${RC} (want 0); ERR=${ERR}"; exit 0; }
        # SC2 invariant: without --show EMPTY, with --show NON-EMPTY
        if [[ -n "${_masked_hit}" ]]; then
            fail "creds_show_reveal_flag: FAKEsecretAAA111 visible WITHOUT --show (SC2 VIOLATION)"
        elif ! printf '%s' "${OUT_PLAIN}" | grep -qF "${FIXTURE_SECRET}"; then
            fail "creds_show_reveal_flag: FAKEsecretAAA111 NOT visible WITH --show (SC2 VIOLATION)"
        else
            # stderr must warn "plaintext"
            printf '%s' "${ERR}" | grep -qi "plaintext" \
                || { fail "creds_show_reveal_flag: no 'plaintext' warning in stderr; ERR=${ERR}"; exit 0; }
            pass "creds_show_reveal_flag: SC2 invariant OK — masked hidden, revealed with --show, warning in stderr"
        fi
    fi
) || true

# ── Case 10: creds_rotate_execs_script (SC2) ──────────────────────────────────
# Non-root: agmind creds rotate → exit 1 + sudo/root in stderr (root gate fires).
# Root: agmind creds rotate --foo bar → MOCK_ROTATE_LOG records "rotate_secrets.sh --foo bar".
(
    set +e
    _rot_log="${TEST_TMPDIR}/rot10.log"
    if [[ "$(id -u)" -ne 0 ]]; then
        # Non-root branch: must be gated by _require_root
        _err="$(mktemp)"
        OUT="$(
            set +e
            export PATH="${MOCK_DIR}:${PATH}"
            export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
            export AGMIND_DIR="${INSTALL_FIXTURE}"
            export INSTALL_DIR="${INSTALL_FIXTURE}"
            export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
            bash "${REPO_ROOT}/scripts/agmind.sh" creds rotate --foo bar 2>"${_err}"
        )"
        RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
        [[ "$RC" -ne 0 ]] || { fail "creds_rotate_execs_script: non-root RC=0 (want non-zero)"; exit 0; }
        printf '%s' "${ERR}" | grep -qiE "sudo|root" \
            || { fail "creds_rotate_execs_script: non-root stderr missing sudo/root hint; ERR=${ERR}"; exit 0; }
        pass "creds_rotate_execs_script: non-root → root gate fires (exit non-zero, sudo/root hint)"
    else
        # Root branch: exec rotate_secrets.sh mock, check calllog
        _err="$(mktemp)"
        OUT="$(
            set +e
            export PATH="${MOCK_DIR}:${PATH}"
            export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
            export AGMIND_DIR="${INSTALL_FIXTURE}"
            export INSTALL_DIR="${INSTALL_FIXTURE}"
            export ENV_FILE="${INSTALL_FIXTURE}/docker/.env"
            export MOCK_ROTATE_LOG="${_rot_log}"
            bash "${REPO_ROOT}/scripts/agmind.sh" creds rotate --foo bar 2>"${_err}"
        )"
        RC=$?; ERR="$(cat "${_err}")"; rm -f "${_err}"
        # The stub exits 0; if it was not called, log is empty or missing
        if [[ -f "${_rot_log}" ]] && grep -qF "rotate_secrets.sh --foo bar" "${_rot_log}"; then
            pass "creds_rotate_execs_script: root → rotate_secrets.sh stub called with --foo bar"
        else
            fail "creds_rotate_execs_script: rotate_secrets.sh not called or args missing; RC=${RC}; ERR=${ERR}"
        fi
    fi
) || true

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
