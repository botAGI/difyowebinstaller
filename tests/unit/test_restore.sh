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
# restore_plan --dry-run output must contain all four section headers:
#   PostgreSQL / Volumes / Config / Будет остановлено
# and the fixture's known artifacts (dify_db.sql.gz, weaviate.tar.gz).
# Plan 03: REAL assertions (was stub-only at Wave-0).
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
    # Re-null colors: lib/restore.sh's fallback shims use ${VAR:-ANSI} which
    # triggers even on empty-string (bash :- treats empty as unset), overriding
    # the test's exported empty vars. Must re-zero AFTER sourcing.
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
    out="$(restore_plan "$fix_dir" --dry-run 2>&1 || true)"
    rc=$?
    # Assertions:
    # 1. restore_verify passed → exit 0
    [[ "$rc" -eq 0 ]] || { echo "  rc=$rc" >&2; false; exit; }
    # 2. All four section headers present
    echo "$out" | grep -q "PostgreSQL:"        || { echo "  missing PostgreSQL section" >&2; false; exit; }
    echo "$out" | grep -qE "Volumes|каталоги"  || { echo "  missing Volumes section" >&2; false; exit; }
    echo "$out" | grep -q "Config:"            || { echo "  missing Config section" >&2; false; exit; }
    echo "$out" | grep -q "остановлено"        || { echo "  missing Будет остановлено section" >&2; false; exit; }
    # 3. Known artifacts listed
    echo "$out" | grep -q "dify_db.sql.gz"     || { echo "  dify_db.sql.gz missing from plan" >&2; false; exit; }
    echo "$out" | grep -q "weaviate.tar.gz"    || { echo "  weaviate.tar.gz missing from plan" >&2; false; exit; }
    # 4. Dry-run trailer present
    echo "$out" | grep -q "Изменений не внесено (dry-run)" || { echo "  dry-run trailer missing" >&2; false; exit; }
) && pass "TC7 dry_run_plan_sections: all 4 section headers + known artifacts + dry-run trailer present" \
  || fail "TC7 dry_run_plan_sections: missing section header, artifact, or dry-run trailer"

# ── TC8: selective_scope_dify ─────────────────────────────────────────────────
# restore_plan <fixture> --service dify --dry-run:
#   - exits 0 (verify passes on fixture)
#   - PostgreSQL section lists dify_db.sql.gz
#   - Будет остановлено section lists "api worker web sandbox plugin_daemon"
#   - Volumes section does NOT include weaviate / qdrant / openwebui
# Plan 03: REAL assertions (was stub-check at Wave-0).
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
    # Re-null colors after source (lib's ${VAR:-ANSI} fallback triggers on empty strings)
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
    out="$(restore_plan "$fix_dir" --service dify --dry-run 2>&1)"
    rc=$?
    # Extract only the plan section (after "=== План") to avoid false matches in
    # restore_verify output (which mentions dify_db.sql.gz in sql_sanity messages).
    plan_section="$(echo "$out" | awk '/=== План/,0')"
    # 1. exits 0
    [[ "$rc" -eq 0 ]] || { echo "  rc=$rc" >&2; false; exit; }
    # 2. dify DB listed in PostgreSQL section of the plan
    echo "$plan_section" | grep -q "dify_db.sql.gz"        || { echo "  dify_db.sql.gz not in plan" >&2; false; exit; }
    # 3. Dify app containers listed in stop section
    echo "$plan_section" | grep -q "api worker web sandbox" || { echo "  dify containers not in stop section" >&2; false; exit; }
    # 4. postgres note present
    echo "$plan_section" | grep -q "postgres НЕ останавливается" || { echo "  postgres note missing" >&2; false; exit; }
    # 5. weaviate/qdrant/openwebui NOT in the plan (out-of-scope for --service dify)
    echo "$plan_section" | grep -q "weaviate.tar.gz"        && { echo "  weaviate.tar.gz incorrectly in dify scope" >&2; false; exit; }
    echo "$plan_section" | grep -q "qdrant.tar.gz"          && { echo "  qdrant.tar.gz incorrectly in dify scope" >&2; false; exit; }
    echo "$plan_section" | grep -q "openwebui.tar.gz"       && { echo "  openwebui.tar.gz incorrectly in dify scope" >&2; false; exit; }
    true  # ensure exit 0 when all "should-not-match" checks pass (last cmd is && which exits 1 on no-match)
) && pass "TC8 selective_scope_dify: --service dify lists dify_db+stop section, excludes weaviate/qdrant/openwebui" \
  || fail "TC8 selective_scope_dify: plan missing expected content or contains out-of-scope artifacts"

