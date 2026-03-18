# Codebase Structure

**Analysis Date:** 2026-03-18

## Directory Layout

```
project-root/
├── install.sh                  # Main 9-phase installation pipeline (75KB)
├── lib/                        # Reusable library modules (sourced by install.sh)
│   ├── detect.sh              # System diagnostics (OS, GPU, RAM, disk, ports, Docker)
│   ├── docker.sh              # OS-specific Docker installation (Debian/RHEL/macOS)
│   ├── config.sh              # Template rendering, config file generation, validation
│   ├── health.sh              # Service health checks, container status monitoring
│   ├── models.sh              # Model download/validation (Ollama, vLLM, TEI)
│   ├── security.sh            # Firewall, fail2ban, SOPS encryption setup
│   ├── authelia.sh            # Authelia SSO configuration and LDAP setup
│   ├── backup.sh              # Backup scheduling (PostgreSQL, Redis snapshots)
│   ├── dokploy.sh             # Dokploy deployment integration
│   └── tunnel.sh              # SSH tunnel setup for VPN/Offline profiles
├── scripts/                    # Post-install operational scripts
│   ├── agmind.sh              # Day-2 CLI hub (status, doctor, backup, restore, update)
│   ├── backup.sh              # Manual backup execution script
│   ├── restore.sh             # Restore from backup with validation
│   ├── update.sh              # Stack upgrade (pulls new image versions)
│   ├── uninstall.sh           # Complete removal of AGMind
│   ├── health-gen.sh          # Generate /health endpoint JSON (cron-called)
│   ├── build-offline-bundle.sh # Package all images/configs for air-gapped deployment
│   ├── generate-manifest.sh   # Create release-manifest.json for version pinning
│   ├── multi-instance.sh      # Deploy multiple isolated AGMind stacks
│   ├── dr-drill.sh            # Disaster recovery drill (backup → destroy → restore)
│   ├── rotate_secrets.sh      # Rotate database passwords, Redis secrets
│   ├── test-upgrade-rollback.sh # Test upgrade path with automatic rollback
│   ├── restore-runbook.sh     # Step-by-step manual restore instructions
│   └── check-manifest-versions.py # Python helper for manifest validation
├── templates/                 # Configuration file templates (rendered to /opt/agmind/docker/)
│   ├── docker-compose.yml    # Service definitions, volumes, networks, health checks (32KB)
│   ├── nginx.conf.template   # Reverse proxy, rate limiting, security headers (12KB)
│   ├── env.vps.template      # VPS profile: public domain, HTTPS via Certbot
│   ├── env.lan.template      # LAN profile: private network, self-signed TLS optional
│   ├── env.vpn.template      # VPN profile: tunnel-only access
│   ├── env.offline.template  # Offline profile: no internet connectivity
│   ├── versions.env          # Docker image versions and version constraints
│   ├── release-manifest.json # Pinned versions for specific release
│   ├── autossh.service.template # Systemd unit for persistent SSH tunnels
│   ├── backup-cron.template  # Cron job configuration for automated backups
│   └── authelia/             # Authelia 2FA SSO configuration
│       ├── configuration.yml # SSO/LDAP settings, session management
│       └── users_database.yml # User and password storage
├── monitoring/               # Observability stack configuration
│   ├── prometheus.yml        # Metrics scraping configuration
│   ├── alert_rules.yml       # Alert rule definitions (CPU, memory, connectivity)
│   ├── alertmanager.yml      # Alert routing, webhook/Telegram integration
│   ├── loki-config.yml       # Log aggregation (Docker logs from all containers)
│   ├── promtail-config.yml   # Log shipping configuration
│   └── grafana/              # Grafana dashboards and datasources
│       ├── dashboards/       # 4 dashboards: overview, containers, alerts, logs
│       └── provisioning/     # Datasource config (Prometheus, Loki)
├── branding/                 # Custom branding assets
│   └── theme.json           # AGMind white-label configuration
├── docs/                     # Docusaurus documentation site
│   ├── docs/
│   │   ├── installation/    # Deployment guides per profile
│   │   ├── migration/       # Upgrade and migration runbooks
│   │   ├── operations/      # Day-2 CLI and troubleshooting
│   │   └── security/        # Security configuration and hardening
│   ├── src/                 # Docusaurus source (MDX)
│   └── package.json         # Docs build configuration
├── tests/                    # BATS (Bash Automated Testing System) tests
│   ├── test_agmind_cli.bats # CLI commands: status, doctor, backup, restore
│   ├── test_compose_profiles.bats # Provider profile activation
│   ├── test_backup.bats     # Backup/restore cycle validation
│   ├── test_config.bats     # Configuration file generation
│   ├── test_lifecycle.bats  # Full install → health → uninstall
│   ├── test_manifest.bats   # Version pinning and manifest validation
│   └── test_wizard_provider.bats # Provider selection in wizard
├── workflows/               # Dify workflow templates (not managed by installer)
│   └── README.md           # Manual import instructions for users
├── references/             # Reference documents and examples
│   └── rag-assistant-mvp-workflow.json # Example Dify workflow
├── .github/                # GitHub Actions CI/CD
│   └── workflows/
│       ├── lint.yml        # shellcheck, yamllint, hadolint
│       ├── test.yml        # BATS tests, compose validation
│       └── lifecycle.yml   # Full install/uninstall cycle test
├── .planning/              # Planning documents (generated by GSD)
│   ├── PROJECT.md          # Project scope and constraints
│   ├── ROADMAP.md          # Phase-based roadmap (v2.0 MVP)
│   ├── STATE.md            # Current execution state (phases completed)
│   ├── config.json         # GSD orchestrator configuration
│   └── codebase/           # Architecture analysis documents
│       ├── ARCHITECTURE.md # Layer analysis and data flow
│       └── STRUCTURE.md    # Directory layout and file purposes
├── ROADMAP.md              # Public roadmap (2026)
├── TASKS.md                # Task backlog with priorities
├── README.md               # User-facing documentation (28KB)
├── CLAUDE.md               # Agent working instructions (Russian)
└── CHANGELOG.md            # Release history

```

