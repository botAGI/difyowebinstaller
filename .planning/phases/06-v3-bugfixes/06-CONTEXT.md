# Phase 6: Runtime Stability - Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

The stack survives real-world conditions: plugin-daemon starts reliably after PostgreSQL is ready with dify_plugin DB, Redis stale locks never block a second startup, and GPU containers come back automatically after a host reboot. No new features — pure reliability fixes.

</domain>

<decisions>
## Implementation Decisions

### DB init strategy (STAB-01)
- **Dual approach**: PostgreSQL init script (`/docker-entrypoint-initdb.d/`) for new installations + enhanced healthcheck for existing volumes
- Init script: `.sql` file mounted into PostgreSQL container that does `CREATE DATABASE dify_plugin`
- Healthcheck: PostgreSQL healthcheck checks not just `pg_isready` but also that `dify_plugin` database exists. plugin-daemon `depends_on: db: condition: service_healthy` — won't start until DB is confirmed
- `create_plugin_db()` in `compose.sh` stays as fallback — not removed
- plugin-daemon restart policy stays `on-failure:5` — with healthcheck it won't start prematurely

### Redis lock cleanup (STAB-02)
- **Init-container** in docker-compose: runs BEFORE plugin-daemon, connects to Redis, cleans locks
- Uses the same `redis:7-alpine` image already in the stack (no new image pull)
- Access method: `SCAN 0 MATCH 'plugin_daemon:*lock*'` + `DEL` — SCAN is not in `@dangerous`, works with current ACL
- **Delete unconditionally** — init-container runs before daemon, so any existing lock is guaranteed stale. No TTL check needed
- Init-container depends_on redis:service_healthy, plugin-daemon depends_on init-container:service_completed_successfully

### GPU reboot survival (STAB-03)
- **systemd service** (`agmind-stack.service`) — follows existing pattern from `lib/tunnel.sh`
- `After=docker.service nvidia-persistenced.service` — waits for both Docker and NVIDIA driver
- Runs `docker compose up -d` for the **entire stack**, not just GPU containers — simpler, also fixes nginx upstream issues
- GPU container restart policy changed to `unless-stopped` (was `on-failure:5`) — double protection: Docker restarts on crash, systemd brings up after reboot
- Service installed during `install.sh` phase, enabled with `systemctl enable`

### Claude's Discretion
- Exact init SQL script contents (CREATE DATABASE IF NOT EXISTS pattern)
- Init-container entrypoint script details (loop/retry on SCAN)
- systemd service ExecStartPre checks (wait for nvidia-smi to succeed)
- Whether to add a small delay/retry in systemd before compose up

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose
- `templates/docker-compose.yml` — plugin_daemon service definition (lines ~608-689), GPU container definitions, depends_on structure, healthchecks
- `lib/compose.sh` — `create_plugin_db()` function (lines ~286-321), `compose_up()`, `_retry_stuck_containers()`

### Configuration
- `lib/config.sh` — `generate_redis_config()` (lines ~338-376) for Redis ACL rules, `enable_gpu_compose()` (lines ~455-494) for GPU uncommenting

### Health & Restart
- `lib/health.sh` — `wait_healthy()`, `check_all()`, critical service list
- `lib/tunnel.sh` — systemd service template pattern (lines ~67-92) to replicate for agmind-stack.service

### Installation
- `install.sh` — `_install_crons()` (lines ~281-294) for cron infrastructure pattern

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/tunnel.sh` systemd template: exact pattern for creating .service files with After/WantedBy
- `_install_crons()` in install.sh: pattern for installing system-level scheduled tasks
- `_retry_stuck_containers()` in compose.sh: existing retry logic for Created-state containers
- Redis config generation in config.sh: ACL user definition, can verify SCAN/DEL permissions

### Established Patterns
- Docker Compose healthchecks: `test: ["CMD-SHELL", ...]` with interval/retries/start_period
- GPU sections use `#__GPU__` markers, uncommented by `enable_gpu_compose()` via sed
- All service images pinned via `${*_VERSION}` from `versions.env`
- Compose profiles: `--profile ollama`, `--profile vllm`, `--profile tei`

### Integration Points
- `compose_up()` in compose.sh: where init-container will be added to the compose flow
- `phase_config()` in install.sh: where systemd service installation should happen
- PostgreSQL healthcheck in docker-compose.yml: needs enhancement to check dify_plugin DB
- GPU container definitions: restart policy change from `on-failure:5` to `unless-stopped`

</code_context>

<specifics>
## Specific Ideas

- Init-container uses same redis image to avoid pulling new images (offline profile compatibility)
- systemd service covers entire stack, not just GPU — simpler and handles nginx upstream issues too
- PostgreSQL dual approach (init script + healthcheck) handles both fresh installs and existing volumes

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 06-v3-bugfixes*
*Context gathered: 2026-03-21*
