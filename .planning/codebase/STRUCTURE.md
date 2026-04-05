# Codebase Structure

**Analysis Date:** 2026-04-04

## Directory Layout

```
difyowebinstaller/
├── install.sh                    # Main installer entry point (35KB, 35+ phases)
├── CLAUDE.md                     # Developer instructions (Russian)
├── SPEC.md                       # Detailed specification (37KB)
├── README.md                     # User-facing docs with profiles
├── COMPATIBILITY.md              # Supported OS/hardware versions
├── COMPONENTS.md                 # Service descriptions
├── LICENSE                       # AGPL-3.0
├── RELEASE                       # Version tag (single line)
├── .planning/                    # Planning documents (GSD workflow)
│   ├── PROJECT.md
│   ├── REQUIREMENTS.md
│   ├── STATE.md
│   ├── codebase/                 # Generated analysis (this location)
│   │   ├── ARCHITECTURE.md
│   │   └── STRUCTURE.md
│   ├── phases/                   # Phase execution plans (GSD)
│   ├── milestones/               # Version milestones
│   └── archive/                  # Historical planning
├── lib/                          # Reusable bash library modules
│   ├── common.sh                 # Shared utilities, logging, validation
│   ├── detect.sh                 # OS/GPU/resource detection, diagnostics
│   ├── wizard.sh                 # Interactive installation wizard
│   ├── docker.sh                 # Docker CE/Compose installation, NVIDIA toolkit
│   ├── config.sh                 # .env, nginx.conf, redis.conf generation
│   ├── compose.sh                # Docker Compose profiles, pull, up/down
│   ├── health.sh                 # Service healthchecks, alerts, reporting
│   ├── models.sh                 # LLM/embedding model pulling (Ollama, vLLM, TEI)
│   ├── backup.sh                 # Volume backup, restore, cron scheduling
│   ├── security.sh               # UFW, fail2ban, SSH hardening
│   ├── authelia.sh               # SSO configuration (Authelia)
│   ├── tunnel.sh                 # Reverse SSH tunnel (VPS profile)
│   └── openwebui.sh              # Open WebUI admin setup
├── scripts/                      # Day-2 operations scripts
│   ├── agmind.sh                 # CLI: status, logs, restart, health, backup
│   ├── update.sh                 # Rolling updates with rollback support
│   ├── health-gen.sh             # Generate health report HTML
│   ├── backup.sh                 # Standalone backup scheduler
│   ├── restore.sh                # Backup restore automation
│   ├── uninstall.sh              # Remove AGMind stack
│   ├── rotate_secrets.sh         # Rotate passwords and API keys
│   ├── dr-drill.sh               # Disaster recovery drill
│   ├── generate-manifest.sh      # Create release manifest
│   ├── patch_dify_features.sh    # Apply Dify premium patches
│   ├── check-upstream.sh         # CI: check for upstream updates
│   └── redis-lock-cleanup.sh     # Clean stale Redis locks
├── templates/                    # Configuration templates
│   ├── docker-compose.yml        # Main service composition (50+ services)
│   ├── versions.env              # Component version pinning
│   ├── release-manifest.json     # GitHub release metadata
│   ├── env.lan.template          # LAN profile .env template
│   ├── env.vps.template          # VPS profile .env template
│   ├── nginx.conf.template       # Reverse proxy + TLS configuration
│   ├── redis.conf.template       # Redis persistence settings
│   ├── agmind-stack.service.template      # Systemd service unit
│   ├── autossh.service.template  # SSH tunnel service (VPS)
│   ├── backup-cron.template      # Backup scheduler
│   ├── logrotate-agmind.conf     # Log rotation rules
│   ├── init-dify-plugin-db.sql   # Dify plugin database schema
│   ├── init-litellm-db.sql       # LiteLLM database schema
│   ├── searxng-settings.yml      # SearXNG search engine config
│   ├── authelia/
│   │   ├── configuration.yml.template      # SSO config
│   │   └── users_database.yml.template     # User database
│   └── sandboxconf.template      # Code execution sandbox settings
├── monitoring/                   # Observability stack configs
│   ├── prometheus.yml            # Metrics collection rules
│   ├── alert_rules.yml           # Alert conditions
│   ├── alertmanager.yml          # Alert routing and notifications
│   ├── loki-config.yml           # Log aggregation configuration
│   ├── promtail-config.yml       # Log collector agent config
│   ├── grafana/
│   │   ├── dashboards/           # Pre-built dashboards (JSON)
│   │   │   ├── overview.json     # System health overview
│   │   │   ├── containers.json   # Container metrics
│   │   │   ├── logs.json         # Log queries
│   │   │   └── alerts.json       # Alert status
│   │   └── provisioning/         # Auto-provisioning configs
│   │       ├── dashboards/dashboard.yml
│   │       ├── datasources/prometheus.yml
│   │       └── datasources/loki.yml
├── docs/                         # User documentation (markdown)
│   ├── 01-architecture.md        # System architecture overview
│   ├── 02-installation-profiles.md
│   ├── 03-cli-and-operations.md
│   ├── 04-security-and-compliance.md
│   └── 05-advanced-scenarios-and-faq.md
├── workflows/                    # Optional: CI/CD workflow scripts
│   └── (CI integration points)
└── branding/                     # Logo, icons, banners
    └── (Visual assets)
```

