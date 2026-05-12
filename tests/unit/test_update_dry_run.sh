#!/usr/bin/env bash
# tests/unit/test_update_dry_run.sh — RED unit tests for update.sh --dry-run (Phase 4 Plan 03).
# Tests FAIL until scripts/update.sh implements --dry-run flag (Wave-0 / Plan 04-01).
# Cases: runs_without_root · prints_version_diff · prints_would_recreate
#        prints_pg_major_warning · zero_mutation · exits_before_dry_run_marker
# Exit: 0=PASS 1=FAIL 77=SKIP
set -uo pipefail  # NOT -e — capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"

# Null colors
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_update_dry_run"

# Verify update.sh exists
if [[ ! -f "${REPO_ROOT}/scripts/update.sh" ]]; then
    echo "SKIP: scripts/update.sh not found"
    exit 77
fi

# ── Shared tmpdir ─────────────────────────────────────────────────────────────
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# ── Shared mock curl response (fake versions.env with one bumped version) ─────
# current DIFY_VERSION=1.13.3, new versions.env returns 1.14.0
# current POSTGRES_VERSION stays same (not a major bump) except TC4 which overrides
MOCK_VERSIONS_BODY="DIFY_VERSION=1.14.0
WEAVIATE_VERSION=1.27.0
REDIS_VERSION=7.4.1-alpine
POSTGRES_VERSION=16-alpine
"

# ── Helper: build a minimal INSTALL_DIR fixture ───────────────────────────────
_mk_update_install_dir() {
    local dir="$1" pg_ver="${2:-16-alpine}"
    mkdir -p "${dir}/docker"
    cat > "${dir}/docker/.env" <<ENVEOF
DIFY_VERSION=1.13.3
WEAVIATE_VERSION=1.27.0
REDIS_VERSION=7.4.1-alpine
POSTGRES_VERSION=${pg_ver}
LLM_PROVIDER=vllm
VECTOR_STORE=weaviate
STORAGE_TYPE=local
ENVEOF
    # versions.env at INSTALL_DIR root
    cat > "${dir}/versions.env" <<VEREOF
DIFY_VERSION=1.13.3
WEAVIATE_VERSION=1.27.0
REDIS_VERSION=7.4.1-alpine
POSTGRES_VERSION=${pg_ver}
VEREOF
}

# ── TC1: runs_without_root ────────────────────────────────────────────────────
# bash scripts/update.sh --dry-run as non-root → must NOT print "must be run as root"
# Uses mock curl so network isn't needed.
(
    set +e
    d="${TMP_ROOT}/tc1"
    _mk_update_install_dir "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_CURL_EXIT=0
    export MOCK_CURL_RESPONSE="$MOCK_VERSIONS_BODY"
    out="$(bash "${REPO_ROOT}/scripts/update.sh" --dry-run 2>&1)"
    rc=$?
    # Must exit 0 and NOT say "must be run as root"
    [[ "$rc" -eq 0 ]] && ! echo "$out" | grep -qi 'must be run as root'
) && pass "TC1 runs_without_root: --dry-run exits 0 without root-check error" \
  || fail "TC1 runs_without_root: expected rc=0 without root error (RED until Plan 03)"

# ── TC2: prints_version_diff ─────────────────────────────────────────────────
# --dry-run output shows version diff (DIFY_VERSION bumped 1.13.3→1.14.0)
(
    set +e
    d="${TMP_ROOT}/tc2"
    _mk_update_install_dir "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_CURL_EXIT=0
    export MOCK_CURL_RESPONSE="$MOCK_VERSIONS_BODY"
    out="$(bash "${REPO_ROOT}/scripts/update.sh" --dry-run 2>&1)"
    rc=$?
    # Should mention DIFY_VERSION and the two version strings
    [[ "$rc" -eq 0 ]] \
        && ( echo "$out" | grep -q 'DIFY_VERSION' || echo "$out" | grep -q '1.13.3' ) \
        && ( echo "$out" | grep -q '1.14.0' || echo "$out" | grep -qi 'version' )
) && pass "TC2 prints_version_diff: --dry-run output shows version diff for DIFY_VERSION" \
  || fail "TC2 prints_version_diff: expected version diff in output (RED until Plan 03)"

