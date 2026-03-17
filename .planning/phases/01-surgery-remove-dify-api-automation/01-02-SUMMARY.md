---
phase: 01-surgery-remove-dify-api-automation
plan: 02
subsystem: infra
tags: [bash, installer, docker-compose, dify, ollama, rag, workflow]

# Dependency graph
requires:
  - phase: 01-01
    provides: 9-phase installer with all Dify API automation removed
provides:
  - workflows/README.md with DSL import guide, plugin list per provider, and pipeline reconnect instructions
  - COMPANY_NAME stale ref removed from docker-compose.yml (hardcoded WEBUI_NAME=AGMind)
  - Zero stale references confirmed across full codebase
affects: [phase-02-security-hardening, phase-03-provider-architecture]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "rag-assistant.json ships with README.md explaining import steps, required plugins, and post-import config"
    - "Pipeline bridge documented as opt-in manual step (set DIFY_API_KEY, rebuild pipeline service)"

key-files:
  created:
    - workflows/README.md
  modified:
    - templates/docker-compose.yml

key-decisions:
  - "WEBUI_NAME hardcoded to AGMind in docker-compose.yml — COMPANY_NAME wizard field removed in Plan 01, default fallback was acceptable but explicit hardcode is cleaner"
  - "Pipeline reconnect instructions folded into workflows/README.md (not a separate docs/advanced/ file) — scope is minimal and single-file is simpler"
  - "grep -c '/9\\]' returns 18 not 9: phase labels appear once in each function + once as comment in main(); this is correct and expected — acceptance criterion was imprecise about counting method, not a real issue"

patterns-established:
  - "Workflow template ships with README beside it — users have self-contained import instructions without installer involvement"

requirements-completed: [SURG-04]

# Metrics
duration: 4min
completed: 2026-03-18
---

# Phase 1 Plan 02: Surgery — Workflow README and Final Sweep Summary

**workflows/README.md created with DSL import guide, per-provider plugin list (Ollama/vLLM/docling), post-import config nodes, and optional Open WebUI pipeline reconnect steps; plus COMPANY_NAME stale ref removed from docker-compose.yml**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-03-17T21:21:40Z
- **Completed:** 2026-03-17T21:25:50Z
- **Tasks:** 2/2
- **Files modified:** 1 created, 1 modified

## Accomplishments

- Created `workflows/README.md` with complete user guide: DSL import steps, required plugins per provider (langgenius/ollama, langgenius/openai_api_compatible, s20ss/docling), post-import node configuration, model provider URLs, and optional pipeline bridge reconnect
- Ran comprehensive grep sweep across install.sh, lib/, templates/ — confirmed zero stale references to all removed code (import.py, DIFY_API_KEY, ADMIN_EMAIL, COMPANY_NAME, phase_workflow, phase_connectivity, setup_dify_account, import_workflow, setup_workflow, build_difypkg)
- Removed `COMPANY_NAME` stale reference from docker-compose.yml (line 226: `WEBUI_NAME=${COMPANY_NAME:-AGMind}` → `WEBUI_NAME=AGMind`)
- Confirmed `rag-assistant.json` preserved unchanged

## Task Commits

Each task was committed atomically:

1. **Task 1: Create workflows/README.md with import and plugin instructions** - `fa33cd1` (feat)
2. **Task 2: Final sweep — verify no stale references remain (+ fix COMPANY_NAME)** - `bbb2fb7` (fix)

## Files Created/Modified

- `workflows/README.md` — Full import guide for rag-assistant.json DSL workflow into Dify UI
- `templates/docker-compose.yml` — Hardcoded WEBUI_NAME=AGMind (removed COMPANY_NAME env var reference)

## Decisions Made

- WEBUI_NAME hardcoded to `AGMind` in docker-compose.yml. Since `COMPANY_NAME` was removed as a wizard field in Plan 01, the `${COMPANY_NAME:-AGMind}` default would always resolve to `AGMind` at runtime anyway — but the explicit reference was misleading and inconsistent with the cleanup intent. Hardcoding is cleaner.
- Pipeline reconnect instructions folded into `workflows/README.md` rather than a separate `docs/advanced/openwebui-dify.md`. The context was minimal and single-file is more discoverable.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed stale COMPANY_NAME reference from docker-compose.yml**
- **Found during:** Task 2 (final sweep)
- **Issue:** `WEBUI_NAME=${COMPANY_NAME:-AGMind}` referenced `COMPANY_NAME` which was removed as a wizard variable in Plan 01. The sweep acceptance criteria explicitly targets `templates/docker-compose.yml` for `COMPANY_NAME` and required zero matches.
- **Fix:** Changed line 226 to `WEBUI_NAME=AGMind` — hardcodes the value that would always have been used anyway
- **Files modified:** `templates/docker-compose.yml`
- **Verification:** `grep -rn 'COMPANY_NAME' templates/docker-compose.yml` returns zero matches
- **Committed in:** `bbb2fb7` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - stale variable reference)
**Impact on plan:** Required cleanup to satisfy acceptance criteria. Behavior-equivalent change (default was always AGMind).

### Note on /9] count

The plan's acceptance criterion says `grep -c '/9\]' install.sh` returns 9. Actual count is 18 because each of the 9 phase labels appears once in the phase function (`echo "${BOLD}[N/9]..."`) and once as a comment in `main()` (`# [N/9]`). This is pre-existing from Plan 01 and correct. The intent (9 phases present, zero /11] labels) is fully satisfied.

## Issues Encountered

None — both tasks proceeded cleanly.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 1 surgery is complete: all Dify API automation removed, 9-phase installer validated, workflows documented
- `workflows/README.md` gives users everything they need to import the RAG workflow post-install
- Phase 2 (Security Hardening v2) can proceed — credentials.txt stdout hardening deferred there (SECV-03)
- `scripts/multi-instance.sh` still contains `DIFY_API_KEY=` and `COMPANY_NAME=` — this was explicitly excluded from sweep (multi-instance is a separate tool, not in scope)

---
*Phase: 01-surgery-remove-dify-api-automation*
*Completed: 2026-03-18*

## Self-Check: PASSED

- workflows/README.md: FOUND
- workflows/rag-assistant.json: FOUND (preserved)
- .planning/phases/01-surgery-remove-dify-api-automation/01-02-SUMMARY.md: FOUND
- Commit fa33cd1: FOUND
- Commit bbb2fb7: FOUND
