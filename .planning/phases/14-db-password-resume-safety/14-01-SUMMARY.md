---
phase: 14-db-password-resume-safety
plan: "01"
subsystem: config-secrets
tags: [bugfix, db-password, resume-safety, IREL-03]
dependency_graph:
  requires: []
  provides: [db-password-resume-safety]
  affects: [lib/config.sh, lib/compose.sh]
tech_stack:
  added: []
  patterns: [backup-restore, graceful-degradation]
key_files:
  created: []
  modified:
    - lib/config.sh
    - lib/compose.sh
decisions:
  - "Check PG_VERSION file (not directory existence) as definitive PG data indicator — directory is always created by _create_directory_structure()"
  - "Generate fresh secrets FIRST, then override with backup — ensures safe fallback on any restore failure"
  - "Restore only three volume-bound secrets (DB_PASSWORD, REDIS_PASSWORD, SECRET_KEY) — other secrets are not persisted in volumes"
metrics:
  duration: 80s
  completed: "2026-03-23"
  tasks_completed: 2
  files_modified: 2
---

# Phase 14 Plan 01: DB Password Resume Safety Summary

**One-liner:** Preserve DB_PASSWORD/REDIS_PASSWORD/SECRET_KEY from .env backup when PG data exists, harden sync_db_password() to 90s with actionable manual fix commands.

## What Was Built

Fixes IREL-03: on resume installation, `_generate_secrets()` was unconditionally regenerating all secrets including `DB_PASSWORD`. If PostgreSQL already had data with the old password, the fresh password caused `FATAL: password authentication failed` and the stack could not start.

**lib/config.sh — `_restore_secrets_from_backup()` function:**
- Detects existing PostgreSQL data via `PG_VERSION` file (definitive indicator, unlike directory which is always created)
- Finds the most recent `.env.backup.*` file written by `_generate_env_file()` before overwriting
- Restores `DB_PASSWORD`, `REDIS_PASSWORD`, `SECRET_KEY` — the three volume-bound secrets
- Called from `_generate_secrets()` AFTER generating fresh secrets (safe fallback always present)
- Fresh install: PG_VERSION absent → returns 1 immediately → zero behavior change
- Resume with backup: restores three secrets → logs informational message
- Resume without backup: warns and returns 1 → fresh secrets used, sync_db_password will fix via ALTER USER

**lib/compose.sh — `sync_db_password()` hardening:**
- Retry loop increased from 30 to 45 attempts (60s → 90s timeout) for slow hardware
- ALTER USER failure now prints copy-paste manual fix command with correct user and env_file path
- Timeout failure now prints copy-paste manual fix command

## Tasks Completed

| Task | Description | Commit | Files |
|------|-------------|--------|-------|
| 1 | Add _restore_secrets_from_backup() + guard in _generate_secrets() | f9cae95 | lib/config.sh |
| 2 | Harden sync_db_password() with 90s timeout and actionable errors | a8dad17 | lib/compose.sh |

## Success Criteria Met

- [x] Resume scenario: PG_VERSION + backup found → DB_PASSWORD/REDIS_PASSWORD/SECRET_KEY restored, no new passwords
- [x] Fresh scenario: PG_VERSION absent → all secrets freshly generated, zero behavior change
- [x] Edge case: PG_VERSION present but no backup → warning logged, sync_db_password will fix via ALTER USER
- [x] sync_db_password waits 90s and provides actionable manual fix on failure
- [x] Both files pass `bash -n` syntax check

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

Files exist:
- lib/config.sh: FOUND (modified, contains _restore_secrets_from_backup)
- lib/compose.sh: FOUND (modified, contains 45-attempt loop)

Commits exist:
- f9cae95: feat(14-01): add _restore_secrets_from_backup() — FOUND
- a8dad17: feat(14-01): harden sync_db_password() — FOUND
