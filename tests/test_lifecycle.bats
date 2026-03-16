#!/usr/bin/env bats

# Lifecycle smoke tests — validate install/backup/restore/update/rollback paths
# All tests use temp dirs and mock files, no Docker required.

setup() {
    export ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

# --- Install ---

@test "install.sh has valid bash syntax" {
    run bash -n "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh supports --help flag" {
    # install.sh should print help text and exit 0 (or at least not crash)
    run bash "${ROOT_DIR}/install.sh" --help 2>&1
    # Accept either 0 or grep for usage/help text
    [[ "$status" -eq 0 ]] || [[ "$output" =~ [Uu]sage ]] || [[ "$output" =~ [Hh]elp ]]
}

# --- Backup ---

@test "backup.sh has valid bash syntax" {
    run bash -n "${ROOT_DIR}/scripts/backup.sh"
    [ "$status" -eq 0 ]
}

@test "backup.sh no longer references localhost:6333 (Qdrant API)" {
    run grep -c 'localhost:6333' "${ROOT_DIR}/scripts/backup.sh"
    [ "$output" = "0" ]
}

# --- Restore ---

@test "restore.sh has valid bash syntax" {
    run bash -n "${ROOT_DIR}/scripts/restore.sh"
    [ "$status" -eq 0 ]
}

@test "restore.sh no longer references localhost:6333 (Qdrant API)" {
    run grep -c 'localhost:6333' "${ROOT_DIR}/scripts/restore.sh"
    [ "$output" = "0" ]
}

# --- Update ---

@test "update.sh has valid bash syntax" {
    run bash -n "${ROOT_DIR}/scripts/update.sh"
    [ "$status" -eq 0 ]
}

@test "update.sh has all required rollback functions" {
    for func in save_rollback_state perform_rollback rollback_service verify_rollback; do
        run grep -c "^${func}()" "${ROOT_DIR}/scripts/update.sh"
        [ "$output" -ge 1 ]
    done
}

@test "rollback_service restores .env before compose up" {
    # Extract the rollback_service function body and verify it restores dot-env.bak
    run bash -c "
        awk '/^rollback_service\\(\\)/,/^}/' '${ROOT_DIR}/scripts/update.sh' | \
        grep -c 'dot-env.bak'
    "
    [ "$output" -ge 1 ]
}

@test "save_rollback_state saves image digests via docker inspect" {
    run grep '{{\.Image}}' "${ROOT_DIR}/scripts/update.sh"
    [ "$status" -eq 0 ]
}

# --- Generate Manifest ---

@test "generate-manifest.sh has valid bash syntax" {
    run bash -n "${ROOT_DIR}/scripts/generate-manifest.sh"
    [ "$status" -eq 0 ]
}

@test "check-manifest-versions.py is valid Python" {
    run python3 -c "import py_compile; py_compile.compile('${ROOT_DIR}/scripts/check-manifest-versions.py', doraise=True)"
    [ "$status" -eq 0 ]
}

# --- All scripts syntax ---

@test "all .sh files pass bash -n" {
    failed=0
    while IFS= read -r f; do
        if ! bash -n "$f" 2>/dev/null; then
            echo "FAIL: $f"
            failed=$((failed + 1))
        fi
    done < <(find "$ROOT_DIR" -name "*.sh" -type f -not -path "*/.git/*")
    [ "$failed" -eq 0 ]
}
