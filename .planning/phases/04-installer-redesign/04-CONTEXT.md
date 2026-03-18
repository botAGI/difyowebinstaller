# Phase 4: Installer Redesign - Context

**Gathered:** 2026-03-18
**Status:** Ready for planning

<domain>
## Phase Boundary

9-phase installation with resume/checkpoint, structured logging, timeouts/retry. Professional installer that never leaves user blind. Named volumes with `agmind_` prefix for new installations. Migration path for v1 installations (Ollama profile breaking change). The installer structure (9 phases) is already established from Phase 1 — this phase adds reliability and observability around it.

</domain>

<decisions>
## Implementation Decisions

### Checkpoint/Resume
- Checkpoint file: `/opt/agmind/.install_phase` — contains only the phase number (1-9)
- On re-run with checkpoint found: interactive prompt "Найдена незавершённая установка (фаза 5/9). Продолжить? [yes/no/restart]"
  - `yes` — resume from saved phase
  - `no` — exit
  - `restart` — delete checkpoint, start from phase 1
- Non-interactive mode: auto-resume (continue from last checkpoint)
- `--force-restart` CLI flag: skip prompt, delete checkpoint, start from phase 1
- Wizard (phase 2) is skipped on resume — variables read from existing `.env`
- All other phases are idempotent and safe to re-run: diagnostics re-checks, docker skips if installed, config overwrites, start/health/models re-run cleanly
- Checkpoint written BEFORE each phase starts, so a crash mid-phase resumes at that phase (not the next)

### Logging
- Method: `exec > >(tee -a "$LOG_FILE") 2>&1` at start of main() — all stdout+stderr automatically goes to screen AND file
- Log file: `/opt/agmind/install.log`
- Timestamps: phase boundary markers via `run_phase()` wrapper — `[HH:MM:SS] === PHASE N/9: name ===` before and after each phase
- Existing echo statements untouched — tee captures everything automatically
- Log file permissions: `chmod 600` (same as credentials.txt)
- Credential scrubbing: NOT needed — Phase 2 already removed credentials from stdout, so nothing sensitive reaches the log. Log file chmod 600 is sufficient protection.
- No log rotation for install.log (one-time file, not recurring)

### Timeout/Retry
- Timeouts on 3 phases only: start (5/9), health (6/9), models (7/9)
- Default values with env override:
  - `TIMEOUT_START=${TIMEOUT_START:-300}` (5 min)
  - `TIMEOUT_HEALTH=${TIMEOUT_HEALTH:-300}` (5 min)
  - `TIMEOUT_MODELS=${TIMEOUT_MODELS:-1200}` (20 min)
- Retry strategy: 1 retry with doubled timeout (e.g., health: 300s → 600s, models: 1200s → 2400s)
- After retry failure: save checkpoint + detailed diagnostic message with:
  - What failed (e.g., "Загрузка модели qwen2.5:14b не завершена за 20 мин")
  - Diagnostic check (e.g., "Проверьте сеть: curl -s https://registry.ollama.ai")
  - How to resume (e.g., "Перезапустить: sudo bash install.sh")
  - How to increase timeout (e.g., "Увеличить таймаут: TIMEOUT_MODELS=3600 sudo bash install.sh")
- Other phases (diagnostics, wizard, docker, config, backups, complete): no timeout — `set -e` handles failures

### Named volumes
- `agmind_` prefix applied only to NEW installations
- Existing v1 installations keep their current volume names — no migration, no risk of data loss
- docker-compose.yml uses `agmind_` prefix in volume definitions for all named volumes
- Phase 1 detection (existing .env or INSTALL_DIR exists) determines new vs upgrade path

### v1 → v2 migration (Ollama profile)
- Auto-detect: if `.env` exists and `LLM_PROVIDER` is not set → append `LLM_PROVIDER=ollama` and `EMBED_PROVIDER=ollama`
- User sees no change — Ollama continues to work with the new compose profile system
- Migration happens in phase_config() before compose profile string is built

