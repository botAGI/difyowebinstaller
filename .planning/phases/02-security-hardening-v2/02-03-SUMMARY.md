---
phase: 02-security-hardening-v2
plan: 03
subsystem: backup-restore
tags: [backup, restore, bats, security, reliability]
dependency_graph:
  requires: []
  provides: [fixed-restore-sh, bats-backup-tests]
  affects: [scripts/restore.sh, tests/test_backup.bats]
tech_stack:
  added: []
  patterns: [tmpdir-same-filesystem, bats-pattern-validation]
key_files:
  created:
    - tests/test_backup.bats
  modified:
    - scripts/restore.sh
decisions:
  - "RESTORE_TMP at /opt/agmind/.restore_tmp (INSTALL_DIR-relative) avoids cross-device mv failures"
  - "BATS tests use grep/head pattern validation — no Docker required for CI"
  - "cleanup_restore() cleans RESTORE_TMP on both success and failure paths via EXIT trap"
  - "--auto-confirm and --help flags added to restore.sh CLI"
metrics:
  duration: 15min
  completed: "2026-03-18"
  tasks: 2
  files: 2
---

# Phase 2 Plan 03: Backup/Restore Reliability Summary

**One-liner:** Fixed restore.sh cross-device tmpdir bug with /opt/agmind/.restore_tmp pattern and added 19 BATS tests validating backup/restore correctness without Docker.

## Tasks Completed

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | Fix restore.sh — tmpdir, pipefail, CLI flags | e377b2a | scripts/restore.sh |
| 2 | Create BATS test for backup/restore validation | f4c9a26 | tests/test_backup.bats |

## What Was Built

### Task 1: restore.sh fixes

Three targeted improvements to `scripts/restore.sh`:

**Fix 1 — Centralized tmpdir (`RESTORE_TMP`):**
- Replaced all three `mktemp -d "${data_dir}.old.XXXXXX"` calls (Qdrant line ~191, Weaviate ~211, Dify storage ~234) with `RESTORE_TMP="${INSTALL_DIR}/.restore_tmp"`
- Since INSTALL_DIR is `/opt/agmind` and data volumes live under `/opt/agmind/docker/volumes`, the tmpdir is on the same filesystem — no cross-device `mv` failures
- `cleanup_restore()` now removes `$RESTORE_TMP` on EXIT trap (success and failure paths)
- `mkdir -p "$RESTORE_TMP"` added before "Stop services" section

**Fix 2 — Pipefail documentation:**
- Script already had `set -euo pipefail` on line 3; `if !` guard on psql pipe already catches errors
- Added explicit comment `# set -o pipefail ensures gunzip|psql pipe failures are caught` for clarity

**Fix 3 — CLI flag parsing:**
- Added `while/case` flag parser before RESTORE_DIR path parsing
- `--auto-confirm`: sets `AUTO_CONFIRM=true`, continues to positional args
- `--help|-h`: prints usage and exits 0
- `--*` unknown flags: error and exit 1
- `realpath -m` fallback to `readlink -f` for portability

### Task 2: tests/test_backup.bats (19 tests)

BATS test suite that validates backup/restore correctness without Docker. All tests use `grep`/`head` pattern matching against the script files, making them fast and CI-safe.

**Test categories:**
- Syntax validation (2): `bash -n` for both scripts
- Restore tmpdir pattern (3): no mktemp, RESTORE_TMP defined, cleanup present
- Pipefail (2): `set -euo pipefail` in both scripts
- Security (3): umask 077, root checks, exclusive flock
- Parser and flags (3): --auto-confirm, --help, INSTALL_DIR validation
- Backup output structure (3): sha256sum, cleanup trap, retention count
- Age key safety (1): `cp.*age_keys` gated behind user confirmation

## Deviations from Plan

### Auto-fixed Issues

None.

### Plan Adjustments

**1. [Adaptation] Test assertion for cleanup_restore → rm -rf.*RESTORE_TMP**
- **Found during:** Task 2
- **Issue:** Plan specified `grep -A5 "cleanup_restore"` → check for RESTORE_TMP in output, but cleanup_restore body spans more than 5 lines so RESTORE_TMP wasn't in the window
- **Fix:** Changed test to `grep "rm -rf.*RESTORE_TMP"` — simpler, more direct, still validates the invariant
- **Files modified:** tests/test_backup.bats

## Verification Results

```
bash -n scripts/restore.sh    → PASS
bash -n scripts/backup.sh     → PASS
grep .restore_tmp restore.sh  → PASS (RESTORE_TMP defined and used)
grep mktemp restore.sh        → PASS (no matches — mktemp removed)
grep --auto-confirm restore.sh → PASS
grep --help restore.sh        → PASS
tests/test_backup.bats exists → PASS
@test count                   → 19 (requirement: >= 15)
```

## Self-Check: PASSED

Files created/modified:
- FOUND: `scripts/restore.sh` (modified)
- FOUND: `tests/test_backup.bats` (created)

Commits:
- FOUND: e377b2a — fix(02-03): restore.sh — tmpdir pattern, pipefail comment, CLI flags
- FOUND: f4c9a26 — feat(02-03): add BATS tests for backup/restore validation
