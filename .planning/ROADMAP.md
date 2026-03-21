# Roadmap: AGmind Installer

## Milestones

- ✅ **v2.0 MVP** — Phases 1-5 (shipped 2026-03-18)
- 🚧 **v2.1 Bugfixes + Improvements** — Phases 6-9 (in progress)

---

<details>
<summary>✅ v2.0 MVP (Phases 1-5) — SHIPPED 2026-03-18</summary>

## Phase 1: Surgery — Remove Dify API Automation

**Goal:** Delete import.py and all code that touches Dify API. Reduce attack surface, eliminate 50% of bugs, enforce three-layer boundary.

**Requirements:** SURG-01, SURG-02, SURG-03, SURG-04, SURG-05

**Plans:** 2 plans

Plans:
- [x] 01-01-PLAN.md — Delete files, restructure install.sh to 9 phases, remove wizard fields, clean downstream configs
- [x] 01-02-PLAN.md — Create workflows/README.md with import instructions, final stale-reference sweep

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

**Plans:** 4/4 plans complete

Plans:
- [x] 02-01-PLAN.md — Nginx rate limiting extension + fail2ban nginx jail removal (SECV-05, SECV-07)
- [x] 02-02-PLAN.md — Wizard admin-UI opt-in, credential suppression, Squid ACL, Authelia policy (SECV-01, SECV-02, SECV-03, SECV-04)
- [x] 02-03-PLAN.md — Backup/restore fixes + BATS test (SECV-06)
- [x] 02-04-PLAN.md — Gap closure: SECV-02 documentation drift fix (SECV-02)

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

**Plans:** 3/3 plans complete

Plans:
- [x] 03-01-PLAN.md — Compose profiles: Ollama to profile, add vLLM + TEI services, versions.env, env templates (PROV-03)
- [x] 03-02-PLAN.md — Wizard provider selection, config.sh, models.sh dispatcher, BATS tests (PROV-01, PROV-02, PROV-03)
- [x] 03-03-PLAN.md — Provider-aware phase_complete() hints + workflows/README.md docs (PROV-04)

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

**Plans:** 2/2 plans complete

Plans:
- [x] 04-01-PLAN.md — run_phase() wrapper, checkpoint/resume, tee logging, --force-restart flag (INST-01, INST-02, INST-03)
- [x] 04-02-PLAN.md — Timeout/retry for phases 5/6/7, named volumes agmind_ prefix, v1 migration (INST-04, INST-01)

**Success criteria:**
- Kill install at phase 5, restart -> resumes from phase 5
- install.log contains every phase with timestamps
- Stuck model pull times out after configured duration with helpful message
- `docker volume ls | grep agmind_` shows all volumes with prefix

**Depends on:** Phase 3

---

## Phase 5: DevOps & UX

**Goal:** CLI tools for day-2 operations. User never needs to guess stack status.

**Requirements:** DEVX-01, DEVX-02, DEVX-03, DEVX-04

**Plans:** 2/2 plans complete

Plans:
- [x] 05-01-PLAN.md — agmind CLI entry point with status dashboard, --json output, doctor diagnostics (DEVX-01, DEVX-02, DEVX-04)
- [x] 05-02-PLAN.md — health-gen.sh + nginx /health endpoint + install.sh integration + BATS tests (DEVX-03)

**Success criteria:**
- `agmind status` shows all containers, GPU util, loaded models, HTTP status of each endpoint
- `agmind status --json` outputs valid JSON with services/gpu/endpoints/backup fields
- `agmind doctor` catches: wrong Docker version, port conflict, DNS failure, low disk
- `curl localhost/health` returns JSON with per-service status
- Non-zero exit code from doctor when issues found

**Depends on:** Phase 4

</details>

---

## 🚧 v2.1 Bugfixes + Improvements (In Progress)

**Milestone Goal:** Fix critical runtime bugs that affect production reliability, add component-level update workflow, and improve post-install feedback and operator guidance.

### Phase 6: Runtime Stability

**Goal:** The stack survives real-world conditions — plugin-daemon starts reliably after PostgreSQL is ready, Redis stale locks never block a second startup, and GPU containers come back automatically after a host reboot.

**Depends on:** Phase 5
**Requirements:** STAB-01, STAB-02, STAB-03
**Success Criteria** (what must be TRUE):
  1. `docker compose up` after a fresh boot never fails with "plugin-daemon DB not ready" — plugin-daemon waits for `dify_plugin` database to exist
  2. Running `docker compose up` a second time after a crash clears any stale Redis lock (older than 15 min) automatically, without manual `redis-cli DEL`
  3. After `sudo reboot`, all GPU containers (vLLM / Ollama) are running within 2 minutes without any manual intervention
  4. `agmind status` confirms healthy GPU containers post-reboot

**Plans:** 3/3 plans complete

Plans:
- [x] 06-01-PLAN.md — PostgreSQL init SQL + enhanced healthcheck, Redis lock-cleaner init-container, plugin_daemon dependency chain (STAB-01, STAB-02)
- [x] 06-02-PLAN.md — systemd auto-start service + GPU container restart policy change to unless-stopped (STAB-03)
- [ ] 06-03-PLAN.md — Gap closure: copy redis-lock-cleanup.sh in installer + persist COMPOSE_PROFILES for systemd reboot (STAB-02, STAB-03)

