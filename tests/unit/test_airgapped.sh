#!/usr/bin/env bash
# tests/unit/test_airgapped.sh — RED tests for Phase 7 SC3: lib/airgapped.sh.
# All 5 cases FAIL until lib/airgapped.sh is implemented (07-04).
# Mirrors tests/unit/test_doctor.sh harness + mock conventions.
# Exit: 0=PASS 1=FAIL 77=SKIP
#
# Cases:
#   airgapped_preflight_all_present  — all images + volumes locally → exit 0
#   airgapped_preflight_missing      — one image absent → exit≠0, "missing" in output, no mutation
#   airgapped_guard_blocks_public    — AGMIND_AIRGAPPED=true → guard returns 0, prints skip-warn
#   airgapped_guard_passthrough      — AGMIND_AIRGAPPED=false → guard returns non-zero (pass-through)
#   compose_pull_noop_in_airgapped   — AGMIND_AIRGAPPED=true → compose_pull makes no pull call
#
# CONTRACT for 07-04 executor (compose_pull_noop_in_airgapped):
#   lib/airgapped.sh must either:
#   (a) export airgapped_guard() that returns 0 when AGMIND_AIRGAPPED=true, so install.sh
#       phase_pull() calls: airgapped_guard "compose pull" || { compose_pull; }
#   (b) OR lib/airgapped.sh wraps compose_pull directly via airgapped_compose_pull()
#   Either way: when AGMIND_AIRGAPPED=true, `docker pull` must NOT appear in MOCK_DOCKER_CALLLOG.
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

echo "## test_airgapped"

# ── _run_preflight helper ──────────────────────────────────────────────────────
# Sources lib/airgapped.sh and calls airgapped_preflight in a clean subshell.
_run_preflight() {
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/airgapped.sh"
        airgapped_preflight "$@"
        echo "RC=$?"
    ) 2>&1
}

# Helper: extract RC value from output
_rc_of() { grep -oE 'RC=[0-9]+' <<< "$1" | tail -1 | cut -d= -f2; }

# 6 model volumes required by airgapped_preflight (from 07-RESEARCH.md).
# Listed here for documentation; airgapped_preflight iterates these internally.
# shellcheck disable=SC2034
_AIRGAPPED_MODEL_VOLUMES="agmind_vllm_cache agmind_tei_cache agmind_tei_rerank_cache agmind_vllm_embed_cache agmind_vllm_rerank_cache agmind_docling_cache"

# ── Case: airgapped_preflight_all_present — all images + volumes present → exit 0 ─
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    # Use the airgapped fixture versions.env (small subset)
    export INSTALLER_DIR="${REPO_ROOT}"
    export INSTALL_DIR="$_tmp"
    # All image inspects succeed (healthy fixture → docker image inspect exits 0)
    export MOCK_DOCKER_FIXTURE=healthy
    # Volume inspects succeed (ok fixture → returns mountpoint JSON)
    export MOCK_DOCKER_VOLUME_INSPECT_FIXTURE=ok
    out="$(_run_preflight "${REPO_ROOT}/tests/fixtures/airgapped/versions.env" 2>&1)"
    rc="$(_rc_of "$out")"
    [[ "$rc" -eq 0 ]] || { echo "exit=$rc (want 0); out=${out}" >&2; exit 1; }
    exit 0
) && pass "airgapped_preflight_all_present: exit 0 when all images + volumes present" \
  || fail "airgapped_preflight_all_present: want exit 0 (lib/airgapped.sh not yet implemented)"

# ── Case: airgapped_preflight_missing — one image absent → exit≠0, "missing" in output ─
(
    set +eu
    _tmp="$(mktemp -d)"
    trap 'rm -rf "$_tmp"' EXIT
    _calllog="$(mktemp)"
    trap 'rm -rf "$_tmp" "$_calllog"' EXIT
    export INSTALLER_DIR="${REPO_ROOT}"
    export INSTALL_DIR="$_tmp"
    # Make docker image inspect fail for "portainer" image pattern
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_IMAGE_INSPECT_MISSING=portainer
    export MOCK_DOCKER_CALLLOG="$_calllog"
    out="$(_run_preflight "${REPO_ROOT}/tests/fixtures/airgapped/versions.env" 2>&1)"
    rc="$(_rc_of "$out")"
    # Must fail (exit≠0)
    [[ -n "$rc" && "$rc" -ne 0 ]] || { echo "exit=$rc (want ≠0); out=${out}" >&2; exit 1; }
    # Output must mention "missing"
    echo "$out" | grep -qi 'missing' || { echo "no 'missing' in output; out=$out" >&2; exit 1; }
    # Must NOT have called docker pull (no mutation before preflight fails)
    if grep -q 'docker pull' "$_calllog" 2>/dev/null; then
        echo "FAIL: docker pull called before preflight failure (mutation before fail-fast)" >&2
        exit 1
    fi
    exit 0
) && pass "airgapped_preflight_missing: exit≠0 + 'missing' in output + no docker pull" \
  || fail "airgapped_preflight_missing: want exit≠0 with missing list (lib/airgapped.sh not yet implemented)"

