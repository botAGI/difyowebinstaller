# Phase 2: Security Hardening v2 - Context

**Gathered:** 2026-03-18
**Status:** Ready for planning

<domain>
## Phase Boundary

Close all known security gaps in the AGmind installer. Fix credential leakage, harden SSRF proxy, replace broken fail2ban with nginx rate limiting, fix backup/restore, extend Authelia coverage, and add wizard opt-in for admin UI access. The installer defaults to maximum security — user explicitly opts in to open anything.

</domain>

<decisions>
## Implementation Decisions

### Fail2ban → nginx rate limiting (SECV-05)
- Remove fail2ban nginx jail (`[agmind-nginx]`) and filter — broken due to Docker logpath mismatch
- Keep fail2ban SSH jail (`[sshd]`) only — still useful for VPS profile
- Replace with nginx `limit_req_zone` — already partially implemented, extend coverage
- Rate limiting zones:
  - `zone=api:10m rate=10r/s` — existing, applied to `/console/api/` and `/api/` (keep as-is)
  - `zone=login:10m rate=1r/10s` — fix from 3r/s to 1r/10s (1 attempt per 10 seconds), apply to `/console/api/login` with `burst=3 nodelay`
  - Apply `zone=api burst=20 nodelay` to `/v1/` and `/files/` routes (currently unprotected)
- Remove `lib/security.sh` fail2ban filter file creation and agmind-nginx jail config
- Keep `setup_fail2ban()` function but only for SSH jail

### Credential suppression (SECV-03)
- Remove all password/secret values from terminal stdout in `phase_complete()`
- Terminal shows: service URLs (Dify Console, Open WebUI, Grafana, Portainer) + path to credentials file
- Format: `Credentials saved to /opt/agmind/credentials.txt (chmod 600)` + `View: cat /opt/agmind/credentials.txt`
- INIT_PASSWORD, Open WebUI password, Grafana password — all only in `credentials.txt`, never stdout
- install.log scrubbing deferred to Phase 4 (Installer Redesign introduces proper logging)

### Backup/restore fixes (SECV-06)
- Restore tmpdir: use `/opt/agmind/.restore_tmp` (same filesystem, no cross-device copy)
- Add `set -o pipefail` to restore.sh for psql piping error detection
- Fix parser flag handling for CLI arguments in restore.sh
- Do NOT copy `.age` key files from source dir — use tmpdir copy pattern
- Clean up `.restore_tmp` after successful restore (trap on EXIT)
- Add BATS test (`tests/test_backup.bats`) with full cycle: backup → destroy data → restore → verify
- Scope: fix what's dangerous. Remote backup, S3 verification, full overhaul — deferred

### Wizard opt-in for admin UIs (SECV-01)
- Portainer and Grafana already default to `127.0.0.1` binding (env var defaults in docker-compose.yml)
- Add single wizard question: "Portainer и Grafana доступны только с localhost. Открыть доступ из сети? [no/yes] (default: no)"
- One question for both services — if yes, set `PORTAINER_BIND_ADDR=0.0.0.0` and `GRAFANA_BIND_ADDR=0.0.0.0`
- Profile behavior:
  - LAN/VPN/Offline profiles: ask the question
  - VPS profile: skip question, keep 127.0.0.1 (Portainer disabled by default on VPS)
- Non-interactive mode: default `no` (locked down). Override via `ADMIN_UI_BIND_ADDR=0.0.0.0` env var

### Authelia route policy (SECV-02 — updated)
- Original SECV-02 required 2FA on all Dify routes — updated based on discussion
- `/console/*` — 2FA (Authelia two_factor policy, human login)
- `/api/*`, `/v1/*`, `/files/*` — bypass Authelia (Dify handles its own API key auth)
- Rationale: forcing 2FA on API routes breaks programmatic integrations (SDK, external apps)
- Compensation: API routes protected by nginx rate limiting (10r/s) instead of Authelia
- Update SECV-02 text: "Authelia 2FA on /console/*. API routes use Dify's own API key auth + nginx rate limiting."

### Squid ACL hardening (SECV-04)
- Add explicit deny rules to Squid config in `create_squid_config()`:
  - `acl metadata dst 169.254.169.254` → `http_access deny metadata`
  - `acl link_local dst 169.254.0.0/16` → `http_access deny link_local`
  - `acl rfc1918_192 dst 192.168.0.0/16` → `http_access deny rfc1918_192`
- Deny rules placed BEFORE existing allow rules (order matters in Squid)
- Existing Docker bridge allows (10.0.0.0/8, 172.16.0.0/12 as source ACLs) stay for container-to-container communication
- Approach: explicit deny list (auditable), not allowlist-only