# ── TC9: selective_scope_rag ──────────────────────────────────────────────────
# Fixture has weaviate.tar.gz (NOT qdrant.tar.gz).
# restore_plan <fixture> --service rag --dry-run:
#   - exits 0
#   - Volumes section lists weaviate.tar.gz
#   - Volumes section does NOT include qdrant, dify, openwebui artifacts
#   - Будет остановлено = "weaviate" (the vector store present in fixture)
# Plan 03: REAL assertions (was stub-check at Wave-0).
(
    set +e
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc9_install"
    export BACKUP_BASE="${TMP_ROOT}/tc9_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc9_fix"
    _mk_fixture "$fix_dir"
    # Confirm: fixture has weaviate but not qdrant
    [[ -f "${fix_dir}/weaviate.tar.gz" ]]   || { echo "  fixture missing weaviate.tar.gz" >&2; false; exit; }
    [[ ! -f "${fix_dir}/qdrant.tar.gz" ]]   || { echo "  fixture unexpectedly has qdrant.tar.gz" >&2; false; exit; }
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    # Re-null colors after source (lib's ${VAR:-ANSI} fallback triggers on empty strings)
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
    out="$(restore_plan "$fix_dir" --service rag --dry-run 2>&1)"
    rc=$?
    # Extract only the plan section (after "=== План") to avoid false matches in
    # restore_verify output (which mentions dify_db.sql.gz in sql_sanity messages).
    plan_section="$(echo "$out" | awk '/=== План/,0')"
    # 1. exits 0
    [[ "$rc" -eq 0 ]] || { echo "  rc=$rc" >&2; false; exit; }
    # 2. weaviate listed in volumes (plan section only)
    echo "$plan_section" | grep -q "weaviate.tar.gz"   || { echo "  weaviate.tar.gz not in plan" >&2; false; exit; }
    # 3. weaviate container in stop section
    echo "$plan_section" | grep -q "weaviate"          || { echo "  weaviate container not in stop section" >&2; false; exit; }
    # 4. qdrant NOT listed (not in fixture)
    echo "$plan_section" | grep -q "qdrant.tar.gz"     && { echo "  qdrant.tar.gz incorrectly listed (not in fixture)" >&2; false; exit; }
    # 5. dify / openwebui artifacts NOT in the plan section
    echo "$plan_section" | grep -q "dify_db.sql.gz"    && { echo "  dify_db.sql.gz incorrectly in rag scope" >&2; false; exit; }
    echo "$plan_section" | grep -q "openwebui.tar.gz"  && { echo "  openwebui.tar.gz incorrectly in rag scope" >&2; false; exit; }
    true  # ensure exit 0 when all "should-not-match" checks pass (last cmd is && which exits 1 on no-match)
) && pass "TC9 selective_scope_rag: --service rag lists only weaviate (present in fixture), excludes qdrant/dify/openwebui" \
  || fail "TC9 selective_scope_rag: plan missing weaviate or contains out-of-scope artifacts"

# ── TC10: unknown_service_exit1 ───────────────────────────────────────────────
# restore_plan <fixture> --service bogus --dry-run:
#   - exits 1
#   - stderr/combined output mentions "bogus" and lists valid service names
#     (dify, rag, ragflow, openwebui, ollama, config)
# Plan 03: REAL assertion (exit 1 also held for stub — add valid-name list check).
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
    # No need to re-null colors here — error is printed before any colored output
    out="$(restore_plan "$fix_dir" --service bogus --dry-run 2>&1)"
    rc=$?
    # 1. exits 1
    [[ "$rc" -ne 0 ]]                                   || { echo "  expected exit 1, got $rc" >&2; false; exit; }
    # 2. output mentions the invalid service name
    echo "$out" | grep -qi "bogus"                      || { echo "  output doesn't mention 'bogus'" >&2; false; exit; }
    # 3. output lists at least 4 of the 6 valid names
    echo "$out" | grep -q "dify"                        || { echo "  valid name 'dify' missing from output" >&2; false; exit; }
    echo "$out" | grep -q "rag"                         || { echo "  valid name 'rag' missing from output" >&2; false; exit; }
    echo "$out" | grep -q "openwebui"                   || { echo "  valid name 'openwebui' missing from output" >&2; false; exit; }
    echo "$out" | grep -q "config"                      || { echo "  valid name 'config' missing from output" >&2; false; exit; }
) && pass "TC10 unknown_service_exit1: --service bogus exits 1, output mentions bogus + lists valid names" \
  || fail "TC10 unknown_service_exit1: wrong exit code or missing service names in output"

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

