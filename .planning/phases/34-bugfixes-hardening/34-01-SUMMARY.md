---
phase: 34-bugfixes-hardening
plan: 01
subsystem: infra
tags: [docker, image-validation, reliability, retry, backoff, release-tag]

# Dependency graph
requires:
  - phase: 30-reliability-validation
    provides: validate_images_exist(), HTTP HEAD registry check, lib/compose.sh foundation
  - phase: 28-update-system
    provides: get_current_release(), RELEASE_FILE, update.sh structure
provides:
  - IMAGE_VALIDATION_TIMEOUT configurable (default 20s) replacing hardcoded 10s
  - Registry token fetch with 3-attempt retry and 5s sleep
  - Parallel image validation (max 5 concurrent background jobs)
  - Exponential backoff 10s/20s/40s for stuck container retry (BUG-V3-043)
  - RELEASE tag fallback chain in install.sh and update.sh (BUG-V3-044)
affects: [install-flow, update-system, image-pull, stuck-containers]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Parallel background jobs with tmpdir result collection and max-concurrency throttle"
    - "Exponential backoff for retry loops: backoff=$((backoff * 2))"
    - "3-level fallback chain: git describe --exact-match -> git describe --always -> dev-<md5>"

key-files:
  created: []
  modified:
    - lib/compose.sh
    - install.sh
    - scripts/update.sh

key-decisions:
  - "IMAGE_VALIDATION_TIMEOUT defaults to 20s, overridable via env var (not hardcoded)"
  - "Parallel validation uses tmpdir + md5sum filenames for race-safe result collection"
  - "Registry token retry: 3 attempts max, 5s sleep between — same as existing compose.sh patterns"
  - "RELEASE fallback persists discovered tag to RELEASE_FILE to avoid re-computation on next call"
  - "Exponential backoff 10/20/40s replaces fixed 10s — allows longer settle time without tripling wait on fast systems"

patterns-established:
  - "Parallel background jobs pattern: launch in subshell, throttle with pids array, collect results from tmpdir"
  - "RELEASE tag fallback: git describe --exact-match > git describe --always > dev-<md5sum of versions.env>"

requirements-completed: [Reliability, performance]

# Metrics
duration: 3min
completed: 2026-04-04
---

# Phase 34 Plan 01: Bugfixes & Hardening — Image Validation + RELEASE Fallback Summary

**Image validation hardened with 20s timeout, parallel checks (5 concurrent), token retry (3 attempts), exponential backoff for stuck containers (10/20/40s), and RELEASE tag 3-level fallback in install.sh and update.sh**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-04-04T15:33:04Z
- **Completed:** 2026-04-04T15:36:04Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- `lib/compose.sh`: IMAGE_VALIDATION_TIMEOUT variable (20s default), registry token retry loop (3 attempts, 5s sleep), validate_images_exist() parallel background jobs (max 5 concurrent, tmpdir result collection), _retry_stuck_containers() exponential backoff 10/20/40s
- `install.sh`: RELEASE tag fallback chain — git describe --exact-match → git describe --always → dev-<md5sum of versions.env>
- `scripts/update.sh`: get_current_release() same 3-level fallback + persists discovered tag to RELEASE_FILE for future calls

## Task Commits

1. **Task 1: Image validation timeout + parallel checks + registry token retry** - `79fa25f` (feat)
2. **Task 2: RELEASE tag fallback** - `cbc7eda` (feat)

## Files Created/Modified

- `lib/compose.sh` - Added IMAGE_VALIDATION_TIMEOUT, parallel validation, token retry, exponential backoff
- `install.sh` - Added RELEASE fallback chain in _install_cli()
- `scripts/update.sh` - Replaced get_current_release() with 3-level fallback chain

## Decisions Made

- IMAGE_VALIDATION_TIMEOUT defaults to 20s — matches plan spec, overridable without code change
- Parallel validation uses tmpdir + md5sum of image name as filename — avoids special characters in filenames and is race-safe across background jobs
- RELEASE tag fallback persists to RELEASE_FILE immediately — next call to get_current_release() returns fast from file

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

- shellcheck not in PATH on Windows; found via npm cache path. All reported warnings (SC1017 CRLF, SC2086, SC1091) are pre-existing across the entire codebase, not introduced by this plan.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- All 4 reliability fixes from Phase 34 BUG-V3-030/043/044 are complete
- lib/compose.sh ready for production use with improved network resilience
- update.sh now always returns a valid release string even on fresh deploys without RELEASE file

## Self-Check: PASSED

- lib/compose.sh: FOUND (IMAGE_VALIDATION_TIMEOUT x2, max_parallel x3, backoff x4, max_attempts=3)
- install.sh: FOUND (git describe x4, dev-md5sum fallback)
- scripts/update.sh: FOUND (git describe x2, dev-md5sum fallback, persist to RELEASE_FILE)
- 34-01-SUMMARY.md: FOUND
- Commit 79fa25f (Task 1): FOUND
- Commit cbc7eda (Task 2): FOUND

---
*Phase: 34-bugfixes-hardening*
*Completed: 2026-04-04*