### Rate limiting on API routes (SECV-07)
- Extend nginx rate limiting to `/v1/chat/completions` and `/files/`
- Same rate as existing: `limit_req zone=api burst=20 nodelay` (10r/s)
- Login endpoint gets dedicated zone: `limit_req zone=login burst=3 nodelay` at `rate=1r/10s`
- WebSocket connections: leave as-is (no rate limiting needed for persistent connections)

### Claude's Discretion
- Exact Squid ACL syntax and ordering (as long as deny rules come before allows)
- Fail2ban SSH jail configuration details (maxretry, bantime values)
- BATS test mock data strategy for backup/restore cycle test
- nginx location block structure for applying rate limits to new routes
- Cleanup approach for removing fail2ban nginx filter files

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Security configuration
- `.planning/REQUIREMENTS.md` §Security — SECV-01 through SECV-07: requirement definitions
- `.planning/ROADMAP.md` §Phase 2 — Key deliverables and success criteria
- `.planning/phases/01-surgery-remove-dify-api-automation/01-CONTEXT.md` §Credentials summary — Phase 1 deferred credential stdout hardening to Phase 2

### Files to modify
- `lib/security.sh` — Fail2ban setup (remove nginx jail, keep SSH jail)
- `lib/authelia.sh` — Authelia config generation
- `templates/authelia/configuration.yml.template` — Authelia access control rules
- `templates/nginx.conf.template` — Rate limiting zones and location blocks
- `templates/docker-compose.yml` — Portainer/Grafana bind address vars (already correct, verify)
- `install.sh` — Wizard question for admin UI opt-in, credential display in phase_complete()
- `install.sh:create_squid_config()` — Squid ACL deny rules
- `scripts/backup.sh` — Backup fixes
- `scripts/restore.sh` — Restore tmpdir, pipefail, parser flags

### Testing
- `tests/test_backup.bats` — New: full backup/restore cycle test

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `templates/nginx.conf.template` lines 37-40: Rate limit zones already defined (`api`, `login`, `ws`). Extend, don't recreate.
- `templates/docker-compose.yml`: Portainer/Grafana already use `${BIND_ADDR:-127.0.0.1}` pattern. Wizard just needs to set the env var.
- `install.sh:create_squid_config()` lines 685-726: Squid config function exists. Add deny rules before existing allows.
- `scripts/restore.sh`: Already uses `mktemp -d` in places. Standardize to `/opt/agmind/.restore_tmp`.

### Established Patterns
- Wizard questions use `read -rp` with `NON_INTERACTIVE` guard (defaults applied when non-interactive)
- Color-coded output: RED=error, GREEN=success, YELLOW=warning, CYAN=info
- `set -euo pipefail` at top of all scripts (backup.sh and restore.sh already have this)
- BATS tests in `tests/` directory, run with `bats tests/`

### Integration Points
- `lib/security.sh:setup_fail2ban()` called from `phase_config()` → narrow scope: remove nginx jail config only
- `install.sh:phase_complete()` lines 1112-1200 → credential display to modify
- `install.sh:phase_wizard()` lines 195-607 → add admin UI opt-in question
- `lib/config.sh:generate_config()` → exports `PORTAINER_BIND_ADDR`, `GRAFANA_BIND_ADDR` to .env

</code_context>

<specifics>
## Specific Ideas

- Login rate limit: `rate=1r/10s burst=3` — 1 attempt per 10 seconds, 3 fast retries for typos, then throttled
- Credential display format: `Credentials saved to /opt/agmind/credentials.txt (chmod 600)` then `View: cat /opt/agmind/credentials.txt`
- Wizard question text (bilingual): "Portainer и Grafana доступны только с localhost (127.0.0.1). Открыть доступ из локальной сети? [no/yes] (default: no)"
- Restore tmpdir at `/opt/agmind/.restore_tmp` — same filesystem as data volumes, cleaned on EXIT trap
- Squid deny rules: metadata (169.254.169.254), link-local (169.254.0.0/16), remaining RFC1918 (192.168.0.0/16)

</specifics>

<deferred>
## Deferred Ideas

- install.log credential scrubbing — Phase 4 (Installer Redesign introduces proper logging)
- Remote backup verification and S3 cycle test — future
- Full backup/restore overhaul — future (Phase 2 fixes what's dangerous only)
- IP whitelist for API routes — could add later if needed
- Separate Portainer/Grafana wizard questions — keep simple with one question for now

</deferred>

---

*Phase: 02-security-hardening-v2*
*Context gathered: 2026-03-18*
