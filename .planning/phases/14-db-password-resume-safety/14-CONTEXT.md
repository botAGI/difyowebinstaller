# Phase 14: DB Password Resume Safety - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Prevent DB password mismatch on resume installation when PG volume already exists. Preserve original DB_PASSWORD from backup .env instead of regenerating.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Key constraints from conversation analysis:

**Core Logic (IREL-03):**
1. In `_generate_env_file()` (lib/config.sh:146): before generating new secrets, check if a Docker volume named `agmind-db-data` (or matching pattern) exists via `docker volume ls -q | grep agmind.*db`
2. If PG volume exists AND `.env.backup.*` exists in the same directory: extract `DB_PASSWORD` from the most recent backup file and reuse it instead of calling `generate_random 32`
3. If PG volume exists but no backup found: log WARNING and proceed with new password (sync_db_password will handle)
4. If no PG volume: normal flow — generate new password as before

**Backup Extraction:**
- Find latest backup: `ls -t "${env_file}.backup."* 2>/dev/null | head -1`
- Extract password: `grep '^DB_PASSWORD=' "$backup" | cut -d= -f2-`
- Also preserve: REDIS_PASSWORD, SECRET_KEY if found (all secrets that may be in existing volumes)

**sync_db_password() Hardening (lib/compose.sh:255):**
- Increase timeout from 60s (30×2s) to 90s (45×2s) — more margin for slow starts
- On ALTER USER failure: log error with actionable instructions instead of bare `return 1`

**Safety:**
- NEVER skip password generation entirely — if backup extraction fails, generate new
- Always create backup of current .env before overwriting (already exists at line 158-161)
- `set -euo pipefail` is active — handle all edge cases to avoid abort

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `_generate_secrets()` at lib/config.sh:116 — generates all secrets
- `_generate_env_file()` at lib/config.sh:146 — calls _generate_secrets then writes .env
- `.env.backup.YYYYMMDD_HHMMSS` pattern at lib/config.sh:160 — backup naming convention
- `sync_db_password()` at lib/compose.sh:255 — syncs .env password into running PG

### Established Patterns
- install.sh:430-431 — resume past wizard loads existing .env (but phase 4 may still re-run)
- Phase table: phase 4 = phase_config = generate_config = calls _generate_env_file
- `docker volume ls` available during install (Docker already running by phase 3)

### Integration Points
- lib/config.sh:116-140 — _generate_secrets()
- lib/config.sh:146-227 — _generate_env_file()
- lib/compose.sh:255-291 — sync_db_password()
- install.sh:417-432 — resume checkpoint logic

</code_context>

<specifics>
## Specific Ideas

From bug report: "При resume — detect существующий PG volume, не перегенерировать DB_PASSWORD. Или: fallback через docker exec с peer auth."

The docker exec peer auth fallback already works (sync_db_password uses unix socket). The main fix is preventing the mismatch in the first place.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
