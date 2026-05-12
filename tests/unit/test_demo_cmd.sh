#!/usr/bin/env bash
# tests/unit/test_demo_cmd.sh — smoke test scaffold for agmind demo.
# RED until Plan 05 implements cmd_demo in scripts/agmind.sh.
# Exit: 0=PASS 1=FAIL 77=SKIP
#
# Cases (when cmd_demo is implemented):
#   1. agmind demo (no arg) → exit 1 + output contains "install" and "ingest" and "ask" (usage)
#   2. agmind demo help     → exit 1 (usage) + non-empty output
#
# SKIP gate: if agmind demo returns "Unknown command" (not yet implemented) → exit 77
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

echo "## test_demo_cmd"

# ── Shared test directory ──────────────────────────────────────────────────────
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# ── Build INSTALL_FIXTURE (fake runtime root for agmind.sh subprocess) ─────────
INSTALL_FIXTURE="${TEST_TMPDIR}/opt"
mkdir -p "${INSTALL_FIXTURE}/docker" "${INSTALL_FIXTURE}/scripts" \
         "${INSTALL_FIXTURE}/lib" "${INSTALL_FIXTURE}/logs"

cp "${REPO_ROOT}/scripts/"*.sh "${INSTALL_FIXTURE}/scripts/"
cp "${REPO_ROOT}/lib/"*.sh     "${INSTALL_FIXTURE}/lib/"

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

# ── SKIP gate: exit 77 if cmd_demo not yet implemented ────────────────────────
_run demo
if [[ "$RC" -ne 0 ]] && printf '%s' "${ERR}" | grep -qi "Unknown command"; then
    echo "SKIP — cmd_demo not implemented yet"
    exit 77
fi

# ── Case 1: demo bare/no-arg → exit 1 + usage contains install/ingest/ask ─────
_run demo
if [[ "$RC" -ne 0 ]] \
   && { printf '%s\n%s' "${OUT}" "${ERR}" | grep -qi "install"; } \
   && { printf '%s\n%s' "${OUT}" "${ERR}" | grep -qi "ingest"; } \
   && { printf '%s\n%s' "${OUT}" "${ERR}" | grep -qi "ask"; }; then
    pass "demo_no_arg: exit non-zero + usage contains install/ingest/ask"
else
    fail "demo_no_arg: RC=${RC}, OUT=${OUT}, ERR=${ERR}"
fi

# ── Case 2: demo help → exit 1 + non-empty output ─────────────────────────────
_run demo help
_combined="${OUT}${ERR}"
if [[ "$RC" -ne 0 ]] && [[ -n "${_combined}" ]]; then
    pass "demo_help: exit non-zero + non-empty output"
else
    fail "demo_help: RC=${RC}, OUT='${OUT}', ERR='${ERR}'"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
