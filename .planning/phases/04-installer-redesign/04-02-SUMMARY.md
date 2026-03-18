---
phase: 04-installer-redesign
plan: 02
subsystem: infra

tags: [bash, install, timeout, retry, docker-compose, volumes, migration]

# Dependency graph
requires:
  - phase: 04-installer-redesign
    plan: 01
    provides: run_phase() wrapper, checkpoint/resume infrastructure
provides:
  - run_phase_with_timeout() for phases 5/6/7 with configurable timeouts and 1-retry logic
  - _run_with_timeout() background-process timer (preserves sourced lib functions)
  - _show_timeout_diagnostic() per-phase diagnostics with check commands and resume hints
  - TIMEOUT_START/TIMEOUT_HEALTH/TIMEOUT_MODELS env-overridable defaults
  - v1 migration in phase_config(): auto-injects LLM_PROVIDER/EMBED_PROVIDER=ollama
  - agmind_ prefix on all 11 named Docker volumes
affects:
  - install.sh (phases 5/6/7 now timeout-wrapped)
  - templates/docker-compose.yml (new installations get agmind_-prefixed volumes)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Background process timer: func & + kill -0 loop — avoids losing sourced lib functions that `timeout` subshell would miss"
    - "Return code 124 convention: matches standard `timeout` command — callers can detect timeout vs error"
    - "Retry with doubled timeout: 1 retry only, 2x multiplier — exponential but capped"
    - "v1 migration: grep '^KEY=' check + >> append — idempotent, safe to re-run"

key-files:
  created: []
  modified:
    - install.sh
    - templates/docker-compose.yml

key-decisions:
  - "Background process approach (_run_with_timeout) instead of `timeout` command: phase functions call sourced lib functions (download_models, wait_healthy) that would be lost in a new bash subprocess"
  - "Return 124 on timeout: matches `timeout` command convention for compatibility with any future callers"
  - "agmind_ prefix for NEW installs only: v1 volumes kept as-is, no data migration, no risk of data loss"
  - "v1 migration in phase_config() not phase_wizard(): migration runs even on --non-interactive resume, before compose profile string is built"

requirements-completed: [INST-04, INST-01]

# Metrics
duration: 8min
completed: 2026-03-18
---

# Phase 4 Plan 02: Timeout/Retry for Phases 5-7, Named Volume Prefix, v1 Migration Summary

**Phases 5/6/7 now run with configurable timeouts (300s/300s/1200s), 1 retry with doubled timeout, and detailed per-phase diagnostics; all Docker named volumes prefixed with agmind_; v1 installs auto-receive LLM_PROVIDER=ollama injection**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-03-18T02:14:00Z
- **Completed:** 2026-03-18T02:22:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `TIMEOUT_START=300`, `TIMEOUT_HEALTH=300`, `TIMEOUT_MODELS=1200` env-overridable globals
- Added `run_phase_with_timeout()`: writes checkpoint, runs phase with timer, retries once at 2x timeout, calls `_show_timeout_diagnostic()` on exhaustion
- Added `_run_with_timeout()`: background process approach (`func &` + `kill -0` poll loop) that returns 124 on timeout — preserves all sourced library functions unlike `timeout` subshell
- Added `_show_timeout_diagnostic()`: per-phase (5/6/7) diagnostic with docker compose check commands, docker ps filter, registry connectivity test, ollama list check, resume instruction, and env var increase hint
- Wired phases 5/6/7 to `run_phase_with_timeout` in `main()`; phases 1-4, 8-9 remain on `run_phase`
- Added v1 → v2 migration block at top of `phase_config()`: checks for missing `LLM_PROVIDER`/`EMBED_PROVIDER` in existing `.env`, appends `=ollama` if absent
- Renamed all 11 named volumes in `templates/docker-compose.yml` with `agmind_` prefix — both top-level `volumes:` block and all 10 service-level mount references

## Task Commits

1. **Task 1: run_phase_with_timeout() + v1 migration** — `9261c81` (feat)
2. **Task 2: agmind_ volume prefix in docker-compose.yml** — `9fc7775` (feat)

## Files Created/Modified

- `install.sh` — +135 lines: 3 timeout functions, 3 timeout vars, updated phases 5/6/7 calls, v1 migration block in phase_config()
- `templates/docker-compose.yml` — 21 volume name replacements (11 top-level + 10 service-level)

## Decisions Made

- Background process approach for `_run_with_timeout()`: phase functions call functions from sourced libraries (`download_models`, `wait_healthy`) — a `timeout` command spawns a fresh bash process that doesn't have these functions. Background fork inherits the current shell environment.
- Return code 124 matches the standard `timeout` command convention — consistent and recognizable.
- `agmind_` prefix applies to new installations only. v1 volumes keep their current names — no data migration, no risk of `docker volume rm` accidents.
- v1 migration placed at the very top of `phase_config()`, after `ensure_bind_mount_files` but before `generate_config`. This ensures the migration runs even in `--non-interactive` resume mode and before the compose profile string uses `LLM_PROVIDER`.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 4 Plan 02 complete — all timeout/retry and volume prefix requirements done
- `install.sh` is now resilient to slow networks (model downloads) and slow container startup
- v1 installations can upgrade to v2 provider profile system without manual `.env` edits
- Plan 03 can proceed with any remaining Phase 4 items

---
*Phase: 04-installer-redesign*
*Completed: 2026-03-18*
