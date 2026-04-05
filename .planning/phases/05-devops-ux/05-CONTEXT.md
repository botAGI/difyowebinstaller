# Phase 5: DevOps & UX - Context

**Gathered:** 2026-03-18
**Status:** Ready for planning

<domain>
## Phase Boundary

CLI tools for day-2 operations: `agmind` unified command with subcommands (status, doctor, backup, restore, update, uninstall, rotate-secrets, logs, help), health endpoint `/health` serving JSON. User never needs to guess stack status. Named volumes with `agmind_` prefix already delivered in Phase 4 (DEVX-04 complete).

</domain>

<decisions>
## Implementation Decisions

### CLI Entry Point
- Single script `scripts/agmind.sh` with case-dispatch on subcommands
- Symlink `/usr/local/bin/agmind` → `/opt/agmind/scripts/agmind.sh` (created during `phase_complete()`)
- Full CLI-hub: status, doctor, backup, restore, update, uninstall, rotate-secrets, logs, help
- Existing scripts in `scripts/` become backends — agmind dispatches to them
- INSTALL_DIR defaults to `/opt/agmind`, overridable via `AGMIND_DIR` env var
- Privilege model: mixed — `agmind status` works without root (if user in docker group), other commands require sudo with clear error message "Запустите: sudo agmind <command>"

### agmind status
- Compact dashboard format by default: sections Services, GPU, Models, Endpoints, Backup, Credentials
- Reuses existing `health.sh` functions: `check_all()`, `check_gpu_status()`, `check_ollama_models()`, `check_vector_health()`, `check_disk_usage()`, `check_backup_status()`
- `--json` flag outputs machine-parseable JSON (same schema as /health endpoint)
- Endpoints section reads DOMAIN, DEPLOY_PROFILE, ADMIN_UI_OPEN from `.env` — shows actual URLs
- Portainer/Grafana endpoints shown only if ADMIN_UI_OPEN=true
- Backup section with color-coded age: green <24h, yellow <72h, red >72h (existing `check_backup_status()` logic)
- Credentials section shows path `/opt/agmind/credentials.txt` only — never content (Phase 2 decision)

### agmind doctor
- Checklist format with severity: [OK] / [WARN] / [FAIL] + actionable recommendation on issues
- Exit codes: 0 = all OK, 1 = warnings present, 2 = failures present (CI-friendly)
- `--json` flag for machine-parseable output (consistent with status)
- Checks (all 4 categories):
  1. **Docker + Compose**: installed, minimum versions (Docker 24+, Compose V2.20+)
  2. **DNS + Network**: resolves registry.ollama.ai, Docker Hub reachable
  3. **GPU driver + runtime**: nvidia-smi available, nvidia-container-toolkit installed, docker runtime nvidia configured
  4. **Ports + Disk + RAM**: ports 80/443 free (or in use by agmind), disk >20GB free, RAM >8GB
- Auto-detect mode: if /opt/agmind exists → post-install checks (restart loops, .env validity, log volume), otherwise pre-install only
- Reuses `detect.sh` functions: `detect_os()`, `detect_gpu()`, port detection, RAM detection

### Health Endpoint (/health)
- Implementation: cron (every minute) runs `scripts/health-gen.sh` → writes `/opt/agmind/docker/nginx/health.json`
- Nginx serves static file at `/health` with `default_type application/json` and `Cache-Control: no-cache`
- JSON schema: summary + per-service detail:
  ```json
  {
    "status": "healthy|degraded|unhealthy",
    "timestamp": "ISO8601",
    "services": {
      "total": N,
      "running": M,
      "details": {"db": "running", "redis": "running", ...}
    },
    "gpu": {"type": "nvidia", "name": "RTX 4090", "utilization": "32%"}
  }
  ```
- Accessible externally without Authelia (bypass rule like /api/ routes — Phase 2 precedent)
- Rate limited: 1r/s (consistent with Phase 2 nginx rate limiting)
- Data freshness: up to 1 minute stale (cron interval)
- `agmind status --json` outputs the same schema for consistency

### Claude's Discretion
- Exact cron/systemd timer implementation for health-gen.sh
- How `agmind logs` dispatches to `docker compose logs`
- Exact minimum Docker/Compose version numbers for doctor checks
- Internal structure of agmind.sh (function organization)
- Whether doctor GPU checks are skipped when LLM_PROVIDER=external

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope
- `.planning/REQUIREMENTS.md` §DevOps — DEVX-01, DEVX-02, DEVX-03, DEVX-04 requirement definitions
- `.planning/ROADMAP.md` §Phase 5 — Key deliverables and success criteria

