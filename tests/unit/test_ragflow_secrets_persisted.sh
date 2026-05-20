#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_ragflow_secrets_persisted.sh — volume secret rotation regression
#
# Bug history
# -----------
# 2026-05-19 fresh install: RAGFlow signup failed because agmind-ragflow caught
# `Access denied for user 'root'@<ip> (using password: YES)`. Root cause: the
# `docker_agmind_ragflow_mysql_data` named volume was preserved from a prior
# install run (Docker stores named volumes in /var/lib/docker/volumes/ which
# survives `rm -rf /opt/agmind`). MySQL's MYSQL_ROOT_PASSWORD env is consumed
# ONLY at first-init, so a fresh install generating a new password ends up with
# `.env` saying one thing and the MySQL data dir saying another. The MinIO and
# ES root passwords sit in the same trap.
#
# Architectural fix: every RAGFlow secret goes through `_state_get_or_generate`
# — the Phase 11 state store (BACKUP-01) reads the value if it exists,
# generates+persists if not. Re-running install.sh never rotates the secret,
# so the volume's first-init password and the .env always stay in lock-step.
#
# This test asserts the fix statically (no live install required):
#
#   A. lib/config.sh must call `_state_get_or_generate` for each RAGFlow
#      password slug — NOT raw `generate_random_named`.
#
#   B. The slug names must match what the .env template references:
#      RAGFLOW_MYSQL_PASSWORD, RAGFLOW_ES_PASSWORD, RAGFLOW_MINIO_PASSWORD.
#
#   C. A live source+call shows that running the secret-gen sequence twice
#      yields the SAME value (the actual contract).
#
# Exit: 0 = PASS, 77 = SKIP (state module not sourcable in CI), else FAIL.
# Auto-discovered by tests/run_all.sh.
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CONFIG="lib/config.sh"

fail=0

# --- (A) every RAGFlow password uses _state_get_or_generate ---
# Legacy pattern: _RAGFLOW_XYZ_PASSWORD="$(generate_random_named ...)".
# New pattern: _RAGFLOW_XYZ_PASSWORD="$(_state_get_or_generate ...)".
for slug in RAGFLOW_MYSQL_PASSWORD RAGFLOW_ES_PASSWORD RAGFLOW_MINIO_PASSWORD; do
    var="_${slug}"
    new_pattern_line=$(grep -nE "^[[:space:]]*${var}=\"\\\$\(_state_get_or_generate[[:space:]]+${slug}\b" "$CONFIG" || true)
    if [[ -z "$new_pattern_line" ]]; then
        echo "FAIL (A): $var is not produced by _state_get_or_generate ${slug}" >&2
        echo "          → grep -n '${var}=' $CONFIG output:" >&2
        grep -nE "^[[:space:]]*${var}=" "$CONFIG" | sed 's/^/            /' >&2
        echo "          Volume secret rotation regression: re-running install will rotate" >&2
        echo "          the password while the MySQL/ES/MinIO data dirs keep the original." >&2
        fail=1
    fi
done

# --- (B) raw generate_random_named for these slugs is gone ---
for slug in RAGFLOW_MYSQL_PASSWORD RAGFLOW_ES_PASSWORD RAGFLOW_MINIO_PASSWORD; do
    if grep -qE "generate_random_named[[:space:]]+${slug}\b" "$CONFIG"; then
        echo "FAIL (B): legacy 'generate_random_named ${slug}' still present in $CONFIG — must go through state-store" >&2
        fail=1
    fi
done

# --- (C) functional: 2 runs of the secret-gen sequence yield identical values ---
# Source common+state+config into a fresh subshell with AGMIND_STATE_DIR pointed
# at a tmp location, call _generate_secrets twice, compare the values.
tmp_state="$(mktemp -d)"
trap 'rm -rf "$tmp_state"' EXIT

run_secret_gen() {
    (
        export AGMIND_STATE_DIR="$1"
        export STATE_DIR="$1"
        export INSTALL_DIR="$tmp_state/install"
        mkdir -p "$INSTALL_DIR"
        # Soft-source — some libs require non-trivial harness; tolerate failures
        # by exporting stubs for missing deps.
        log_info()    { :; }
        log_warn()    { :; }
        log_error()   { :; }
        log_success() { :; }
        log_success_with_url() { :; }
        export -f log_info log_warn log_error log_success log_success_with_url

        # shellcheck source=../../lib/common.sh
        source "${REPO_ROOT}/lib/common.sh"        2>/dev/null
        # shellcheck source=../../lib/state.sh
        source "${REPO_ROOT}/lib/state.sh"         2>/dev/null
        # shellcheck source=../../lib/config.sh
        source "${REPO_ROOT}/lib/config.sh"        2>/dev/null

        # Touch the secret-gen entrypoint
        _generate_secrets 2>/dev/null || true

        # Emit what the test cares about
        printf 'MYSQL=%s\n' "${_RAGFLOW_MYSQL_PASSWORD:-}"
        printf 'ES=%s\n'    "${_RAGFLOW_ES_PASSWORD:-}"
        printf 'MINIO=%s\n' "${_RAGFLOW_MINIO_PASSWORD:-}"
    )
}

run1="$(run_secret_gen "$tmp_state" 2>/dev/null)"
run2="$(run_secret_gen "$tmp_state" 2>/dev/null)"

if [[ -z "$run1" ]] || [[ -z "$run2" ]]; then
    echo "SKIP: could not source lib/config.sh secret-gen path in this environment" >&2
    exit 77
fi

if [[ "$run1" != "$run2" ]]; then
    echo "FAIL (C): two consecutive runs of _generate_secrets produced different RAGFlow passwords:" >&2
    diff <(printf '%s' "$run1") <(printf '%s' "$run2") | sed 's/^/         /' >&2
    echo "          State-store is NOT persisting RAGFlow secrets — same bug class as 2026-05-19" >&2
    fail=1
fi

# Extra: at least one of the values must be non-empty (otherwise we passed by
# accident due to empty == empty)
mysql_val="$(awk -F= '/^MYSQL=/{print $2}' <<<"$run1")"
if [[ -z "$mysql_val" ]]; then
    echo "FAIL (C): _RAGFLOW_MYSQL_PASSWORD came back empty — secret-gen path is broken in this env" >&2
    fail=1
fi

if (( fail )); then
    echo "" >&2
    echo "test_ragflow_secrets_persisted.sh: FAIL — volume secret rotation regression risk" >&2
    exit 1
fi

echo "test_ragflow_secrets_persisted.sh: PASS — RAGFlow MySQL/ES/MinIO passwords persist across runs"
exit 0