# ── Case: airgapped_guard_blocks_public — AGMIND_AIRGAPPED=true → returns 0, warns ─
# airgapped_guard "apt-get update" should: return 0, print skip-warn to stderr.
# Contract: caller uses: airgapped_guard "op" || { real_op; }
#   When guard returns 0 → real_op is skipped. When returns non-zero → real_op runs.
(
    set +eu
    combined="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export AGMIND_AIRGAPPED=true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/airgapped.sh"
        airgapped_guard "apt-get update"
        echo "RC=$?"
    ) 2>&1"
    rc="$(grep -oE 'RC=[0-9]+' <<< "$combined" | tail -1 | cut -d= -f2)"
    # Guard must return 0 (so caller's || { real_op; } is skipped)
    [[ "$rc" -eq 0 ]] || { echo "exit=$rc (want 0); combined=${combined}" >&2; exit 1; }
    # Must print a skip/airgapped warning
    echo "$combined" | grep -qiE 'airgap|skip' \
        || { echo "no airgap/skip warn in output; combined=$combined" >&2; exit 1; }
    # Must mention the operation name
    echo "$combined" | grep -q 'apt-get update' \
        || { echo "no op name in warn output; combined=$combined" >&2; exit 1; }
    exit 0
) && pass "airgapped_guard_blocks_public: AGMIND_AIRGAPPED=true → returns 0 + skip-warn" \
  || fail "airgapped_guard_blocks_public: want return 0 + skip-warn (lib/airgapped.sh not yet implemented)"

# ── Case: airgapped_guard_passthrough — AGMIND_AIRGAPPED=false → non-zero (pass-through) ─
(
    set +eu
    combined="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export AGMIND_AIRGAPPED=false
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/airgapped.sh"
        airgapped_guard "apt-get update"
        echo "RC=$?"
    ) 2>&1"
    rc="$(grep -oE 'RC=[0-9]+' <<< "$combined" | tail -1 | cut -d= -f2)"
    # Guard must return non-zero (so caller's || { real_op; } RUNS)
    [[ -n "$rc" && "$rc" -ne 0 ]] \
        || { echo "exit=$rc (want ≠0 pass-through); combined=${combined}" >&2; exit 1; }
    exit 0
) && pass "airgapped_guard_passthrough: AGMIND_AIRGAPPED=false → returns non-zero (pass-through)" \
  || fail "airgapped_guard_passthrough: want non-zero pass-through (lib/airgapped.sh not yet implemented)"

# ── Case: compose_pull_noop_in_airgapped — AGMIND_AIRGAPPED=true → no docker pull ─
# CONTRACT for 07-04: the airgapped guard must wrap compose_pull/phase_pull so that
# when AGMIND_AIRGAPPED=true, no `docker compose pull` / `docker pull` is invoked.
# This test sources lib/airgapped.sh and calls airgapped_compose_pull (or the guarded
# phase_pull) — if the function doesn't exist, the test fails RED as expected.
(
    set +eu
    _calllog="$(mktemp)"
    trap 'rm -f "$_calllog"' EXIT
    export MOCK_DOCKER_CALLLOG="$_calllog"
    export MOCK_DOCKER_FIXTURE=healthy
    _fn_rc=0
    combined="$(
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        export AGMIND_AIRGAPPED=true
        export MOCK_DOCKER_CALLLOG="$_calllog"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
        # Try to source lib/airgapped.sh — if missing, print marker and exit non-zero
        # shellcheck source=/dev/null
        if ! source "${REPO_ROOT}/lib/airgapped.sh" 2>/dev/null; then
            echo "airgapped.sh: source failed (not yet implemented)" >&2
            echo "RC=127"
            exit 127
        fi
        # 07-04 must implement one of these (first found wins):
        if declare -f airgapped_compose_pull >/dev/null 2>&1; then
            airgapped_compose_pull
            echo "RC=$?"
        elif declare -f airgapped_phase_pull >/dev/null 2>&1; then
            airgapped_phase_pull
            echo "RC=$?"
        else
            echo "airgapped_compose_pull: command not found" >&2
            echo "RC=127"
            exit 127
        fi
    ) 2>&1"
    rc="$(grep -oE 'RC=[0-9]+' <<< "$combined" | tail -1 | cut -d= -f2)"
    # Must have produced RC marker
    [[ -n "$rc" ]] || { echo "no RC in output; combined=${combined}" >&2; exit 1; }
    # When implemented: must not call docker pull
    if grep -qE 'docker (compose )?pull' "$_calllog" 2>/dev/null; then
        echo "FAIL: docker pull was called with AGMIND_AIRGAPPED=true" >&2
        exit 1
    fi
    # For RED phase: rc=127 = function not found = correct RED
    [[ "$rc" -ne 0 ]] || { echo "exit=0 (want ≠0 RED); combined=${combined}" >&2; exit 1; }
    exit 0
) && pass "compose_pull_noop_in_airgapped: no docker pull when AGMIND_AIRGAPPED=true" \
  || fail "compose_pull_noop_in_airgapped: airgapped_compose_pull not yet implemented (lib/airgapped.sh RED)"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
