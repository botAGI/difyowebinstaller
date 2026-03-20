# Requirements: AGmind Installer v2.1

**Defined:** 2026-03-20
**Core Value:** One command installs, secures, and monitors a production-ready AI stack

## v2.1 Requirements

Requirements for v2.1 Bugfixes + Improvements. Each maps to roadmap phases.

### Runtime Stability

- [ ] **STAB-01**: plugin-daemon стартует только после PostgreSQL с готовой БД `dify_plugin` (healthcheck + depends_on) — BUG-V3-022
- [ ] **STAB-02**: Stale Redis locks (`plugin_daemon:env_init_lock:*`) автоудаляются при старте, если старше 15 мин — WISH-003
- [ ] **STAB-03**: GPU-контейнеры автоматически поднимаются после ребута хоста (systemd service или cron @reboot) — BUG-V3-027

### Update System

- [ ] **UPDT-01**: `agmind update --component <name> --version <tag>` обновляет отдельный компонент (pull + restart + healthcheck) — BUG-V3-024 + WISH-001
- [ ] **UPDT-02**: `agmind update --check` показывает текущие vs доступные версии из Docker Hub/GHCR
- [ ] **UPDT-03**: Rollback при неудачном healthcheck после обновления компонента

### Health Verification

- [ ] **HLTH-01**: Post-install verify проверяет реальную доступность сервисов через curl (vLLM /v1/models, TEI /info, Dify /console/api/setup), результат в summary — WISH-002

### UX Polish

- [ ] **UXPL-01**: При отключении SSH PasswordAuthentication — предупреждение + инструкция по SSH-ключам — BUG-V3-025
- [ ] **UXPL-02**: Portainer tunnel-доступ (`ssh -L 9443:127.0.0.1:9443`) указан в credentials summary — BUG-V3-026

## v2.0 Requirements (Validated)

All 24 requirements shipped and confirmed working in v2.0. See git history for details.

### Surgery

- [x] **SURG-01**: Remove import.py and all Dify API automation
- [x] **SURG-02**: Remove live plugin download from GitHub
- [x] **SURG-03**: Remove wizard fields no longer needed
- [x] **SURG-04**: Keep rag-assistant.json as template + README
- [x] **SURG-05**: Installation reduced from 11 to 9 phases

### Security

- [x] **SECV-01**: Portainer/Grafana bind 127.0.0.1 by default
- [x] **SECV-02**: Authelia 2FA on /console/*, API routes bypass with rate limiting
- [x] **SECV-03**: Credentials only in credentials.txt (chmod 600)
- [x] **SECV-04**: SSRF sandbox blocks RFC1918 + link-local + cloud metadata
- [x] **SECV-05**: Nginx rate limiting replaces fail2ban
- [x] **SECV-06**: Backup/restore fixed
- [x] **SECV-07**: Rate limiting on nginx API routes

### Provider Architecture

- [x] **PROV-01**: LLM provider wizard
- [x] **PROV-02**: Embedding provider wizard
- [x] **PROV-03**: Compose profiles per provider
- [x] **PROV-04**: Plugin documentation per provider

### Installer

- [x] **INST-01**: 9-phase installation structure
- [x] **INST-02**: Resume from checkpoint
- [x] **INST-03**: Installation log with timestamps
- [x] **INST-04**: Timeout + retry per phase

### DevOps

- [x] **DEVX-01**: agmind status
- [x] **DEVX-02**: agmind doctor
- [x] **DEVX-03**: Health endpoint /health
- [x] **DEVX-04**: Named volumes with agmind_ prefix

## Deferred

### v2.2+

- **BUG-V3-023**: Авто-настройка model providers через Dify Console API — нарушает boundary, defer
- **TLSU-01**: TLS out of box (mkcert / Let's Encrypt)
- **TLSU-03**: agmind rollback
- **TLSU-04**: Changelog / breaking changes warning
- **MONV-01..04**: Victoria Metrics, GPU monitoring, vLLM metrics, alerts
- **INSE-01..04**: Non-interactive mode, uninstall, dry-run, model validation
- **ADVX-01..06**: Graceful shutdown, GPU isolation, multi-model, billing, docs, resource limits

## Out of Scope

| Feature | Reason |
|---------|--------|
| Dify API automation (import workflows, create KB) | Boundary violation; source of 50% bugs |
| GUI/web installer | CLI sufficient for target audience |
| Multi-node / cluster | Single-node focus |
| Auto model provider config (BUG-V3-023) | Violates three-layer boundary; deferred to v2.2 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| STAB-01 | Phase 6 | Pending |
| STAB-02 | Phase 6 | Pending |
| STAB-03 | Phase 6 | Pending |
| UPDT-01 | Phase 7 | Pending |
| UPDT-02 | Phase 7 | Pending |
| UPDT-03 | Phase 7 | Pending |
| HLTH-01 | Phase 8 | Pending |
| UXPL-01 | Phase 8 | Pending |
| UXPL-02 | Phase 8 | Pending |

**Coverage:**

- v2.1 requirements: 9 total
- Mapped to phases: 9
- Unmapped: 0

---
*Requirements defined: 2026-03-20*
*Last updated: 2026-03-20 — traceability filled after roadmap creation*