## Directory Purposes

**Root Directory:**
- Purpose: Entry point and configuration center
- Key files: `install.sh` (main), `.gitignore`, `.planning/` (planning artifacts)
- Project metadata: `README.md`, `ROADMAP.md`, `TASKS.md`, `CHANGELOG.md`

**lib/ (Installation Libraries):**
- Purpose: Reusable Bash functions sourced by install.sh
- Responsibility: Divide concerns (detect, docker, config, health, models, security)
- Called by: `install.sh` during each phase and by `scripts/agmind.sh` during operations
- Isolation: Each module imports its own dependencies, minimal cross-module calls

**scripts/ (Operational CLI):**
- Purpose: Day-2 operations after initial installation
- Responsibility: Manual operations (backup, restore, update), diagnostics, emergency recovery
- Called by: End users via `/usr/local/bin/agmind` symlink
- Isolation: Most scripts source `health.sh` but operate independently

**templates/ (Configuration Templates):**
- Purpose: Generate runtime configurations from template files
- Variable injection: Replace `${VAR_NAME}` placeholders during `config.sh` phase
- Outputs: Written to `/opt/agmind/docker/` during installation
- Profiles: Separate env templates for VPS/LAN/VPN/Offline profiles

**monitoring/ (Observability Stack):**
- Purpose: Prometheus + Grafana + Loki stack for monitoring and alerting
- Files: YAML configs for scraping, dashboards, alert rules, log aggregation
- Activation: Via Docker Compose profile `--profile monitoring` (default for VPS)
- Output: Grafana UI at localhost:3001, Prometheus at localhost:9090

**branding/ (White-Label Assets):**
- Purpose: Customize Open WebUI appearance (logo, theme colors)
- File: `theme.json` defines colors, logos, site name
- Applied: By Open WebUI container on startup
- Scope: AGMind-specific branding, not user customizable during install

