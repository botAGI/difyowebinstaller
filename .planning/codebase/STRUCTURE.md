# Codebase Structure

**Analysis Date:** 2026-03-18

## Directory Layout

```
difyowebinstaller/
├── install.sh                      # Main entry point (9-phase installer)
├── lib/                            # Library modules sourced by install.sh
│   ├── detect.sh                   # System diagnostics (OS, GPU, RAM, disk, ports)
│   ├── docker.sh                   # Docker installation and setup
│   ├── config.sh                   # Configuration generation from templates
│   ├── health.sh                   # Container health monitoring
│   ├── models.sh                   # LLM/embedding model pulling
│   ├── backup.sh                   # Backup and cron setup
│   ├── security.sh                 # UFW, fail2ban, SOPS
│   ├── authelia.sh                 # 2FA authentication setup
│   └── tunnel.sh                   # SSH tunnel and port forwarding (optional)
├── templates/                      # Configuration templates
│   ├── docker-compose.yml          # Multi-profile docker compose (25 services)
│   ├── env.vps.template            # VPS profile .env template
│   ├── env.lan.template            # LAN profile .env template
│   ├── env.vpn.template            # VPN profile .env template
│   ├── env.offline.template        # Offline profile .env template
│   ├── nginx.conf.template         # Nginx reverse proxy config
│   ├── versions.env                # Service version pins (Dify, Ollama, etc.)
│   ├── release-manifest.json       # Version manifest
│   ├── backup-cron.template        # Cron job template
│   ├── autossh.service.template    # Systemd service for SSH tunnel
│   └── authelia/                   # Authelia configuration templates
├── scripts/                        # Utility scripts (post-install)
│   ├── backup.sh                   # Manual backup trigger
│   ├── restore.sh                  # Restore from backup archive
│   ├── uninstall.sh                # Remove AGMind stack
│   ├── update.sh                   # Upgrade Dify version
│   ├── dr-drill.sh                 # Disaster recovery drill
│   ├── multi-instance.sh           # Deploy multiple instances
│   ├── rotate_secrets.sh           # Rotate passwords and keys
│   ├── test-upgrade-rollback.sh    # Test upgrade/rollback
│   ├── build-offline-bundle.sh     # Create air-gapped bundle
│   ├── generate-manifest.sh        # Generate version manifest
│   └── check-manifest-versions.py  # Verify manifest versions
├── tests/                          # Bash Automated Testing (BATS)
│   ├── test_config.bats            # Config generation tests
│   ├── test_lifecycle.bats         # Install/uninstall tests
│   └── test_manifest.bats          # Manifest validation tests
├── workflows/                      # Dify workflow definitions
│   └── rag-assistant.json          # RAG assistant workflow (imported to Dify)
├── branding/                       # Logo and theming assets
│   ├── logo.svg                    # AGMind logo
│   └── theme.json                  # UI theme customization
├── monitoring/                     # Monitoring stack config references
├── references/                     # Reference docs and examples
├── docs/                           # Docusaurus documentation site
│   ├── docusaurus.config.js
│   ├── package.json
│   └── sidebars.js
├── .github/                        # GitHub Actions CI/CD
├── .planning/                      # GSD planning context
│   ├── PROJECT.md
│   ├── config.json
│   └── codebase/                   # Generated codebase analysis docs
├── README.md                       # Installation guide and quick start
├── CHANGELOG.md                    # Version history
├── ROADMAP.md                      # Feature roadmap
├── COMPATIBILITY.md                # OS/hardware compatibility matrix
├── DR-POLICY.md                    # Disaster recovery policy
├── TASKS.md                        # Implementation tasks
├── CLAUDE_CODE_DRIVER.md           # Instructions for Claude Code
└── agmind-installer-full.txt       # Reference dump of full installer
```

## Directory Purposes

