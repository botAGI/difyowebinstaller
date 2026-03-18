# Architecture

**Analysis Date:** 2026-03-18

## Pattern Overview

**Overall:** Three-layer modular Bash architecture with clear separation of concerns.

**Key Characteristics:**
- Single-node Docker Compose orchestration (no clustering)
- Modular library system for code reuse and separation of concerns
- 9-phase installation pipeline with checkpoint/resume capability
- Profile-based container activation (Ollama/vLLM/TEI/Weaviate/Qdrant)
- Event-driven health checking and operational monitoring

## Layers

**Infrastructure Layer:**
- Purpose: Operating system detection, Docker setup, firewall/security configuration
- Location: `lib/detect.sh`, `lib/docker.sh`, `lib/security.sh`
- Contains: OS detection, GPU detection, port/disk/RAM checks, firewall rules, fail2ban setup
- Depends on: Host system capabilities, package managers (apt/dnf/yum)
- Used by: `install.sh` phases 1-3

**Configuration Layer:**
- Purpose: Generate and manage runtime configuration from templates
- Location: `lib/config.sh`, `templates/`
- Contains: Template rendering, environment file generation, bind mount validation, service discovery
- Depends on: Detected system state, user inputs from wizard
- Used by: `install.sh` phase 4, daily operations via environment files

**Docker Compose Layer:**
- Purpose: Orchestrate and manage containerized services
- Location: `templates/docker-compose.yml`, `templates/env.*.template`
- Contains: Service definitions (23+ containers), volume management, networking, health checks
- Depends on: Configuration layer (environment files)
- Used by: Docker runtime, `agmind.sh` operations CLI

**Health & Monitoring Layer:**
- Purpose: Service health validation, operational status dashboards, alerts
- Location: `lib/health.sh`, `scripts/agmind.sh`, `templates/nginx.conf.template`
- Contains: Container status checks, health endpoints, GPU monitoring, model availability checks
- Depends on: Docker runtime, exposed service ports
- Used by: Installation phases 6-8, day-2 operations

**Operations Layer:**
- Purpose: Day-2 lifecycle and troubleshooting
- Location: `scripts/agmind.sh`, `scripts/backup.sh`, `scripts/restore.sh`, `scripts/update.sh`
- Contains: CLI commands (status, doctor, backup, restore), diagnostics
- Depends on: All lower layers
- Used by: End users for operational tasks

## Data Flow

**Installation Flow:**

1. **Phase 1: Diagnostics**
   - `detect.sh` probes: OS, GPU, RAM, disk, Docker, ports
   - Outputs: DETECTED_* environment variables exported globally
   - Validates: Minimum 4GB RAM, 20GB disk, ports 80/443/5001/3000 free

2. **Phase 2: Wizard**
   - Interactive prompts for: deployment profile, vector store, LLM provider, domain (if VPS)
   - Inputs stored in variables: DEPLOY_PROFILE, VECTOR_STORE, LLM_PROVIDER, etc.
   - Outputs: Global variables ready for configuration

3. **Phase 3: Docker Setup**
   - Calls `docker.sh` functions: install_docker, install_nvidia_runtime (if NVIDIA GPU detected)
   - Outputs: Docker daemon running with compose plugin

4. **Phase 4: Configuration**
   - `config.sh` reads: templates + global variables + user inputs
   - Generates: `.env` file, nginx.conf, monitoring configs, Authelia configs
   - Validates: All bind mount sources exist as files (not directories)
   - Creates: `/opt/agmind/docker/` directory structure with all config files

5. **Phase 5: Start Services**
   - Executes: `docker compose up -d --profile <provider-choice>`
   - Profiles activate based on: LLM_PROVIDER, VECTOR_STORE, MONITORING_MODE selections
   - Outputs: 23-34 containers running

6. **Phase 6: Health Checks**
   - `health.sh` waits for: all containers in service list to reach healthy state
   - Timeout: TIMEOUT_HEALTH (default 300s, configurable)
   - Retry: on failure, reads service list again and retries
   - Outputs: [OK]/[..]/[!!] status per container

7. **Phase 7: Model Download**
   - `models.sh` waits for Ollama/vLLM to be healthy
   - Pulls: LLM_MODEL, EMBEDDING_MODEL from provider
   - Timeout: TIMEOUT_MODELS (default 1200s, configurable per model)
   - Outputs: Model availability verified

8. **Phase 8: Backups**
   - Creates initial: PostgreSQL dump, Redis snapshot (if enabled)
   - Stores: `/opt/agmind/backups/` directory
   - Outputs: First backup timestamp logged

9. **Phase 9: Complete**
   - Displays: Endpoints, credentials file path, next-steps documentation
   - Outputs: SUCCESS or FAILURE status