### Phase 7: Update System

**Goal:** Operators can check for available version updates and update any single component without touching the rest of the stack, with automatic rollback if the updated container fails its healthcheck.

**Depends on:** Phase 6
**Requirements:** UPDT-01, UPDT-02, UPDT-03
**Success Criteria** (what must be TRUE):
  1. `agmind update --check` prints a table of current vs. available image tags for all managed components
  2. `agmind update --component dify-api --version 1.4.0` pulls the new image, restarts only that container, and runs its healthcheck
  3. If the healthcheck fails after update, the previous image tag is restored and the container is restarted — no manual steps needed
  4. `agmind update` records what was updated and the outcome in install.log with a timestamp

**Plans:** 2/2 plans complete

Plans:
- [ ] 07-01-PLAN.md — Remote version fetching from GitHub + component targeting with short-name mapping (UPDT-01, UPDT-02)
- [ ] 07-02-PLAN.md — Per-component rollback hardening + manual rollback command + BATS tests (UPDT-03)

### Phase 8: Health Verification & UX Polish

**Goal:** Post-install summary confirms real service reachability (not just container health), `agmind doctor` becomes a comprehensive diagnostics tool, operator pain points (SSH lockout, Portainer tunnel) are resolved, and the repo has a license for public release.

**Depends on:** Phase 6
**Requirements:** HLTH-01, HLTH-02, UXPL-01, UXPL-02, UXPL-03
**Success Criteria** (what must be TRUE):
  1. After `install.sh` completes, the summary block shows a per-service HTTP status (OK / FAIL) based on real `curl` calls to vLLM `/v1/models`, TEI `/info`, and Dify `/console/api/setup`
  2. When the installer disables SSH `PasswordAuthentication`, the terminal outputs a warning and SSH public key setup instructions before making the change
  3. `credentials.txt` and the post-install summary both include the Portainer SSH tunnel command (`ssh -L 9443:127.0.0.1:9443 user@host`)
  4. An operator on a fresh server can access Portainer on the first attempt by following only the on-screen instructions
  5. `agmind doctor` checks disk/RAM usage, Docker daemon, unhealthy/exited/high-restart containers, GPU availability, key service HTTP endpoints, and .env completeness — outputs colored summary with exit code 0/1
  6. `LICENSE` file (Apache 2.0) exists in repo root

**Plans:** 3/3 plans complete

Plans:
- [ ] 08-01-PLAN.md — verify_services() HTTP liveness checks + Portainer SSH tunnel in credentials/summary (HLTH-01, UXPL-02)
- [ ] 08-02-PLAN.md — Doctor enhancement: container health, HTTP endpoints, disk/RAM %, .env completeness (HLTH-02)
- [ ] 08-03-PLAN.md — SSH lockout prevention with warning + Apache 2.0 LICENSE (UXPL-01, UXPL-03)

### ~~Phase 9: Operator Makefile~~ — SKIPPED

**Reason:** agmind CLI already covers all operator commands (status, logs, doctor, update, restart). Makefile would be redundant.

---

## Phases

- [x] **Phase 1: Surgery** — Remove Dify API automation and enforce three-layer boundary
- [x] **Phase 2: Security Hardening v2** — Close security gaps, protect credentials
- [x] **Phase 3: Provider Architecture** — Wizard + Compose profiles per LLM/embedding provider
- [x] **Phase 4: Installer Redesign** — 9-phase install with resume, logging, timeouts
- [x] **Phase 5: DevOps & UX** — agmind CLI, status, doctor, health endpoint
- [x] **Phase 6: Runtime Stability** — Fix plugin-daemon ordering, Redis stale locks, GPU reboot survival (gap closure in progress) (completed 2026-03-21)
- [x] **Phase 7: Update System** — Component-level update with healthcheck + rollback (completed 2026-03-21)
- [x] **Phase 8: Health Verification & UX Polish** — Real endpoint checks, doctor enhancement, LICENSE, SSH/Portainer guidance (completed 2026-03-21)
- [~] ~~**Phase 9: Operator Makefile**~~ — SKIPPED: agmind CLI covers all operations

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Surgery | v2.0 | 2/2 | Complete | 2026-03-18 |
| 2. Security Hardening v2 | v2.0 | 4/4 | Complete | 2026-03-18 |
| 3. Provider Architecture | v2.0 | 3/3 | Complete | 2026-03-18 |
| 4. Installer Redesign | v2.0 | 2/2 | Complete | 2026-03-18 |
| 5. DevOps & UX | v2.0 | 2/2 | Complete | 2026-03-18 |
| 6. Runtime Stability | 3/3 | Complete   | 2026-03-21 | - |
| 7. Update System | 2/2 | Complete   | 2026-03-21 | - |
| 8. Health Verification & UX Polish | 3/3 | Complete   | 2026-03-21 | - |
| 9. Operator Makefile | v2.1 | — | Skipped | — |

---
*Roadmap created: 2026-03-17*
*Last updated: 2026-03-21 — Phase 9 skipped (agmind CLI covers all operations)*
