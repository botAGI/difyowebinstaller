---
phase: 33-optional-services-searxng-open-notebook-db-gpt-crawl4ai
plan: 01
subsystem: infra
tags: [docker-compose, searxng, surrealdb, open-notebook, dbgpt, crawl4ai, profiles]

requires:
  - phase: 32-litellm-ai-gateway
    provides: LiteLLM service definition (DB-GPT depends on it)
provides:
  - 5 docker-compose service definitions with profiles (searxng, notebook, dbgpt, crawl4ai)
  - Version pins for 5 new service images
  - SearXNG settings.yml with JSON API enabled
affects: [33-02 wizard integration, 33-03 credentials and health]

tech-stack:
  added: [searxng, surrealdb, open-notebook, dbgpt, crawl4ai]
  patterns: [optional-service-profile-pattern, surrealdb-websocket-rpc]

key-files:
  created:
    - templates/searxng-settings.yml
  modified:
    - templates/docker-compose.yml
    - templates/versions.env

key-decisions:
  - "SurrealDB used as Open Notebook backend (not PostgreSQL) — per upstream project design"
  - "DB-GPT routes through LiteLLM via OPENAI_API_BASE — consistent with AI gateway pattern"
  - "SearXNG secret_key uses __SEARXNG_SECRET_KEY__ placeholder for install-time substitution"

patterns-established:
  - "Optional service profile: each service gets its own compose profile name"
  - "SurrealDB websocket RPC: ws://surrealdb:8000/rpc for Open Notebook connection"

requirements-completed: [OSVC-01, OSVC-02, OSVC-03, OSVC-04]

duration: 1min
completed: 2026-03-30
---

# Phase 33 Plan 01: Optional Services Docker Compose Summary

**5 optional service definitions (SearXNG, SurrealDB, Open Notebook, DB-GPT, Crawl4AI) with compose profiles, healthchecks, and version pins**

## Performance

- **Duration:** 1 min
- **Started:** 2026-03-30T05:51:48Z
- **Completed:** 2026-03-30T05:52:58Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Added 5 docker-compose service definitions with unique container names, mem_limits, healthchecks, and profiles
- Pinned all 5 new service image versions in versions.env
- Created SearXNG settings.yml with JSON API enabled and 4 search engines (Google, Bing, DuckDuckGo, Wikipedia)

## Task Commits

Each task was committed atomically:

1. **Task 1: Add 5 service definitions to docker-compose.yml** - `67eb2ce` (feat)
2. **Task 2: Add version pins and SearXNG settings** - `21d7fae` (feat)

## Files Created/Modified
- `templates/docker-compose.yml` - 5 new service blocks with profiles, healthchecks, named volumes
- `templates/versions.env` - 5 version pins in new "Optional Services" section
- `templates/searxng-settings.yml` - SearXNG config with JSON API, 4 search engines, secret_key placeholder

## Decisions Made
- SurrealDB used as Open Notebook backend (upstream design, not PostgreSQL)
- DB-GPT routes through LiteLLM via OPENAI_API_BASE (consistent AI gateway pattern)
- SearXNG secret_key uses placeholder for install-time substitution (same pattern as LiteLLM master key)
- Crawl4AI gets 2GB mem_limit and 1GB shm_size (Chromium requirements)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Service definitions ready for wizard integration (33-02)
- Credentials and health check integration ready (33-03)
- All profiles can be independently enabled via COMPOSE_PROFILES

---
*Phase: 33-optional-services-searxng-open-notebook-db-gpt-crawl4ai*
*Completed: 2026-03-30*
