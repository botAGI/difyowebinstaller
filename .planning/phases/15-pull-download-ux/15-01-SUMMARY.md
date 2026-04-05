---
phase: 15-pull-download-ux
plan: 01
subsystem: infra
tags: [docker, compose, ollama, pull, progress, timeout, ux]

# Dependency graph
requires: []
provides:
  - "_validate_pulled_images() in lib/compose.sh: per-image ERROR with image:tag after failed pull"
  - "MODEL_SIZES lookup table in lib/models.sh: approximate sizes for 13 common models"
  - "TTY passthrough in pull_model(): docker exec -t with non-TTY fallback"
  - "phase_models_graceful() in install.sh: model failures produce WARNING not fatal error"
  - "Models timeout handler in run_phase_with_timeout(): Models phase non-fatal, others remain fatal"
affects: [install.sh, lib/compose.sh, lib/models.sh, operator-ux]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Post-pull validation: check each image individually after compose pull, report missing with image:tag"
    - "Non-fatal phase: wrapper function that catches errors, logs warning, returns 0"
    - "TTY-with-fallback: docker exec -t first, then docker exec without -t on failure"

key-files:
  created: []
  modified:
    - lib/compose.sh
    - lib/models.sh
    - install.sh

key-decisions:
  - "Missing Docker images produce per-image ERROR (not swallowed) but installation continues — operator sees clear feedback without abort"
  - "MODEL_SIZES hardcoded table (not dynamic) for zero-overhead size hints — unknown models simply skip size display"
  - "phase_models_graceful() returns 0 on ANY failure — combined with run_phase_with_timeout Models-specific handler covers both normal failure and timeout"
  - "docker exec -t fallback to docker exec: TTY detection without explicit isatty() check — simpler and handles piped/non-interactive contexts"

patterns-established:
  - "Non-fatal phase pattern: wrap phase_X() in phase_X_graceful() that catches error, logs warning with recovery instructions, returns 0"
  - "Post-pull validation pattern: _validate_pulled_images() nameref helper separate from progress display"

requirements-completed: [DLUX-01, DLUX-02]

# Metrics
duration: 20min
completed: 2026-03-23
---

# Phase 15 Plan 01: Pull & Download UX Summary

**Per-image ERROR reporting after compose pull, Ollama TTY progress with model size hints, and graceful model phase timeout that continues installation instead of aborting**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-03-23T00:00:00Z
- **Completed:** 2026-03-23
- **Tasks:** 2/2
- **Files modified:** 3

## Accomplishments

- Missing Docker images now produce a clear `log_error "Образ не найден: <image>:<tag>. Проверьте тег в versions.env"` for each missing image after compose pull — operator sees exactly which images failed
- Installation never aborts on missing images: `_pull_with_progress` returns non-zero, `compose_up` catches it with `|| log_warn` and continues
- Ollama model downloads now show layer-by-layer progress bars when TTY is available via `docker exec -t`, with fallback to silent mode when piped
- Known models display approximate download size before starting (e.g. "~8.5 GB" for qwen2.5:14b, "~1.2 GB" for bge-m3)
- Model phase timeout/failure now yields WARNING + manual pull instruction instead of fatal abort — installation proceeds to phases 8 (Backups) and 9 (Complete)

## Task Commits

Each task was committed atomically:

1. **Task 1: Post-pull image validation in _pull_with_progress (DLUX-01)** - `1513796` (feat)
2. **Task 2: Model download progress + graceful timeout (DLUX-02)** - `9aea335` (feat)

**Plan metadata:** (docs commit — see below)

## Files Created/Modified

- `lib/compose.sh` - Added `_validate_pulled_images()` helper, replaced `wait || true` with exit code capture, added per-image error reporting and non-fatal warning in `compose_up()`
- `lib/models.sh` - Added `MODEL_SIZES` associative array (13 entries), updated `pull_model()` with size hint display and `docker exec -t` TTY passthrough + fallback
- `install.sh` - Added `phase_models_graceful()` wrapper, replaced phase 7 invocation to use it, modified `run_phase_with_timeout()` timeout handler for Models-specific non-fatal behavior

## Decisions Made

- Missing images: ERROR per image + continue (not abort) — operator needs clear feedback but install must not die over a stale image tag
- MODEL_SIZES hardcoded: dynamic `docker exec ollama show` would add latency and require Ollama to be running — hardcoded table is zero-overhead
- Two-layer graceful handling: `phase_models_graceful()` covers normal failures, `run_phase_with_timeout()` Models-specific handler covers timeout — belt-and-suspenders
- TTY fallback: `docker exec -t` first, then plain `docker exec` — simpler than explicit `[ -t 1 ]` check, handles all contexts correctly

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Phase 15 Plan 01 complete, requirements DLUX-01 and DLUX-02 fulfilled
- All three modified files pass `bash -n` syntax check and shellcheck with no warnings
- No regression to existing pull/health/start behavior (additive changes only)

## Self-Check: PASSED

- lib/compose.sh: FOUND
- lib/models.sh: FOUND
- install.sh: FOUND
- 15-01-SUMMARY.md: FOUND
- Commit 1513796 (Task 1): FOUND
- Commit 9aea335 (Task 2): FOUND
- .planning/ is in .gitignore — planning artifacts are local-only (expected)

---
*Phase: 15-pull-download-ux*
*Completed: 2026-03-23*
