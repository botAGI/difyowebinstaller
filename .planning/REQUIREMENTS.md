# Requirements: AGmind Installer v2.0

**Defined:** 2026-03-17
**Core Value:** One command installs, secures, and monitors a production-ready AI stack

## v1 Requirements

Requirements for v2.0 MVP release. Each maps to roadmap phases.

### Surgery

- [x] **SURG-01**: Remove import.py and all Dify API automation (setup_account, login, CSRF, save_api_key, add_model)
- [ ] **SURG-02**: Remove live plugin download from GitHub (build_difypkg_from_github)
- [x] **SURG-03**: Remove wizard fields no longer needed (ADMIN_EMAIL, ADMIN_PASSWORD, COMPANY_NAME)
- [x] **SURG-04**: Keep rag-assistant.json as template + README with import instructions
- [x] **SURG-05**: Installation reduced from 11 to 9 phases

### Security

- [x] **SECV-01**: Portainer/Grafana bind 127.0.0.1 by default, opt-in to open
- [x] **SECV-02**: Authelia 2FA on /console/* (human login). API routes (/api/, /v1/, /files/) bypass Authelia — protected by Dify API key auth + nginx rate limiting (10r/s).
- [x] **SECV-03**: Credentials written only to credentials.txt (chmod 600), not printed to stdout
- [x] **SECV-04**: SSRF sandbox blocks RFC1918 + link-local + cloud metadata (169.254.169.254)
- [x] **SECV-05**: Fail2ban fixed (mount nginx access.log to host) or replaced with nginx rate limiting
- [x] **SECV-06**: Backup/restore fixed (restore via tmpdir copy, parser flags corrected)
- [x] **SECV-07**: Rate limiting on nginx API routes (/v1/chat/completions, /console/api/)

### Provider Architecture

- [x] **PROV-01**: LLM provider wizard (Ollama / vLLM / External API / Skip)
- [x] **PROV-02**: Embedding provider wizard (Ollama / TEI / External / Same as LLM)
- [x] **PROV-03**: Compose profiles per provider choice (ollama, vllm, external)
- [x] **PROV-04**: Plugin documentation per provider (README with install commands)

### Installer

- [x] **INST-01**: 9-phase installation structure (diagnostics → wizard → docker → config → start → health → models → backups → complete)
- [x] **INST-02**: Resume from checkpoint on failure (/opt/agmind/.install_phase)
- [x] **INST-03**: Installation log with timestamps (/opt/agmind/install.log)
- [x] **INST-04**: Timeout + retry on each installation phase with fallback messages

### DevOps

- [x] **DEVX-01**: agmind status — containers, GPU, models, endpoints, credentials path
- [x] **DEVX-02**: agmind doctor — DNS, GPU driver, Docker version, port conflicts, disk, network
- [ ] **DEVX-03**: Health endpoint /health — JSON with status of all services
- [x] **DEVX-04**: Named volumes with agmind_ prefix

## v2 Requirements

Deferred to v2.1 release. Tracked but not in current roadmap.

### TLS & Updates

- **TLSU-01**: TLS out of box — LAN: mkcert self-signed, VPS: Let's Encrypt auto-cert
- **TLSU-02**: agmind update — update Dify + services preserving data
- **TLSU-03**: agmind rollback — revert to previous version from release-manifest.json
- **TLSU-04**: Changelog / breaking changes warning on update

### Monitoring v2

- **MONV-01**: Victoria Metrics replacing Prometheus (lighter for single-node)
- **MONV-02**: GPU monitoring via nvidia-smi exporter
- **MONV-03**: vLLM metrics from built-in Prometheus endpoint
- **MONV-04**: Alerts: disk >80%, GPU OOM, container restart loop

### Installer Enhancements

- **INSE-01**: Non-interactive mode (config.yaml / env vars, CI/CD ready)
- **INSE-02**: agmind uninstall with choice (volumes or containers only)
- **INSE-03**: Dry run mode (--dry-run shows plan without executing)
- **INSE-04**: Model validation in wizard (check registry before pulling)

## v2.2+ Requirements

Deferred to future. Tracked for planning.

### Advanced Operations

- **ADVX-01**: Graceful shutdown / maintenance mode (drain requests before stop)
- **ADVX-02**: GPU memory isolation (vLLM 80% VRAM, embedding 20%)
- **ADVX-03**: Multi-model support in wizard (fast + powerful)
- **ADVX-04**: LLM request logging / billing (structured log via Loki)
- **ADVX-05**: Documentation: limits and recommendations (file size, KB count, VRAM per user)
- **ADVX-06**: Resource limits on all containers (memory limits on API, worker, nginx)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Dify API automation (import workflows, create KB) | Boundary violation; source of 50% bugs; user configures AI in Dify UI |
| GUI/web installer | CLI sufficient for target audience (sysadmins, DevOps) |
| Multi-node / cluster | Single-node focus; Kubernetes is a different product |
| Mobile app / web dashboard | Not an application, it's an installer |
| OAuth/SSO beyond Authelia+LDAP | Already shipped in v1 enterprise |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| SURG-01 | Phase 1 | Pending |
| SURG-02 | Phase 1 | Pending |
| SURG-03 | Phase 1 | Pending |
| SURG-04 | Phase 1 | Complete |
| SURG-05 | Phase 1 | Pending |
| SECV-01 | Phase 2 | Complete |
| SECV-02 | Phase 2 | Complete |
| SECV-03 | Phase 2 | Complete |
| SECV-04 | Phase 2 | Complete |
| SECV-05 | Phase 2 | Complete |
| SECV-06 | Phase 2 | Complete |
| SECV-07 | Phase 2 | Complete |
| PROV-01 | Phase 3 | Complete |
| PROV-02 | Phase 3 | Complete |
| PROV-03 | Phase 3 | Complete |
| PROV-04 | Phase 3 | Complete |
| INST-01 | Phase 4 | Complete |
| INST-02 | Phase 4 | Complete |
| INST-03 | Phase 4 | Complete |
| INST-04 | Phase 4 | Complete |
| DEVX-01 | Phase 5 | Complete |
| DEVX-02 | Phase 5 | Complete |
| DEVX-03 | Phase 5 | Pending |
| DEVX-04 | Phase 5 | Complete |

**Coverage:**
- v1 requirements: 24 total
- Mapped to phases: 24
- Unmapped: 0

---
*Requirements defined: 2026-03-17*
*Last updated: 2026-03-18 after Phase 2 gap closure — SECV-02 text aligned with Authelia bypass design*