# ── TC14: wrapper_dispatch ────────────────────────────────────────────────────
# Static assertions that scripts/restore.sh and scripts/agmind.sh are correctly wired.
# Also a behavioral check: source lib/restore.sh with mocks + call restore_plan --dry-run.
(
    set +e
    # ── Part A: scripts/restore.sh wiring ──
    # 1. sources lib/restore.sh
    grep -q 'source.*lib/restore.sh' "${REPO_ROOT}/scripts/restore.sh" \
        || { echo "  restore.sh does not source lib/restore.sh" >&2; false; exit; }
    # 2. delegates to restore_plan with --dry-run
    grep -q 'restore_plan.*--dry-run' "${REPO_ROOT}/scripts/restore.sh" \
        || { echo "  restore.sh does not call restore_plan --dry-run" >&2; false; exit; }
    # 3. delegates to restore_apply
    grep -q 'restore_apply' "${REPO_ROOT}/scripts/restore.sh" \
        || { echo "  restore.sh does not call restore_apply" >&2; false; exit; }
    # 4. flock acquired BEFORE source (line number check)
    _fl=$(grep -n 'flock -n 9' "${REPO_ROOT}/scripts/restore.sh" | head -1 | cut -d: -f1)
    _sl=$(grep -n 'source.*lib/restore.sh' "${REPO_ROOT}/scripts/restore.sh" | head -1 | cut -d: -f1)
    [[ -n "$_fl" && -n "$_sl" && "$_fl" -lt "$_sl" ]] \
        || { echo "  flock (line ${_fl}) is NOT before source lib/restore.sh (line ${_sl})" >&2; false; exit; }
    # 5. thin entrypoint: ≤ 90 lines
    _lc="$(wc -l < "${REPO_ROOT}/scripts/restore.sh")"
    [[ "$_lc" -le 90 ]] \
        || { echo "  restore.sh has ${_lc} lines (expected ≤90 for thin entrypoint)" >&2; false; exit; }

    # ── Part B: scripts/agmind.sh wiring ──
    # 6. dispatches backup verify
    grep -q 'backup verify' "${REPO_ROOT}/scripts/agmind.sh" \
        || { echo "  agmind.sh does not contain 'backup verify'" >&2; false; exit; }
    # 7. dispatches backup list via restore_list
    grep -q 'restore_list' "${REPO_ROOT}/scripts/agmind.sh" \
        || { echo "  agmind.sh does not call restore_list" >&2; false; exit; }
    # 8. sources lib/restore.sh for list/verify branches
    _sc="$(grep -c 'source.*lib/restore.sh' "${REPO_ROOT}/scripts/agmind.sh")"
    [[ "$_sc" -ge 2 ]] \
        || { echo "  agmind.sh sources lib/restore.sh only ${_sc} time(s) (expected ≥2)" >&2; false; exit; }
    # 9. cmd_help mentions backup <sub> and --dry-run
    grep -q 'backup <sub>' "${REPO_ROOT}/scripts/agmind.sh" \
        || { echo "  cmd_help missing 'backup <sub>'" >&2; false; exit; }
    grep -q '\-\-dry-run' "${REPO_ROOT}/scripts/agmind.sh" \
        || { echo "  cmd_help missing '--dry-run'" >&2; false; exit; }

    # ── Part C: behavioral — lib/restore.sh restore_plan --dry-run via mocks ──
    export PATH="${MOCK_DIR}:${PATH}"
    export INSTALL_DIR="${TMP_ROOT}/tc14_install"
    export BACKUP_BASE="${TMP_ROOT}/tc14_backups"
    mkdir -p "$INSTALL_DIR" "$BACKUP_BASE"
    fix_dir="${TMP_ROOT}/tc14_fix"
    _mk_fixture "$fix_dir"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/restore.sh"
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
    out="$(restore_plan "$fix_dir" --dry-run 2>&1 || true)"
    # restore_plan exits 0 when verify passes (fixture is valid)
    rc=0
    restore_plan "$fix_dir" --dry-run >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] \
        || { echo "  restore_plan --dry-run on valid fixture returned rc=$rc (expected 0)" >&2; false; exit; }
    # plan output contains the dry-run trailer
    echo "$out" | grep -q "Изменений не внесено (dry-run)" \
        || { echo "  restore_plan --dry-run output missing dry-run trailer" >&2; false; exit; }
    true
) && pass "TC14 wrapper_dispatch: scripts/restore.sh + agmind.sh correctly wired to lib/restore.sh" \
  || fail "TC14 wrapper_dispatch: wiring check failed — see details above"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "## test_restore: ${PASS} PASS, ${FAIL} FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
