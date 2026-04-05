---
phase: 28-release-branch-workflow
plan: 03
subsystem: infra
tags: [update, release-notes, github-api, bash, display]

# Dependency graph
requires:
  - phase: 28-02
    provides: fetch_release_info() sets RELEASE_TAG/RELEASE_NOTES globals; empty strings on API failure

provides:
  - Full release notes display in agmind update --check (no truncation)
  - Early exit with "актуальная версия" when version matches
  - Warning message when GitHub API fails (403/429)

affects: [phase-29, phase-30, phase-31]

# Tech tracking
tech-stack:
  added: []
  patterns: [display-only release notes via while-read loop, early-return pattern on version match]

key-files:
  created: []
  modified:
    - scripts/update.sh

key-decisions:
  - "display_bundle_diff() shows full RELEASE_NOTES without line limit (while-read loop)"
  - "Early return with 'актуальная версия' when RELEASE_TAG matches current_release"
  - "elif [[ -z RELEASE_TAG ]] branch shows fallback warning when API failed"

patterns-established:
  - "Release notes block: if notes available → full display + URL; elif no tag → API failure warning"

requirements-completed: [RELU-05]

# Metrics
duration: 3min
completed: 2026-03-29
---

# Phase 28 Plan 03: Full Release Notes in --check Mode Summary

**display_bundle_diff() in update.sh shows unbounded release notes, early "актуальная версия" on match, and GitHub API failure warning**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-29T04:08:54Z
- **Completed:** 2026-03-29T04:11:01Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Removed 10-line truncation from release notes display in `display_bundle_diff()`
- Added early-exit check: when `RELEASE_TAG == current_release`, prints "актуальная версия" and returns 1
- Added fallback `elif [[ -z "${RELEASE_TAG:-}" ]]` branch showing clear warning when GitHub API failed (rate-limited or network error)
- GitHub release URL still shown at bottom of notes when tag is known

## Task Commits

Each task was committed atomically:

1. **Task 1: Full release notes in --check mode** - `b5492c8` (feat)

**Plan metadata:** (will be added after STATE.md commit)

## Files Created/Modified

- `scripts/update.sh` - Modified `display_bundle_diff()`: full notes display, version-match early return, API failure fallback

## Decisions Made

None - followed plan as specified.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 28 Plan 03 complete: `agmind update --check` now shows full release notes without truncation
- Phase 29 can proceed — no blockers
- Operators can now read full release notes in terminal before committing to an update

---
*Phase: 28-release-branch-workflow*
*Completed: 2026-03-29*
