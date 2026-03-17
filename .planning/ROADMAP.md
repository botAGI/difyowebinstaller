# Roadmap: AGmind Installer v2.0

**Created:** 2026-03-17
**Milestone:** v2.0 MVP
**Phases:** 5
**Core Value:** One command installs, secures, and monitors a production-ready AI stack

## Phase 1: Surgery — Remove Dify API Automation

**Goal:** Delete import.py and all code that touches Dify API. Reduce attack surface, eliminate 50% of bugs, enforce three-layer boundary.

**Requirements:** SURG-01, SURG-02, SURG-03, SURG-04, SURG-05

**Plans:** 2 plans

Plans:
- [x] 01-01-PLAN.md — Delete files, restructure install.sh to 9 phases, remove wizard fields, clean downstream configs
- [x] 01-02-PLAN.md — Create workflows/README.md with import instructions, final stale-reference sweep

**Key deliverables:**
- import.py deleted
- build_difypkg_from_github deleted
- install.sh reduced from 11 to 9 phases
- Wizard simplified (no ADMIN_EMAIL/PASSWORD/COMPANY_NAME)
- rag-assistant.json kept as template + README
- TASK-012/013/014/015 become irrelevant (code deleted)

**Success criteria:**
- `install.sh` runs clean without import.py
- No HTTP calls to Dify API in codebase
- No GitHub downloads of plugin source code
- Stack comes up healthy (23+ containers minus import-dependent ones)

**Depends on:** nothing

---

## Phase 2: Security Hardening v2

**Goal:** Close all known security gaps. Fail2ban and backup must actually work. Credentials never leak to stdout.

**Requirements:** SECV-01, SECV-02, SECV-03, SECV-04, SECV-05, SECV-06, SECV-07

**Plans:** 3 plans

Plans:
- [ ] 02-01-PLAN.md — Nginx rate limiting extension + fail2ban nginx jail removal (SECV-05, SECV-07)
- [ ] 02-02-PLAN.md — Wizard admin-UI opt-in, credential suppression, Squid ACL, Authelia policy (SECV-01, SECV-02, SECV-03, SECV-04)
- [ ] 02-03-PLAN.md — Backup/restore fixes + BATS test (SECV-06)

**Key deliverables:**
- Portainer/Grafana on 127.0.0.1 by default, wizard opt-in to open
- Authelia covers /console/api/, /api/, /v1/, /files/
- credentials.txt (chmod 600) — terminal shows path only
- Squid ACL denies RFC1918 + link-local + 169.254.169.254
- Fail2ban reads Docker nginx logs (or replaced with limit_req_zone)
- Backup restore via tmpdir, parser flags fixed, full cycle test
- Rate limiting on /v1/chat/completions and /console/api/

**Success criteria:**
- `ss -tlnp | grep 9443` shows 127.0.0.1 (not 0.0.0.0)
- `grep -r "password\|DIFY_API" install.log` returns nothing
- `backup.sh && destroy && restore.sh && verify` passes
- Fail2ban active and banning (or nginx rate limiting configured)
- `curl 169.254.169.254` from sandbox container blocked

**Depends on:** Phase 1

---

## Phase 3: Provider Architecture

**Goal:** User chooses LLM and embedding provider in wizard. Compose profiles start only what's needed.

**Requirements:** PROV-01, PROV-02, PROV-03, PROV-04

**Key deliverables:**
- Wizard: LLM provider selection (Ollama/vLLM/External/Skip)
- Wizard: Embedding provider selection (Ollama/TEI/External/Same)
- docker-compose profiles: `--profile ollama`, `--profile vllm`, `--profile monitoring`, `--profile etl-enhanced`
- Plugin documentation README per provider
- vLLM container with GPU passthrough + model preload
- TEI container for production embeddings

**Success criteria:**
- Each provider choice results in correct containers running (and nothing extra)
- `docker compose --profile vllm up` starts vLLM, not Ollama
- `docker compose --profile ollama up` starts Ollama, not vLLM
- External provider: no LLM container started
- README documents which plugins to install per provider

**Depends on:** Phase 1

---

## Phase 4: Installer Redesign

**Goal:** 9-phase installation with resume, logging, timeouts. Professional installer that never leaves user blind.

**Requirements:** INST-01, INST-02, INST-03, INST-04

**Key deliverables:**
- 9 phases: diagnostics → wizard → docker → config → start → health → models → backups → complete
- Checkpoint file /opt/agmind/.install_phase — resume on failure
- Full log /opt/agmind/install.log with timestamps
- Timeout per phase (configurable) + retry + fallback message
- Compose profiles integration (from Phase 3)
- Named volumes with agmind_ prefix

**Success criteria:**
- Kill install at phase 5, restart → resumes from phase 5
- install.log contains every phase with timestamps
- Stuck model pull times out after configured duration with helpful message
- `docker volume ls | grep agmind_` shows all volumes with prefix

**Depends on:** Phase 3

---

## Phase 5: DevOps & UX

**Goal:** CLI tools for day-2 operations. User never needs to guess stack status.

**Requirements:** DEVX-01, DEVX-02, DEVX-03, DEVX-04

**Key deliverables:**
- `agmind status`: containers, GPU, models, endpoints, credentials path
- `agmind doctor`: DNS, GPU driver, Docker version, ports, disk, network
- Health endpoint /health: JSON with all service statuses
- Integration with existing health.sh checks

**Success criteria:**
- `agmind status` shows all containers, GPU util, loaded models, HTTP status of each endpoint
- `agmind doctor` catches: wrong Docker version, port conflict, DNS failure, low disk
- `curl localhost/health` returns JSON with per-service status
- Non-zero exit code from doctor when issues found

**Depends on:** Phase 4

---

## Execution Order

```
Phase 1 ──→ Phase 2 ──→ Phase 3 ──→ Phase 4 ──→ Phase 5
(surgery)   (security)   (providers)  (installer)  (devops)
```

Phases 2 and 3 can run in parallel after Phase 1 (no mutual dependency), but sequential execution is simpler for a solo developer.

## Milestones

| Checkpoint | After Phase | What to verify |
|------------|-------------|----------------|
| Clean slate | 1 | Stack works without import.py, no Dify API calls |
| Secure | 2 | All security items pass, backup cycle verified |
| Provider MVP | 3 | Wizard works, profiles start correct containers |
| Professional installer | 4 | Resume, logs, timeouts all working |
| v2.0 release | 5 | Full stack with CLI tools, ready for users |

---
*Roadmap created: 2026-03-17*
*Last updated: 2026-03-18 after Phase 2 planning — 3 plans created*
