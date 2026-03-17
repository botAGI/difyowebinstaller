---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: milestone
status: planning
last_updated: "2026-03-17T23:25:19.086Z"
progress:
  total_phases: 5
  completed_phases: 1
  total_plans: 5
  completed_plans: 5
---

# State: AGmind Installer v2.0

## Current Phase

**Phase:** 1 — Surgery
**Status:** Ready to plan
**Plans:** 2/2 complete

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-17)

**Core value:** One command installs, secures, and monitors a production-ready AI stack
**Current focus:** Phase 1 — Remove Dify API automation

## Phase History

| Phase | Name | Status | Plans | Completed |
|-------|------|--------|-------|-----------|
| 1 | Surgery | Complete | 2/2 | 2026-03-18 |
| 2 | Security Hardening v2 | In Progress | 2/3 | -- |
| 3 | Provider Architecture | Not Started | 0/0 | -- |
| 4 | Installer Redesign | Not Started | 0/0 | -- |
| 5 | DevOps & UX | Not Started | 0/0 | -- |

## Context from v1

All v1 tasks DONE (Phases 0-7 in CLAUDE_CODE_DRIVER.md). Open TASKS.md bugs (012-015) become irrelevant after Phase 1 surgery removes import.py.

Last deploy: #10, 2026-03-17, 23/23 containers healthy.

## Decisions

- Phase 1 Plan 01: INIT_PASSWORD auto-generated in config.sh (not wizard-collected); used for Dify first-login and WebUI admin password
- Phase 1 Plan 01: Open WebUI talks directly to Ollama (pipeline proxy removed); ENABLE_OPENAI_API=false
- Phase 1 Plan 01: lib/tunnel.sh and lib/dokploy.sh kept on disk for Phase 5 (only source lines removed from install.sh)
- Phase 1 Plan 02: WEBUI_NAME hardcoded to AGMind in docker-compose.yml (COMPANY_NAME removed as wizard field in Plan 01); pipeline reconnect folded into workflows/README.md
- [Phase 02]: Phase 2 Plan 01: Login rate at 1r/10s burst=3 blocks dictionary attacks, burst allows typos
- [Phase 02]: Phase 2 Plan 01: Fail2ban nginx jail removed entirely — Docker logpath mismatch makes it non-functional; nginx rate limiting replaces it
- [Phase 02]: RESTORE_TMP at /opt/agmind/.restore_tmp (INSTALL_DIR-relative) avoids cross-device mv failures
- [Phase 02]: BATS backup tests use grep/head pattern validation — no Docker required for CI
- [Phase 02 Plan 02]: ADMIN_UI_OPEN defaults to false; VPS always locked; ADMIN_UI_BIND_ADDR env triggers yes in non-interactive mode
- [Phase 02 Plan 02]: Credentials suppressed from terminal stdout; credentials.txt (chmod 600) is single source of truth for passwords
- [Phase 02 Plan 02]: Authelia bypass for /api,/v1,/files placed before two_factor rule (first-match wins in Authelia)

## Performance Metrics

| Phase | Plan | Duration | Tasks | Files |
|-------|------|----------|-------|-------|
| 1 | 01 | 7min | 2 | 13 |
| 1 | 02 | 4min | 2 | 2 |
| 2 | 01 | 2min | 2 | 2 |
| 2 | 02 | 4min | 3 | 5 |

---
*Last updated: 2026-03-18 after Phase 2 Plan 02 completion — admin UI lock, credential suppression, Squid SSRF, Authelia bypass*

