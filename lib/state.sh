#!/usr/bin/env bash
# lib/state.sh — AGmind state-store substrate (Phase 11, STATE-02 + STATE-03).
#
# Public API for ${STATE_DIR} (default /var/lib/agmind/state):
#   state_init_dir              — bootstrap dir + .locks/ + secrets.env + schema_version
#   state_get <key>             — read non-secret state from ${STATE_DIR}/<key>
#   state_set <key> <value>     — atomic write (temp-then-rename), exclusive lock
#   state_get_secret <name>     — byte-exact read from secrets.env via _env_get_raw
#   state_set_secret <name> <v> — upsert in secrets.env, atomic, exclusive lock, mode 0600
#                                 REJECTS empty value (returns 1) — defense vs grep|cut bug.
#   state_schema_version        — print integer from schema_version file (0 if absent)
#   state_schema_version_set N  — atomic write of integer, exclusive lock
#
# Locking contract: per-key flock in ${STATE_DIR}/.locks/<sanitized-key>.lock,
#   -w 5 timeout. NEVER nest locks — single-purpose calls only. See ADR-0011.
#
# Env overrides (test-friendly):
#   STATE_DIR        — root of state-store; default /var/lib/agmind/state.
#   STATE_DIR_OWNER  — optional owner:group for state_init_dir (default unset → no chown).
#
# This module ships DORMANT in v3.2.0 — legacy .preserved / .env readers in
# lib/config.sh remain unchanged. Phase 14 (STATE-11) migrates consumers.
#
# Source: docs/adr/0011-state-store-architecture.md
set -uo pipefail

# ────────────────────────────────────────────────────────────────────────────
# FALLBACK SHIMS (active when sourced standalone, e.g. unit tests)
# ────────────────────────────────────────────────────────────────────────────
command -v log_info  >/dev/null 2>&1 || log_info()  { echo "  -> $*" >&2; }
command -v log_warn  >/dev/null 2>&1 || log_warn()  { echo "  ! $*" >&2; }
command -v log_error >/dev/null 2>&1 || log_error() { echo "  x $*" >&2; }

# ────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────
STATE_DIR="${STATE_DIR:-/var/lib/agmind/state}"

# Sanitize key for use as lockfile basename: replace `/` and `.` with `_`.
_state_lock_name() {
    printf '%s' "$1" | tr '/.' '__'
}

# _state_lock <key> <s|x> <cmd...>
# Acquire shared (s) or exclusive (x) lock on ${STATE_DIR}/.locks/<key>.lock
# with 5-second timeout, then run cmd... Returns 1 on lock timeout, otherwise
# cmd's exit code. RETURN trap closes FD even on early exit.
_state_lock() {
    local key="$1" mode="$2"; shift 2
    local lock_dir="${STATE_DIR}/.locks"
    if ! install -d -m 0700 "$lock_dir" 2>/dev/null; then
        log_error "state: cannot create lock dir ${lock_dir}"
        return 1
    fi
    local lock_name
    lock_name="$(_state_lock_name "$key")"
    local lockfile="${lock_dir}/${lock_name}.lock"
    local fd
    if ! exec {fd}>"$lockfile"; then
        log_error "state: cannot open lockfile ${lockfile}"
        return 1
    fi
    local flag="-x"
    [[ "$mode" == "s" ]] && flag="-s"
    if ! flock -w 5 "$flag" "$fd"; then
        exec {fd}>&-
        log_error "state: lock '${key}' held >5s — another agmind operation may be running"
        return 1
    fi
    # shellcheck disable=SC2064
    trap "exec ${fd}>&-" RETURN
    "$@"
}

