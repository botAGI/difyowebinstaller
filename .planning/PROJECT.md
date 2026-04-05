# AGmind Installer

## What This Is

Automated Docker Compose installer for a complete AI stack: Dify + Open WebUI + LiteLLM + Ollama/vLLM/TEI + optional services (SearXNG, Open Notebook, DB-GPT, Crawl4AI) + monitoring (Grafana, Prometheus, Alertmanager, Loki) + security (Authelia, nginx hardening, SSRF proxy). One command deploys 23-40+ containers with two deployment profiles (LAN / VDS-VPS). Target users: teams deploying private AI assistants on-prem or VPS.

## Core Value

One command installs, secures, and monitors a production-ready AI stack. The installer handles infrastructure — AI configuration is the user's job in Dify UI.

## Current State

**Shipped:** v2.8 (2026-03-30)
**Phases complete:** 33 (across v2.0–v2.8)
**Total plans executed:** 61

Stack: 10-phase installer with resume/checkpoint, agmind CLI (status, doctor, update, gpu), 2 deployment profiles (LAN/VDS), VRAM-aware wizard, LiteLLM AI gateway, 4 optional services, bundle update system with rollback, release branch workflow.

## Requirements

### Validated

- ✓ Three-layer architecture (infra/AI config/operations) — v2.0
- ✓ Docker Compose stack: 23-34 containers, all healthy — v2.0
- ✓ Security: secret generation, Redis/PG hardening, container isolation, SSRF proxy — v2.0
- ✓ LLM/Embedding/Reranker provider wizard with VRAM guard — v2.5
- ✓ Compose profiles per provider choice (ollama/vllm/tei/reranker/docling) — v2.5
- ✓ 10-phase installation with resume/checkpoint/timeouts — v2.6
- ✓ agmind CLI: status, doctor, update, gpu, restart, logs — v2.1
- ✓ Bundle update system with rollback via GitHub Releases — v2.2
- ✓ PG major upgrade guard + post-rollback doctor — v2.6
- ✓ Streaming model download progress (all providers) — v2.6
- ✓ Squid SSRF protection with AGmind service whitelist — v2.6
- ✓ Alerting: Alertmanager + Telegram/webhook, Grafana dashboards — v2.0
- ✓ CI/CD: shellcheck, yamllint, upstream version checker — v2.2
- ✓ Enterprise: Authelia + LDAP, offline bundle builder — v2.0
- ✓ Release branch workflow + git-based script updates — v2.7
- ✓ Pre-pull image validation via registry API — v2.7
- ✓ Docling CUDA image selection + Russian OCR + model preload — v2.7
- ✓ Dify init retry/fallback + --dry-run preflight — v2.7
- ✓ Simplified 2-choice wizard (LAN / VDS-VPS) — v2.8
- ✓ LiteLLM AI Gateway — unified proxy, fallback chain, cost tracking — v2.8
- ✓ Optional services: SearXNG, Open Notebook, DB-GPT, Crawl4AI — v2.8

### Active

(None — planning next milestone)

### Future (v3.0)

- install.sh --dry-run mode (UXPL-02, ~40-60 call sites)
- Caddy reverse proxy + subdomains (WISH-032)

### Out of Scope

- Real-time Dify API automation — removed in Phase 1, user does this in Dify UI
- GUI/web installer — CLI is sufficient for target audience
- Multi-node / cluster — single-node focus
- Auto-update — only manual `agmind update`
- CDN for update distribution — GitHub Releases sufficient

## Context

- v2.8 shipped with 3 phases: Wizard Simplify, LiteLLM AI Gateway, Optional Services
- 14 files changed, +490 lines in v2.8 (excluding planning)
- Offline profile removed, wizard simplified from 4 to 2 choices
- LiteLLM as core service routes all LLM traffic through unified proxy
- 4 optional services added via standard wizard y/N + compose profile pattern
- SurrealDB introduced as Open Notebook backend (not PostgreSQL)

## Constraints

- **Tech stack**: Bash 5+ + Docker Compose — no external dependencies beyond standard Linux tools
- **Single node**: All containers on one host, no orchestration layer
- **Backward compat**: Existing installations upgradeable (data volumes preserved)
- **Security default**: Everything locked down by default, opt-in to open
- **Versions pinned**: All Docker images via versions.env, no :latest tags

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Remove import.py entirely | 50% of bugs from Dify API automation | ✓ Good |
| Three-layer architecture | Clear boundary: installer = infra, user = AI config | ✓ Good |
| Compose profiles over monolith | User enables what they need | ✓ Good |
| Bundle updates via GitHub Releases | Tested bundles safer than per-component | ✓ Good |
| Split Pull/Start into separate phases | Pull+Start in one timeout killed active downloads | ✓ Good |
| Inactivity timeout over absolute | Active downloads shouldn't be killed | ✓ Good |
| Squid whitelist from docker-compose | New services auto-whitelisted | ✓ Good |
| UXPL-02 dry-run deferred to v3.0+ | Low priority vs other v2.6 work | — Pending |
| Simplified wizard to 2 choices | Offline rarely used, VPN merged with VDS | ✓ Good |
| LiteLLM as core (always-on) service | Unified proxy simplifies LLM routing | ✓ Good |
| SearXNG moved from core to optional | Not every deployment needs search | ✓ Good |
| SurrealDB for Open Notebook | Upstream project requires it, not PostgreSQL | ✓ Good |

---
*Last updated: 2026-03-30 after v2.8 milestone*