## Directory Purposes

**Root Level:**
- Purpose: Project metadata and installer entry
- Key files: `install.sh` (executable), `SPEC.md` (detailed design), `README.md` (user guide), `CLAUDE.md` (dev rules)

**`.planning/`:**
- Purpose: GSD workflow artifacts and codebase analysis
- Contains: Phase plans, milestones, requirements, current state tracking
- Generated by: `/gsd:execute-phase`, `/gsd:map-codebase` commands
- Key files: `PROJECT.md`, `STATE.md`, `codebase/ARCHITECTURE.md`, `codebase/STRUCTURE.md`

**`lib/`:**
- Purpose: Modular bash library sourced by `install.sh`
- Contains: ~13 modules, each ~100-500 lines, each with clear responsibility
- Key files:
  - `common.sh`: Utilities + logging (sourced first by all others)
  - `detect.sh`: System diagnostics
  - `wizard.sh`: Interactive prompts
  - `docker.sh`: Docker installation
  - `config.sh`: Config generation
  - `compose.sh`: Docker orchestration
  - `health.sh`: Service health verification
  - `models.sh`: Model pulling and streaming
- Usage: All sourced by `install.sh` via `source` command

**`scripts/`:**
- Purpose: Day-2 operations and maintenance tools
- Contains: Standalone scripts for post-install management
- Key files:
  - `agmind.sh`: CLI tool (symlinked to `/usr/local/bin/agmind`)
  - `update.sh`: Component updates with rollback
  - `health-gen.sh`, `backup.sh`, `restore.sh`, `uninstall.sh`
- Usage: Run as `sudo agmind <cmd>` or `scripts/<script>.sh`

**`templates/`:**
- Purpose: Configuration templates with variable substitution
- Contains: Docker Compose, env files, nginx, Authelia, monitoring configs
- Key files:
  - `docker-compose.yml`: Master service definition (50+ services, conditional profiles)
  - `versions.env`: All component versions pinned to specific tags
  - `env.lan.template`, `env.vps.template`: Profile-specific defaults
  - `nginx.conf.template`: Reverse proxy, TLS, domain routing
- Expansion: Done in `config.sh` phase 4 via `sed` substitution

**`monitoring/`:**
- Purpose: Observability stack (Prometheus, Grafana, Loki, Alertmanager)
- Contains: YAML configs + pre-built Grafana dashboards
- Key files:
  - `prometheus.yml`: Scrape targets (all docker containers)
  - `alert_rules.yml`: Conditions for critical alerts
  - `grafana/dashboards/*.json`: Pre-imported visualizations
- Usage: Copied to `/opt/agmind/docker/volumes/` if MONITORING_MODE=local

**`docs/`:**
- Purpose: User-facing documentation
- Contains: Architecture guide, installation profiles, operations, security, FAQ
- Key files: 01-05 markdown files covering all aspects
- Usage: Referenced in README.md, linked in installer prompts

**`workflows/`:**
- Purpose: CI/CD and automation points
- Contains: GitHub Actions, testing scripts, sync jobs
- Key files: `.github/workflows/*.yml` (test.yml, sync-release.yml, check-upstream.yml)

## Key File Locations

**Entry Points:**
- `install.sh` — Main installation script (sudo bash install.sh)
- `scripts/agmind.sh` — Day-2 CLI (symlinked to /usr/local/bin/agmind)
- `scripts/update.sh` — Component updates

**Configuration Sources:**
- `templates/docker-compose.yml` — Service definitions
- `templates/versions.env` — Component versions
- `templates/env.*.template` — Profile-specific env defaults
- `templates/nginx.conf.template` — Reverse proxy rules
- `lib/wizard.sh` — Interactive prompts (50+ variables)

**Core Logic:**
- `lib/detect.sh` — System detection and validation
- `lib/config.sh` — Config generation and expansion
- `lib/compose.sh` — Docker Compose orchestration
- `lib/health.sh` — Health checking and alerts
- `lib/models.sh` — Model pulling logic

**Monitoring & Operations:**
- `monitoring/prometheus.yml` — Metrics collection
- `monitoring/grafana/dashboards/` — Pre-built visualizations
- `scripts/backup.sh` — Backup scheduling
- `scripts/update.sh` — Rolling updates

## Naming Conventions

**Files:**
- Main installer: `install.sh` (no prefix, executable)
- Library modules: `lib/<name>.sh` (lowercase, verb-noun: config.sh, health.sh)
- Operation scripts: `scripts/<action>.sh` (lowercase, action-verb: backup.sh, update.sh)
- Templates: `templates/<domain>.<format>.template` (e.g., nginx.conf.template, env.lan.template)
- Configs: `.yml`, `.yaml`, `.conf`, `.json` (no .template suffix once expanded)