# ────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP
# ────────────────────────────────────────────────────────────────────────────
# state_init_dir — idempotent bootstrap of STATE_DIR layout.
# Creates ${STATE_DIR} (0700), .locks/ (0700), schema_version=0 + secrets.env (0600,
# header `# schema=0`) if absent. Honors STATE_DIR_OWNER env (default unset → no chown)
# so CI runners (non-root) can call state_init_dir without sudo.
state_init_dir() {
    local owner_args=()
    if [[ -n "${STATE_DIR_OWNER:-}" ]]; then
        owner_args=(-o "$STATE_DIR_OWNER" -g "$STATE_DIR_OWNER")
    fi
    if ! install -d -m 0700 "${owner_args[@]}" "$STATE_DIR" 2>/dev/null; then
        # Fallback without owner (CI mode)
        install -d -m 0700 "$STATE_DIR" || return 1
    fi
    install -d -m 0700 "${STATE_DIR}/.locks" 2>/dev/null || return 1
    if [[ ! -f "${STATE_DIR}/schema_version" ]]; then
        state_schema_version_set 0 || return 1
    fi
    if [[ ! -f "${STATE_DIR}/secrets.env" ]]; then
        install -m 0600 /dev/null "${STATE_DIR}/secrets.env" || return 1
        printf '# schema=0\n' > "${STATE_DIR}/secrets.env"
    fi
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# SCHEMA VERSION
# ────────────────────────────────────────────────────────────────────────────
# state_schema_version — print integer schema version (0 if file absent).
state_schema_version() {
    local f="${STATE_DIR}/schema_version"
    if [[ ! -f "$f" ]]; then
        printf '0\n'
        return 0
    fi
    awk '{ gsub(/[^0-9]/, ""); print ($0 == "" ? 0 : $0); exit }' "$f"
}

# state_schema_version_set <N> — atomic write of integer to schema_version (mode 0644).
# Wrapped in exclusive flock on the "schema_version" key so concurrent writers
# don't race on temp-then-rename (e.g. two parallel migrations_apply attempts,
# or one operator + cron, or migrate + agmind status). The temp-then-rename is
# already atomic at the filesystem level — flock adds total ordering so the
# observed final value matches exactly one caller's input, never a torn write.
state_schema_version_set() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || { log_error "state: schema version must be non-negative integer (got: ${n})"; return 1; }
    _state_lock "schema_version" x _state_schema_version_set_body "$n"
}

