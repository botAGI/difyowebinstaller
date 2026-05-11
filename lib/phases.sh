#!/usr/bin/env bash
# phases.sh — Phase engine for install.sh: PHASES descriptor array + iterator.
# Dependencies: common.sh (log_*)
# Functions: phases_count, phases_get <idx> <field>, phases_name_to_idx <name|N>,
#   phases_run_all <start_idx> [--dry-run] [--skip-optional]
# Expects: INSTALL_DIR, TIMEOUT_START, run_phase, run_phase_with_timeout
#   (run_phase* defined in install.sh BEFORE phases_run_all is called;
#    in unit tests, define stubs before sourcing or before calling phases_run_all)
# Exports: PHASES (array), TOTAL_PHASES (derived from array length)
set -euo pipefail

# ============================================================================
# FALLBACK SHIMS (active when sourced without common.sh, e.g. in unit tests)
# ============================================================================

# Mirror lib/doctor.sh / lib/health.sh pattern for standalone sourcing
command -v log_info  >/dev/null 2>&1 || log_info()  { echo -e "  -> $*" >&2; }
command -v log_warn  >/dev/null 2>&1 || log_warn()  { echo -e "  ! $*" >&2; }
command -v log_error >/dev/null 2>&1 || log_error() { echo -e "  x $*" >&2; }

# ============================================================================
# PHASE DESCRIPTOR SCHEMA
# ============================================================================
# Record format: "name${SEP}fn${SEP}timeout${SEP}flags"
# SEP = \x1f (ASCII Unit Separator — same as lib/doctor.sh DOCTOR_REGISTRY)
# Fields:
#   name    — human-readable phase name (for banner display); may contain spaces
#   fn      — bash function name to invoke (resolved at call time from install.sh scope)
#   timeout — seconds (0 = no external timeout; fn manages timing internally)
#   flags   — comma-separated from: preflight | optional | master-only | graceful
#             preflight  : run even in --dry-run mode (read-only diagnostics)
#             optional   : skip in --skip-optional mode; emits status=skip to jsonl
#             master-only: skip when cluster_mode_read != master (enforced by engine)
#             graceful   : non-zero return does NOT abort the loop (belt+suspenders)
#
# NOTE: timeout for phase 6 (Start) uses ${TIMEOUT_START:-300} runtime expansion.
# install.sh sets TIMEOUT_START=300 (line 43) BEFORE the source block, so the value
# is captured correctly when lib/phases.sh is sourced. Unit tests should export
# TIMEOUT_START before sourcing (or rely on the :-300 fallback).

SEP=$'\x1f'

PHASES=(
    "Diagnostics${SEP}phase_diagnostics${SEP}0${SEP}preflight"
    "Wizard${SEP}phase_wizard${SEP}0${SEP}"
    "Docker${SEP}phase_docker${SEP}0${SEP}"
    "Configuration${SEP}phase_config${SEP}0${SEP}"
    "Pull${SEP}phase_pull${SEP}0${SEP}"
    "Start${SEP}phase_start${SEP}${TIMEOUT_START:-300}${SEP}"
    "Deploy Peer${SEP}peer_deploy${SEP}1800${SEP}optional,master-only"
    "Health${SEP}phase_health${SEP}0${SEP}"
    "Models${SEP}phase_models_graceful${SEP}0${SEP}graceful"
    "Backups${SEP}phase_backups${SEP}0${SEP}"
    "Complete${SEP}phase_complete${SEP}0${SEP}"
)

