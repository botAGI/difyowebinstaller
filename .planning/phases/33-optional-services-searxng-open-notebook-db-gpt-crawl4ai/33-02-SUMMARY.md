---
phase: 33-optional-services-searxng-open-notebook-db-gpt-crawl4ai
plan: 02
subsystem: infra
tags: [wizard, compose-profiles, health, secrets, searxng, open-notebook, dbgpt, crawl4ai]

requires:
  - phase: 33-optional-services-searxng-open-notebook-db-gpt-crawl4ai
    plan: 01
    provides: Docker compose service definitions for 5 optional services
provides:
  - Wizard y/N steps for 4 optional services
  - Compose profile building for searxng, notebook, dbgpt, crawl4ai
  - Health detection for all optional services
  - Secret generation for SearXNG, SurrealDB, Notebook encryption
  - Credentials.txt output for enabled optional services
  - Env template placeholders for all ENABLE_* and secrets
affects: [install verification, doctor health checks]

tech-stack:
  added: []
  patterns: [optional-service-wizard-pattern, conditional-credentials-output]

key-files:
  created: []
  modified:
    - lib/wizard.sh
    - lib/compose.sh
    - lib/health.sh
    - lib/config.sh
    - install.sh
    - templates/env.lan.template
    - templates/env.vps.template
    - templates/docker-compose.yml

key-decisions:
  - "SearXNG settings.yml generated into docker/ dir (not read from templates/) -- consistent with litellm-config.yaml pattern"
  - "docker-compose.yml searxng volume mount changed to ./searxng-settings.yml for generated config"

patterns-established:
  - "Optional service wizard: NON_INTERACTIVE checks ENABLE_* env var, interactive asks y/N"
  - "Optional service credentials: conditional block in _save_credentials with ENABLE_* guard"

requirements-completed: [OSVC-01, OSVC-02, OSVC-03, OSVC-04]

duration: 4min
completed: 2026-03-30
---

# Phase 33 Plan 02: Optional Services Installer Integration Summary

**4 optional services wired into wizard (y/N prompts), compose profiles, health detection, secret generation, and credentials output**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-30T05:54:53Z
- **Completed:** 2026-03-30T05:59:00Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- Added 4 wizard steps with NON_INTERACTIVE support for SearXNG, Open Notebook, DB-GPT, Crawl4AI
- Wired compose profile building, health detection, env template placeholders for all 4 services
- Added secret generation (SearXNG key, SurrealDB password, Notebook encryption key) and SearXNG settings.yml processing
- Added credentials.txt output blocks with URLs for each enabled optional service

## Task Commits

Each task was committed atomically:

1. **Task 1: Add wizard steps, compose profiles, health detection, and env templates** - `deb25fa` (feat)
2. **Task 2: Add secret generation in config.sh and credentials output in install.sh** - `bdbbd1e` (feat)

## Files Created/Modified
- `lib/wizard.sh` - 4 new wizard functions, run_wizard calls, exports, summary lines
- `lib/compose.sh` - Profile building for searxng/notebook/dbgpt/crawl4ai, updated COMPOSE_PROFILES in stop/cleanup
- `lib/health.sh` - get_service_list() detects optional services from .env
- `lib/config.sh` - Secret generation, sed substitutions, _generate_searxng_config()
- `install.sh` - Credentials blocks for all 4 optional services
- `templates/env.lan.template` - ENABLE_* and secret placeholders
- `templates/env.vps.template` - ENABLE_* and secret placeholders
- `templates/docker-compose.yml` - Fixed searxng volume mount to ./searxng-settings.yml

## Decisions Made
- SearXNG settings.yml generated into docker/ dir (same pattern as litellm-config.yaml)
- docker-compose.yml volume mount changed from ../templates/ to ./ for processed config

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed SearXNG settings.yml volume mount**
- **Found during:** Task 2
- **Issue:** docker-compose.yml mounted ../templates/searxng-settings.yml which contains __SEARXNG_SECRET_KEY__ placeholder
- **Fix:** Changed mount to ./searxng-settings.yml and added _generate_searxng_config() to process template
- **Files modified:** templates/docker-compose.yml, lib/config.sh
- **Verification:** Mount path consistent with litellm-config.yaml pattern
- **Committed in:** bdbbd1e (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Fix necessary for SearXNG to work with generated secret key. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All 4 optional services fully integrated into installer
- Wizard, profiles, health, secrets, credentials all wired
- Ready for testing with `install.sh --non-interactive ENABLE_SEARXNG=true`

---
*Phase: 33-optional-services-searxng-open-notebook-db-gpt-crawl4ai*
*Completed: 2026-03-30*