_state_schema_version_set_body() {
    local n="$1"
    local f="${STATE_DIR}/schema_version"
    local tmp
    tmp="$(mktemp "${f}.tmp.XXXXXX")" || return 1
    chmod 0644 "$tmp" 2>/dev/null || true
    printf '%d\n' "$n" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# NON-SECRET STATE (one file per key)
# ────────────────────────────────────────────────────────────────────────────
# state_get <key> — print value from ${STATE_DIR}/<key>; return 1 if absent.
# Shared lock — multiple readers OK.
state_get() {
    local key="$1"
    [[ -n "$key" ]] || { log_error "state_get: empty key"; return 1; }
    local f="${STATE_DIR}/${key}"
    [[ -f "$f" ]] || return 1
    _state_lock "$key" s cat "$f"
}

# state_set <key> <value> — atomic write to ${STATE_DIR}/<key>, mode 0644.
# Value is printed via printf '%s' (no trailing newline). Empty value ALLOWED here
# (only state_set_secret rejects empty — secrets have stricter contract).
state_set() {
    local key="$1" value="$2"
    [[ -n "$key" ]] || { log_error "state_set: empty key"; return 1; }
    [[ "$key" == *..* ]] && { log_error "state_set: '..' not allowed in key"; return 1; }
    [[ "$key" == /* ]] && { log_error "state_set: absolute paths not allowed in key"; return 1; }
    _state_lock "$key" x _state_set_body "$key" "$value"
}

_state_set_body() {
    local key="$1" value="$2"
    local f="${STATE_DIR}/${key}"
    install -d -m 0700 "$(dirname "$f")" 2>/dev/null || true
    local tmp
    tmp="$(mktemp "${f}.tmp.XXXXXX")" || return 1
    chmod 0644 "$tmp" 2>/dev/null || true
    printf '%s' "$value" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    log_info "state: ${key} set"
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# SECRETS (KEY=VALUE in single secrets.env)
# ────────────────────────────────────────────────────────────────────────────
# state_get_secret <name> — print value via _env_get_raw (byte-exact, $-safe).
# Skips `# schema=N` marker (^# is filtered by _env_get_raw). Shared lock.
state_get_secret() {
    local name="$1"
    [[ -n "$name" ]] || { log_error "state_get_secret: empty name"; return 1; }
    if ! command -v _env_get_raw >/dev/null 2>&1; then
        log_error "state: _env_get_raw not available — source lib/common.sh first"
        return 1
    fi
    local f="${STATE_DIR}/secrets.env"
    [[ -r "$f" ]] || return 1
    _state_lock "secrets" s _env_get_raw "$name" "$f"
}

# state_set_secret <name> <value> — upsert NAME=VALUE in secrets.env, atomic, mode 0600.
# Preserves all other keys + the `# schema=N` marker on line 1. REJECTS empty value (return 1).
state_set_secret() {
    local name="$1" value="$2"
    [[ -n "$name" ]] || { log_error "state_set_secret: empty name"; return 1; }
    if [[ -z "$value" ]]; then
        log_error "state_set_secret: empty value for '${name}' rejected (use state_set if intentional)"
        return 1
    fi
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        log_error "state_set_secret: invalid env-var name '${name}' (must match [A-Za-z_][A-Za-z0-9_]*)"
        return 1
    }
    _state_lock "secrets" x _state_set_secret_body "$name" "$value"
}

_state_set_secret_body() {
    local name="$1" value="$2"
    local f="${STATE_DIR}/secrets.env"
    # Bootstrap if missing
    if [[ ! -f "$f" ]]; then
        install -m 0600 /dev/null "$f" || return 1
        printf '# schema=0\n' > "$f"
    fi
    local tmp
    tmp="$(mktemp "${f}.tmp.XXXXXX")" || return 1
    chmod 0600 "$tmp" 2>/dev/null || true
    # Stream existing file, replace matching key, append if not seen.
    # awk preserves byte-exactness for all OTHER lines (incl. comments + blank).
    awk -v k="$name" -v v="$value" '
        BEGIN { replaced = 0 }
        {
            line = $0
            # Match leading KEY= but not commented lines
            if (line !~ /^[[:space:]]*#/ && line ~ "^"k"=") {
                print k "=" v
                replaced = 1
                next
            }
            print line
        }
        END {
            if (!replaced) print k "=" v
        }
    ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    log_info "state: secrets.env::${name} set"
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# UPGRADE CLI — Phase 11, STATE-06 / STATE-07 / STATE-08
# ────────────────────────────────────────────────────────────────────────────
# upgrade_run [--check|--apply|--rollback <N>] [args...]
#   Default action: --check (read-only).
#   Exit codes (mirror `agmind doctor`):
#     0 = up-to-date / success
#     1 = pending / actionable
#     2 = blocked / error / corrupt state
upgrade_run() {
    local mode="--check"
    case "${1:-}" in
        --check|--apply|--rollback) mode="$1"; shift ;;
        "")                          ;;
        -h|--help)                   _upgrade_usage; return 0 ;;
        *)                           echo "agmind upgrade: unknown action: $1" >&2; _upgrade_usage >&2; return 2 ;;
    esac
    case "$mode" in
        --check)    upgrade_check    "$@" ;;
        --apply)    upgrade_apply    "$@" ;;
        --rollback) upgrade_rollback "$@" ;;
    esac
}

_upgrade_usage() {
    cat <<'USAGE'
Usage: agmind upgrade [--check | --apply | --rollback <schema>] [--yes]

  --check               Report current schema and pending migrations (read-only). [default]
                          exit 0 = up-to-date · 1 = pending · 2 = blocked
  --apply [--target N]  Apply pending migrations atomically (tar-backup + bump schema).
                          Prompts unless --yes is passed.
  --rollback <schema>   Restore state-dir from pre-migration tarball.
                          Always prompts (Q-10) unless --yes.

Flags:
  --yes, -y     Skip interactive confirmation (CI / scripted use).
USAGE
}

# upgrade_check — exit 0/1/2 per Phase 11 contract.
# OQ-1 lock-in: LIGHT variant — schema/migration status only.
# versions.env diff is deferred to Phase 16.
upgrade_check() {
    local f="${STATE_DIR}/secrets.env" current marker_n first_line
    current="$(state_schema_version)"
    if [[ -f "$f" ]]; then
        first_line="$(head -1 "$f" 2>/dev/null || true)"
        if [[ "$first_line" =~ ^#[[:space:]]*schema=([0-9]+)[[:space:]]*$ ]]; then
            marker_n="${BASH_REMATCH[1]}"
            if [[ "$marker_n" != "$current" ]]; then
                log_error "schema mismatch: schema_version=${current}, secrets.env marker=${marker_n}"
                log_error "run 'agmind upgrade --rollback ${current}' to restore"
                return 2
            fi
        fi
    fi

    if ! command -v migrations_pending >/dev/null 2>&1; then
        log_error "migrations module not loaded — source lib/migrations.sh first"
        return 2
    fi
    local pending
    pending="$(migrations_pending)"
    echo "Current schema: ${current}"
    if [[ -z "$pending" ]]; then
        echo "Status: up-to-date"
        return 0
    fi
    echo "Pending migrations:"
    # shellcheck disable=SC2086  # intentional word-splitting on newline-separated list
    printf '  %s\n' $pending
    return 1
}

# upgrade_apply [--target N] [--yes]
# Q-10 contract: prompts unless --yes. Non-blocking flock on upgrade.lock
# (T-11-03-01 mitigation — concurrent --apply gets exit 2).
upgrade_apply() {
    local target_arg=() yes=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) shift; target_arg=(--target "${1:-latest}"); shift ;;
            --yes|-y) yes=1; shift ;;
            *) echo "upgrade --apply: unknown arg: $1" >&2; return 2 ;;
        esac
    done

    install -d -m 0700 "${STATE_DIR}/.locks" 2>/dev/null || true
    local lockfile="${STATE_DIR}/.locks/upgrade.lock"
    local fd
    exec {fd}>"$lockfile" || { log_error "cannot open ${lockfile}"; return 2; }
    if ! flock -n -x "$fd"; then
        log_error "agmind upgrade --apply already running (lock held)"
        exec {fd}>&-
        return 2
    fi

    local pending
    pending="$(migrations_pending)"
    if [[ -z "$pending" ]]; then
        echo "Already up-to-date (schema=$(state_schema_version))"
        exec {fd}>&-
        return 0
    fi

    if [[ "$yes" -ne 1 ]]; then
        echo "Pending migrations:"
        # shellcheck disable=SC2086
        printf '  %s\n' $pending
        read -rp "Apply? (yes/no): " ans
        if [[ "$ans" != "yes" ]]; then
            echo "Cancelled."
            exec {fd}>&-
            return 0
        fi
    fi

    local rc=0
    migrations_apply --yes "${target_arg[@]}" || rc=$?
    exec {fd}>&-
    if [[ "$rc" -eq 0 ]]; then
        echo "Applied — schema=$(state_schema_version)"
    fi
    return "$rc"
}

# upgrade_rollback <target_schema> [--yes]
# Q-10 contract: ALWAYS prompts unless --yes. Safe-rename pattern with
# rollback-of-rollback on extract failure. Retains last 3 .broken-* dirs.
upgrade_rollback() {
    local target="${1:-}"
    if [[ -z "$target" ]] || ! [[ "$target" =~ ^[0-9]+$ ]]; then
        echo "upgrade --rollback: target schema (non-negative integer) required" >&2
        return 2
    fi
    shift
    local yes=0
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && yes=1

    local restore_num backup_dir tarball
    restore_num="$(printf '%03d' "$((target + 1))")"
    backup_dir="${BACKUP_BASE:-/var/backups/agmind}"
    tarball="$(ls -1t "${backup_dir}/state-pre-${restore_num}-"*.tar.gz 2>/dev/null | head -1)"
    if [[ -z "$tarball" || ! -f "$tarball" ]]; then
        log_error "no backup tarball for rolling back to schema=${target}"
        log_error "expected file: ${backup_dir}/state-pre-${restore_num}-*.tar.gz"
        return 2
    fi

    if [[ "$yes" -ne 1 ]]; then
        echo "Rolling back state from schema=$(state_schema_version) → schema=${target}"
        echo "Source: $tarball"
        echo "Current state ${STATE_DIR} will be moved aside as ${STATE_DIR}.broken-<ts> and replaced."
        read -rp "Proceed? (yes/no): " ans
        [[ "$ans" == "yes" ]] || { echo "Cancelled."; return 0; }
    fi

    install -d -m 0700 "${STATE_DIR}/.locks" 2>/dev/null || true
    local lockfile="${STATE_DIR}/.locks/upgrade.lock"
    local fd
    exec {fd}>"$lockfile" || { log_error "cannot open ${lockfile}"; return 2; }
    if ! flock -n -x "$fd"; then
        log_error "another upgrade in flight"
        exec {fd}>&-
        return 2
    fi
    exec {fd}>&-

    local ts broken parent base
    ts="$(date +%Y%m%dT%H%M%S)"
    parent="$(dirname "$STATE_DIR")"
    base="$(basename "$STATE_DIR")"
    broken="${parent}/${base}.broken-${ts}"

    mv "$STATE_DIR" "$broken" || { log_error "rename ${STATE_DIR} → ${broken} failed"; return 1; }
    install -d -m 0700 "$STATE_DIR" || { log_error "recreate ${STATE_DIR} failed"; return 1; }
    if ! tar xzf "$tarball" -C "$parent"; then
        log_error "tar extract failed — restoring previous state"
        rm -rf "$STATE_DIR"
        mv "$broken" "$STATE_DIR"
        return 1
    fi

    # shellcheck disable=SC2012  # ls -t is intentional for mtime sort
    ls -1dt "${parent}/${base}.broken-"* 2>/dev/null | tail -n +4 | xargs -r rm -rf 2>/dev/null || true

    echo "Rolled back to schema=$(state_schema_version)"
    return 0
}
