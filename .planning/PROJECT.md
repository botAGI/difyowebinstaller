# AGmind Installer

## What This Is

Automated Docker Compose installer for Dify + Open WebUI + Ollama/vLLM + monitoring stack (Grafana, Prometheus, Alertmanager, Loki) with security hardening. One command deploys a complete AI infrastructure on a single node. Target users: teams deploying private AI assistants on-prem or VPS.

## Core Value

One command installs, secures, and monitors a production-ready AI stack. The installer handles infrastructure — AI configuration is the user's job in Dify UI.

## Requirements

### Validated

<!-- Shipped in v1.0 and confirmed working -->

- Docker Compose stack: 23+ containers, all healthy
- Security: secret generation, Redis/PG hardening, container isolation, nginx headers
- Version governance: release-manifest.json, pinned images, pre-flight checks
- Alerting: Alertmanager + Telegram/webhook, 4 Grafana dashboards, health.sh 26 checks
- CI/CD: shellcheck + yamllint + hadolint, BATS tests, Trivy scan, smoke tests
- DR: restore-runbook.sh, DR policy, monthly drill cron
- Docs: Docusaurus site, incident runbook
- Enterprise: Authelia + LDAP, offline bundle builder

### Active

<!-- v2.0 MVP scope -->

- [ ] Remove import.py and all Dify API automation (surgery)
- [ ] Remove live plugin download from GitHub (security surface)
- [ ] Portainer/Grafana bind 127.0.0.1 by default
- [ ] Authelia 2FA covers all Dify routes
- [ ] Credentials only in file (not stdout)
- [ ] SSRF sandbox blocks private/metadata addresses
- [ ] Fail2ban fix or replace with nginx rate limiting
- [ ] Backup/Restore fix (tmpdir copy, parser flags)
- [ ] LLM provider wizard (Ollama/vLLM/External/Skip)
- [ ] Embedding provider wizard
- [ ] Compose profiles per provider choice
- [ ] 9-phase installation with resume/checkpoint
- [ ] Installation log with timestamps
- [ ] Timeout + retry on each installation phase
- [ ] agmind status — full stack overview
- [ ] agmind doctor — diagnostics
- [ ] Health endpoint /health — JSON status of all services
- [ ] Rate limiting on nginx API routes

### Out of Scope

- Real-time Dify API automation (import workflows, create KB, register models) — removed in Phase 1, user does this in Dify UI
- GUI/web installer — CLI is sufficient for target audience
- Multi-node / cluster — single-node focus for v2.0
- Graceful shutdown / maintenance mode — v2.2+
- GPU memory isolation (vLLM vs embedding VRAM split) — v2.2+
- Multi-model support in wizard — v2.2+
- LLM request logging / billing — v2.2+

## Context

- v1.0 shipped with 7 phases (hot fixes through docs), all tasks DONE except COM-003 (skipped, open-source)
- Open bugs from TASKS.md (TASK-012/013/014/015) become irrelevant after Phase 1 surgery removes import.py
- 23-container stack verified working on deploy #10 (2026-03-17)
- Three-layer architecture: Infra (installer) / AI Config (user in Dify UI) / Operations (CLI)
- Boundary: installer never touches Dify API, never creates accounts, never imports workflows

## Constraints

- **Tech stack**: Bash + Docker Compose — no external dependencies beyond standard Linux tools
- **Single node**: All containers on one host, no orchestration layer
- **Backward compat**: Existing v1 installations should be upgradeable (data volumes preserved)
- **Security default**: Everything locked down by default, opt-in to open

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Remove import.py entirely | 50% of bugs originate from Dify API automation; boundary violation | -- Pending |
| Remove live plugin download | RCE surface through unsigned GitHub code | -- Pending |
| Credentials to file only | stdout leaks to logs, screenshots, CI output | -- Pending |
| Three-layer architecture | Clear boundary: installer = infra, user = AI config, CLI = operations | -- Pending |
| Compose profiles over monolith | User enables what they need, rest stays down | -- Pending |

---
*Last updated: 2026-03-17 after v2.0 milestone initialization*