**State Management:**
- Checkpoint file: `/opt/agmind/.install_phase` stores current phase number
- Installation log: `/opt/agmind/install.log` tees all output with timestamps
- Environment state: `/opt/agmind/docker/.env` persists configuration
- Service state: Docker Compose maintains container state via volumes

## Key Abstractions

**Validation Functions:**
- Purpose: Consistent input validation across wizard and CLI
- Examples: `validate_domain()`, `validate_port()`, `validate_email()`, `validate_model_name()`
- Pattern: Regex-based validation with error messages in Russian

**Library Modules:**
- `detect.sh`: System probing functions (detect_os, detect_gpu, detect_disk_space, etc.)
- `docker.sh`: OS-specific Docker installation (install_docker_debian, install_docker_rhel, etc.)
- `config.sh`: Template rendering and file management (safe_write_file, ensure_bind_mount_files)
- `health.sh`: Service status checks (check_container, wait_healthy, check_all)
- `models.sh`: Model pulling and validation (wait_for_ollama, pull_model, check_ollama_models)
- `security.sh`: Firewall and access control (configure_ufw, configure_fail2ban, encrypt_secrets)
- `authelia.sh`: Single sign-on configuration (generate_authelia_config)
- `backup.sh`: Backup scheduling (setup_backup_cron, backup_database)

**Service Lists:**
- Purpose: Dynamically determine which services to monitor based on configuration
- Location: `health.sh:get_service_list()` function
- Logic: Reads .env to determine active profiles (Weaviate vs Qdrant, local monitoring, ETL enhancement)
- Outputs: Array of container names for validation

**Profile System:**
- Purpose: Enable/disable service groups based on user choices
- Docker Compose profiles: `ollama`, `vllm`, `tei`, `monitoring`, `etl`
- Activation: `docker compose --profile <profile>` selects which containers start
- Rationale: Keep resource usage minimal, user enables only what's needed

## Entry Points

**Installation Entry Point:**
- Location: `install.sh`
- Triggers: User runs `sudo bash install.sh`
- Responsibilities: Execute 9-phase pipeline, handle errors, log all output, manage checkpoint file

**Operations Entry Point:**
- Location: `scripts/agmind.sh` (symlinked to `/usr/local/bin/agmind`)
- Triggers: User runs `agmind <command>`
- Responsibilities: Expose day-2 operations (status, doctor, backup, restore, update, help)
- Subcommands: status, doctor, backup, restore, update, logs, uninstall, rotate-secrets

**Health Endpoint Entry Point:**
- Location: `templates/nginx.conf.template` → nginx service
- Triggers: User runs `curl http://localhost/health`
- Responsibilities: Serve static JSON status of all services (cron-updated)
- Output: JSON with per-service status, updated every 60 seconds

## Error Handling

**Strategy:** Fail-fast with clear recovery steps.

**Patterns:**
- `set -euo pipefail` in all scripts: exit on error, undefined variables, pipe failures
- `trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR` at script start: log error context
- Validation before action: all inputs validated before use
- Checkpoint files: store progress to allow resume on failure
- Cleanup trap: remove lock file, display partial install summary on exit

**Recovery:**
- Restart same script: `sudo bash install.sh` resumes from last checkpoint
- Clean restart: `rm -rf /opt/agmind && sudo bash install.sh` fresh install
- Emergency exit: all traps trigger cleanup (lock removal, phase logging)

## Cross-Cutting Concerns

**Logging:**
- Method: `tee` to `/opt/agmind/install.log` with `script` timestamp prepend
- Colors in terminal, plain text in log file
- All phases log their start/end with timestamps

**Validation:**
- Early in wizard: all user inputs validated before storing in globals
- Pre-flight checks in phase 1: OS, Docker, ports, disk, RAM verified
- Bind mount validation: all config files checked to exist as files (not directories)

**Authentication:**
- Dify: via INIT_PASSWORD (set once, never changes)
- Authelia: via LDAP (optional, OTP setup)
- Portainer/Grafana: localhost-only by default, opt-in to open

**Security Defaults:**
- Profile-based: VPS profile → UFW + Fail2ban enabled by default
- LAN/VPN profiles → Fail2ban enabled, firewall optional
- All credentials: stored in credentials.txt (chmod 600), never logged
- Container capabilities: dropped except for required ones (CHOWN, SETUID, SETGID for db/api)

**Timeouts:**
- Configurable environment variables: TIMEOUT_START, TIMEOUT_HEALTH, TIMEOUT_MODELS
- Phase 5 (start): 300s default to wait for containers to become healthy
- Phase 6 (health): 300s default to validate all services
- Phase 7 (models): 1200s default per model to download
- Stuck operations show helpful message: "Model pull timeout. Load manually: docker compose exec ollama ollama pull..."

---

*Architecture analysis: 2026-03-18*