**lib/ — Library Modules:**
- Purpose: Reusable bash functions, sourced by install.sh
- Contains: 10 modules, each focused on one concern (detect, docker, config, health, etc.)
- Key files: `detect.sh` (700 lines), `config.sh` (1100 lines), `health.sh` (400 lines)

**templates/ — Configuration Templates:**
- Purpose: Profile-agnostic templates that are rendered with environment variables during phase_config
- Contains: docker-compose.yml, 4 .env templates (vps/lan/vpn/offline), nginx.conf, cron/systemd templates
- Usage: config.sh reads `templates/env.${DEPLOY_PROFILE}.template`, substitutes __PLACEHOLDERS__, writes to `/opt/agmind/.env`

**scripts/ — Post-Install Utilities:**
- Purpose: Operator-facing scripts for maintenance (backup, restore, update, uninstall)
- Contains: 12 executable scripts, copied to `/opt/agmind/scripts/` during phase_config
- Invoked: Manually by admin or via cron (backup.sh)

**tests/ — BATS Test Suite:**
- Purpose: Automated validation of config generation, lifecycle, manifest integrity
- Contains: 3 .bats files (bash test syntax)
- Run: `bats tests/` (requires bats tool)

**workflows/ — Dify Workflow Exports:**
- Purpose: Pre-built RAG workflows for users to import into Dify console
- Contains: `rag-assistant.json` (RAG chatbot workflow)
- Copied: To `/opt/agmind/workflows/` in phase_config

**branding/ — Customization Assets:**
- Purpose: Logo and theme customization
- Contains: logo.svg, theme.json (UI overrides)
- Copied: To `/opt/agmind/branding/` in phase_config

**.planning/ — GSD Context:**
- Purpose: Generated codebase analysis (this file and others)
- Contains: PROJECT.md (overall context), config.json (phase config), codebase/ (ARCHITECTURE.md, STRUCTURE.md, etc.)

## Key File Locations

