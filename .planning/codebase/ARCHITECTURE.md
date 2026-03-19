# Architecture

**Analysis Date:** 2026-03-20

## Pattern Overview

**Overall:** Layered Bash installer with modular library composition + Docker container orchestration

**Key Characteristics:**
- Single-entry-point design (`install.sh`) with 9-phase sequential execution
- Library-based modularity: 13 specialized Bash modules in `lib/` sourced by installer
- Profile-driven configuration: 4 deployment profiles (LAN/VPN/VPS/Offline) affect generated configs
- Checkpoint-resumable installation: saves phase state to `$INSTALL_DIR/.install_phase` for recovery
- Declarative Docker Compose with profile-based service filtering
- Atomic file operations to prevent race conditions and partial writes
- Environment-driven configuration inheritance from templates to runtime

## Layers

**Bootstrap Layer:**
- Purpose: Detect OS, check prerequisites, validate dependencies
- Location: `lib/detect.sh`, `lib/docker.sh`
- Contains: System detection (OS, GPU, RAM, disk), Docker/Compose version checks, preflight validations
- Depends on: `lib/common.sh` (logging, validation utilities)
- Used by: `install.sh` phase 1 (Diagnostics)

**Interaction Layer:**
- Purpose: Collect user choices via interactive wizard
- Location: `lib/wizard.sh`
- Contains: Profile selection, provider choices, TLS/security toggles, backup/monitoring options
- Depends on: `lib/common.sh`, `lib/detect.sh` (hardware recommendations)
- Used by: `install.sh` phase 2 (Wizard), exports 30+ global variables
- Output: Environment variable overrides for subsequent phases

**Configuration Layer:**
- Purpose: Generate runtime configs from templates and user choices
- Location: `lib/config.sh`
- Contains: `.env` generation, secret creation, sub-configs (nginx, redis, Authelia, monitoring)
- Depends on: `lib/common.sh`, `lib/wizard.sh` exports
- Produces: `$INSTALL_DIR/docker/.env` (sensitive), nginx.conf, redis.conf, sandbox config, Authelia YAML
- Used by: `install.sh` phase 4 (Configuration)

**Orchestration Layer:**
- Purpose: Manage Docker Compose lifecycle and post-launch setup
- Location: `lib/compose.sh`
- Contains: Profile building, `docker compose up/down`, bind mount safety, stale container cleanup
- Depends on: `lib/common.sh`
- Used by: `install.sh` phase 5 (Start)
- Key functions: `compose_up()`, `sync_db_password()`, `create_plugin_db()`

**Health & Monitoring Layer:**
- Purpose: Container health verification, service status reporting, alerts
- Location: `lib/health.sh`
- Contains: Service discovery from `.env`, container health checks, timeout-based wait loops
- Depends on: `lib/common.sh`
- Used by: `install.sh` phase 6 (Health), `agmind status` CLI
- Dynamic: Reads `.env` to determine which services should exist (Ollama, vLLM, TEI, vector stores, etc.)

**Model & Setup Layer:**
- Purpose: LLM/embedding model downloads, Xinference setup, credential storage
- Location: `lib/models.sh`, `lib/openwebui.sh`, `lib/backup.sh`
- Contains: Ollama pull operations, reranker registration, Open WebUI admin creation, backup cron setup
- Depends on: `lib/common.sh`, Docker Compose running
- Used by: `install.sh` phase 7 (Models), phase 8 (Backups), phase 9 (Complete)

**Security & Integration Layer:**
- Purpose: UFW/Fail2Ban, Authelia auth, reverse tunnel setup
- Location: `lib/security.sh`, `lib/authelia.sh`, `lib/tunnel.sh`
- Contains: Firewall rules, JWT/Basic auth configuration, remote backup credentials, SSH tunnel setup
- Depends on: `lib/common.sh`, `lib/config.sh` (conditional setup)
- Used by: Phase 4 (Configuration), called conditionally on `ENABLE_*` flags

**Day-2 Operations:**
- Purpose: Post-install management and monitoring
- Location: `scripts/agmind.sh`, `scripts/backup.sh`, `scripts/health-gen.sh`, `scripts/update.sh`
- Contains: Status dashboards, backup execution, health JSON generation for nginx, update checks
- Depends on: `lib/health.sh`, `lib/detect.sh` (sourced via agmind.sh)
- Entry point: `agmind` symlinked to `/usr/local/bin/agmind` by phase 9

## Data Flow

**Installation Flow:**