**Directories:**
- Library code: `lib/` (all bash modules)
- Scripts: `scripts/` (standalone day-2 scripts)
- Configuration templates: `templates/` (pre-install)
- Generated configs: `${INSTALL_DIR}/docker/` (/opt/agmind/docker at runtime)
- Monitoring: `monitoring/` (Prometheus/Grafana/Loki configs)
- Documentation: `docs/` (user guides, technical specs)
- Planning: `.planning/` (GSD workflow artifacts)

**Variables:**
- Environment: UPPERCASE_SNAKE_CASE (INSTALL_DIR, DEPLOY_PROFILE, LLM_PROVIDER)
- Function-local: lowercase_with_underscores (_log_ts, _create_directory_structure)
- Global state: UPPERCASE (DETECTED_OS, DETECTED_GPU, COMPOSE_PROFILE_STRING)
- Wizard exports: UPPERCASE (DOMAIN, CERTBOT_EMAIL, VECTOR_STORE)

## Where to Add New Code

**New Installation Feature (e.g., new security setting):**
- Wizard prompt: Add to `lib/wizard.sh` (question + export variable)
- Config expansion: Add template variable to `templates/env.lan.template`, `templates/env.vps.template`
- Phase execution: Add logic to `install.sh` phase function or new lib module
- Validation: Add validator to `lib/common.sh` if input is complex

Example: Adding SearXNG search engine
1. Prompt in `lib/wizard.sh`: `_ask_searxng "Enable SearXNG search engine?"`
2. Template: `templates/searxng-settings.yml` (already done, no new template needed)
3. Compose: Add `searxng` service with `profiles: ["searxng"]` in `docker-compose.yml`
4. Config: Expand template in `lib/config.sh` (already done)
5. Health: Add to service list in `lib/health.sh` (if ENABLE_SEARXNG=true)

**New Service/Container:**
- Add to `templates/docker-compose.yml`:
  ```yaml
  myservice:
    image: myimage:${VERSION}
    container_name: agmind-myservice
    profiles: ["optional"]  # if optional, else omit
    environment:
      <<: *shared-env
    healthcheck: ...
  ```
- Version tracking: Add to `templates/versions.env`:
  ```bash
  MYSERVICE_VERSION=1.2.3
  ```
- Update logic: Add mapping in `scripts/update.sh`:
  ```bash
  declare -A NAME_TO_VERSION_KEY=([myservice]=MYSERVICE_VERSION ...)
  ```
- Health: Register in `lib/health.sh` get_service_list() function

**New Operation/CLI Command:**
- Add handler in `scripts/agmind.sh`:
  ```bash
  cmd_mycommand() {
      # Implementation
  }
  ```
- Integrate into main switch: Add `"mycommand")` case

**New Validation Rule:**
- Add to `lib/common.sh`:
  ```bash
  validate_myinput() {
      local value="${1:-}"
      [[ value =~ pattern ]] || { log_error "message"; return 1; }
  }
  ```
- Use in wizard: `validate_myinput "$REPLY"` in `lib/wizard.sh`

## Special Directories

**`${INSTALL_DIR}/docker/` (at runtime: `/opt/agmind/docker/`):**
- Purpose: Runtime configuration and Docker Compose execution directory
- Generated: Yes (created during phase 4, expands from templates/)
- Committed: No (contains secrets, instance-specific config)
- Key files:
  - `.env` — All configuration variables (mode 600, contains secrets)
  - `docker-compose.yml` — Copied from templates/, profile filtering applied
  - `volumes/` — Data directories (db, redis, app storage, backups)
  - `nginx/` — Expanded nginx.conf + TLS certs
  - `redis/` — Expanded redis.conf
  - `authelia/` — Expanded Authelia configs (if enabled)
  - `monitoring/` — Copied Prometheus/Grafana configs (if enabled)

**`${INSTALL_DIR}/.credentials.txt`:**
- Purpose: Human-readable credentials backup
- Generated: Yes, one per installation
- Committed: No (contains secrets)
- Format: Plain text key=value, includes: DB_PASSWORD, REDIS_PASSWORD, DIFY_ADMIN_KEY, etc.

**`${INSTALL_DIR}/versions.env`:**
- Purpose: Version pinning for all components
- Generated: Yes, copied from templates/versions.env
- Committed: Yes (part of codebase)
- Updated by: `scripts/update.sh` when upgrading components

**`${INSTALL_DIR}/.install_phase`:**
- Purpose: Track current installation phase for recovery
- Generated: Yes (during install.sh execution)
- Committed: No (ephemeral)
- Removed: After successful completion

**`${INSTALL_DIR}/.rollback/`:**
- Purpose: Backup for rolling back failed updates
- Generated: Yes (during update.sh)
- Committed: No (instance-specific backups)
- Cleanup: Manual cleanup via agmind cleanup-rollback

---

*Structure analysis: 2026-04-04*
