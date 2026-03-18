# Codebase Concerns

**Analysis Date:** 2026-03-18

---

## Tech Debt

**`pipeline` service referenced but absent from docker-compose.yml:**
- Issue: `lib/health.sh` line 11 includes `pipeline` in `get_service_list()`. `scripts/update.sh` line 393 includes `"pipeline"` in `update_order`. No `pipeline` service exists in `templates/docker-compose.yml`. This is a remnant of the v1 architecture where an Open WebUI pipeline proxy existed.
- Files: `lib/health.sh`, `scripts/update.sh`
- Impact: `check_all` always reports one "not found" service. Rolling update silently skips it. Misleading output in `agmind status`.
- Fix approach: Remove `pipeline` from both lists.

**`DB_USER` / `DB_USERNAME` naming inconsistency:**
- Issue: The `.env` template and docker-compose use `DB_USERNAME=postgres`. The backup script (`scripts/backup.sh` lines 81, 91, 93) uses the variable `${DB_USER:-postgres}`. `DB_USER` is never set anywhere in the system.
- Files: `scripts/backup.sh`, `templates/env.lan.template`
- Impact: Backup always falls back to `postgres` regardless of any custom username; fails silently if a real override was intended.
- Fix approach: Replace `DB_USER` with `DB_USERNAME` in `backup.sh`, sourcing it from `.env`.

**`config.sh` double-call to `ensure_bind_mount_files`:**
- Issue: `ensure_bind_mount_files` is called twice in `phase_config()` — once before `generate_config` and once after. This is compensatory coding for a historical Docker directory-artifact bug. The `preflight_bind_mount_check` (which aborts) plus a third "nuclear find+delete" loop also exist in `phase_start()`.
- Files: `install.sh` lines 776-968
- Impact: Multiple overlapping defense layers add complexity and install time. Underlying cause (Docker creating directories instead of files when bind-mount sources are missing) is fully addressed; redundant layers can be reduced.
- Fix approach: Keep only `ensure_bind_mount_files` + `preflight_bind_mount_check`. Remove duplicate ensure call and nuclear find loop.

**`harden_docker_compose` applies `no-new-privileges` by mutating the installed file:**
- Issue: `lib/security.sh:harden_docker_compose()` uses Python to post-process `docker-compose.yml` in-place after it is copied to `INSTALL_DIR`. This modifies the live compose file on every fresh install but is skipped on reinstall (idempotent check). The source template already ships with `security_opt` commented out.
- Files: `lib/security.sh` lines 160-202, `templates/docker-compose.yml`
- Impact: Fragile — depends on YAML structure being stable for regex. Template already has the capability; the function adds complexity without benefit.
- Fix approach: Add `security_opt: [no-new-privileges:true]` directly to all applicable services in `templates/docker-compose.yml`, remove `harden_docker_compose()`.

**`Authelia` `jwt_secret` reused as session secret:**
- Issue: In `templates/authelia/configuration.yml.template`, both `jwt_secret` and `session.secret` are set to `__AUTHELIA_JWT_SECRET__` (same placeholder, replaced by the same value in `lib/authelia.sh:51`). This means both secrets are identical.
- Files: `templates/authelia/configuration.yml.template` lines 12, 47
- Impact: Reduces cryptographic separation between JWT and session contexts. Low practical risk, but contradicts security principle of separate keys per purpose.
- Fix approach: Generate a separate `__AUTHELIA_SESSION_SECRET__` placeholder and set it to a distinct random value in `lib/authelia.sh`.

---

## Known Bugs

**BUG-017: IPv6 DNS breaks Ollama model pull (partially fixed, risk remains):**
- Symptoms: `ollama pull` inside the container fails with `dial tcp [IPv6]:443: connect: cannot assign requested address` on hosts without IPv6 routing.
- Files: `templates/docker-compose.yml` lines 254-258, `lib/models.sh` lines 39-43
- Trigger: Any host where IPv6 networking is absent (most LAN/VPS servers). Go runtime ignores kernel sysctl for its internal DNS resolver.
- Status: Partially fixed with `GODEBUG=netdns=cgo` + `sysctls: net.ipv6.conf.all.disable_ipv6=1` in docker-compose for the `ollama` service. Comment in `lib/models.sh` confirms the fix is in place. TASKS.md TASK-013 remains open but the fix described there (GODEBUG env var) has already been applied. Risk: If these lines are accidentally removed or the ollama service definition is restructured, the bug resurfaces.
- Workaround: Current compose is correct; adding `GODEBUG=netdns=cgo` is already present.

