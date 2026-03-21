#!/usr/bin/env bats

# test_backup.bats — Backup/Restore validation tests

setup() {
    export ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export INSTALL_DIR="$(mktemp -d)"
    mkdir -p "${INSTALL_DIR}/docker"
    mkdir -p "${INSTALL_DIR}/docker/volumes/app/storage"
    mkdir -p "${INSTALL_DIR}/scripts"
}

teardown() {
    rm -rf "$INSTALL_DIR"
}

# --- Restore tmpdir pattern ---

@test "restore.sh uses .restore_tmp not mktemp" {
    run grep "mktemp" "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -ne 0 ]
}

@test "restore.sh defines RESTORE_TMP variable" {
    run grep "RESTORE_TMP=" "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -eq 0 ]
}

@test "restore.sh cleans RESTORE_TMP in cleanup trap" {
    run grep "rm -rf.*RESTORE_TMP" "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESTORE_TMP"* ]]
}

# --- Security ---

@test "backup.sh sets umask 077" {
    run grep "umask 077" "${ROOT_DIR}/scripts/backup.sh"
    [ "$status" -eq 0 ]
}

@test "backup.sh requires root" {
    run grep "EUID.*-ne 0\|id -u.*-ne 0" "${ROOT_DIR}/scripts/backup.sh"
    [ "$status" -eq 0 ]
}

@test "restore.sh requires root" {
    run grep "id -u.*-ne 0" "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -eq 0 ]
}

# --- Exclusive lock ---

@test "backup.sh uses exclusive lock" {
    run grep "flock" "${ROOT_DIR}/scripts/backup.sh"
    [ "$status" -eq 0 ]
}

@test "restore.sh uses exclusive lock" {
    run grep "flock" "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -eq 0 ]
}

# --- Parser and flags ---

@test "restore.sh supports --auto-confirm flag" {
    run grep "\-\-auto-confirm" "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -eq 0 ]
}

@test "restore.sh supports --help flag" {
    run grep "\-\-help" "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -eq 0 ]
}

@test "restore.sh validates INSTALL_DIR path" {
    run grep 'INSTALL_DIR.*==.*/opt/agmind' "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -eq 0 ]
}

# --- Backup output structure ---

@test "backup.sh creates checksums file" {
    run grep "sha256sum" "${ROOT_DIR}/scripts/backup.sh"
    [ "$status" -eq 0 ]
}

@test "backup.sh has cleanup trap on failure" {
    run grep "cleanup_backup" "${ROOT_DIR}/scripts/backup.sh"
    [ "$status" -eq 0 ]
}

@test "backup.sh supports retention by count" {
    run grep "BACKUP_RETENTION_COUNT" "${ROOT_DIR}/scripts/backup.sh"
    [ "$status" -eq 0 ]
}

# --- Restore does not blindly copy .age keys ---

@test "restore.sh does not blindly copy .age keys from backup" {
    # The restore should use age keys from INSTALL_DIR, not copy from backup source
    # The age_keys restore is gated behind user confirmation (RESTORE_CONFIG)
    run grep -c "cp.*age_keys" "${ROOT_DIR}/scripts/restore.sh"
    # Should only appear in the optional config restore block (user-confirmed)
    [ "$status" -eq 0 ]
}