1. **User Invocation** → `sudo bash install.sh [--non-interactive] [--force-restart]`
2. **Phase 1: Diagnostics** → `run_diagnostics()` → detect OS/GPU, run `preflight_checks()`
3. **Phase 2: Wizard** → `run_wizard()` → collect 30+ user choices → export as env vars
4. **Phase 3: Docker** → `setup_docker()` → install Docker runtime if missing
5. **Phase 4: Configuration** → `generate_config(PROFILE, TEMPLATE_DIR)` →
   - Create directory structure at `$INSTALL_DIR/docker/volumes/*`
   - Copy `templates/docker-compose.yml` → `$INSTALL_DIR/docker/docker-compose.yml`
   - Render `templates/env.${PROFILE}.template` + substitutions → `.env` (secrets + user config)
   - Generate sub-configs: nginx.conf, redis.conf, sandbox config, Authelia YAML (if enabled)
   - Enable GPU support in compose file (if DETECTED_GPU != "none")
6. **Phase 5: Start** → `compose_up()` →
   - Build compose profiles from wizard choices
   - Cleanup stale containers
   - Ensure bind mount files exist (touch empty files if missing)
   - `docker compose up -d --pull missing` (or `--pull never` for offline)
   - Sync Dify database password with Redis
   - Create plugin database schema
   - Retry stuck containers with exponential backoff
7. **Phase 6: Health** → `wait_healthy(timeout)` →
   - Read `.env` to discover expected services
   - Poll `docker ps` for each service, check healthcheck status
   - Mark critical services as must-be-healthy
   - Return 0 if all healthy within timeout, else fail with hint
8. **Phase 7: Models** → `download_models()` →
   - For Ollama: wait for Ollama API, `docker exec ollama ollama pull $MODEL` × 2 (LLM + embedding)
   - For vLLM/TEI: container startup handles download
   - For ETL enhanced: register bce-reranker in Xinference
9. **Phase 8: Backups** → `setup_backups()`, `setup_tunnel()` →
   - Create cron job at `/etc/cron.d/agmind-health` (health-gen.sh every minute)
   - Setup remote backup cron if configured
   - Configure SSH reverse tunnel if `ENABLE_TUNNEL=true`
10. **Phase 9: Complete** → `_save_credentials()`, `_install_cli()`, `_show_final_summary()` →
    - Write credentials to `$INSTALL_DIR/credentials.txt` (chmod 600)
    - Symlink `agmind.sh` → `/usr/local/bin/agmind`
    - Display summary with URLs, credentials, container count

**Checkpoint Resume:**
- On failure or interruption, phase number written to `$INSTALL_DIR/.install_phase`
- On next run, user prompted: "Resume from phase N? (yes/no/restart)"
- If resume: source cached `.env` and restart from saved phase
- If restart: remove `.install_phase` and start from phase 1

**State Management:**
- `.env` file is source of truth for active config (read by health checks, CLI, templates)
- Docker volume mounts: all services read from `$INSTALL_DIR/docker/volumes/*`
- Secrets: stored in `.env` (chmod 600), passed to containers via environment
- Credentials file: `$INSTALL_DIR/credentials.txt` (chmod 600) for operator reference

## Key Abstractions

**Validate* Functions:**
- Purpose: Input validation with consistent error messages
- Examples: `validate_model_name()`, `validate_domain()`, `validate_email()`, `validate_port()`, `validate_cron()`, `validate_path()`
- Pattern: Each returns 0 on success, 1 on failure; logs error to stderr
- Location: `lib/common.sh`

**Log Functions:**
- Purpose: Standardized colored output with timestamps
- Functions: `log_info()`, `log_warn()`, `log_error()`, `log_success()`
- Pattern: Write to stderr to preserve stdout for piping; optional timestamp via `LOG_FILE` env var
- Used throughout: All lib modules use these for consistency

**_atomic_sed():**
- Purpose: Safe file modification with temp file + atomic move
- Pattern: Prevents TOCTOU races and partial writes
- Failures: Clean up temp file and return error
- Used by: `lib/config.sh` for `.env` modifications, nginx.conf rewrites

**safe_write_file():**
- Purpose: Remove directory artifacts before creating file (Docker bind mount issue)
- Pattern: On reinstall, Docker may leave directories in place of files; this removes them
- Safety: Whitelisted paths only (under `INSTALL_DIR`)
- Used by: Config generation functions

**_ask() / _ask_choice():**
- Purpose: Interactive prompt with NON_INTERACTIVE override
- Pattern: If `NON_INTERACTIVE=true`, use env var or default; else read stdin
- Enables: Unattended installation via env vars
- Used by: `lib/wizard.sh` all sections

**generate_random():**
- Purpose: Cryptographically secure random string for secrets
- Pattern: Head 256 bytes from `/dev/urandom`, filter alphanumeric, take N chars
- Failures: Exit with error if `/dev/urandom` produces empty (fatal)
- Used by: Secret generation in `_generate_secrets()`