**`sync_db_password` rejects passwords with special characters:**
- Symptoms: `sync_db_password` in `install.sh` line 1119 rejects any `DB_PASSWORD` that does not match `^[a-zA-Z0-9]+$`. Generated passwords from `generate_random` in `lib/config.sh` only use `a-zA-Z0-9`, so this currently never triggers. However, any manual override or future change to `generate_random` that allows symbols will cause silent install failure.
- Files: `install.sh` lines 1114-1122
- Trigger: Manually setting `DB_PASSWORD` with special characters (underscore, dash, etc.) before install.
- Fix approach: Use parameterized `psql` with `--command` and `PGPASSWORD`, not string interpolation, to avoid this constraint.

**`create_openwebui_admin` falls through silently on password decode failure:**
- Symptoms: Line 1044 of `install.sh` attempts to base64-decode `INIT_PASSWORD`. If decode fails, it falls back to a freshly generated 16-char random password which is never recorded. The admin account is created with an unknown password.
- Files: `install.sh` lines 1043-1044
- Trigger: Reinstall where `.env` from a previous run has a differently-encoded `INIT_PASSWORD`.
- Fix approach: Fail explicitly if decode fails; always write resulting password to `credentials.txt`.

---

## Security Considerations

**`sandbox` container runs with `SYS_ADMIN` capability:**
- Risk: The Dify sandbox service requires `SYS_ADMIN` for its chroot/namespace operations (see compose comment lines 504-510). `SYS_ADMIN` is one of the most powerful Linux capabilities, enabling a wide range of privileged operations.
- Files: `templates/docker-compose.yml` lines 517-520
- Current mitigation: Sandbox is on an `ssrf-network` internal network only; no direct host port binding; SSRF proxy (Squid) blocks outbound private-range requests. Sandbox network is isolated (`internal: true` equivalent via ssrf-network design).
- Recommendations: Add `--security-opt seccomp=/path/to/sandbox-seccomp.json` when a minimal syscall profile is determined. Monitor for upstream Dify sandbox image updates that eliminate `SYS_ADMIN` need.

**`cAdvisor` runs `privileged: true` with full host filesystem mounts:**
- Risk: cAdvisor has `privileged: true` plus read-only mounts of `/`, `/sys`, `/proc`, `/var/lib/docker`, and `docker.sock`. Compromise of cAdvisor = full host read access.
- Files: `templates/docker-compose.yml` lines 818-836
- Current mitigation: Only active under the `monitoring` profile (opt-in); bound to internal `agmind-backend` network; no external port exposed.
- Recommendations: Consider replacing with a less-privileged alternative (e.g., using Docker API stats endpoint only) or restricting filesystem mounts to the minimum required.

**`Portainer` has read-write access to `docker.sock`:**
- Risk: RW access to `/var/run/docker.sock` grants full host control (container escape, arbitrary command execution on host).
- Files: `templates/docker-compose.yml` lines 902-903
- Current mitigation: Bound to `127.0.0.1` (or LAN IP if `ADMIN_UI_OPEN=true`); only available under `monitoring` profile; `read_only: true` filesystem; `no-new-privileges`. Comment in compose explicitly warns about this.
- Recommendations: Consider Portainer Agent mode with socket proxy, or replace with a read-only Docker stats dashboard. Document that `ADMIN_UI_OPEN=true` increases attack surface for this service specifically.

**Squid SSRF proxy uses hardcoded Google DNS (`8.8.8.8 8.8.4.4`):**
- Risk: Squid is configured with `dns_nameservers 8.8.8.8 8.8.4.4` in `create_squid_config()`. In air-gapped (offline) or VPN profiles, this DNS may be unreachable, causing Squid to fail silently or leak DNS queries outside the corporate network.
- Files: `install.sh` lines 926-927
- Current mitigation: Offline profile skips model downloads but still runs Squid.
- Recommendations: Make Squid DNS configurable via `SQUID_DNS` env var; default to host's DNS (`/etc/resolv.conf` nameserver).

**Alertmanager Telegram config uses shell variable interpolation into YAML heredoc:**
- Risk: In `lib/config.sh` lines 544-578, Telegram bot token and chat ID are interpolated directly into a YAML heredoc without sanitization. A token containing `${}` characters could produce malformed YAML.
- Files: `lib/config.sh` lines 540-578
- Current mitigation: Token format from Telegram API is `[0-9]+:[A-Za-z0-9_-]+`; unlikely to contain injection characters. `escape_sed` is used for webhook URL but not for Telegram token.
- Recommendations: Validate Telegram token format before interpolation; use `escape_sed` or validate with a regex like `^[0-9]+:[A-Za-z0-9_-]+$`.

---

## Performance Bottlenecks

**`wait_healthy` polls all services every 5s with individual `docker compose ps` calls:**
- Problem: `lib/health.sh:wait_healthy()` loops calling `docker compose ps --format {{.Status}} <service>` individually per service in a tight loop. With 23+ services and 5s sleep, this generates significant subprocess overhead during a long wait.
- Files: `lib/health.sh` lines 72-95
- Cause: One `docker compose ps` call per service per tick instead of a single batch call.
- Improvement path: Replace with a single `docker compose ps --format '{{.Service}}:{{.Status}}'` call per tick, then parse in Bash.

