---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: milestone
status: completed
last_updated: "2026-03-18T04:47:27.911Z"
progress:
  total_phases: 5
  completed_phases: 5
  total_plans: 13
  completed_plans: 13
---

# State: AGmind Installer v2.0

## Current Phase

**Phase:** 4 — Installer Redesign
**Status:** Milestone complete
**Plans:** 0/0 complete

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-17)

**Core value:** One command installs, secures, and monitors a production-ready AI stack
**Current focus:** Phase 4 — Installer Redesign (Phase 3 complete)

## Phase History

| Phase | Name | Status | Plans | Completed |
|-------|------|--------|-------|-----------|
| 1 | Surgery | Complete | 2/2 | 2026-03-18 |
| 2 | Security Hardening v2 | Complete | 4/4 | 2026-03-18 |
| 3 | Provider Architecture | Complete | 3/3 | 2026-03-18 |
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
- [Phase 02]: SECV-02 documentation updated with (10r/s) rate precision — bypass rationale self-contained without cross-referencing CONTEXT.md
- [Phase 03]: Open WebUI ENABLE_OLLAMA_API defaults to false in compose; config.sh sets true only for Ollama provider to prevent connection error logs
- [Phase 03]: vLLM ipc: host required for PyTorch tensor parallel; start_period 900s for 14B model download (8-20 min on 1Gbps)
- [Phase 03]: LLM provider question precedes model selection; Ollama model list shown only when LLM_PROVIDER=ollama
- [Phase 03]: need_ollama unified flag: single wait_for_ollama call when LLM or embed provider uses Ollama
- [Phase 03]: config.sh appends provider WebUI vars after template sed to avoid duplication across profiles
- [Phase 03]: plugin_hint variable set to empty after inline vLLM print to avoid duplicate echo via common guard
- [Phase 03]: llm_display/embed_display declared at top of phase_complete() — reused in both terminal summary box and credentials.txt
- [Phase 04]: run_phase() checkpoint written BEFORE phase starts — crash mid-phase retries that phase on resume
- [Phase 04]: tee logging: exec > >(tee -a LOG) 2>&1 at start of main() — all output captured without modifying existing echo statements
- [Phase 04]: install.log chmod 600: no credential scrubbing needed since Phase 2 already removed creds from stdout
- [Phase 04]: Background process approach for _run_with_timeout(): preserves sourced lib functions unlike timeout subshell
- [Phase 04]: agmind_ volume prefix for new installs only — v1 volumes unchanged to prevent data loss
- [Phase 04]: v1 migration in phase_config() top: auto-injects LLM_PROVIDER/EMBED_PROVIDER=ollama before compose profile build
- [Phase 05]: [Phase 05 Plan 01]: INSTALL_DIR exported before sourcing health.sh to prevent COMPOSE_DIR scoping issue at source time
- [Phase 05]: [Phase 05 Plan 01]: _status_as_json() does NOT call check_all() — avoids ANSI escapes in JSON output (Pitfall 6)
- [Phase 05]: [Phase 05 Plan 01]: GPU checks skipped in doctor when both LLM_PROVIDER=external AND EMBED_PROVIDER=external
- [Phase 05]: health-gen.sh uses atomic write (mktemp+mv) to prevent nginx serving partial JSON during update
- [Phase 05]: nginx /health uses auth_request off via #__AUTHELIA__ pattern — explicit Authelia bypass for VPN profiles
- [Phase 05]: cron.d/agmind-health logs to INSTALL_DIR/health-gen.log; initial health.json placeholder created in phase_config() before nginx start

## Performance Metrics

| Phase | Plan | Duration | Tasks | Files |
|-------|------|----------|-------|-------|
| 1 | 01 | 7min | 2 | 13 |
| 1 | 02 | 4min | 2 | 2 |
| 2 | 01 | 2min | 2 | 2 |
| 2 | 02 | 4min | 3 | 5 |
| 2 | 03 | -- | -- | -- |
| 2 | 04 | 2min | 1 | 2 |

### Quick Tasks Completed

| # | Description | Date | Directory |
|---|-------------|------|-----------|
| 260318-e1f | Fix remaining bugs: atomic sed, BUG-015, restart policies, plugin pool, logrotate | 2026-03-18 | [260318-e1f](./quick/260318-e1f-fix-remaining-bugs-atomic-sed-bug-015-re/) |

---
*Last updated: 2026-03-18 — Completed quick task 260318-e1f: Fix remaining bugs*
| Phase 03 P01 | 15min | 2 tasks | 6 files |
| Phase 03 P02 | 4min | 2 tasks | 5 files |
| Phase 03 P03 | 8min | 2 tasks | 2 files |
| Phase 04 P01 | 12min | 1 tasks | 1 files |
| Phase 04 P02 | 8min | 2 tasks | 2 files |
| Phase 05 P01 | 2min | 2 tasks | 1 files |
| Phase 05 P02 | 15min | 3 tasks | 5 files |

