# Phase 7: Update System - Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Operators can check for available version updates and update any single component without touching the rest of the stack, with automatic rollback if the updated container fails its healthcheck. Existing `scripts/update.sh` (~500 lines) has rolling update infrastructure — this phase fixes the version source bug (BUG-V3-024) and adds per-component targeting.

</domain>

<decisions>
## Implementation Decisions

### Version source
- Fetch new versions via `curl -sL https://raw.githubusercontent.com/botAGI/difyowebinstaller/main/versions.env` into a temp file
- Compare temp (remote) versions against local `${INSTALL_DIR}/docker/.env` (current running versions)
- Offline/unreachable: graceful skip — show current versions only + suggest `--version` for manual update
- `--check` output: table only (COMPONENT | CURRENT | AVAILABLE | STATUS), no changelog/release notes
- This fixes BUG-V3-024: `load_new_versions()` currently reads local `versions.env` which is identical to installed

### Component targeting
- Short names for operator: `dify-api`, `vllm`, `tei`, `ollama`, `openwebui`, etc.
- Script maps short names to Docker service names (e.g., `dify-api` → `agmind-api`)
- Service groups for shared images: `--component dify-api` shows "Also updating: worker, sandbox, plugin-daemon. Continue?" with confirmation
- All services with versions in `versions.env` are updatable (~15 components)
- `agmind update` without flags: fetch remote versions → show diff table → ask "Update all? (yes/no)" (same as current behavior but with real remote diff)
- `agmind update --component <name> --version <tag>`: update specific component to specific version
- `agmind update --check`: show table only, no changes
- `agmind update --auto`: skip confirmation (for cron/CI)

### Rollback UX
- Automatic rollback on healthcheck failure — no operator confirmation needed
- Clear log output: `✗ dify-api: unhealthy → rolled back to 1.12.0`
- On failure during multi-component update: stop + report ("1/5 updated, dify-api rolled back, remaining skipped")
- Manual rollback supported: `agmind update --rollback <component>` restores previous version from `.rollback/` directory
- All rollback events logged to `update_history.log` with timestamp
- Telegram/webhook notifications on rollback (existing infrastructure)

### Claude's Discretion
- Exact name mapping table (short name → service name)
- Service group definitions (which services share images)
- Healthcheck timeout values
- Temp file cleanup strategy for downloaded versions.env
- `.rollback/` directory structure and retention policy

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Update system
- `scripts/update.sh` — Existing update script (~500 lines): rolling update, rollback, notifications, logging. Core to rewrite.
- `scripts/agmind.sh` — CLI entry point, delegates `update` command to `update.sh`
- `versions.env` — Source of truth for image versions (what gets published to GitHub)

### Docker infrastructure
- `templates/docker-compose.yml` — Service definitions, container names, healthchecks
- `lib/compose.sh` — `compose_up()`, `build_compose_profiles()`, profile management

### Requirements
- `.planning/REQUIREMENTS.md` — UPDT-01, UPDT-02, UPDT-03 definitions

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/update.sh`: `rollback_service()` — already implements .env restore + restart (needs minor fix for per-component)
- `scripts/update.sh`: `update_service()` — pull + restart + healthcheck wait loop (120s)
- `scripts/update.sh`: `send_notification()` — telegram/webhook already working
- `scripts/update.sh`: `create_update_backup()` — pre-update backup via backup.sh
- `scripts/update.sh`: `check_preflight()` — disk space, docker running, compose file checks
- `scripts/update.sh`: `log_update()` — logging to update_history.log

### Established Patterns
- `agmind.sh` delegates subcommands to scripts: `update) exec "${SCRIPTS_DIR}/update.sh" "$@"`
- Colors and log functions defined at top of each script
- Exclusive flock-based locking (`/var/lock/agmind-operation.lock`)
- `declare -gA` associative arrays for version tracking

### Integration Points
- `agmind update` → `scripts/update.sh` (already wired)
- `versions.env` in repo root = remote version source
- `${INSTALL_DIR}/docker/.env` = current running versions (COMPOSE variables)
- `${INSTALL_DIR}/.rollback/` = rollback state directory (exists)

</code_context>

<specifics>
## Specific Ideas

- BUG-V3-024 root cause: `load_new_versions()` reads `${INSTALL_DIR}/versions.env` (same as installed). Fix: fetch from GitHub raw URL instead.
- Current `perform_rolling_update()` has hardcoded order array — keep this for `--all` but make it configurable for `--component`
- Current `display_version_diff()` already renders the table format we want — just needs correct NEW source

</specifics>

<deferred>
## Deferred Ideas

- BUG-V3-023: Auto-configure Dify model providers via Console API — separate phase
- Scheduled auto-updates via cron — future enhancement
- Update notifications dashboard in Grafana — future enhancement

</deferred>

---

*Phase: 07-update-system*
*Context gathered: 2026-03-21*