**Service List Discovery:**
- Purpose: Dynamically determine which services should be healthy
- Pattern: Read `.env` for `VECTOR_STORE`, `LLM_PROVIDER`, `EMBED_PROVIDER`, `MONITORING_MODE`, `ETL_TYPE`
- Returns: Array of service names to check
- Used by: `lib/health.sh` `get_service_list()` → health checks, `agmind status`
- Rationale: Profiles affect which containers exist; health checks must adapt

## Entry Points

**Installation Entry Point:**
- Location: `install.sh`
- Triggers: User runs `sudo bash install.sh [--non-interactive] [--force-restart]`
- Responsibilities:
  1. Lock management (prevent concurrent runs)
  2. Banner display
  3. Phase sequencing (1-9)
  4. Error handling and phase recovery
  5. Logging setup
  6. Final summary

**Day-2 CLI Entry Point:**
- Location: `scripts/agmind.sh`, symlinked to `/usr/local/bin/agmind`
- Triggers: User runs `agmind <command> [options]`
- Responsibilities:
  1. Directory resolution (locate `$INSTALL_DIR`)
  2. Docker compose file discovery
  3. Command dispatch (status, health, logs, backup, restore, etc.)
  4. JSON and dashboard output modes
  5. Require root for mutating operations

**Cron Health Monitor:**
- Location: `scripts/health-gen.sh`
- Triggers: Cron job every 1 minute (set by phase 9)
- Responsibilities:
  1. Check all services
  2. Write JSON to `$INSTALL_DIR/docker/nginx/health.json` (read by nginx /health endpoint)
  3. Send alerts if configured

**Docker Entrypoints:**
- Location: `templates/docker-compose.yml`
- Core services (always started):
  - `db`: PostgreSQL, healthcheck via `/health` SQL query
  - `redis`: Redis, healthcheck via `redis-cli ping`
  - `api`: Dify API server, healthcheck via `/health` HTTP
  - `worker`: Dify Celery worker, healthcheck via `celery inspect ping`
  - `web`: Dify console web UI, no explicit healthcheck
  - `nginx`: Reverse proxy, reads `/health.json` from cron
  - `sandbox`: Python code sandbox, healthcheck via HTTP
  - `ssrf_proxy`: Squid SSRF protection, healthcheck via curl
  - `plugin_daemon`: Plugin system, healthcheck via HTTP
  - `open-webui`: Open WebUI, healthcheck via HTTP

## Error Handling

**Strategy:** Fail-fast with phase recovery; non-critical errors are warnings

**Patterns:**
- Phase failure: Exits with non-zero code, logs error, saves phase number
- Timeout errors: Logged as warnings (not critical for vLLM/TEI), user hints provided
- Validation errors: Pre-flight checks stop if critical; non-critical continue with confirmation
- GPU incompatibility: Warning only (vLLM/TEI are optional); Ollama becomes fallback
- Docker not found: Attempts install; if fails, user sees clear error
- Secrets generation: Fatal if `/dev/urandom` fails
- Bind mount races: Atomic operations + nuclear cleanup of artifact directories

**User-Facing Hints:**
- vLLM GPU compute capability mismatch: Suggests AWQ models or switch to Ollama
- TEI OOM: Suggests reducing model size or increasing VRAM
- Missing models (offline): Shows manual load command
- Phase failure: Logs phase number and suggests re-running install.sh

## Cross-Cutting Concerns

**Logging:**
- Tool: POSIX shell `echo` with color codes
- Pattern: All log_* functions write to stderr; timestamps optional via `LOG_FILE`
- Captured: `install.sh` redirects all output to `$INSTALL_DIR/install.log` (append mode)

**Validation:**
- Tool: Regex patterns in validate_* functions
- Pattern: Model names, domains, emails, URLs, ports, crons, paths all validated before use
- Whitelisting: Paths restricted to `/tmp`, `/home`, `/root`, `/etc/ssl`, `/opt`, `/var/backups`

**Authentication:**
- Modes: Custom (Open WebUI admin), TLS (Certbot), Authelia (OAuth2/LDAP proxy)
- Secrets: Generated with `generate_random()`, stored in `.env`, passed to containers
- Rotation: `scripts/rotate_secrets.sh` regenerates all secrets in-place

**GPU Support:**
- Detection: NVIDIA (nvidia-smi), AMD (rocminfo), Intel (lspci + /dev/dri), Apple (hardcoded)
- Compose enablement: `enable_gpu_compose()` rewrites docker-compose.yml to add GPU device mappings
- Providers: Ollama, vLLM (CUDA-specific), TEI (CUDA-specific)
- Fallback: If vLLM/TEI fails, recommend AWQ models or switch to Ollama

---

*Architecture analysis: 2026-03-20*
