#!/usr/bin/env bash
# tests/unit/test_troubleshoot_cmd.sh — smoke test scaffold for agmind troubleshoot.
# RED until Plan 05 implements cmd_troubleshoot in scripts/agmind.sh.
# Exit: 0=PASS 1=FAIL 77=SKIP
#
# Cases (when cmd_troubleshoot is implemented):
#   1. agmind troubleshoot (no arg) → exit 0 + output contains word "темы" or "topics"
#   2. agmind troubleshoot vllm   → exit 0 + non-empty stdout
#   3. agmind troubleshoot __nonexistent__ → exit 1 (non-zero)
#
# SKIP gate: if agmind troubleshoot returns "Unknown command" (not yet implemented) → exit 77
set -uo pipefail   # NOT -e — we capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"

# Null out colors so test output is plain text
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_troubleshoot_cmd"

# ── Shared test directory ──────────────────────────────────────────────────────
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# ── Build INSTALL_FIXTURE (fake runtime root for agmind.sh subprocess) ─────────
INSTALL_FIXTURE="${TEST_TMPDIR}/opt"
mkdir -p "${INSTALL_FIXTURE}/docker" "${INSTALL_FIXTURE}/scripts" \
         "${INSTALL_FIXTURE}/lib" "${INSTALL_FIXTURE}/logs"

cp "${REPO_ROOT}/scripts/"*.sh "${INSTALL_FIXTURE}/scripts/"
cp "${REPO_ROOT}/lib/"*.sh     "${INSTALL_FIXTURE}/lib/"

# Copy docs/troubleshooting.md so cmd_troubleshoot can find it via AGMIND_DIR
mkdir -p "${INSTALL_FIXTURE}/docs"
cp "${REPO_ROOT}/docs/troubleshooting.md" "${INSTALL_FIXTURE}/docs/"

for _lib in common.sh detect.sh service-map.sh health.sh doctor.sh status.sh \
            config.sh restore.sh peer.sh phases.sh creds.sh; do
    [[ -f "${REPO_ROOT}/lib/${_lib}" ]] \
        && ln -sf "${REPO_ROOT}/lib/${_lib}" "${INSTALL_FIXTURE}/scripts/${_lib}"
done

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
# Captures stdout → OUT, stderr → ERR, exit code → RC.
# RC is written to a tmp file to survive the $() subshell.
_run() {
    local _err _rcfile
    _err="$(mktemp)"
    _rcfile="$(mktemp)"
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
        printf '%d' $? > "${_rcfile}"
    )"
    RC="$(cat "${_rcfile}" 2>/dev/null || echo 0)"
    ERR="$(cat "${_err}")"
    rm -f "${_err}" "${_rcfile}"
    return 0
}

# ── SKIP gate: exit 77 if cmd_troubleshoot not yet implemented ─────────────────
_run troubleshoot
if [[ "$RC" -ne 0 ]] && printf '%s' "${ERR}" | grep -qi "Unknown command"; then
    echo "SKIP — cmd_troubleshoot not implemented yet"
    exit 77
fi

# ── Case 1: bare troubleshoot lists topics ─────────────────────────────────────
_run troubleshoot
if [[ "$RC" -eq 0 ]] && { printf '%s' "${OUT}" | grep -qi "темы" || printf '%s' "${OUT}" | grep -qi "topics"; }; then
    pass "troubleshoot_no_arg: exit 0 + topics list printed"
else
    fail "troubleshoot_no_arg: RC=${RC}, OUT=${OUT}, ERR=${ERR}"
fi

# ── Case 2: troubleshoot vllm → exit 0 + non-empty output ─────────────────────
_run troubleshoot vllm
if [[ "$RC" -eq 0 ]] && [[ -n "${OUT}" ]]; then
    pass "troubleshoot_vllm: exit 0 + non-empty stdout"
else
    fail "troubleshoot_vllm: RC=${RC}, OUT='${OUT}', ERR=${ERR}"
fi

# ── Case 3: troubleshoot __nonexistent__ → exit 1 ─────────────────────────────
_run troubleshoot __nonexistent__
if [[ "$RC" -ne 0 ]]; then
    pass "troubleshoot_nonexistent: exit non-zero for unknown topic"
else
    fail "troubleshoot_nonexistent: RC=0 (want non-zero); OUT=${OUT}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
