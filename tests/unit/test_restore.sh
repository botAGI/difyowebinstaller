#!/usr/bin/env bash
# tests/unit/test_restore.sh — unit coverage for Phase 5 lib/restore.sh (verify / plan / selective / latest).
# Runs without root. Uses tests/mocks/ via PATH prepend. Exit 77=SKIP 0=PASS 1=FAIL.
# Cases: TC1 verify_happy_path · TC2 verify_corrupt_tar · TC3 verify_checksum_fail · TC4 verify_empty_sql
#        TC5 verify_missing_artifact · TC5b verify_old_no_manifest · TC6 dry_run_read_only · TC7 dry_run_plan_sections
#        TC8 selective_scope_dify · TC9 selective_scope_rag · TC10 unknown_service_exit1
#        TC11 latest_resolver · TC12 latest_no_backups · TC13 backup_writes_manifest (static)
set -uo pipefail   # NOT -e — capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"
export MOCK_DOCKER_FIXTURE=healthy

# Null out colors so test output is plain text (no escape sequences in diffs)
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_restore"

# ── Shared tmp root ───────────────────────────────────────────────────────────
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# ── _mk_fixture <dir> <with_manifest:true|false> ─────────────────────────────
# Builds a valid fake backup directory with real gzip/tar artifacts.
_mk_fixture() {
    local dir="$1" with_manifest="${2:-true}"
    mkdir -p "$dir"
    # Valid pg_dump SQL with standard header markers
    printf -- '-- PostgreSQL database dump\nSET statement_timeout = 0;\nSET lock_timeout = 0;\n' \
        | gzip > "${dir}/dify_db.sql.gz"
    # Valid tiny tar.gz (single dummy file inside)
    local tmpf; tmpf="$(mktemp)"
    printf 'dummy vector store data\n' > "$tmpf"
    tar czf "${dir}/weaviate.tar.gz" -C "$(dirname "$tmpf")" "$(basename "$tmpf")"
    rm -f "$tmpf"
    # env.backup — core config artifact
    printf 'VECTOR_STORE=weaviate\nDIFY_VERSION=1.13.3\nCOMPOSE_PROFILES=monitoring,weaviate\n' \
        > "${dir}/env.backup"
    chmod 600 "${dir}/env.backup"
    # sha256sums.txt — computed from artifacts
    ( cd "$dir" && sha256sum ./*.gz ./*.backup 2>/dev/null > sha256sums.txt || true )
    # MANIFEST.txt
    if [[ "$with_manifest" == "true" ]]; then
        {
            echo "# AGmind backup manifest v1"
            echo "# Schema: 1"
            echo "dify_db.sql.gz"
            echo "weaviate.tar.gz"
            echo "env.backup"
            echo "sha256sums.txt"
        } > "${dir}/MANIFEST.txt"
    fi
}

# ── TC1: verify_happy_path ────────────────────────────────────────────────────
# restore_verify on valid fixture → exit 0, no [FAIL] in output (Plan 02 GREEN).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc1_install"
    export BACKUP_BASE="${TMP_ROOT}/tc1_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc1_fix"
    _mk_fixture "$fix_dir"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    out="$(restore_verify "$fix_dir" 2>&1)"
    rc=$?
    # Plan 02: valid fixture → exit 0 AND no [FAIL] lines
    [[ "$rc" -eq 0 ]] && ! echo "$out" | grep -q '\[FAIL\]'
) && pass "TC1 verify_happy_path: valid fixture → restore_verify exits 0, no [FAIL]" \
  || fail "TC1 verify_happy_path: restore_verify did not exit 0 or printed [FAIL] on valid fixture"

# ── TC2: verify_corrupt_tar ───────────────────────────────────────────────────
# Overwrite last 4 bytes of weaviate.tar.gz → gzip -t fails (corruption confirmed).
# restore_verify must exit 1 with [FAIL] in output (Plan 02 GREEN).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc2_install"
    export BACKUP_BASE="${TMP_ROOT}/tc2_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc2_fix"
    _mk_fixture "$fix_dir"
    # Corrupt weaviate.tar.gz — overwrite last 4 bytes (guaranteed CRC mismatch)
    python3 -c "
import sys
path = sys.argv[1]
with open(path, 'r+b') as f:
    f.seek(-4, 2)
    f.write(b'\x00\x00\x00\x00')
" "${fix_dir}/weaviate.tar.gz"
    # Verify that gzip -t now fails (corruption is real)
    gzip -t "${fix_dir}/weaviate.tar.gz" 2>/dev/null
    corrupt_rc=$?
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    out="$(restore_verify "$fix_dir" 2>&1)"
    verify_rc=$?
    # Plan 02: corrupt tar → exit 1 AND [FAIL] in output (archive_integrity or checksums)
    [[ "$corrupt_rc" -ne 0 ]] && [[ "$verify_rc" -ne 0 ]] && echo "$out" | grep -q '\[FAIL\]'
) && pass "TC2 verify_corrupt_tar: corrupt tar → restore_verify exits 1 with [FAIL]" \
  || fail "TC2 verify_corrupt_tar: corruption not detected or restore_verify did not exit 1 / print [FAIL]"

# ── TC3: verify_checksum_fail ─────────────────────────────────────────────────
# Flip one hex char in sha256sums.txt → sha256sum -c fails (mismatch confirmed).
# restore_verify must exit 1 with [FAIL] in output (Plan 02 GREEN).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc3_install"
    export BACKUP_BASE="${TMP_ROOT}/tc3_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc3_fix"
    _mk_fixture "$fix_dir"
    # Flip first hex char in sha256sums.txt to break checksum
    sed -i 's/[0-9a-f]/z/1' "${fix_dir}/sha256sums.txt"
    # Verify mismatch is real
    ( cd "$fix_dir" && sha256sum -c sha256sums.txt 2>/dev/null )
    chk_rc=$?
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    out="$(restore_verify "$fix_dir" 2>&1)"
    verify_rc=$?
    # Plan 02: checksum mismatch → exit 1 AND [FAIL] in output
    [[ "$chk_rc" -ne 0 ]] && [[ "$verify_rc" -ne 0 ]] && echo "$out" | grep -q '\[FAIL\]'
) && pass "TC3 verify_checksum_fail: checksum mismatch → restore_verify exits 1 with [FAIL]" \
  || fail "TC3 verify_checksum_fail: mismatch not confirmed or restore_verify did not exit 1 / print [FAIL]"

# ── TC4: verify_empty_sql ─────────────────────────────────────────────────────
# Replace dify_db.sql.gz with empty gzip → gunzip -c gives empty output.
# restore_verify must exit 1 with [FAIL] sql_sanity (Plan 02 GREEN).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc4_install"
    export BACKUP_BASE="${TMP_ROOT}/tc4_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc4_fix"
    _mk_fixture "$fix_dir"
    # Replace with empty gzip
    printf '' | gzip > "${fix_dir}/dify_db.sql.gz"
    # Verify that gunzip -c gives empty output
    sql_content="$(gunzip -c "${fix_dir}/dify_db.sql.gz" 2>/dev/null | head -1 || true)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    out="$(restore_verify "$fix_dir" 2>&1)"
    verify_rc=$?
    # Plan 02: empty SQL → exit 1 AND [FAIL] in output
    [[ -z "$sql_content" ]] && [[ "$verify_rc" -ne 0 ]] && echo "$out" | grep -q '\[FAIL\]'
) && pass "TC4 verify_empty_sql: empty SQL → restore_verify exits 1 with [FAIL]" \
  || fail "TC4 verify_empty_sql: empty SQL not detected or restore_verify did not exit 1 / print [FAIL]"

# ── TC5: verify_missing_artifact ──────────────────────────────────────────────
# Delete env.backup from fixture that HAS MANIFEST listing it.
# restore_verify must exit 1 with [FAIL] completeness (Plan 02 GREEN).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc5_install"
    export BACKUP_BASE="${TMP_ROOT}/tc5_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc5_fix"
    _mk_fixture "$fix_dir"
    rm -f "${fix_dir}/env.backup"
    # Confirm env.backup absent but MANIFEST still lists it
    if [[ -f "${fix_dir}/env.backup" ]]; then exit 1; fi
    if ! grep -q "env.backup" "${fix_dir}/MANIFEST.txt"; then exit 1; fi
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    out="$(restore_verify "$fix_dir" 2>&1)"
    verify_rc=$?
    # Plan 02: missing MANIFEST artifact → exit 1 AND specific message
    [[ "$verify_rc" -ne 0 ]] && echo "$out" | grep -q "env.backup"
) && pass "TC5 verify_missing_artifact: missing env.backup → restore_verify exits 1, mentions env.backup" \
  || fail "TC5 verify_missing_artifact: restore_verify did not exit 1 or did not mention env.backup"

# ── TC5b: verify_old_no_manifest ─────────────────────────────────────────────
# Fixture WITHOUT MANIFEST.txt but WITH dify_db.sql.gz + env.backup (core set present).
# restore_verify must exit 0 with [WARN] (no FAIL — core files present) (Plan 02 GREEN).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc5b_install"
    export BACKUP_BASE="${TMP_ROOT}/tc5b_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc5b_fix"
    _mk_fixture "$fix_dir" "false"  # no MANIFEST
    if [[ -f "${fix_dir}/MANIFEST.txt" ]]; then exit 1; fi
    if [[ ! -f "${fix_dir}/dify_db.sql.gz" ]]; then exit 1; fi
    if [[ ! -f "${fix_dir}/env.backup" ]]; then exit 1; fi
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    out="$(restore_verify "$fix_dir" 2>&1)"
    verify_rc=$?
    # Plan 02: no MANIFEST + core present → exit 0 (WARN only, no FAIL) + WARN message about old format
    [[ "$verify_rc" -eq 0 ]] && echo "$out" | grep -q '\[WARN\]' && ! echo "$out" | grep -q '\[FAIL\]'
) && pass "TC5b verify_old_no_manifest: no MANIFEST + core present → exit 0, WARN shown, no FAIL" \
  || fail "TC5b verify_old_no_manifest: restore_verify did not exit 0 or WARN missing or FAIL present"

# ── TC6: dry_run_read_only ────────────────────────────────────────────────────
# restore_plan <fixture> --dry-run → fixture dir mtime unchanged AND
# MOCK_DOCKER_CALLLOG contains zero mutating docker calls.
# The stub doesn't call docker at all — so both assertions hold at Wave-0.
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc6_install"
    export BACKUP_BASE="${TMP_ROOT}/tc6_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc6_fix"
    _mk_fixture "$fix_dir"
    CALLLOG="$(mktemp)"
    export MOCK_DOCKER_CALLLOG="$CALLLOG"
    mtime_before="$(stat -c %Y "$fix_dir" 2>/dev/null || echo "0")"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    restore_plan "$fix_dir" --dry-run 2>/dev/null || true  # stub exits 1 — expected
    mtime_after="$(stat -c %Y "$fix_dir" 2>/dev/null || echo "0")"
    # Count mutating docker calls in the call-log (grep -c returns 0 lines on no match)
    mutating_calls=0
    if [[ -s "$CALLLOG" ]]; then
        mutating_calls="$(grep -cE 'docker (compose )?(down|stop|exec|rm|run|cp)' "$CALLLOG" 2>/dev/null || true)"
        mutating_calls="${mutating_calls:-0}"
    fi
    rm -f "$CALLLOG"
    # Assert: mtime unchanged AND no mutating calls
    [[ "$mtime_before" == "$mtime_after" ]] && [[ "${mutating_calls}" -eq 0 ]]
) && pass "TC6 dry_run_read_only: fixture mtime unchanged + no mutating docker calls" \
  || fail "TC6 dry_run_read_only: fixture was mutated or mutating docker calls issued"

# ── TC7: dry_run_plan_sections ────────────────────────────────────────────────
# restore_plan --dry-run output should contain section headers.
# Against stub: output is "не реализовано" — sections absent (RED until Plan 02).
# Wave-0 assertion: stub returns non-empty output and doesn't crash.
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc7_install"
    export BACKUP_BASE="${TMP_ROOT}/tc7_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc7_fix"
    _mk_fixture "$fix_dir"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    out="$(restore_plan "$fix_dir" --dry-run 2>&1 || true)"
    [[ -n "$out" ]]
) && pass "TC7 dry_run_plan_sections: stub returned output (plan sections pending Plan 02 — RED for real assertion)" \
  || fail "TC7 dry_run_plan_sections: stub returned no output at all"

# ── TC8: selective_scope_dify ─────────────────────────────────────────────────
# restore_plan <fixture> --service dify --dry-run → stub exits non-zero (RED until Plan 02).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc8_install"
    export BACKUP_BASE="${TMP_ROOT}/tc8_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc8_fix"
    _mk_fixture "$fix_dir"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    restore_plan "$fix_dir" --service dify --dry-run 2>/dev/null
    stub_rc=$?
    [[ "$stub_rc" -ne 0 ]]
) && pass "TC8 selective_scope_dify: stub exits non-zero for --service dify (RED, Plan 02 implements)" \
  || fail "TC8 selective_scope_dify: unexpected result"

# ── TC9: selective_scope_rag ──────────────────────────────────────────────────
# restore_plan <fixture> --service rag --dry-run → stub exits non-zero (RED until Plan 02).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc9_install"
    export BACKUP_BASE="${TMP_ROOT}/tc9_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc9_fix"
    _mk_fixture "$fix_dir"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    restore_plan "$fix_dir" --service rag --dry-run 2>/dev/null
    stub_rc=$?
    [[ "$stub_rc" -ne 0 ]]
) && pass "TC9 selective_scope_rag: stub exits non-zero for --service rag (RED, Plan 02 implements)" \
  || fail "TC9 selective_scope_rag: unexpected result"

# ── TC10: unknown_service_exit1 ───────────────────────────────────────────────
# restore_plan <fixture> --service bogus --dry-run → exit non-zero.
# Both stub and future implementation exit non-zero for bogus --service.
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc10_install"
    export BACKUP_BASE="${TMP_ROOT}/tc10_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc10_fix"
    _mk_fixture "$fix_dir"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    restore_plan "$fix_dir" --service bogus --dry-run 2>/dev/null
    stub_rc=$?
    [[ "$stub_rc" -ne 0 ]]
) && pass "TC10 unknown_service_exit1: --service bogus exits non-zero (consistent with future impl)" \
  || fail "TC10 unknown_service_exit1: unexpected result"

# ── TC11: latest_resolver ─────────────────────────────────────────────────────
# _resolve_backup_dir latest → returns path ending /2026-05-12_0300 (lexicographic newest).
# This is fully implemented in the skeleton — should be GREEN at Wave-0.
(
    set +e
    base="${TMP_ROOT}/tc11_backups"
    mkdir -p "${base}/2026-05-10_0300" "${base}/2026-05-11_0300" "${base}/2026-05-12_0300"
    export BACKUP_BASE="$base"
    export INSTALL_DIR="${TMP_ROOT}/tc11_install"
    mkdir -p "$INSTALL_DIR"
    export PATH="${MOCK_DIR}:${PATH}"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    result="$(_resolve_backup_dir latest 2>/dev/null)"
    rc=$?
    [[ "$rc" -eq 0 ]] && [[ "$result" == */2026-05-12_0300 ]]
) && pass "TC11 latest_resolver: _resolve_backup_dir latest → newest dir by lexicographic sort" \
  || fail "TC11 latest_resolver: did not return newest dir"

