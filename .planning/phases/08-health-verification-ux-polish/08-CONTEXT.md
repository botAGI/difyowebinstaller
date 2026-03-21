# Phase 8: Health Verification & UX Polish - Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Post-install summary confirms real service reachability via HTTP checks, `agmind doctor` becomes comprehensive diagnostics tool, SSH lockout and Portainer tunnel pain points resolved, Apache 2.0 LICENSE added for public release.

</domain>

<decisions>
## Implementation Decisions

### Post-install HTTP verification (HLTH-01)
- Separate `verify_services()` function in `lib/health.sh` — called BEFORE `_show_final_summary()` in `phase_complete()`
- Checks ALL key services (skip those not in active profiles):
  - vLLM: `curl /v1/models`
  - Ollama: `curl /v1/models` (or `/api/tags`)
  - TEI: `curl /info`
  - Dify API: `curl /console/api/setup`
  - Open WebUI: `curl /`
  - Weaviate: `curl /v1/.well-known/ready`
  - Qdrant: `curl /readyz`
- Retry with backoff: first attempt 5s timeout, on FAIL retry after 10s. Max 2 attempts.
- On FAIL: show `URL + [FAIL] + troubleshoot hint` — e.g. "vLLM /v1/models  [FAIL] — Модель ещё грузится. Проверьте: agmind logs vllm"
- On OK: show `URL + [OK]` in green
- `verify_services()` returns structured results (associative array or stdout format) so both install.sh summary and `agmind doctor` can consume it
- `_show_final_summary()` references verify results — adds status column next to each service URL

### Doctor enhancement (HLTH-02)
- Extends existing `cmd_doctor()` in `scripts/agmind.sh`
- Reuses `verify_services()` from `lib/health.sh` for HTTP endpoint liveness checks
- New check sections to add:
  1. **Container health details**: unhealthy containers, exited containers, restart count >3 — per container
  2. **HTTP endpoint liveness**: calls `verify_services()`, formats as [OK]/[WARN]/[FAIL] in doctor style
  3. **Disk/RAM as percentage**: add usage % alongside existing GB values + `docker system df` summary
  4. **.env completeness**: mandatory vars (DOMAIN, LLM_PROVIDER, EMBED_PROVIDER, DIFY_SECRET_KEY, POSTGRES_PASSWORD, REDIS_PASSWORD, etc.) — [OK] if set, [FAIL] if empty/missing
- Existing checks (Docker/Compose, DNS, GPU, Resources, Ports) stay as-is
- Exit codes stay: 0=OK, 1=WARN, 2=FAIL (already implemented)

### SSH lockout prevention (UXPL-01)
- SSH hardening code does NOT exist yet — this is new functionality
- When installer would disable `PasswordAuthentication` in `sshd_config`:
  - Print WARNING banner before making the change
  - Show SSH public key setup instructions
  - Ask confirmation (unless `--non-interactive`)
- Exact implementation details at Claude's discretion (where in install flow, exact wording)

### Portainer tunnel guidance (UXPL-02)
- Add SSH tunnel command to BOTH `credentials.txt` AND `_show_final_summary()`
- Format: `ssh -L 9443:127.0.0.1:9443 user@<server-ip>`
- Show for ALL profiles where Portainer binds 127.0.0.1 (default behavior)
- If `ADMIN_UI_OPEN=true`: skip tunnel hint (Portainer already accessible)

### LICENSE (UXPL-03)
- Apache 2.0 license file in repo root
- Standard Apache 2.0 text with copyright "AGMind Contributors"

### Claude's Discretion
- Exact troubleshoot hints per service
- Order of new doctor check sections
- SSH hardening: where exactly in install flow, confirmation UX
- .env mandatory variable list (derive from existing code)
- `verify_services()` internal implementation (stdout format, return codes)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Post-install flow
- `install.sh` lines 134, 318-363 — `phase_complete()` chain and `_show_final_summary()`
- `install.sh` lines 249-271 — `_save_credentials()` where Portainer tunnel goes

### Doctor and health
- `scripts/agmind.sh` lines 133-212 — `cmd_doctor()` existing implementation with `_check()` helper
- `lib/health.sh` — `check_all()`, `get_service_list()`, all `check_*()` functions — verify_services() goes here

### Security
- `lib/security.sh` — `configure_ufw()`, `configure_fail2ban()`, `harden_docker_compose()` — SSH hardening pattern

### Requirements
- `.planning/REQUIREMENTS.md` — HLTH-01, HLTH-02, UXPL-01, UXPL-02, UXPL-03 definitions

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/health.sh:get_service_list()` — dynamic service list from .env profiles. Reuse in verify_services() to know which services to check
- `lib/health.sh:check_all()` — orchestrates all health checks. Model for verify_services()
- `scripts/agmind.sh:_check()` — doctor's severity formatter [OK]/[WARN]/[FAIL]. Reuse for new sections
- `scripts/agmind.sh:_read_env()` — reads .env values. Reuse for .env completeness check

### Established Patterns
- `_check SEVERITY "label" "message" "fix"` — doctor's consistent output format
- `--json` flag on doctor — new checks must produce JSON output too
- `source "${SCRIPTS_DIR}/../lib/health.sh"` — agmind.sh already sources health.sh
- Colors: RED/GREEN/YELLOW/CYAN/BOLD/NC defined at top of every script

### Integration Points
- `phase_complete()` calls: `_save_credentials` → verify_services() (NEW) → `_show_final_summary()`
- `agmind doctor` → `cmd_doctor()` → calls verify_services() for HTTP section
- `lib/security.sh:setup_security()` → SSH hardening would go here

</code_context>

<specifics>
## Specific Ideas

- verify_services() outputs в формате пригодном и для summary (colored) и для doctor (через _check)
- Doctor рекомендации на русском — конкретные команды: `agmind logs vllm`, `docker system prune`, и т.д.
- SSH warning должен быть ОЧЕНЬ заметным — оператор может потерять доступ
- Portainer tunnel hint только когда Portainer bind 127.0.0.1 (не когда ADMIN_UI_OPEN=true)

</specifics>

<deferred>
## Deferred Ideas

- WISH-007: Update preview с docker manifest digest comparison — v2.2 (базовый --check уже в Phase 7)
- WISH-008: Welcome page после установки — HTML с URL-ами и credentials — v2.2

</deferred>

---

*Phase: 08-health-verification-ux-polish*
*Context gathered: 2026-03-21*