**docs/ (Documentation Site):**
- Purpose: User-facing guides for installation, operation, troubleshooting
- Framework: Docusaurus (React-based static site generator)
- Content: Markdown files organized by topic (install, migrate, operate, secure)
- Build: `npm run build` generates static HTML in `build/`

**tests/ (Automated Test Suite):**
- Purpose: Validate all critical paths (install, backup, restore, CLI)
- Framework: BATS (Bash Automated Testing System)
- Execution: GitHub Actions CI on every push
- Coverage: Happy path + error cases for each major feature

**workflows/ (Dify AI Workflows):**
- Purpose: Example and template Dify workflows (user-imported, not auto-installed)
- Scope: Not managed by installer after Phase 1 surgery
- Instructions: `README.md` documents how to manually import into Dify UI

**references/ (Reference Documents):**
- Purpose: Examples and reference material (not part of deployment)
- Content: Sample Dify workflows, API request examples, architecture diagrams
- Not deployed: Stays in git, not copied to production

**.planning/ (GSD Planning Artifacts):**
- Purpose: Structural documentation consumed by `/gsd:*` commands
- Files: `PROJECT.md` (scope), `ROADMAP.md` (phases), `STATE.md` (progress)
- Updated: After each phase completion
- Not deployed: Stays in git, guides future development

## Key File Locations

**Entry Points:**
- `install.sh`: Main installation script, run once per system
- `scripts/agmind.sh`: Symlinked to `/usr/local/bin/agmind` for CLI access

**Configuration:**
- `templates/docker-compose.yml`: Master service definition (23+ containers)
- `templates/versions.env`: Pinned Docker image versions
- `lib/config.sh`: Configuration generation logic
- `.env` (generated): Runtime environment variables at `/opt/agmind/docker/.env`

**Core Logic:**
- `lib/detect.sh`: System probing (320+ lines)
- `lib/docker.sh`: Docker installation per OS (200+ lines)
- `lib/config.sh`: Template rendering and validation (1000+ lines)
- `lib/health.sh`: Service health checking (400+ lines)
- `lib/models.sh`: Model downloading and validation (200+ lines)

**Testing:**
- `tests/test_*.bats`: BATS test suites (6 files)
- `.github/workflows/test.yml`: CI test execution
- `.github/workflows/lint.yml`: Static analysis (shellcheck, yamllint)

**Observability:**
- `monitoring/prometheus.yml`: Metrics configuration
- `monitoring/alert_rules.yml`: Alert definitions
- `monitoring/grafana/dashboards/`: 4 operational dashboards
- `scripts/health-gen.sh`: Generate `/health` JSON endpoint

## Naming Conventions

**Files:**
- Shell scripts: `*.sh` (executable, `chmod +x`)
- Templates: `*.template` (placeholder variables, `${VAR_NAME}`)
- Configuration: `*.yml` (YAML, docker-compose/monitoring)
- Tests: `test_*.bats` (BATS syntax)
- Documentation: `*.md` (Markdown)

**Directories:**
- Installation libraries: `lib/` (lowercase, short names)
- Runtime scripts: `scripts/` (lowercase, feature-based names)
- Config templates: `templates/` (file extensions preserved: `.yml`, `.env`, `.template`)
- Observability: `monitoring/` (prometheus, alertmanager, grafana subdirs)
- Testing: `tests/` (BATS files only)
- Planning: `.planning/` (dotdir, hidden by default)
- Generated: `/opt/agmind/docker/` (created during phase 4, not in git)

**Functions in Shell:**
- Validation: `validate_*` (validate_domain, validate_port, etc.)
- Detection: `detect_*` (detect_os, detect_gpu, etc.)
- Installation: `phase_*` (phase_diagnostics, phase_wizard, etc.)
- Checks: `check_*` (check_container, check_all, etc.)
- Configuration: `configure_*` (configure_ufw, configure_fail2ban, etc.)
- Private functions: `_*` (underscore prefix, not exported)