# ── TC12: latest_no_backups ───────────────────────────────────────────────────
# Empty BACKUP_BASE → _resolve_backup_dir latest → exit 1, message mentions "Нет бэкапов".
# Fully implemented in skeleton — should be GREEN at Wave-0.
(
    set +e
    base="${TMP_ROOT}/tc12_backups"
    mkdir -p "$base"  # empty — no subdirs
    export BACKUP_BASE="$base"
    export INSTALL_DIR="${TMP_ROOT}/tc12_install"
    mkdir -p "$INSTALL_DIR"
    export PATH="${MOCK_DIR}:${PATH}"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    err_out="$(_resolve_backup_dir latest 2>&1)"
    rc=$?
    [[ "$rc" -ne 0 ]] && \
        echo "$err_out" | grep -q "Нет бэкапов" && \
        echo "$err_out" | grep -q "agmind backup create"
) && pass "TC12 latest_no_backups: empty BACKUP_BASE → exit 1 with actionable message" \
  || fail "TC12 latest_no_backups: did not exit 1 or message missing"

# ── TC13: backup_writes_manifest (static) ────────────────────────────────────
# Static assertion: scripts/backup.sh contains MANIFEST.txt generation block (added in Plan 02).
# At Wave-0 this is 0 → FAIL (documented RED; Plan 02 adds the block).
(
    set +e
    # grep -c exits 1 on no match; capture the count separately to avoid || echo 0 doubling
    count=0
    if grep -q "MANIFEST.txt" "${REPO_ROOT}/scripts/backup.sh" 2>/dev/null; then
        count="$(grep -c "MANIFEST.txt" "${REPO_ROOT}/scripts/backup.sh" 2>/dev/null)"
    fi
    has_header=0
    grep -q "AGmind backup manifest" "${REPO_ROOT}/scripts/backup.sh" 2>/dev/null && has_header=1
    # Must appear ≥2 times AND contain the manifest header comment
    [[ "$count" -ge 2 ]] && [[ "$has_header" -eq 1 ]]
) && pass "TC13 backup_writes_manifest: backup.sh contains MANIFEST.txt generation block" \
  || fail "TC13 backup_writes_manifest: MANIFEST.txt block absent from backup.sh (RED until Plan 02)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "## test_restore: ${PASS} PASS, ${FAIL} FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