**Ollama model downloads block the install for up to 20 minutes:**
- Problem: `phase_models` calls `download_models` which blocks install completion while downloading large LLMs (up to 45GB for 72B quant). No progress display. The installer appears hung.
- Files: `lib/models.sh`, `install.sh` lines 1242-1246
- Cause: Synchronous model pull with no parallel download or background option.
- Improvement path: Use `docker exec agmind-ollama ollama pull ... &` with a progress tracking loop; or defer model download to a post-install background process.

---

## Fragile Areas

**`harden_docker_compose` Python regex modifies live YAML structurally:**
- Files: `lib/security.sh` lines 176-199
- Why fragile: Uses regex on raw YAML lines to inject `security_opt` after `container_name` lines. Any YAML reformatting, comment insertion, or multi-line `container_name` values will cause incorrect injection or double-injection (though the idempotency check mitigates the latter).
- Safe modification: The idempotency check (`grep -q 'no-new-privileges'`) prevents re-application. Any change to docker-compose.yml YAML structure must be tested against this function.
- Test coverage: No BATS test covers this function.

**`enable_gpu_compose` uses `sed` to replace multi-line YAML blocks:**
- Files: `lib/config.sh` lines 655-682
- Why fragile: Uses `sed` address ranges (`/driver: nvidia/,/capabilities: \[gpu\]/c\...`) to replace GPU blocks. This works only if the YAML block matches exactly the expected format. Any whitespace change, comment insertion, or line order change in the template breaks the AMD/Intel GPU transformation.
- Safe modification: GPU block format in `templates/docker-compose.yml` (lines 269-276, 299-305, 328-334, 488-494) must not be changed without testing all four GPU paths.
- Test coverage: No integration test for AMD/Intel GPU paths.

**Authelia `generate_argon2_hash` fallback produces wrong hash type:**
- Files: `lib/authelia.sh` lines 92-113
- Why fragile: If Docker is unavailable (e.g., first install before Docker is installed), the fallback uses Python scrypt, which produces a hash format incompatible with Authelia's argon2id requirement. The function prints a warning but returns successfully with a bad hash. Authelia will then reject all logins.
- Safe modification: Authelia setup requires Docker to be installed first (Phase 3: Docker install). As long as install phase order is maintained (Docker installed before Authelia config), the primary path always succeeds. Verify phase ordering if install.sh phase order changes.
- Test coverage: No test for hash generation failure path.

**`restore.sh` uses `COMPOSE_PROFILES` reconstruction without LLM/embed provider info:**
- Files: `scripts/restore.sh` lines 342-358
- Why fragile: When restarting after restore, the script reconstructs `COMPOSE_PROFILES` from `.env` for vector store, ETL, monitoring, and Authelia — but does NOT include `ollama`, `vllm`, or `tei` profiles. Services requiring these profiles won't start after restore.
- Safe modification: After restore, the operator must manually identify and start provider-specific profiles: `COMPOSE_PROFILES=...,ollama docker compose up -d`.
- Fix approach: Read `LLM_PROVIDER` and `EMBED_PROVIDER` from restored `.env` and include appropriate profiles.

**`config.sh:generate_redis_config` embeds a random suffix in `rename-command SHUTDOWN`:**
- Files: `lib/config.sh` lines 490-491
- Why fragile: `rename-command SHUTDOWN AGMIND_SHUTDOWN_$(head -c 8 /dev/urandom | ...)` runs at config generation time. The random suffix changes every time `generate_config` runs (e.g., reinstall). If the redis.conf is regenerated but the Redis data volume persists, the operator loses the ability to run `SHUTDOWN` via the known command name. The randomly renamed command is never recorded anywhere.
- Safe modification: The actual `SHUTDOWN` rename is a defense-in-depth measure; Redis restart via `docker compose restart redis` bypasses it. Still, recording the renamed command (or using a stable deterministic suffix) would be safer.

---

## Scaling Limits

**Single PostgreSQL instance, no connection pooling:**
- Current capacity: `max_connections=128`, `shared_buffers=256MB`, `effective_cache_size=512MB` — appropriate for single-tenant use.
- Limit: Under heavy concurrent Dify API + worker + plugin-daemon load, connection exhaustion is possible (3 services × multiple workers each).
- Scaling path: Add PgBouncer sidecar; or increase `max_connections` and `shared_buffers` (requires container memory limit adjustment).

**`MONITORING_MODE=local` adds 8 containers, no resource limits set:**
- Current capacity: Prometheus, Alertmanager, Grafana, Loki, Promtail, Node Exporter, cAdvisor, Portainer add ~2-3GB RAM overhead with no `mem_limit` defined.
- Limit: On 16GB servers, local monitoring can squeeze out RAM for LLM inference.
- Scaling path: Add `deploy.resources.limits.memory` to monitoring containers in docker-compose template.