# ── TC3: prints_would_recreate ────────────────────────────────────────────────
# --dry-run output mentions 'Would recreate' and at least one service name
(
    set +e
    d="${TMP_ROOT}/tc3"
    _mk_update_install_dir "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_CURL_EXIT=0
    export MOCK_CURL_RESPONSE="$MOCK_VERSIONS_BODY"
    out="$(bash "${REPO_ROOT}/scripts/update.sh" --dry-run 2>&1)"
    rc=$?
    [[ "$rc" -eq 0 ]] && echo "$out" | grep -qi 'would recreate'
) && pass "TC3 prints_would_recreate: --dry-run output contains 'Would recreate'" \
  || fail "TC3 prints_would_recreate: expected 'Would recreate' in output (RED until Plan 03)"

# ── TC4: prints_pg_major_warning ─────────────────────────────────────────────
# POSTGRES_VERSION bumped 16-alpine→17-alpine → output mentions PostgreSQL + major
(
    set +e
    d="${TMP_ROOT}/tc4"
    _mk_update_install_dir "$d" "16-alpine"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_CURL_EXIT=0
    # Override: new versions.env has PG 17
    export MOCK_CURL_RESPONSE="DIFY_VERSION=1.14.0
WEAVIATE_VERSION=1.27.0
REDIS_VERSION=7.4.1-alpine
POSTGRES_VERSION=17-alpine
"
    out="$(bash "${REPO_ROOT}/scripts/update.sh" --dry-run 2>&1)"
    rc=$?
    [[ "$rc" -eq 0 ]] \
        && echo "$out" | grep -qi 'postgresql\|postgres' \
        && echo "$out" | grep -qi 'major'
) && pass "TC4 prints_pg_major_warning: PG major bump → output mentions PostgreSQL + major" \
  || fail "TC4 prints_pg_major_warning: expected PG major warning (RED until Plan 03)"

# ── TC5: zero_mutation ───────────────────────────────────────────────────────
# --dry-run must not change any files in INSTALL_DIR
# Also must not write *downloaded*versions* or *.tmp or .update-* under INSTALL_DIR
(
    set +e
    d="${TMP_ROOT}/tc5"
    _mk_update_install_dir "$d"
    export INSTALL_DIR="$d"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_CURL_EXIT=0
    export MOCK_CURL_RESPONSE="$MOCK_VERSIONS_BODY"

    # Snapshot before
    snap_before="$(find "$d" -type f -exec sha256sum {} \; 2>/dev/null | sort)"

    bash "${REPO_ROOT}/scripts/update.sh" --dry-run > /dev/null 2>&1

    # Snapshot after
    snap_after="$(find "$d" -type f -exec sha256sum {} \; 2>/dev/null | sort)"

    # Assert snapshots identical AND no tmp/downloaded files under INSTALL_DIR
    tmp_files="$(find "$d" \( -name '*downloaded*' -o -name '*.tmp' -o -name '.update-*' \) 2>/dev/null || true)"

    [[ "$snap_before" == "$snap_after" ]] && [[ -z "$tmp_files" ]]
) && pass "TC5 zero_mutation: INSTALL_DIR files unchanged + no tmp artifacts after --dry-run" \
  || fail "TC5 zero_mutation: --dry-run mutated files or created tmp artifacts (RED until Plan 03)"

# ── TC6: exits_before_dry_run_marker ─────────────────────────────────────────
# Static: scripts/update.sh contains --dry-run handling
(
    set +e
    grep -q -- '--dry-run' "${REPO_ROOT}/scripts/update.sh" \
        && grep -qi 'dry.run\|DRY_RUN' "${REPO_ROOT}/scripts/update.sh"
) && pass "TC6 exits_before_dry_run_marker: update.sh contains --dry-run flag handling" \
  || fail "TC6 exits_before_dry_run_marker: update.sh missing --dry-run (RED until Plan 03)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "## test_update_dry_run: ${PASS} PASS, ${FAIL} FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
