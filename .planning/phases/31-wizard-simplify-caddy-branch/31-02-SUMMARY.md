---
phase: 31-wizard-simplify-caddy-branch
plan: 02
subsystem: infra
tags: [bash, git, install, wizard, caddy, vds, vps]

# Dependency graph
requires:
  - phase: 31-wizard-simplify-caddy-branch-01
    provides: "2-choice wizard (LAN/VDS-VPS), offline profile removed"
provides:
  - "Local branch agmind-caddy created from main (placeholder for Caddy-based VDS/VPS)"
  - "install.sh accepts --vds flag, sets DEPLOY_PROFILE=vps and VDS_MODE=true"
affects: [agmind-caddy branch future Caddy work, wizard VDS/VPS flow]

# Tech tracking
tech-stack:
  added: []
  patterns: ["--vds flag pattern: branch-level feature flag for Caddy variant"]

key-files:
  created: []
  modified: ["install.sh"]

key-decisions:
  - "agmind-caddy branch created locally from main; user must push with git push origin agmind-caddy"
  - "--vds flag sets DEPLOY_PROFILE=vps and VDS_MODE=true; Caddy-specific logic deferred to agmind-caddy branch"

patterns-established:
  - "VDS_MODE flag pattern: global default false, set true via --vds arg"

requirements-completed: [WZRD-04]

# Metrics
duration: 5min
completed: 2026-03-30
---

# Phase 31 Plan 02: agmind-caddy Branch + --vds Flag Summary

**Local agmind-caddy branch created from main and install.sh extended with --vds flag setting DEPLOY_PROFILE=vps**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-03-30T03:40:00Z
- **Completed:** 2026-03-30T03:45:00Z
- **Tasks:** 1/2 (checkpoint at Task 2)
- **Files modified:** 1

## Accomplishments
- Created local git branch `agmind-caddy` from `main` (placeholder for future Caddy-based VDS/VPS installer)
- Added `VDS_MODE="${VDS_MODE:-false}"` global default to install.sh
- Added `--vds` case in arg parser: sets `DEPLOY_PROFILE="vps"` and `VDS_MODE=true`
- Updated `--help` usage line to include `--vds` flag

## Task Commits

Each task was committed atomically:

1. **Task 1: Create agmind-caddy branch and add --vds flag to install.sh** - `2284dde` (feat)

## Files Created/Modified
- `install.sh` - Added VDS_MODE global default, --vds arg case, updated --help line

## Decisions Made
- agmind-caddy branch created locally only; `git push origin agmind-caddy` must be run by user with push access
- VDS_MODE flag is a placeholder — Caddy-specific logic will be implemented in the agmind-caddy branch, not on main

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required

**After verification, push the agmind-caddy branch to origin:**
```bash
git push origin agmind-caddy
```
This is required for the wizard's VDS/VPS choice to work (`git fetch origin agmind-caddy`).

## Next Phase Readiness
- agmind-caddy branch exists locally, ready to be pushed and developed
- All 5 WZRD requirements verified (see Task 2 checkpoint results)
- Phase 31 complete after user verification

---
*Phase: 31-wizard-simplify-caddy-branch*
*Completed: 2026-03-30*

## Self-Check: PASSED
- install.sh modified: FOUND (2284dde)
- agmind-caddy branch: FOUND (git branch --list returns agmind-caddy)
- --vds in install.sh: FOUND (lines 42, 584, 585)
- bash -n install.sh: PASSED (valid syntax)