### Claude's Discretion
- Exact `run_phase()` wrapper implementation details
- Checkpoint file format (plain number vs with timestamp)
- Timeout implementation mechanism (bash `timeout` command vs background process with timer)
- Exact diagnostic messages per timeout scenario
- Whether to add `--resume-from N` flag for explicit phase override (nice-to-have)
- Phase progress display format (`[N/9]` — keep current or enhance)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope
- `.planning/REQUIREMENTS.md` §Installer — INST-01 through INST-04: requirement definitions
- `.planning/ROADMAP.md` §Phase 4 — Key deliverables and success criteria

### Prior decisions carrying forward
- `.planning/phases/02-security-hardening-v2/02-CONTEXT.md` §Credential suppression — Phase 2 deferred install.log scrubbing here; resolved as "not needed" since credentials already removed from stdout
- `.planning/phases/03-provider-architecture/03-CONTEXT.md` §Compose profiles: Ollama — breaking change: v1 installs need LLM_PROVIDER=ollama auto-injected

### Files to modify
- `install.sh` — main(): add tee logging, checkpoint read/write, run_phase() wrapper, resume prompt, --force-restart flag parsing
- `install.sh:phase_config()` — v1 migration: auto-inject LLM_PROVIDER/EMBED_PROVIDER if missing from .env
- `install.sh:phase_start()` — timeout wrapper
- `install.sh:phase_health()` / `lib/health.sh` — timeout wrapper
- `install.sh:phase_models()` / `lib/models.sh` — timeout wrapper with diagnostic messages
- `templates/docker-compose.yml` — agmind_ volume prefix for all named volumes

### Existing patterns
- `.planning/codebase/ARCHITECTURE.md` — Phase orchestration, data flow, error handling patterns
- `.planning/codebase/CONVENTIONS.md` — Naming, error handling, logging conventions

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `install.sh` main() (lines 1485-1493): sequential phase calls — wrap each in `run_phase()` for checkpoint + timing + logging
- `install.sh` phase functions: all follow `phase_NAME()` pattern — idempotent by design (config overwrites, docker skips if installed)
- `lib/health.sh:wait_healthy()`: already has 300s timeout and 5s poll loop — extend or wrap with outer timeout
- `set -euo pipefail` + ERR trap: existing error handling covers fast-fail phases

### Established Patterns
- `NON_INTERACTIVE` guard for all interactive prompts — resume prompt follows same pattern
- CLI argument parsing in main(): `--profile`, `--non-interactive`, etc. — add `--force-restart` here
- Color-coded output: RED=error, GREEN=success, YELLOW=warning, CYAN=info — timeout messages follow same pattern
- Lock file `/var/lock/agmind-install.lock` with `flock` — prevents parallel execution (already exists)

### Integration Points
- `main()` entry point (line 1485): wrap phase calls with `run_phase()` and checkpoint logic
- Existing reinstall check (lines 1464-1483): checkpoint detection goes alongside this
- `.env` file at `/opt/agmind/docker/.env`: source for wizard variables on resume, target for v1 migration writes
- `versions.env`: no changes needed (already pinned)

</code_context>

<specifics>
## Specific Ideas

- Resume prompt text: "Найдена незавершённая установка (фаза 5/9). Продолжить? [yes/no/restart]"
- Model timeout message includes specific model name and practical diagnostic commands
- `run_phase()` wrapper prints both start and end markers with HH:MM:SS timestamps for easy log grepping
- Checkpoint written BEFORE phase starts (not after) — crash mid-phase retries that phase

</specifics>

<deferred>
## Deferred Ideas

- `--resume-from N` explicit phase override flag — nice-to-have, not v2.0
- Log rotation / log shipping — not needed for one-time install log
- Auto-migration of Docker volumes (rename old → agmind_*) — too risky, deferred
- Non-interactive config.yaml input format (INSE-01) — v2.1
- Dry run mode --dry-run (INSE-03) — v2.1

</deferred>

---

*Phase: 04-installer-redesign*
*Context gathered: 2026-03-18*