# Derived — single source of truth; no literal 11/9 hardcodes.
# install.sh sets TOTAL_PHASES=$(phases_count) after sourcing to pick this up.
# shellcheck disable=SC2034  # used by _cleanup_on_failure in install.sh after sourcing
TOTAL_PHASES=${#PHASES[@]}

# ============================================================================
# PUBLIC API
# ============================================================================

# phases_count — print the number of registered phases
phases_count() {
    printf '%s\n' "${#PHASES[@]}"
}

# phases_get <idx> <field>
# Print one field from the PHASES record at 0-based index.
# field: name | fn | timeout | flags
phases_get() {
    local idx="${1:?idx required}" field="${2:?field required}"
    local record="${PHASES[$idx]}"
    local name fn timeout flags
    IFS=$'\x1f' read -r name fn timeout flags <<< "$record"
    case "$field" in
        name)    printf '%s' "$name"    ;;
        fn)      printf '%s' "$fn"      ;;
        timeout) printf '%s' "$timeout" ;;
        flags)   printf '%s' "$flags"   ;;
        *)       log_error "phases_get: unknown field '${field}'"; return 1 ;;
    esac
}

# phases_name_to_idx <name|N>
# Resolve a phase to its 0-based array index.
#   Numeric input N (1-based user-visible number) → returns N-1
#   Name input (exact, case-sensitive)             → returns matching index
# Returns non-zero and prints error if not found.
phases_name_to_idx() {
    local input="${1:?name or number required}"

    # Numeric: convert 1-based phase number to 0-based array index
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx=$(( input - 1 ))
        if [[ $idx -lt 0 || $idx -ge ${#PHASES[@]} ]]; then
            log_error "Phase number ${input} out of range (1-${#PHASES[@]})"
            return 1
        fi
        printf '%s\n' "$idx"
        return 0
    fi

    # Name: linear search through PHASES array
    local i=0 record name
    for record in "${PHASES[@]}"; do
        IFS=$'\x1f' read -r name _ <<< "$record"
        if [[ "$name" == "$input" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
        i=$(( i + 1 ))
    done

    log_error "Phase name '${input}' not found"
    return 1
}

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

# _phases_emit_jsonl <file> <n> <name> <status> <started> <duration_s>
# Append one JSON record to the .install-phases.jsonl file.
# status: ok | fail | skip
# name: must not contain double-quotes (all current phase names are safe)
_phases_emit_jsonl() {
    local file="$1" n="$2" name="$3" status="$4" started="$5" duration="$6"
    local ended
    ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"n":%d,"name":"%s","status":"%s","started":"%s","ended":"%s","duration_s":%d}\n' \
        "$n" "$name" "$status" "$started" "$ended" "$duration" >> "$file"
}

# ============================================================================
# PHASE ITERATOR
# ============================================================================

# phases_run_all <start_idx> [--dry-run] [--skip-optional]
# Run all phases beginning from start_idx (0-based array index).
#
# --dry-run:       execute only preflight-flagged phases, then exit 0 with a
#                  summary of phases that would have run. (exit 0 is intentional
#                  and correct — phases_run_all is always called directly from
#                  main(), never from a $() capture.)
# --skip-optional: skip phases flagged optional (emit status=skip in jsonl).
#
# Phases flagged master-only are skipped when cluster_mode_read != master.
# Phases flagged graceful: non-zero return is logged as a warning but does NOT
#   abort the loop (belt-and-suspenders; phase_models_graceful already returns 0
#   internally).
# Non-graceful phases: non-zero return propagates out of phases_run_all immediately.
#
# .install-phases.jsonl truncated on fresh run (start_idx == 0); appended on
#   resume (start_idx > 0) so prior-phase lines are preserved.
#
# run_phase / run_phase_with_timeout: defined in install.sh (D-02); resolved at
#   call time via the sourcing shell's namespace. Unit tests must define stubs
#   for these functions before invoking phases_run_all.
phases_run_all() {
    local start_idx="${1:-0}"; shift || true

    # Parse optional flags
    local dry_run=false skip_optional=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)       dry_run=true       ;;
            --skip-optional) skip_optional=true ;;
        esac
        shift
    done

    local total="${#PHASES[@]}"
    local jsonl_file="${INSTALL_DIR}/.install-phases.jsonl"

    # Fresh install truncates; resume (start_idx > 0) appends to preserve prior lines.
    if [[ "$start_idx" -eq 0 ]]; then
        : > "$jsonl_file"
    fi

    # Collect non-preflight names for the --dry-run summary (built once, before the loop).
    local dry_run_would_run=()
    if [[ "$dry_run" == "true" ]]; then
        local _rec _name _fn _to _fl
        for _rec in "${PHASES[@]}"; do
            IFS=$'\x1f' read -r _name _fn _to _fl <<< "$_rec"
            if [[ ",$_fl," != *",preflight,"* ]]; then
                dry_run_would_run+=("$_name")
            fi
        done
    fi

    local i=0 record name fn timeout flags
    for record in "${PHASES[@]}"; do
        IFS=$'\x1f' read -r name fn timeout flags <<< "$record"
        local num=$(( i + 1 ))

        # Skip phases before start_idx (resume support)
        if [[ $i -lt $start_idx ]]; then
            i=$(( i + 1 ))
            continue
        fi

        # --dry-run: run preflight phases only; skip everything else
        if [[ "$dry_run" == "true" ]]; then
            if [[ ",$flags," == *",preflight,"* ]]; then
                local started t_start duration phase_rc
                started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                t_start="$(date +%s)"
                phase_rc=0
                run_phase "$num" "$total" "$name" "$fn" || phase_rc=$?
                duration=$(( $(date +%s) - t_start ))
                _phases_emit_jsonl "$jsonl_file" "$num" "$name" "ok" "$started" "$duration"
            fi
            i=$(( i + 1 ))
            continue
        fi

        # --skip-optional: skip optional phases (emit skip record to jsonl)
        if [[ "$skip_optional" == "true" && ",$flags," == *",optional,"* ]]; then
            local ts
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _phases_emit_jsonl "$jsonl_file" "$num" "$name" "skip" "$ts" "0"
            log_info "Skipping optional phase ${num}/${total}: ${name}"
            i=$(( i + 1 ))
            continue
        fi

        # master-only: skip when not running as master node
        if [[ ",$flags," == *",master-only,"* ]]; then
            local mode
            mode="$(cluster_mode_read 2>/dev/null || echo "single")"
            if [[ "$mode" != "master" ]]; then
                local ts
                ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                _phases_emit_jsonl "$jsonl_file" "$num" "$name" "skip" "$ts" "0"
                log_info "Skipping master-only phase ${num}/${total}: ${name} (mode=${mode})"
                i=$(( i + 1 ))
                continue
            fi
        fi

        # Run the phase
        local started t_start phase_rc status duration
        started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        t_start="$(date +%s)"
        phase_rc=0

        if [[ "${timeout}" -gt 0 ]]; then
            run_phase_with_timeout "$num" "$total" "$name" "$fn" "$timeout" || phase_rc=$?
        else
            run_phase "$num" "$total" "$name" "$fn" || phase_rc=$?
        fi

        duration=$(( $(date +%s) - t_start ))

        if [[ $phase_rc -ne 0 ]]; then
            status="fail"
            _phases_emit_jsonl "$jsonl_file" "$num" "$name" "$status" "$started" "$duration"
            if [[ ",$flags," == *",graceful,"* ]]; then
                log_warn "Phase ${name} returned ${phase_rc} (graceful — continuing)"
            else
                return "$phase_rc"
            fi
        else
            status="ok"
            _phases_emit_jsonl "$jsonl_file" "$num" "$name" "$status" "$started" "$duration"
        fi

        i=$(( i + 1 ))
    done

    # --dry-run: print summary of phases that would have run, then exit 0
    if [[ "$dry_run" == "true" ]]; then
        local summary
        summary="$(IFS=', '; echo "${dry_run_would_run[*]}")"
        log_info "Dry-run complete — would run (phases 2-${total}): ${summary}"
        exit 0
    fi
}
