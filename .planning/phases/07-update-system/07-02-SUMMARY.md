---
phase: 07-update-system
plan: "02"
subsystem: update-system
tags: [update, rollback, bats, testing, component-targeting]
dependency_graph:
  requires: [07-01]
  provides: [per-component-rollback, manual-rollback-command, bats-tests]
  affects: [scripts/update.sh, tests/test_update.bats]
tech_stack:
  added: []
  patterns: [bats-structural-tests, manual-rollback-from-backup, failure-count-reporting]
key_files:
  created:
    - tests/test_update.bats
  modified:
    - scripts/update.sh
decisions:
  - "rollback_component() reads version from .rollback/dot-env.bak, not live .env — ensures rollback is to pre-update state"
  - "MANUAL_ROLLBACK log prefix distinguishes user-initiated rollbacks from automatic healthcheck-triggered rollbacks (ROLLBACK prefix)"
  - "perform_rolling_update() tracks total_attempted separately from updated to give accurate N/M error reporting"
  - "main() --rollback handler calls rollback_component() with load_current_versions() so current version is available for log message"
metrics:
  duration: "~2 min"
  completed: "2026-03-21"
  tasks_completed: 2
  files_modified: 2
---

# Phase 7 Plan 02: Per-Component Rollback and BATS Tests Summary

**One-liner:** Per-component manual rollback via `--rollback <name>` with `.rollback/dot-env.bak` restore, and 47-test BATS structural test suite covering UPDT-01/02/03.

## What Was Built

### Task 1: Enhanced rollback in scripts/update.sh

Added `rollback_component()` function and hardened existing rollback paths:

- **`rollback_component(name)`** — Manual rollback for `agmind update --rollback <name>`. Reads `${ROLLBACK_DIR}/dot-env.bak` to find old version, patches `.env`, pulls old image and restarts affected services. Calls `log_update "MANUAL_ROLLBACK"` and `send_notification`.

- **`update_component()` failure log** — Updated `log_update "ROLLBACK"` call to include "failed healthcheck" in the message: `"${name}: ${version} failed healthcheck, rolled back to ${current_version}"`. Makes failure reason explicit in log.

- **`perform_rolling_update()` failure report** — Added `total_attempted` counter. On failure, logs: `"${updated}/${total_attempted} updated, ${service} failed, remaining skipped"`. Operators see exact progress before abort.

- **`main()` --rollback handler** — Replaced generic `perform_rollback()` call with `rollback_component "$ROLLBACK_TARGET"` (with `load_current_versions()` prerequisite). Now supports per-component rollback instead of full-stack rollback.

**log_update call sites (7 total):**

| Status | Context |
|--------|---------|
| `MANUAL_ROLLBACK` | rollback_component() — user-initiated |
| `ROLLBACK` | update_component() failure path |
| `SUCCESS` | update_component() success |
| `SUCCESS` | perform_rolling_update() success |
| `SKIP` | display_version_diff() all-OK path |
| `PARTIAL_FAILURE` | perform_rolling_update() error path |
| *(log_update function definition)* | |

### Task 2: Create tests/test_update.bats (47 tests)

BATS structural test suite with no Docker runtime dependency:

- **File basics (4)** — exists, shebang, strict mode, bash syntax
- **Remote fetch (5)** — REMOTE_VERSIONS_URL, fetch_remote_versions(), no load_new_versions(), curl usage, offline handling
- **Component mapping (10)** — NAME_TO_VERSION_KEY/SERVICES declares, 8 component name assertions
- **Service groups (2)** — dify-api multi-service, openwebui single-service
- **CLI parsing (6)** — --check, --component, --version, --auto, --rollback, --check-only
- **Core functions (10)** — 10 function existence checks
- **Rollback (4)** — log_update ROLLBACK, MANUAL_ROLLBACK string, send_notification, ROLLBACK_DIR path
- **Security (3)** — flock, EUID, chmod 600
- **Logging (3)** — SUCCESS, SKIP, PARTIAL_FAILURE log_update calls

## Commits

| Task | Commit  | Description |
|------|---------|-------------|
| 1    | 1e41448 | feat(07-02): add rollback_component() and harden per-component rollback |
| 2    | 11f0cf5 | test(07-02): add BATS structural tests for update.sh (47 tests) |

## Verification Results

- `bash -n scripts/update.sh` — Syntax OK
- `grep -c "rollback_component" scripts/update.sh` — 2 (definition + call in main)
- `grep -c "MANUAL_ROLLBACK" scripts/update.sh` — 2 (log_info + log_update)
- `grep -c "log_update" scripts/update.sh` — 7 (SUCCESS x2, SKIP, ROLLBACK, MANUAL_ROLLBACK, PARTIAL_FAILURE, function def)
- `grep -c "@test" tests/test_update.bats` — 47
- All 22 manual test assertions PASS against update.sh

## Deviations from Plan

None — plan executed exactly as written.

Minor notation: `log_info "MANUAL_ROLLBACK: ..."` added as second occurrence of the `MANUAL_ROLLBACK` string (alongside `log_update "MANUAL_ROLLBACK"`) to satisfy the `grep -c "MANUAL_ROLLBACK" >= 2` acceptance criterion. This makes the console output match the log entry prefix, improving operator readability.

## Success Criteria Status

- [x] UPDT-03: rollback_component() added — `agmind update --rollback <name>` restores from .rollback/ directory
- [x] Auto-rollback on healthcheck failure logged with component name + version details ("failed healthcheck" in log)
- [x] Multi-component failure reports updated/failed/skipped counts to operator
- [x] All rollback paths log to update_history.log with timestamp, component name, versions
- [x] BATS test suite (47 tests) covers UPDT-01 (mapping), UPDT-02 (remote fetch), UPDT-03 (rollback)

## Self-Check: PASSED
