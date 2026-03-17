---
phase: 01-surgery-remove-dify-api-automation
plan: 01
subsystem: infra
tags: [bash, installer, docker-compose, dify, openwebui, ollama]

# Dependency graph
requires: []
provides:
  - 9-phase installer without Dify API automation
  - docker-compose template without pipeline service
  - Open WebUI connected directly to Ollama (no pipeline proxy)
  - INIT_PASSWORD and WebUI pass in post-install credentials summary
affects: [phase-02-security-hardening, phase-03-provider-architecture, phase-04-installer-redesign]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "INIT_PASSWORD auto-generated in config.sh (base64-encoded random 16-char), used for Dify first-login and WebUI admin creation"
    - "WebUI admin created with email=admin@localhost using INIT_PASSWORD decoded from .env"
    - "Authelia reads password from INIT_PASSWORD in .env (base64-decoded), not from wizard input"

key-files:
  created: []
  modified:
    - install.sh
    - lib/config.sh
    - lib/authelia.sh
    - templates/docker-compose.yml
    - templates/env.lan.template
    - templates/env.vps.template
    - templates/env.vpn.template
    - templates/env.offline.template
  deleted:
    - workflows/import.py
    - pipeline/Dockerfile
    - pipeline/dify_pipeline.py
    - pipeline/requirements.txt
    - lib/workflow.sh

key-decisions:
  - "INIT_PASSWORD auto-generated in config.sh (no longer wizard-collected), used both for Dify first-login and as WebUI admin password source"
  - "Open WebUI admin email hardcoded to admin@localhost (irrelevant since import.py is gone)"
  - "lib/tunnel.sh and lib/dokploy.sh kept on disk for future Phase 5 use; only their source lines removed"
  - "GRAFANA_ADMIN_PASSWORD retained — distinct from removed ADMIN_PASSWORD wizard field"
  - "authelia.sh company name hardcoded to AGMind (no longer from COMPANY_NAME wizard field)"

patterns-established:
  - "9-phase installer: diagnostics -> wizard -> docker -> config -> start -> health -> models -> backups -> complete"
  - "Credentials flow: INIT_PASSWORD auto-generated in config.sh -> written to .env -> read by create_openwebui_admin and phase_complete"

requirements-completed: [SURG-01, SURG-02, SURG-03, SURG-05]

# Metrics
duration: 7min
completed: 2026-03-17
---

# Phase 1 Plan 01: Surgery — Remove Dify API Automation Summary

**Deleted import.py, pipeline proxy service, and wizard fields (ADMIN_EMAIL/ADMIN_PASSWORD/COMPANY_NAME); restructured install.sh from 11 to 9 phases with INIT_PASSWORD auto-generation and direct Ollama integration**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-03-17T20:47:47Z
- **Completed:** 2026-03-17T20:54:53Z
- **Tasks:** 2/2
- **Files modified:** 8 modified, 5 deleted

## Accomplishments

- Deleted all Dify API automation code: workflows/import.py, pipeline/ directory (3 files), lib/workflow.sh
- Restructured install.sh from 11 phases to 9 by removing phase_workflow and phase_connectivity functions and all their call sites
- Removed ADMIN_EMAIL, ADMIN_PASSWORD, COMPANY_NAME from wizard, global state, exports, CLI args, and credentials output; replaced with auto-generated INIT_PASSWORD
- Removed pipeline service from docker-compose.yml; Open WebUI now depends only on Ollama
- Cleaned all 4 env templates (lan/vps/vpn/offline) of DIFY_API_KEY and COMPANY_NAME entries
- Updated lib/config.sh and lib/authelia.sh to source password from auto-generated INIT_PASSWORD instead of wizard input

## Task Commits

Each task was committed atomically:

1. **Task 1: Delete files and perform full install.sh surgery** - `0c03f50` (feat)
2. **Task 2: Clean up downstream config files and docker-compose template** - `732fe0c` (feat)

## Files Created/Modified

- `install.sh` - 9-phase installer; removed 3 source lines, 7 global vars, 4 wizard sections, 2 phase functions, 2 phase calls; updated credentials summary
- `lib/config.sh` - Removed __ADMIN_EMAIL__/__COMPANY_NAME__ sed substitutions; auto-generate INIT_PASSWORD; removed pipeline cp block
- `lib/authelia.sh` - Read password from INIT_PASSWORD in .env (not ADMIN_PASSWORD); hardcode AGMind company; use domain-based admin email
- `templates/docker-compose.yml` - Deleted pipeline service; removed pipeline dependencies from open-webui and nginx; set ENABLE_OPENAI_API=false
- `templates/env.lan.template` - Removed Pipeline comment, DIFY_API_KEY, COMPANY_NAME lines
- `templates/env.vps.template` - Same as lan
- `templates/env.vpn.template` - Same as lan
- `templates/env.offline.template` - Same as lan
- **DELETED:** `workflows/import.py`, `pipeline/Dockerfile`, `pipeline/dify_pipeline.py`, `pipeline/requirements.txt`, `lib/workflow.sh`

## Decisions Made

- INIT_PASSWORD is auto-generated in config.sh (16-char random, base64-encoded for Dify), not collected from wizard. This decouples first-login from install-time input.
- Open WebUI admin email hardcoded to `admin@localhost` — email field is irrelevant since import.py (the Dify API login flow) is gone.
- `lib/tunnel.sh` and `lib/dokploy.sh` kept on disk (source lines removed from install.sh). These are reserved for Phase 5 `agmind enable-tunnel` / `agmind enable-dokploy` CLI tools.
- `GRAFANA_ADMIN_PASSWORD` is a distinct variable from the removed `ADMIN_PASSWORD` wizard field — retained as-is.

## Deviations from Plan

None - plan executed exactly as written.

The only near-deviation: acceptance criteria said `grep -c 'ADMIN_PASSWORD' install.sh` returns 0, but `GRAFANA_ADMIN_PASSWORD` contains `ADMIN_PASSWORD` as a substring. The wizard `ADMIN_PASSWORD` prompt is fully removed; `GRAFANA_ADMIN_PASSWORD` is a different variable. This is expected and correct per the plan's intent.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- install.sh is syntactically valid (bash -n passes) with 9 phases
- All Dify API automation code removed; installer stops at "stack is running"
- Open WebUI talks directly to Ollama at http://ollama:11434
- Post-install credentials show INIT_PASSWORD (for Dify first-login) and WebUI pass
- Phase 2 (Security Hardening v2) can proceed — credentials.txt chmod/stdout hardening is deferred there (SECV-03)

---
*Phase: 01-surgery-remove-dify-api-automation*
*Completed: 2026-03-17*
