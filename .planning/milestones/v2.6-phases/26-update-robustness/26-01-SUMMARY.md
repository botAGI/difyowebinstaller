---
phase: 26-update-robustness
plan: "01"
subsystem: update
tags: [update, postgres, rollback, release-notes, safety]
dependency_graph:
  requires: []
  provides: [UPDT-01, UPDT-02, UPDT-03]
  affects: [scripts/update.sh]
tech_stack:
  added: []
  patterns: [pg-major-guard, release-notes-display, post-rollback-doctor]
key_files:
  created: []
  modified:
    - scripts/update.sh
decisions:
  - "PG guard placed after CHECK_ONLY exit so --check still shows diff but actual update is blocked on major upgrade"
  - "FORCE=true bypasses PG guard with explicit operator-responsibility warning"
  - "doctor output always logged to install.log even on success; errors shown as warnings (not fatal)"
metrics:
  duration: "89s"
  completed: "2026-03-25"
  tasks_completed: 1
  files_changed: 1
---

# Phase 26 Plan 01: Update Robustness — PG Guard + Release Notes + Post-Rollback Doctor

**One-liner:** Three update.sh safety improvements: PostgreSQL major upgrade guard with pg_dump instructions, 10-line release notes display with GitHub URL, and post-rollback agmind doctor --json logging to install.log.

## What Was Built

Modified `scripts/update.sh` with three targeted improvements:

### UPDT-01: PostgreSQL Major Upgrade Guard

New function `check_pg_major_upgrade()` compares current vs new POSTGRES_VERSION.
Extracts major version via `${var%%[.-]*}` pattern (`16-alpine` -> `16`).
On major version change (e.g. 16->17): prints error with pg_dump instructions and pg-upgrade.md link, then exits 1.
With `--force` flag: logs a warning and continues (operator takes responsibility).
Called in `main()` AFTER the `CHECK_ONLY` early exit, so `agmind update --check` still shows the diff unblocked.

### UPDT-02: Full Release Notes in --check Output

Replaced the single-line truncated release notes display in `display_bundle_diff()` with a multi-line loop reading up to 10 lines from `$RELEASE_NOTES`.
Skips leading blank lines. Shows `... (N lines total)` if notes exceed 10 lines.
Adds `Full changelog: https://github.com/botAGI/AGmind/releases/tag/${RELEASE_TAG}` at the end.

### UPDT-03: Post-Rollback Health Verification

Added doctor invocation in `rollback_bundle()` after `verify_rollback`.
Runs `${INSTALL_DIR}/scripts/agmind.sh doctor --json`; captures stdout+stderr.
On success: logs `Post-rollback health check passed`.
On failure: warns and prints first 20 lines to console.
Always appends full output to `${INSTALL_DIR}/logs/install.log` with timestamp header.
`mkdir -p` ensures logs directory exists.

## Verification Results

```
grep -c "PostgreSQL major upgrade detected" scripts/update.sh  -> 1
grep -c "Full changelog:" scripts/update.sh                    -> 1
grep -c "Post-rollback health check" scripts/update.sh         -> 2
grep -c "doctor --json" scripts/update.sh                      -> 1
grep -c "check_pg_major_upgrade" scripts/update.sh             -> 2  (definition + call)
bash -n scripts/update.sh                                      -> Syntax OK
```

All acceptance criteria met.

## Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | PG guard + release notes + post-rollback doctor | 3130c83 | scripts/update.sh |

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check

- [x] `scripts/update.sh` exists and modified
- [x] Commit 3130c83 present
- [x] All grep criteria pass
- [x] Bash syntax OK

## Self-Check: PASSED
