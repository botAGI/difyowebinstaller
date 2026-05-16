#!/usr/bin/env bash
# lib/migrations.sh — AGmind state-store migration runner (Phase 11, STATE-04).
#
# Public API:
#   migrations_dir              — print resolved migrations directory
#   migrations_list             — print all NNN-*.sh basenames (numeric sort)
#   migrations_pending          — print pending migrations (NNN > current schema_version)
#   migrations_apply [--target N] [--yes] [--dry-run]
#                               — apply pending migrations atomically with tar-backup
#
# Discovery: ${MIGRATIONS_DIR:-${INSTALL_DIR}/scripts/migrations} (installed)
#            fallback ${AGMIND_DIR}/lib/migrations (dev mode, mirror agmind.sh pattern).
#
# Atomic invariant per migration:
#   1. tar-backup STATE_DIR -> ${BACKUP_BASE}/state-pre-NNN-<ts>.tar.gz (atomic .tmp+rename)
#   2. bash -n on migration file
#   3. source in subshell with set -euo pipefail
#   4. on success: state_schema_version_set NNN
#   5. on failure: bail, NO auto-rollback (operator runs `agmind upgrade --rollback`)
#
# References:
#   docs/adr/0011-state-store-architecture.md
#   .planning/phases/11-state-store-substrate-adr-0011/11-RESEARCH.md "Migration Framework"
set -uo pipefail

command -v log_info  >/dev/null 2>&1 || log_info()  { echo "  -> $*" >&2; }
command -v log_warn  >/dev/null 2>&1 || log_warn()  { echo "  ! $*" >&2; }
command -v log_error >/dev/null 2>&1 || log_error() { echo "  x $*" >&2; }

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------
BACKUP_BASE="${BACKUP_BASE:-/var/backups/agmind}"
INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
AGMIND_DIR="${AGMIND_DIR:-${INSTALL_DIR}}"

# migrations_dir — print resolved migrations directory.
# Installed path: ${INSTALL_DIR}/scripts/migrations (mirrors lib/X.sh -> scripts/X.sh pattern,
# populated by _copy_runtime_files in install.sh — see Plan 11-05).
# Dev fallback: ${AGMIND_DIR}/lib/migrations is only reachable when AGMIND_DIR points at a
# repo checkout (i.e. NOT equal to INSTALL_DIR). In production AGMIND_DIR defaults to
# INSTALL_DIR (see line above this function), making the fallback evaluate to
# ${INSTALL_DIR}/lib/migrations — a path that does NOT exist (we only ship to scripts/migrations).
# So in production the primary path MUST be used; the fallback is dev-mode-only.
# Callers running outside both layouts MUST set $MIGRATIONS_DIR explicitly.
migrations_dir() {
    local d="${MIGRATIONS_DIR:-${INSTALL_DIR}/scripts/migrations}"
    if [[ ! -d "$d" ]]; then
        # Dev fallback: repo checkout where lib/migrations exists. Production path:
        # AGMIND_DIR=INSTALL_DIR and ${INSTALL_DIR}/lib/migrations does not exist —
        # callers should never land here in production. dev-mode-only.
        d="${AGMIND_DIR}/lib/migrations"
    fi
    printf '%s' "$d"
}

# migrations_list — print all NNN-*.sh basenames, numerically sorted.
# Skips non-conforming filenames. Empty output if dir absent.
migrations_list() {
    local d
    d="$(migrations_dir)"
    [[ -d "$d" ]] || return 0
    # find with -printf %f for basenames; sort by leading integer
    # (NNN- prefix is zero-padded so plain sort == numeric sort for files 001..999).
    find "$d" -maxdepth 1 -name '[0-9][0-9][0-9]-*.sh' -type f -printf '%f\n' 2>/dev/null \
        | sort
}