**Entry Points:**
- `install.sh` — Primary installer, 1285 lines, sources all lib/*.sh modules
- `scripts/update.sh` — Upgrade script, pulls new Dify version and re-renders config
- `scripts/uninstall.sh` — Clean removal, kills containers and removes /opt/agmind

**Configuration:**
- `/opt/agmind/.env` — Runtime environment file (secrets, service URLs, profiles)
- `/opt/agmind/docker/docker-compose.yml` — Generated compose file with all services
- `/opt/agmind/docker/nginx/nginx.conf` — Reverse proxy configuration
- `/opt/agmind/docker/volumes/redis/redis.conf` — Redis persistence and replication settings
- `/opt/agmind/.admin_password` — Admin credentials (mode 600)

**Core Logic:**
- `lib/detect.sh` — System diagnostics, 500 lines
- `lib/config.sh` — Template rendering engine, 1100 lines
- `lib/health.sh` — Container healthcheck polling, 400 lines
- `lib/docker.sh` — Docker installation, OS-specific, 250 lines
- `install.sh:162-1283` — Phase functions (9 phases)

**Testing:**
- `tests/test_config.bats` — Config generation validation
- `tests/test_lifecycle.bats` — Install/uninstall lifecycle
- `tests/test_manifest.bats` — Version manifest consistency

## Naming Conventions

**Files:**
- `*.sh` — Bash executable scripts (lib, scripts, install.sh, tests)
- `*.template` — Template files with __PLACEHOLDER__ variables
- `*.bats` — BATS test files
- `*.json` — JSON config (docker-compose, workflows, manifest)
- `*.yml` — YAML config (docker-compose)
- `*-manifest.json` — Release version manifest
- `*-cron.template` — Cron job templates

**Directories:**
- `lib/` — Library modules (one function per file conceptually, but multi-function files)
- `templates/` — Template files with variables
- `scripts/` — Operator-facing scripts
- `tests/` — Test files
- `workflows/` — Workflow definitions
- `branding/` — Branding assets
- `.planning/` — GSD planning context

**Variables (bash):**
- Global constants: UPPERCASE (INSTALL_DIR, TEMPLATE_DIR, VERSION)
- Configuration: UPPERCASE (DEPLOY_PROFILE, LLM_MODEL, DOMAIN)
- Local: lowercase (phase, choice, status)
- Exported: export VARIABLE=value (propagated to child processes)
- Detected: DETECTED_* (DETECTED_OS, DETECTED_GPU, DETECTED_RAM)

**Functions:**
- Phase functions: phase_* (phase_diagnostics, phase_wizard, phase_docker)
- Setup functions: setup_* (setup_docker, setup_security)
- Check functions: check_*, detect_*, validate_*
- Utility: generate_*, enable_*, create_*, copy_*

## Where to Add New Code

**New Feature in Installer:**
- Primary code: `install.sh` (add new phase function) or new `lib/module.sh`
- Source in install.sh: `source "${INSTALLER_DIR}/lib/module.sh"`
- Add to main(): `phase_newfeature` in sequence
- Tests: Add test case to `tests/test_lifecycle.bats`

**New Configuration Option (e.g., new vector store):**
- Template: Add case to `templates/env.*.template` (all 4 profiles)
- Detection: Update `lib/health.sh:get_service_list()` to add service to health checks
- Compose: Add service definition to `templates/docker-compose.yml`
- Config generation: Update `lib/config.sh` to handle new variable substitutions

**New Post-Install Script:**
- Location: `scripts/newscript.sh` (executable, shebang, license header)
- Copy in phase_config: `cp "${INSTALLER_DIR}/scripts/newscript.sh" "${INSTALL_DIR}/scripts/"`
- Document in: `scripts/` section of README.md

**New Monitoring Alert:**
- Prometheus rule: `lib/config.sh` generates `${INSTALL_DIR}/docker/monitoring/alert_rules.yml`
- Alertmanager config: `lib/config.sh` generates `${INSTALL_DIR}/docker/monitoring/alertmanager.yml`
- Both only included if `MONITORING_MODE=local`

**New Test:**
- Location: `tests/test_*.bats` (BATS syntax)
- Run: `bats tests/test_*.bats`
- Document: Add test case name to TASKS.md

## Special Directories

**`/opt/agmind/` (Installation Target):**
- Purpose: Runtime directory created during installation
- Generated: .env, docker/, scripts/, branding/, workflows/
- Committed: No (generated at install time)
- Structure:
  ```
  /opt/agmind/
  ├── .env                          # Secrets and config
  ├── .admin_password               # Admin credentials (600 perm)
  ├── .agmind_installed             # Marker file
  ├── .agmind_gpu_profile           # Cached GPU detection
  ├── docker/
  │   ├── docker-compose.yml        # Generated from template
  │   ├── volumes/                  # Service data (db, redis, ollama)
  │   ├── nginx/nginx.conf
  │   ├── monitoring/               # Optional: prometheus, grafana config
  │   └── authelia/                 # Optional: 2FA config
  ├── scripts/                      # Copied from ./scripts/
  ├── workflows/                    # Copied from ./workflows/
  ├── branding/                     # Copied from ./branding/
  └── backups/                      # Created by backup.sh
  ```

**`/opt/agmind/docker/volumes/` (Persistent Data):**
- `ollama_data/` — Ollama models (10-50GB depending on model size)
- `postgres_data/` — PostgreSQL database (grows with documents)
- `redis_data/` — Redis persistence
- `openwebui_data/` — Open WebUI user data
- Not committed, persists across restarts

**.planning/codebase/ (Generated Analysis):**
- Purpose: GSD codebase documentation
- Contents: ARCHITECTURE.md, STRUCTURE.md, CONVENTIONS.md, TESTING.md, CONCERNS.md, STACK.md, INTEGRATIONS.md
- Committed: Yes (useful for planner and executor)

---

*Structure analysis: 2026-03-18*
