# Architecture

**Analysis Date:** 2026-04-04

## Pattern Overview

**Overall:** Modular Bash-based installer with sequential phase execution and declarative Docker Compose orchestration.

**Key Characteristics:**
- Single-entry-point installer (`install.sh`) that sources reusable library modules
- Phase-based installation flow (9 sequential phases with timeout handling and recovery)
- Library separation: detection, configuration, Docker operations, health checking, security
- Declarative infrastructure via Docker Compose with profile-based service composition
- Interactive wizard for deployment configuration with non-interactive mode support
- Environment-driven behavior through template expansion and .env configuration

## Layers

**Entry Point (Installer):**
- Purpose: Main orchestrator that runs 9 installation phases in sequence
- Location: `install.sh`
- Contains: Phase runners, phase wrappers, error handling, cleanup logic
- Depends on: All lib/*.sh modules
- Used by: Direct execution via `sudo bash install.sh`

**Configuration & Detection Layer:**
- Purpose: Gather system facts and generate installation configuration
- Location: `lib/detect.sh`, `lib/wizard.sh`, `lib/config.sh`
- Contains: 
  - OS/GPU/resource detection (detect.sh)
  - Interactive user prompts (wizard.sh)
  - .env and service config generation (config.sh)
- Depends on: `lib/common.sh` (utilities, logging, validation)
- Used by: `install.sh` phases 1-4

**Docker & Infrastructure Layer:**
- Purpose: Docker installation, image management, and compose orchestration
- Location: `lib/docker.sh`, `lib/compose.sh`, `templates/docker-compose.yml`, `templates/versions.env`
- Contains:
  - Docker CE + Compose plugin installation per OS
  - Image registry validation and pre-pull checks
  - Docker Compose profile building and service lifecycle
  - GPU configuration (NVIDIA toolkit, runtime setup)
- Depends on: `lib/common.sh`, system utilities (curl, apt/dnf/yum)
- Used by: `install.sh` phases 2, 5-6

**Model & AI Provider Layer:**
- Purpose: LLM and embedding model management
- Location: `lib/models.sh`
- Contains:
  - Ollama model pulling with wait logic
  - vLLM/TEI GPU streaming and health monitoring
  - Model size hints and provider fallbacks
- Depends on: `lib/common.sh`, Docker CLI, health checks
- Used by: `install.sh` phase 8

**Security & Network Layer:**
- Purpose: Hardening, firewall, authentication, TLS, SSH tunnel
- Location: `lib/security.sh`, `lib/authelia.sh`, `lib/tunnel.sh`
- Contains:
  - UFW firewall rules (VPS/LAN-aware)
  - fail2ban SSH jail configuration
  - SSH hardening and key-based auth
  - Authelia SSO setup (YAML config generation)
  - Reverse SSH tunnel for VPS profile
- Depends on: `lib/common.sh`, system firewall/auth tools
- Used by: `install.sh` phase 4, optional post-config

**Health & Monitoring Layer:**
- Purpose: Service health verification and alerting
- Location: `lib/health.sh`
- Contains:
  - Dynamic service list from .env
  - HTTP healthcheck probing (curl/wget fallback)
  - Error classification and hint system (GPU, memory, compute)
  - Alert dispatch (webhook, Telegram)
- Depends on: `lib/common.sh`, Docker CLI
- Used by: `install.sh` phase 7, operational CLI

**Backup & Disaster Recovery Layer:**
- Purpose: Backup scheduling and restore logic
- Location: `lib/backup.sh`
- Contains:
  - Docker volume backup to tar.gz
  - Cron scheduling (local + remote SSH)
  - Restore automation from backup archive
- Depends on: `lib/common.sh`, tar, rsync
- Used by: `install.sh` phase 9, operational scripts

**Operations & Day-2 CLI Layer:**
- Purpose: Post-installation management and troubleshooting
- Location: `scripts/agmind.sh`, `scripts/update.sh`, `scripts/health-gen.sh`
- Contains:
  - Service status dashboard
  - Rolling updates with rollback support
  - Component version tracking (versions.env)
  - Manual health checks and log streaming
- Depends on: `lib/health.sh`, `lib/detect.sh`
- Used by: System operators via CLI

**Common Utilities Layer:**
- Purpose: Shared helpers, logging, validation, file operations
- Location: `lib/common.sh`
- Contains:
  - Logging functions with color/timestamp
  - Validators (domain, port, email, model name, URL)
  - Safe file operations (atomic sed, atomic writes)
  - Secret generation (random strings, tokens)
- Depends on: Bash 5.0+
- Used by: All modules (sourced first)

## Data Flow

**Installation Flow (Main):**

1. **Lock Acquisition** → Prevent concurrent installations
2. **Phase 1: Diagnostics** → run_diagnostics() + preflight_checks()
   - Detect OS, GPU, resources, Docker presence
   - Validate minimum requirements (4GB RAM, 20GB disk, Bash 5+)
3. **Phase 2: Wizard** → run_wizard()
   - Prompt user for: profile (LAN/VPS/Offline), domain, services, models
   - Export 50+ variables from wizard choices
4. **Phase 3: Docker Setup** → setup_docker()
   - Install Docker CE + Compose plugin (if missing)
   - Install NVIDIA toolkit (if GPU detected)
5. **Phase 4: Configuration** → generate_config()
   - Create `/opt/agmind/docker/` structure
   - Expand templates: docker-compose.yml, .env, nginx.conf, redis.conf
   - Store admin credentials in `.credentials.txt` (mode 600)
6. **Phase 5: Pull Images** → compose_pull()
   - Pre-validate images exist in registries (HTTP HEAD to API)
   - docker compose pull all images (or direct docker pull with retry)
7. **Phase 6: Start Containers** → compose_start()
   - docker compose up -d with COMPOSE_PROFILES
   - Post-launch: create plugin DB, sync Dify DB password
8. **Phase 7: Health Check** → wait_healthy()
   - Poll all services via HTTP/healthcheck until healthy (timeout: 5min)
   - Request LetsEncrypt cert if TLS_MODE=auto
9. **Phase 8: Model Download** → download_models()
   - For Ollama: docker exec ollama pull
   - For vLLM: stream logs, detect CUDA/memory errors
   - For TEI: similar streaming approach
10. **Phase 9: Post-Install** → Final setup
    - Create admin users (Dify, Open WebUI)
    - Install systemd service (agmind-stack.service)
    - Install CLI symlink (/usr/local/bin/agmind)
    - Setup backup crons
    - Apply Dify premium patches

**Config Generation Flow:**

1. User selections (wizard) → 50+ bash variables
2. Template expansion:
   - `env.lan.template` → `.env` (for LAN profile)
   - `env.vps.template` → `.env` (for VPS profile)
   - `docker-compose.yml` → Copy + profile filtering
   - `nginx.conf.template` → Expand domain/TLS settings
3. Secrets generation:
   - DB_PASSWORD, REDIS_PASSWORD, SECRET_KEY → 16-char random
   - API keys per service (stored in .env, mode 600)
4. Optional configs:
   - Authelia: `authelia/configuration.yml` + users DB
   - Monitoring: Copy Prometheus/Grafana/Loki configs
   - LiteLLM: Generate config from provider settings

**Service Composition Flow:**

1. **Profile Building** (build_compose_profiles):
   - Iterate 20+ optional services
   - Check wizard vars: VECTOR_STORE, LLM_PROVIDER, ENABLE_MONITORING, etc.
   - Build comma-separated COMPOSE_PROFILE_STRING
   - Example: "weaviate,ollama,monitoring,authelia,litellm"

2. **Docker Compose Up**:
   - Export COMPOSE_PROFILES, COMPOSE_PROJECT_NAME=agmind
   - docker compose -f /opt/agmind/docker/docker-compose.yml up -d
   - Compose respects `profiles:` directives → only enabled services start

3. **Service Dependencies**:
   - Core: db → redis → api/worker/web
   - Compute: api → sandbox → ssrf_proxy
   - LLM: (ollama OR vllm) ← api/web reference
   - Vector: (weaviate OR qdrant) ← api uses via env var
   - Monitoring: prometheus/grafana/loki/promtail (optional profile)

## State Management

**Installation State:**
- Phase checkpoint: `.install_phase` file (updated per phase)
- On re-run: resume from last failed phase or restart clean
- Environment persistence: `/opt/agmind/docker/.env` (created once, survives updates)
- Credentials: `/opt/agmind/credentials.txt` (human-readable, mode 600)

**Runtime State:**
- Service health: Tracked via docker inspect + HTTP probes
- Model status: Via ollama/vllm logs streaming
- GPU status: nvidia-smi parsed output
- Backup metadata: In `/opt/agmind/backups/manifest.json`

**Version Tracking:**
- `versions.env`: All component versions (DIFY_VERSION, OLLAMA_VERSION, etc.)
- `release-manifest.json`: Downloaded from GitHub releases
- Update system: Maps component name → version key + docker service names

## Key Abstractions

**Phase Runner:**
- Purpose: Encapsulate phase logic with timeout, logging, recovery
- Location: `install.sh` (run_phase, run_phase_with_timeout functions)
- Pattern: 
  ```bash
  run_phase_with_timeout 7 9 "Health Check" "wait_healthy" "$TIMEOUT_HEALTH"
  ```
- Used for: Any long-running operation (pulls, health checks, model downloads)

**Configuration Template:**
- Purpose: Declarative config with variable substitution
- Location: `templates/*.template` files
- Pattern: Variable references `${VAR_NAME:-default}` expanded during phase 4
- Examples: `env.lan.template`, `nginx.conf.template`, `authelia/configuration.yml.template`

**Compose Profile:**
- Purpose: Conditional service inclusion in docker-compose
- Location: `templates/docker-compose.yml` service definitions
- Pattern: `profiles: ["monitoring", "authelia"]` → only if ENABLE_MONITORING=true and ENABLE_AUTHELIA=true
- Used for: Optional services (Qdrant, Docling, Authelia, monitoring stack)

**Health Probe:**
- Purpose: Verify service readiness without manual inspection
- Location: `lib/health.sh` (healthcheck logic)
- Pattern: HTTP GET to /health endpoint, parse `docker inspect Status`, retry with backoff
- Fallback: curl vs wget, TTY vs non-TTY log streaming

**Validator:**
- Purpose: Input sanitization before template expansion
- Location: `lib/common.sh` (validate_domain, validate_port, validate_email, etc.)
- Pattern: Regex match + error message on failure
- Used for: Wizard input, model names, domains, ports

## Entry Points

**Installation Entry:**
- Location: `install.sh`
- Triggers: `sudo bash install.sh [--non-interactive] [--force-restart]`
- Responsibilities:
  - Parse command-line flags
  - Acquire exclusive lock
  - Source all lib modules
  - Run 9 phases in sequence
  - Cleanup and recovery on failure

**Operations Entry:**
- Location: `scripts/agmind.sh` (symlinked to `/usr/local/bin/agmind`)
- Triggers: `agmind <command> [options]`
- Commands: status, logs, restart, health, backup, restore, update, config
- Responsibilities:
  - Read `.env` configuration
  - Invoke docker compose / docker exec
  - Display formatted output

**Update Entry:**
- Location: `scripts/update.sh`
- Triggers: `sudo /opt/agmind/scripts/update.sh [--component <name>] [--version <tag>]`
- Responsibilities:
  - Fetch GitHub releases
  - Backup current state
  - Update `versions.env`
  - Rebuild docker-compose
  - Restart affected services with rollback support

## Error Handling

**Strategy:** Fail-fast with recovery guidance and checkpoint resumption.

**Patterns:**

1. **Phase Timeout Retry:**
   - First timeout → Wait and retry at 2x timeout
   - Second timeout (models only) → Log warning, continue (models download in background)
   - Other phases → Abort with error message

2. **Service Startup Failure:**
   - Check critical services (db, redis, api, worker, web, nginx)
   - Log last 5 docker logs
   - Provide hints: GPU compute capability, VRAM shortage, missing toolkit

3. **Model Download Fallback:**
   - vLLM fails → Suggest AWQ-quantized model or Ollama fallback
   - TEI fails → Show docker logs, suggest re-download
   - Ollama → Manual retry command provided in warning

4. **Configuration Error:**
   - Validate secrets before starting (no defaults like `password`)
   - Check disk space before creating volumes
   - Trap BASH_COMMAND for line-specific error reporting

5. **Image Pull Failure:**
   - Pre-validate images (HTTP HEAD to registry)
   - Retry with exponential backoff
   - Fallback to docker CLI if compose pull fails

## Cross-Cutting Concerns

**Logging:** 
- All modules use common.sh functions (log_info, log_warn, log_error, log_success)
- Format: `[HH:MM:SS] {symbol} {message}` (colors + timestamps in LOG_FILE if set)
- Severity: Info (→), Warn (⚠), Error (✗), Success (✓)

**Validation:** 
- Domain names, email addresses, ports, model names validated before use
- Regex-based patterns with user-friendly error messages
- Some complex validation deferred to runtime (GPU compute capability)

**Authentication:** 
- Secrets (passwords, API keys) generated randomly per installation
- Stored in `.env` (mode 600) and `.credentials.txt` (human-readable backup)
- Optional Authelia SSO for multi-user access
- SSH key-based auth hardening in `lib/security.sh`

**Profile-Based Behavior:**
- LAN: No TLS, local network access, reduced security
- VPS: TLS (Let's Encrypt), firewall (UFW), fail2ban SSH jail
- Offline: No external image registries, pre-cached models
- Behavior switches via DEPLOY_PROFILE variable throughout codebase

**GPU Support:**
- Auto-detect (nvidia-smi, rocm-smi, Metal)
- Manual override via FORCE_GPU_TYPE, FORCE_GPU_COMPUTE
- NVIDIA toolkit installation (lib/docker.sh)
- GPU memory limits in compose (mem_limit per service)
- Error hints for vLLM/TEI GPU failures

---

*Architecture analysis: 2026-04-04*
