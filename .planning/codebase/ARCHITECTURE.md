# Architecture

**Analysis Date:** 2026-03-18

## Pattern Overview

**Overall:** Modular bash-based installer with phased deployment orchestration and multi-container Docker stack.

**Key Characteristics:**
- Sequential 9-phase installation with rollback support (diagnostics → wizard → docker → config → start → health → models → backups → complete)
- Pluggable library modules (detect, docker, config, health, security, backup, etc.) sourced by main installer
- Template-driven configuration generation (profile-aware .env and compose files)
- Health-check driven startup verification before proceeding to next phase
- Immutable installation profiles (vps, lan, vpn, offline) that determine defaults and security hardening

## Layers

**Phase Orchestration (install.sh):**
- Purpose: Central conductor that sequences all installation phases and manages global state
- Location: `/d/Agmind/difyowebinstaller/install.sh`
- Contains: Phase functions, banner/UI, main() entry point, global variables
- Depends on: All library modules in `lib/`, templates in `templates/`
- Used by: System admin via `sudo bash install.sh`

**System Detection & Diagnostics (lib/detect.sh):**
- Purpose: Identify OS, CPU, GPU, RAM, disk, Docker, ports, network connectivity — abort if requirements not met
- Location: `/d/Agmind/difyowebinstaller/lib/detect.sh`
- Contains: detect_os(), detect_gpu(), detect_ram(), detect_disk(), detect_ports(), detect_docker()
- Depends on: /etc/os-release, lspci, nvidia-smi, rocminfo, curl, docker commands
- Used by: phase_diagnostics() → preflight_checks()

**Docker Installation & Setup (lib/docker.sh):**
- Purpose: Install Docker/Compose via OS-specific package managers; GPU toolkit support
- Location: `/d/Agmind/difyowebinstaller/lib/docker.sh`
- Contains: install_docker(), install_docker_debian(), install_docker_rhel(), install_docker_macos(), nvidia-smi integration
- Depends on: OS detection, apt/yum/brew commands
- Used by: phase_docker() → setup_docker()

**Configuration Generation (lib/config.sh):**
- Purpose: Generate .env, docker-compose.yml, nginx.conf, redis.conf from templates using environment variables; bind-mount safety checks
- Location: `/d/Agmind/difyowebinstaller/lib/config.sh`
- Contains: generate_config(), safe_write_file(), ensure_bind_mount_files(), preflight_bind_mount_check(), enable_gpu_compose()
- Depends on: Templates in `templates/`, detected variables from phase_wizard()
- Used by: phase_config() → generate_config()

**Health Monitoring (lib/health.sh):**
- Purpose: Wait for all containers to reach healthy state, handle timeout and retry logic
- Location: `/d/Agmind/difyowebinstaller/lib/health.sh`
- Contains: wait_healthy(), check_container(), get_service_list(), run_checks()
- Depends on: docker compose ps, Docker healthcheck definitions
- Used by: phase_health() → wait_healthy()

**Model Initialization (lib/models.sh):**
- Purpose: Pull LLM and embedding models into Ollama, handle multi-architecture support
- Location: `/d/Agmind/difyowebinstaller/lib/models.sh`
- Contains: pull_models(), verify_ollama_models()
- Depends on: Ollama container, OLLAMA_API_BASE
- Used by: phase_models() → pull_models()

**Backup & Disaster Recovery (lib/backup.sh):**
- Purpose: Cron-based backup scheduling, local/remote backup targets
- Location: `/d/Agmind/difyowebinstaller/lib/backup.sh`
- Contains: setup_backup_cron(), configure_remote_backup()
- Depends on: cron, ssh, rsync
- Used by: phase_backups()

**Security Hardening (lib/security.sh):**
- Purpose: UFW firewall, fail2ban, secret rotation, Docker capability dropping
- Location: `/d/Agmind/difyowebinstaller/lib/security.sh`
- Contains: setup_security(), enable_ufw(), setup_fail2ban(), setup_sops()
- Depends on: ufw, fail2ban, sops binaries
- Used by: phase_config() → setup_security()

**Authelia 2FA (lib/authelia.sh):**
- Purpose: Configure Authelia reverse proxy for authentication gate-keeping
- Location: `/d/Agmind/difyowebinstaller/lib/authelia.sh`
- Contains: configure_authelia(), generate_authelia_config()
- Depends on: Authelia service in docker-compose
- Used by: phase_config() → configure_authelia()

