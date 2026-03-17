# State: AGmind Installer v2.0

## Current Phase

**Phase:** 1 — Surgery
**Status:** In Progress
**Plans:** 1/1 complete

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-17)

**Core value:** One command installs, secures, and monitors a production-ready AI stack
**Current focus:** Phase 1 — Remove Dify API automation

## Phase History

| Phase | Name | Status | Plans | Completed |
|-------|------|--------|-------|-----------|
| 1 | Surgery | In Progress | 1/1 | 2026-03-17 |
| 2 | Security Hardening v2 | Not Started | 0/0 | -- |
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

## Performance Metrics

| Phase | Plan | Duration | Tasks | Files |
|-------|------|----------|-------|-------|
| 1 | 01 | 7min | 2 | 13 |

---
*Last updated: 2026-03-17 after Phase 1 Plan 01 completion*