**Environment Variables:**
- Detected system state: `DETECTED_*` (DETECTED_OS, DETECTED_GPU, DETECTED_DOCKER_INSTALLED)
- User selections: Uppercase, no prefix (DEPLOY_PROFILE, DOMAIN, LLM_PROVIDER)
- Configuration: `*_URL`, `*_HOST`, `*_PORT` suffixes
- Container names: `agmind-*` prefix in docker-compose

## Where to Add New Code

**New Feature (e.g., backup encryption):**
- Primary code: Add function to `lib/backup.sh` or create `lib/encryption.sh`
- Tests: Add test to `tests/test_backup.bats`
- CLI hook: Add command to `scripts/agmind.sh` if user-facing
- Example: `encrypt_backup()` function in `lib/backup.sh`, `cmd_backup_encrypt()` in `scripts/agmind.sh`

**New Component/Module (e.g., Redis Cluster support):**
- Implementation: Create `lib/redis.sh` with functions (detect_redis, setup_redis_cluster)
- Integration: Source in `install.sh` after line 76: `source "${INSTALLER_DIR}/lib/redis.sh"`
- Tests: Create `tests/test_redis.bats` with BATS test cases
- Docker: Add service(s) to `templates/docker-compose.yml` with profile `redis_cluster`
- Config: Add env vars to `lib/config.sh` template rendering

**Utilities/Helpers (e.g., log formatting):**
- Shared helpers: `lib/common.sh` (if doesn't exist)
- Logging: Add `log_*` functions (log_info, log_warn, log_error)
- Called from: Any script via `source "${INSTALLER_DIR}/lib/common.sh"`
- No tests required: Utility functions are tested through integration tests

**New Health Check (e.g., SSL certificate expiry):**
- Implementation: Add function to `lib/health.sh` (check_ssl_expiry)
- Add to service list: Update `get_service_list()` or call from `check_all()`
- CLI integration: Display in `agmind status` output via `scripts/agmind.sh`
- Tests: Add to `tests/test_agmind_cli.bats` under status tests

**New Docker Service (e.g., Vector search alternative):**
- Service definition: Add to `templates/docker-compose.yml` with unique profile
- Environment vars: Add to appropriate `templates/env.*.template` (or all)
- Version pinning: Add to `templates/versions.env`
- Health check: Add function to `lib/health.sh`, include in service list
- CLI hint: Add provider-specific message to `phase_complete()` in `install.sh`

## Special Directories

**Generated Directories (Not Committed):**
- `/opt/agmind/` (entire production directory)
  - Location: Created during phase 4 configuration
  - Contains: docker/, backups/, credentials.txt, install.log, .install_phase
  - Ownership: root (created by install.sh with sudo)
  - Persistence: Survives `docker compose down` (data in named volumes)

**Volume Directories (Persistent Data):**
- `volumes/db/data/` (PostgreSQL data)
- `volumes/app/storage/` (Dify file storage, uploads)
- Named volumes: `agmind_ollama_data`, `agmind_openwebui_data`, etc.
  - Managed by: Docker daemon
  - Located: `/var/lib/docker/volumes/` (system-dependent)
  - Persist: Across container restarts and upgrades

**Temporary Directories:**
- `/tmp/agmind-*` (temporary files during install)
- `/tmp/agmind-install.lock` (macOS lock)
- Cleaned up: By cleanup trap on exit

## Git Ignore Patterns

```
# Environment and secrets (never committed)
.env*
credentials.txt
*.key
*.pem

# Generated/runtime (never committed)
/docker/          # symlink or copies created at install time
/opt/              # production directory (outside repo)

# Local dev and test artifacts
/.bats/
/build/
/node_modules/
*.log

# OS and IDE
.DS_Store
.vscode/
.idea/
*.swp
```

---

*Structure analysis: 2026-03-18*