**Interactive Wizard (install.sh, phase_wizard):**
- Purpose: Capture user choices via prompts: profile, domain, models, TLS, monitoring, backups
- Location: install.sh lines 195–607
- Contains: Input validation functions, choice-to-variable mapping
- Depends on: read command, validation regex patterns
- Used by: main() → phase_wizard()

## Data Flow

**Installation Sequence:**

1. **phase_diagnostics:** `run_diagnostics()` + `preflight_checks()`
   - Exports: DETECTED_OS, DETECTED_GPU, DETECTED_RAM, DETECTED_DISK, DETECTED_DOCKER_INSTALLED
   - Aborts if critical failures (no Docker, insufficient RAM)

2. **phase_wizard:** Interactive prompts capture user intent
   - Exports: DEPLOY_PROFILE, DOMAIN, LLM_MODEL, EMBEDDING_MODEL, VECTOR_STORE, MONITORING_MODE, TLS_MODE
   - Variables stored in global scope for phase_config()

3. **phase_docker:** `setup_docker()` installs Docker/Compose if needed
   - Installs nvidia-container-toolkit if DETECTED_GPU == nvidia
   - Exports: None (idempotent, verifies existing install)

4. **phase_config:** `generate_config()` renders templates with wizard variables
   - Reads: `templates/env.${DEPLOY_PROFILE}.template`, `templates/docker-compose.yml`
   - Substitutes: __SECRET_KEY__, __DOMAIN__, __LLM_MODEL__, etc. with environment variables
   - Writes: `/opt/agmind/.env`, `/opt/agmind/docker/docker-compose.yml`, nginx.conf, redis.conf
   - Safety: `safe_write_file()` prevents directory artifacts from blocking file creation
   - GPU: `enable_gpu_compose()` adds nvidia runtime to api/worker services if GPU detected

5. **phase_start:** `docker compose up` with depends_on ordering
   - Starts all services: db (postgres) → redis → dify api/worker → ollama → nginx
   - Creates Dify admin user via API calls
   - Exports: None (containers are live)

6. **phase_health:** `wait_healthy()` polls all containers
   - Reads: `.env` to determine active services (vector_store: weaviate vs qdrant, monitoring_mode, etl_type)
   - Polls: docker compose ps Status field every 5 seconds, max 300 seconds
   - Aborts: If any critical service fails health check

7. **phase_models:** `pull_models()` downloads LLM + embedding into Ollama
   - Calls: ollama pull ${LLM_MODEL}, ollama pull ${EMBEDDING_MODEL}
   - Blocks: Until models available in ollama container

8. **phase_backups:** `setup_backup_cron()` installs cron job
   - Creates: /etc/cron.d/agmind-backup with BACKUP_SCHEDULE cron expression
   - Calls: /opt/agmind/scripts/backup.sh on schedule

9. **phase_complete:** Prints URLs and admin password location

**State Management:**

- Global bash variables set by phase_wizard, persisted across phases via `export`
- Secrets generated once: SECRET_KEY, DB_PASSWORD, REDIS_PASSWORD, SANDBOX_API_KEY (22+ random chars)
- Stored: All runtime config in `/opt/agmind/.env` (sourced by docker-compose)
- Immutable: Once DEPLOY_PROFILE chosen, security defaults locked in (UFW, fail2ban rules)
- Idempotent: Subsequent phases can re-run without corrupting state (safe_write_file() pattern)

## Key Abstractions

**Deploy Profile:**
- Purpose: Template selection and security defaults (vps → UFW+fail2ban+sops, lan → fail2ban, offline → none)
- Examples: `vps`, `lan`, `vpn`, `offline` as bash string, maps to template file
- Pattern: `templates/env.${DEPLOY_PROFILE}.template` → `/opt/agmind/.env`

**Vector Store Abstraction:**
- Purpose: Allow Weaviate or Qdrant as pluggable backend
- Examples: `VECTOR_STORE=weaviate` → WEAVIATE_ENDPOINT, `VECTOR_STORE=qdrant` → QDRANT_HOST
- Pattern: health.sh dynamically adds weaviate or qdrant service to health checks based on .env