---

## Dependencies at Risk

**`ubuntu/squid:6.6-24.04_edge` — uses unstable "edge" tag:**
- Risk: The `_edge` suffix in Ubuntu container images denotes the `edge` channel, which receives unvetted upstream updates. This violates the project's version-pinning policy (documented in `CLAUDE.md`).
- Files: `templates/versions.env` line 23, `templates/docker-compose.yml` line 546
- Impact: Container could receive breaking changes silently between deploys without version change in `versions.env`.
- Migration plan: Pin to a stable Ubuntu/Squid image, e.g., `ubuntu/squid:6.6-24.04_beta` or use the official `sameersbn/squid` image pinned to a specific digest.

**`Authelia 4.38` — major version only, no minor/patch pin:**
- Risk: `AUTHELIA_VERSION=4.38` in `templates/versions.env` is pinned at minor version. Docker will pull the latest `4.38.x` patch, which may include breaking configuration format changes.
- Files: `templates/versions.env` line 35
- Impact: Authelia configuration format has changed between minor versions; silent upgrade could break 2FA logins.
- Migration plan: Pin to a specific patch version, e.g., `4.38.10`.

---

## Missing Critical Features

**No credential rotation for PostgreSQL `DB_PASSWORD` in `rotate_secrets.sh`:**
- Problem: `scripts/rotate_secrets.sh` rotates `SECRET_KEY`, `REDIS_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `SANDBOX_API_KEY`, `PLUGIN_DAEMON_KEY`, `PLUGIN_INNER_API_KEY` — but NOT `DB_PASSWORD` or `WEAVIATE_API_KEY`/`QDRANT_API_KEY`.
- Files: `scripts/rotate_secrets.sh` lines 60-82
- Blocks: Periodic credential hygiene (monthly rotation via cron) is incomplete. DB password rotation requires both `.env` update AND `ALTER USER` inside PostgreSQL.

**No health.json bind-mount file listed in nginx volume for non-initial installs:**
- Problem: `health.json` is referenced as a bind-mount in `templates/docker-compose.yml` line 674 (`./nginx/health.json:/etc/nginx/health/health.json:ro`) and in `scripts/health-gen.sh`. It is created as a placeholder in `phase_config()`. However, `ensure_bind_mount_files()` in `lib/config.sh` (lines 34-57) does not include `nginx/health.json` in its protection list. If Docker creates a directory artifact at this path, nginx will fail to start with no clear error message.
- Files: `lib/config.sh` lines 34-57, `install.sh` line 855

**No automatic multi-instance volume isolation:**
- Problem: `scripts/multi-instance.sh` exists but is not integrated into the main installer. Multiple installs on the same host will conflict on port 80/443 and potentially on named volumes if the `agmind_` prefix is shared.
- Files: `scripts/multi-instance.sh`

---

## Test Coverage Gaps

**No integration tests for install phases 3-9:**
- What's not tested: `phase_config`, `phase_start`, `phase_health`, `phase_models`, `phase_backups`, `phase_complete`. All BATS tests validate script structure and static patterns, not actual execution with Docker.
- Files: `tests/test_config.bats`, `tests/test_compose_profiles.bats`
- Risk: A runtime error in `generate_config`, `enable_gpu_compose`, or `harden_docker_compose` would only be caught by a live deployment test.
- Priority: High — the installer is the primary product.

**No test for AMD/Intel GPU transformation paths in `enable_gpu_compose`:**
- What's not tested: The `sed`-based YAML transformation for `amd` and `intel` GPU types in `lib/config.sh` lines 653-683.
- Files: `lib/config.sh`
- Risk: Any template change to GPU block format silently breaks non-NVIDIA GPU support.
- Priority: Medium.

**No test for `validate_no_default_secrets` with partial matches:**
- What's not tested: The regex `^[^#].*=changeme$` will miss `MY_PASS=changeme_extended`. A user setting `DB_PASSWORD=changeme123` would pass validation.
- Files: `lib/config.sh` lines 144-180
- Risk: Weak passwords with known-default prefixes slip past the guard.
- Priority: Low — generated passwords from `generate_random` are never weak defaults.

**`trivy` security scan uses `@master` for the action:**
- What's not tested: `.github/workflows/test.yml` line 32 uses `aquasecurity/trivy-action@master` — an unpinned action reference. This is a supply-chain risk: a malicious or broken commit to the action repo could compromise CI.
- Files: `.github/workflows/test.yml`
- Risk: CI security posture.
- Priority: Medium — pin to a specific SHA or tag (e.g., `aquasecurity/trivy-action@v0.28.0`).

---

*Concerns audit: 2026-03-18*