### Existing code to reuse
- `lib/health.sh` — check_all(), check_gpu_status(), check_ollama_models(), check_vector_health(), check_disk_usage(), check_backup_status(), report_health(), get_service_list()
- `lib/detect.sh` — detect_os(), detect_gpu(), port/RAM/Docker detection functions
- `scripts/*.sh` — existing backend scripts that agmind CLI will dispatch to

### Prior decisions carrying forward
- `.planning/phases/02-security-hardening-v2/02-CONTEXT.md` §Credential suppression — credentials shown as path only, never content
- `.planning/phases/02-security-hardening-v2/02-CONTEXT.md` §Authelia bypass — /api,/v1,/files bypass Authelia (precedent for /health bypass)
- `.planning/phases/02-security-hardening-v2/02-CONTEXT.md` §Rate limiting — nginx rate limiting pattern for API routes
- `.planning/phases/03-provider-architecture/03-CONTEXT.md` §Provider display — llm_display/embed_display variables for status output
- `.planning/phases/04-installer-redesign/04-CONTEXT.md` §Named volumes — agmind_ prefix already implemented (DEVX-04 complete)

### Patterns and conventions
- `.planning/codebase/CONVENTIONS.md` — Naming, error handling, logging conventions
- `.planning/codebase/STRUCTURE.md` — Directory layout, where to add new code

### Files to modify/create
- `scripts/agmind.sh` — NEW: main CLI entry point with case-dispatch
- `scripts/health-gen.sh` — NEW: generates health.json for nginx to serve
- `templates/nginx.conf.template` — add /health location block + Authelia bypass
- `install.sh:phase_complete()` — add symlink creation: `/usr/local/bin/agmind`
- `templates/docker-compose.yml` — mount health.json volume for nginx (if needed)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/health.sh:report_health()` — Full health report orchestrator, calls all check_* functions. Direct reuse for `agmind status`
- `lib/health.sh:get_service_list()` — Dynamic service list from .env. Reuse for health-gen.sh
- `lib/health.sh:check_gpu_status()` — nvidia-smi/rocm-smi output. Reuse for status GPU section
- `lib/health.sh:check_backup_status()` — Last backup info with age coloring. Direct reuse
- `lib/detect.sh:detect_gpu()` — GPU type/name/VRAM detection. Reuse for doctor GPU checks
- `scripts/backup.sh`, `scripts/restore.sh`, `scripts/update.sh`, `scripts/uninstall.sh`, `scripts/rotate_secrets.sh` — backends for agmind subcommands

### Established Patterns
- `set -euo pipefail` + ERR trap: all scripts follow this
- Color-coded output: RED/GREEN/YELLOW/CYAN/BOLD/NC — status and doctor follow same pattern
- `NON_INTERACTIVE` guard: doctor may need similar for CI mode
- CLI argument parsing: `--json`, `--help` follow existing `--profile`, `--non-interactive` pattern in install.sh
- Lock file pattern: `flock` for exclusive operations (backup, restore already use this)

### Integration Points
- `install.sh:phase_complete()` — symlink creation goes here (end of successful install)
- `templates/nginx.conf.template` — add `/health` location and Authelia bypass
- `.env` file: source for DOMAIN, DEPLOY_PROFILE, ADMIN_UI_OPEN, LLM_PROVIDER, EMBED_PROVIDER
- `/opt/agmind/.agmind_gpu_profile` — cached GPU info used by check_gpu_status()

</code_context>

<specifics>
## Specific Ideas

- `agmind status` dashboard визуально похож на existing `report_health()` в health.sh, но дополнен Endpoints и Credentials секциями
- health-gen.sh переиспользует те же функции из health.sh, но выводит JSON вместо colored text
- Doctor рекомендации на русском языке, конкретные команды для исправления (apt install ..., docker system prune, ...)
- Symlink создаётся в phase_complete() чтобы быть доступным сразу после установки

</specifics>

<deferred>
## Deferred Ideas

- `agmind update` / `agmind rollback` — полная реализация в TLSU-02/TLSU-03 (v2.1), в v2.0 только dispatch на существующий scripts/update.sh
- `agmind uninstall --volumes` / `--containers-only` — расширенный uninstall в INSE-02 (v2.1)
- `agmind --dry-run` — INSE-03 (v2.1)
- Real-time health endpoint (websocket/SSE) — overkill для текущего скоупа
- `agmind shell <service>` — интерактивный shell в контейнер, удобно но не в v2.0

</deferred>

---

*Phase: 05-devops-ux*
*Context gathered: 2026-03-18*