# migrations_pending — print pending migrations (NNN > state_schema_version).
migrations_pending() {
    local current m num
    current="$(state_schema_version)"
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        num="${m%%-*}"
        # strip leading zeros (10# base prefix avoids octal parsing)
        num=$((10#$num))
        if (( num > current )); then
            printf '%s\n' "$m"
        fi
    done < <(migrations_list)
}

# _migrations_disk_ok — refuse to apply if BACKUP_BASE has <512MB free.
_migrations_disk_ok() {
    install -d -m 0700 "$BACKUP_BASE" 2>/dev/null || true
    [[ -d "$BACKUP_BASE" ]] || return 1
    local free_kb
    free_kb="$(df -k "$BACKUP_BASE" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ "${free_kb:-0}" -lt 524288 ]]; then
        log_error "less than 512 MB free in ${BACKUP_BASE} — refuse to apply migrations"
        return 1
    fi
    return 0
}

# _migrations_backup <NNN> — atomic tar-backup of STATE_DIR.
_migrations_backup() {
    local num="$1"
    local ts tarball tmp
    ts="$(date +%Y%m%dT%H%M%S)"
    tarball="${BACKUP_BASE}/state-pre-${num}-${ts}.tar.gz"
    tmp="${tarball}.tmp"
    (umask 077; tar czf "$tmp" -C "$(dirname "$STATE_DIR")" "$(basename "$STATE_DIR")") || {
        rm -f "$tmp"
        log_error "tar backup failed: ${tarball}"
        return 1
    }
    chmod 0600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$tarball" || { rm -f "$tmp"; return 1; }
    log_info "migrations: backup -> ${tarball}"
    printf '%s\n' "$tarball"
    return 0
}

# migrations_apply [--target N] [--yes] [--dry-run]
# Apply pending migrations in order. --target N stops at schema=N (default: latest).
# --yes is accepted for symmetry with CLI; runner itself does not prompt (CLI layer prompts).
# --dry-run prints what WOULD be applied, performs no writes.
migrations_apply() {
    local target=999999 yes=0 dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)   shift; target="${1:-}"; shift || true ;;
            --yes|-y)   yes=1; shift ;;
            --dry-run)  dry_run=1; shift ;;
            *) log_error "migrations_apply: unknown arg: $1"; return 2 ;;
        esac
    done
    # `yes` reserved for CLI-side prompt suppression — runner itself never prompts.
    # Silence unused-variable warning explicitly:
    : "${yes}"

    local pending
    pending="$(migrations_pending)"
    if [[ -z "$pending" ]]; then
        log_info "migrations: up-to-date (schema=$(state_schema_version))"
        return 0
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        log_info "migrations: pending (dry-run)"
        # shellcheck disable=SC2086
        printf '  %s\n' $pending
        return 0
    fi

    _migrations_disk_ok || return 2

    local m num d
    d="$(migrations_dir)"
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        num="${m%%-*}"; num=$((10#$num))
        if (( num > target )); then
            log_info "migrations: stopping at target=${target}"
            break
        fi

        local mfile="${d}/${m}"
        log_info "migrations: applying ${m}"

        # 1. Syntax check (R10 mitigation)
        if ! bash -n "$mfile" 2>/dev/null; then
            log_error "migrations: syntax error in ${m} — refusing to apply"
            return 1
        fi

        # 2. Backup
        local tarball
        tarball="$(_migrations_backup "$(printf '%03d' "$num")")" || return 1

        # 3. Source in subshell with set -euo pipefail (R10 mitigation)
        local up_fn="migration_${num}_up"
        if ! (
            set -euo pipefail
            # shellcheck source=/dev/null
            source "$mfile"
            if ! declare -F "$up_fn" >/dev/null 2>&1; then
                log_error "migrations: ${m} missing ${up_fn} function"
                exit 1
            fi
            "$up_fn"
        ); then
            log_error "migrations: ${m} FAILED — schema unchanged, backup at ${tarball}"
            log_error "migrations: run 'agmind upgrade --rollback $((num - 1))' to restore"
            return 1
        fi

        # 4. Bump schema_version ONLY after success
        if ! state_schema_version_set "$num"; then
            log_error "migrations: schema bump failed after ${m}"
            return 1
        fi
        log_info "migrations: ${m} -> schema=${num}"
    done < <(printf '%s\n' "$pending")

    return 0
}