**ETL Type:**
- Purpose: Toggle between Dify native ETL vs Unstructured API + Docling + Xinference
- Examples: `ETL_TYPE=dify`, `ETL_TYPE=unstructured_api`
- Pattern: config.sh includes/excludes docling and xinference services in docker-compose based on env var

**Service Enablement:**
- Purpose: Conditionally include monitoring stack (prometheus, alertmanager, grafana) without bloating compose
- Pattern: docker-compose.yml lists all services but config.sh comments/uncomments based on MONITORING_MODE

## Entry Points

**Primary Entry Point:**
- Location: `/d/Agmind/difyowebinstaller/install.sh:1285` — `main "$@"`
- Triggers: `sudo bash install.sh` (interactive) or `sudo bash install.sh --non-interactive` (automated)
- Responsibilities: Parse CLI arguments, run 9 phases in sequence

**CLI Arguments:**
```bash
--profile {vps|lan|vpn|offline}
--llm MODEL_NAME
--embedding MODEL_NAME
--domain DOMAIN
--non-interactive
--help
```

**Environment Variables (override CLI):**
```bash
DEPLOY_PROFILE, DOMAIN, LLM_MODEL, EMBEDDING_MODEL, MONITORING_MODE, VECTOR_STORE
TLS_MODE, TLS_CERT_PATH, TLS_KEY_PATH, ENABLE_UFW, ENABLE_FAIL2BAN, ENABLE_SOPS
NON_INTERACTIVE, FORCE_REINSTALL, SKIP_GPU_DETECT, SKIP_PREFLIGHT
```

**Post-Installation Scripts (in `/opt/agmind/scripts/`):**
- `update.sh` — Upgrade Dify version, re-pull models
- `backup.sh` — Manual backup trigger (also runs via cron)
- `restore.sh` — Restore from backup
- `uninstall.sh` — Remove AGMind stack
- `health.sh` — Check container status
- `multi-instance.sh` — Deploy multiple AGMind instances on one host

## Error Handling

**Strategy:** Fail-fast with `set -euo pipefail` (exit on error, undefined vars, pipe failures); trap ERR handler logs error line

**Patterns:**
- **Pre-flight validation:** Each phase checks preconditions; abort with helpful message if violated
- **Diagnostic fallback:** phase_diagnostics warns but continues if non-critical (can force with --yes)
- **Docker health-check:** phase_start waits 300s for containers; if timeout, logs which services failed and exits
- **Bind-mount safety:** config.sh calls `safe_write_file()` before writing, ensures parent dir exists, removes stale directory artifacts
- **Rollback:** phase_cleanup() on EXIT trap removes /var/lock/agmind-install.lock; user manually runs `uninstall.sh` if full rollback needed

**Color-Coded Output:**
- RED=error, YELLOW=warning, GREEN=success, CYAN=info
- Helps admin quickly spot failures in logs

## Cross-Cutting Concerns

**Logging:**
- Pattern: `echo -e "${COLOR}Message${NC}"` throughout (inline logging)
- Storage: Installation logs not centralized; runtime logs in docker logs (docker logs agmind-api)
- Monitoring: Optional Loki + Promtail stack for log aggregation (MONITORING_MODE=local)

**Validation:**
- Input: validate_domain(), validate_email(), validate_port(), validate_model_name() regex checks in phase_wizard()
- System: preflight_checks() verifies ≥4GB RAM, ≥2 cores, ≥20GB disk, ports 80/443 free
- Docker: Healthcheck probes in compose (e.g., api service: curl /health)

**Authentication:**
- Default: Generated admin password stored in `/opt/agmind/.admin_password` (600 perms)
- Optional: Authelia 2FA gate (ENABLE_AUTHELIA=true) for nginx upstream
- Secrets: All passwords/keys generated once with 22+ random chars, stored in .env

**Port Management:**
- nginx: 80 (http), 443 (https, for vps profile)
- Dify API: 5001, Web: 3000
- Open WebUI: 8080
- Ollama: 11434
- PostgreSQL: 5432 (localhost only, not exposed)
- Redis: 6379 (localhost only)
- All internal service-to-service via docker network (no host port exposure for internal APIs)

---

*Architecture analysis: 2026-03-18*
