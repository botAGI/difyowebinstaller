---
phase: 11-bundle-update-rewrite
plan: "01"
subsystem: infra
tags: [bash, docker, github-releases, update, rollback, bundle]

# Dependency graph
requires:
  - phase: 10-release-foundation
    provides: "RELEASE.bak pattern, LC_ALL=C fix, versions.env as GitHub Release asset, COMPONENTS.md"
provides:
  - "Bundle update system in scripts/update.sh via GitHub Releases API"
  - "fetch_release_info() — fetches and parses latest release JSON, downloads versions.env asset"
  - "display_bundle_diff() — shows current vs latest release diff with per-component version changes"
  - "perform_bundle_update() — rolling update of only changed services in dependency order"
  - "rollback_bundle() — full stack rollback from .rollback/ directory"
  - "get_current_release() — reads /opt/agmind/RELEASE file"
  - "GITHUB_API_URL and RELEASE_FILE constants"
  - "DOWNLOADED_VERSIONS_FILE global linking fetch_release_info() to main()"
affects: [11-bundle-update-rewrite-02, verify-work-11]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Bundle-based updates: GitHub Release = tested bundle definition"
    - "RELEASE_FILE = /opt/agmind/RELEASE tracks current bundle version"
    - "DOWNLOADED_VERSIONS_FILE global pattern: temp file path passed between functions"
    - "python3 inline JSON parsing for GitHub API response (single eval() call)"
    - "Rolling restart only for changed services (compare CURRENT_VERSIONS vs NEW_VERSIONS)"

key-files:
  created: []
  modified:
    - "scripts/update.sh — full rewrite: bundle workflow, new functions, new arg parsing, new main()"

key-decisions:
  - "Tasks 1 and 2 merged into single atomic implementation: functions and main() are tightly coupled, split would create intermediate broken state"
  - "rollback_component() kept for backward compatibility with --rollback <component> syntax"
  - "perform_rollback() already restores RELEASE.bak (added), so rollback_bundle() call is safe double-copy"
  - "DOWNLOADED_VERSIONS_FILE as global variable (not return value) — bash cannot return strings from functions"
  - "display_bundle_diff() returns 1 when up-to-date (bash idiom: 0=success=updates available, 1=no updates needed)"

patterns-established:
  - "fetch_release_info() sets DOWNLOADED_VERSIONS_FILE global for main() to consume"
  - "Bundle update flow: fetch_release_info -> display_bundle_diff -> confirm -> backup -> save_rollback_state -> apply .env -> perform_bundle_update -> write RELEASE or rollback"

requirements-completed: [BUPD-01, BUPD-02, BUPD-03, BUPD-04]

# Metrics
duration: 3min
completed: 2026-03-22
---

# Phase 11 Plan 01: Bundle Update Rewrite Summary

**Rewrote scripts/update.sh from per-component fetch to bundle-based workflow via GitHub Releases API with automatic rollback on healthcheck failure**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-03-22T00:26:23Z
- **Completed:** 2026-03-22T00:29:05Z
- **Tasks:** 2 (merged into 1 atomic commit)
- **Files modified:** 1

## Accomplishments

- Full rewrite of scripts/update.sh: replaced `fetch_remote_versions()` + `display_version_diff()` + `perform_rolling_update()` with bundle-based equivalents
- `fetch_release_info()` calls GitHub Releases API, parses JSON via python3, downloads `versions.env` asset, sets `DOWNLOADED_VERSIONS_FILE` global and `NEW_VERSIONS` array
- `display_bundle_diff()` shows current release vs latest with per-component version diff; prints "You are up to date" when current == latest
- `perform_bundle_update()` pulls/restarts only services whose version actually changed, in dependency order (infra -> app -> frontend)
- `rollback_bundle()` restores full stack from `.rollback/` directory; `save_rollback_state()` and `perform_rollback()` now also handle `RELEASE.bak`
- Argument parsing rewritten: `--rollback` without argument = bundle rollback, `--rollback <name>` = per-component (backward compat), `--force` added
- `main()` implements full bundle workflow: fetch -> diff -> confirm -> backup -> apply versions -> bundle update -> write RELEASE or auto-rollback

## Task Commits

Tasks 1 and 2 were implemented together as a single atomic commit (functions and main() are tightly coupled):

1. **Tasks 1+2: Add bundle functions + rewrite main()** - `d891aca` (feat)

## Files Created/Modified

- `scripts/update.sh` — full rewrite: ~430 lines replaced with ~470 lines; bundle workflow, GitHub Releases API, RELEASE_FILE tracking, new functions, new arg parsing and main()

## Decisions Made

- Tasks 1 and 2 merged into single atomic commit: separating new functions (Task 1) from the main() that calls them (Task 2) would create an intermediate broken state where new functions exist but old main() still calls removed functions.
- `DOWNLOADED_VERSIONS_FILE` implemented as bash global variable (set in `fetch_release_info()`, consumed in `main()`) — bash cannot return strings from functions; global is the standard pattern.
- `rollback_component()` kept intact for backward compatibility: `--rollback <component>` still works as before.
- `display_bundle_diff()` returns 1 when up-to-date (bash convention: 0 = true/updates available, 1 = false/no updates).

## Deviations from Plan

None — plan executed exactly as written. Both tasks implemented as a single coherent rewrite per plan structure.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required beyond what was already established in Phase 10 (GitHub Release v2.1.0 published with versions.env asset).

## Next Phase Readiness

- `scripts/update.sh` ready with bundle workflow functions
- Plan 11-02 can proceed: will add emergency `--component` mode warning, update `agmind` CLI wrapper, and add `--help` output
- `RELEASE_FILE` pattern established: `/opt/agmind/RELEASE` stores current bundle tag

## Self-Check

Status: PASSED

- FOUND: `scripts/update.sh`
- FOUND: `.planning/phases/11-bundle-update-rewrite/11-01-SUMMARY.md`
- FOUND: commit `d891aca`
- Note: `.planning/` is in `.gitignore` — planning files are local only (by design)

---
*Phase: 11-bundle-update-rewrite*
*Completed: 2026-03-22*
