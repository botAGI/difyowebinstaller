# Codebase Concerns

**Analysis Date:** 2026-03-18

## Tech Debt

**BUG-017: Ollama IPv6 DNS resolution failure**
- Issue: Go runtime in Ollama container has its own DNS resolver that ignores kernel `sysctl net.ipv6.conf.all.disable_ipv6=1`. Current "fix" (sysctls in docker-compose) does not work. `ollama pull` fails on hosts without IPv6 routes when registry returns AAAA records.
- Files: `lib/models.sh:39`, `templates/docker-compose.yml:254-260`, `TASKS.md:15`
- Impact: Blocks model downloads on most home/office networks without IPv6. Installation fails on step 7/11.
- Fix approach:
  1. Add `GODEBUG: "netdns=cgo"` to ollama environment in docker-compose (forces Go to use system DNS resolver via cgo)
  2. Remove resolv.conf hacks from `lib/models.sh` if present
  3. Test on IPv6-disabled host: `docker exec agmind-ollama ollama pull qwen2.5:7b`

**BUG-015: docker compose up -d dependency chain incomplete**
- Issue: `docker compose up -d` returns before full dependency chain is ready. Services with health checks may still be starting, causing race conditions in immediate health checks.
- Files: `install.sh:788` (comment indicates awareness)
- Impact: Transient "service not ready" errors during first health check loops in phase 6.
- Fix approach: After `docker compose up`, add explicit wait for critical services (db/redis/weaviate) using `docker compose exec` polling with timeout.

**Directory artifact after reinstall**
- Issue: Docker creates directories when bind-mount source files don't exist. On reinstall, these stale directories block file creation. Workaround exists but is manual cleanup step.
- Files: `lib/config.sh:17-58` (safe_write_file, ensure_bind_mount_files), `lib/config.sh:63-132` (preflight_bind_mount_check)
- Impact: Reinstalls require manual `rm -rf /opt/agmind/docker/*` to clear artifact directories. UX friction.
- Fix approach: Make `ensure_bind_mount_files()` more aggressive: run after template generation AND before first `docker compose up`, remove all `.yml/.conf` directories unconditionally.

## Known Bugs (Open Tracking Issues)

**TASK-012: import.py missing required model credentials**
- Symptoms: Model registration fails with 400 Bad Request during setup phase 8. Embedding add_model needs `context_size`, reranker needs `invoke_timeout`, LLM needs `context_size`.
- Files: Python import.py script (location TBD in Phase 6-7 implementation)
- Trigger: Automatically on install, step 18-19 model registration
- Current state: Models fail silently, workflow import succeeds but KB creation fails later
- Workaround: Manual credentials patch after install

**TASK-013: import.py does not save DIFY_API_KEY**
- Symptoms: After install, `grep DIFY_API_KEY /opt/agmind/docker/.env` returns empty. Pipeline cannot connect to Dify. RAG workflow not visible in Open WebUI model list.
- Files: Python import.py script, `install.sh:XXX` (phase_complete function)
- Trigger: During setup phase 8 after workflow import
- Current state: API key generated but not persisted to `.env`. File created but empty.
- Workaround: Manually edit `.env` and restart pipeline + openwebui

**TASK-014: Post-install summary shows no credentials**
- Symptoms: `phase_complete()` shows URLs but hides passwords. Admin password file is root-only even though user is root during install.
- Files: `install.sh:XXX` (phase_complete function - line TBD)
- Trigger: At end of installation
- Current state: Credentials visible in console during install but not saved to credential file
- Workaround: Grep `.env` and `.admin_password` file manually

## Security Considerations

**Dual source of truth for versions (RESOLVED: BUG-004)**
- Risk: Version variables in both `versions.env` AND template `.env` files → guaranteed drift → non-deterministic installs
- Files: `templates/versions.env`, `templates/*.env` (should be empty)
- Current mitigation: BUG-004 complete — `versions.env` is now single source, templates have no `*_VERSION` vars
- Recommendations: Verify in CI that templates contain zero `*_VERSION` assignments

**Environment variable exposure in docker-compose**
- Risk: Sensitive variables (SECRET_KEY, REDIS_PASSWORD, DB_PASSWORD, API keys) visible in plain text in docker-compose.yml
- Files: `templates/docker-compose.yml:50-122` (x-shared-env, all env vars hardcoded)
- Current mitigation: `.env` file is mode 600, root-only access
- Recommendations:
  1. Never commit `.env` to git (already in .gitignore)
  2. Add validation in `lib/security.sh:145-175` to prevent common default passwords

**ADMIN_TOKEN removed (RESOLVED: SEC-001)**
- Risk: Dify console accessible at `http://server/<admin_token>/` — security anti-pattern
- Files: All references removed per SEC-001
- Current mitigation: INIT_PASSWORD flow replaces token-based access
- Recommendations: Verify no legacy token references in custom nginx.conf extensions

**Redis hardening (RESOLVED: SEC-003)**
- Risk: Without requirepass + command rename, malicious container can FLUSHALL or CONFIG SET
- Files: `lib/config.sh:431-470` (generate_redis_config), `docker/volumes/redis/redis.conf`
- Current mitigation: requirepass + disabled FLUSHALL/FLUSHDB/CONFIG/DEBUG/SHUTDOWN
- Recommendations: Periodically audit redis.conf template for new dangerous commands

**PostgreSQL hardening (RESOLVED: SEC-004)**
- Risk: Plain password auth + SSL disabled + unlimited connections
- Files: `templates/docker-compose.yml` (db service command args)
- Current mitigation: scram-sha-256 auth, ssl=on, max_connections=100, log_connections=on
- Recommendations: Monitor `log_connections` for brute force patterns

**Docker container hardening (RESOLVED: SEC-005)**
- Risk: Containers running with too many capabilities, privileged mode, world-writable storage
- Files: `templates/docker-compose.yml:1-48` (x-security-defaults)
- Current mitigation:
  - ALL capabilities dropped by default
  - no-new-privileges: true
  - Minimal caps added only to services that need them (e.g., SYS_ADMIN for ollama GPU)
  - read_only: true + tmpfs where possible
  - Network segmentation (frontend/backend)
- Recommendations: Verify ollama only has SYS_ADMIN when GPU present

**Nginx security headers (RESOLVED: SEC-006)**
- Risk: Missing security headers (X-Frame-Options, CSP, etc.)
- Files: `lib/config.sh:382-430` (generate_nginx_config)
- Current mitigation: All OWASP security headers configured
- Recommendations: Review CSP `default-src 'self'` for plugin/marketplace resources

## Performance Bottlenecks

**Health check timeout on slow disks**
- Problem: Phase 6 waits max 300s for all 23 containers to reach healthy status. On slow storage (NAS, cloud VPS), containers take longer to initialize.
- Files: `install.sh:XXX` (health check loop - line TBD)
- Cause: Sequential health check with fixed 30s interval + 5 retries = max 150s per service, but 23 services can exceed 300s total
- Improvement path:
  1. Add `HEALTHCHECK_TIMEOUT` env var (default 300s, configurable)
  2. Parallelize health checks: poll all services concurrently instead of sequentially
  3. Add progress indicator showing which services are still starting

**Model download in serial (phase 7)**
- Problem: `pull_model()` downloads LLM + embedding + optional reranker models one-by-one. LLM models (4-14GB) take 5-30 min each.
- Files: `lib/models.sh:24-51` (pull_model)
- Cause: Sequential execution, no parallelization
- Improvement path:
  1. Background polling: start both pulls in background, wait for both to complete
  2. Add progress bars (bytes downloaded / total) instead of silent waiting
  3. Allow model download to run in parallel with workflow import (phase 8)

**Restore script I/O bound on large databases**
- Problem: `restore.sh` streams entire PostgreSQL backup to stdin. On large databases (10+ GB), disk I/O is saturated.
- Files: `scripts/restore.sh:80-246` (restore flow)
- Cause: No parallelization, single psql stream
- Improvement path:
  1. Use `pg_dump -j` flag for parallel dumps during backup
  2. Restore with `--jobs` flag for parallel recovery
  3. Add transfer rate estimation to progress output

## Fragile Areas

**install.sh script (812 lines of bash)**
- Files: `/d/Agmind/difyowebinstaller/install.sh`
- Why fragile:
  - Multiple interdependent phases with no transaction semantics
  - Phase failure leaves system in partially configured state
  - No rollback mechanism for partial installs
  - Heavy reliance on `set -euo pipefail` for error handling (exit on first error)
  - Race conditions between docker compose health checks and subsequent operations
- Safe modification:
  1. Each phase should be idempotent (can re-run without breaking state)
  2. Test install on fresh VM after each change
  3. Use `trap` for phase-level cleanup (not just script-level)
  4. Write phase completion markers to `/var/lib/agmind/phases/` so resume works
- Test coverage: Basic smoke test exists (CI-004) but does not test all profile combinations

**config.sh templates (812 lines)**
- Files: `/d/Agmind/difyowebinstaller/lib/config.sh`
- Why fragile:
  - Multiple sed replacements on templates with minimal validation
  - Safe_write_file() needs to handle both file and directory cleanup
  - Preflight_bind_mount_check() has complex logic that can obscure real errors
  - No schema validation for generated .env files
- Safe modification:
  1. Test template generation in isolation: `bash lib/config.sh`
  2. Validate .env syntax before docker compose up: `grep "^[A-Z_]*=" .env | wc -l`
  3. Use `source .env 2>&1` to catch parsing errors before deployment
- Test coverage: No unit tests for config generation

**Version pinning across 40+ services**
- Files: `templates/versions.env`, `templates/docker-compose.yml`
- Why fragile:
  - Any new service requires updating versions.env
  - Missing version pin = `latest` tag → non-deterministic builds
  - Upstream breaking changes not tested before pin
- Safe modification:
  1. Pre-release testing: run full install with new versions in integration test
  2. Add CI check: no `latest` tags allowed in docker-compose.yml
  3. Document compatibility matrix in COMPATIBILITY.md
- Test coverage: CI-002 runs `check-manifest-versions.py` but does not validate image existence

**Redis configuration templating**
- Files: `lib/config.sh:431-470`, `docker/volumes/redis/redis.conf` (generated)
- Why fragile:
  - Generated config replaces `requirepass`, `bind`, `rename-command` on each install
  - If install fails after redis starts, next install tries to configure already-running redis
  - Password generation race: `REDIS_PASSWORD` generated in config.sh, but redis.conf needs matching value
- Safe modification:
  1. Validate redis.conf template syntax before using: `redis-cli --test-memory 0` (dry-run)
  2. Use `docker compose config` to catch compose file errors before apply
  3. Test redis hardening in CI: try disabled commands and verify they fail
- Test coverage: Manual verification only (grep disabled commands)

**Restore script state management**
- Files: `scripts/restore.sh:1-80` (parameter parsing and safety checks)
- Why fragile:
  - Manual RESTORE_DIR path entry is error-prone
  - SERVICES_DOWN flag can get out of sync if multiple exits occur
  - Temporary backup directory naming uses `mktemp -d ... .old.XXXXXX` which could collide
  - No atomic swap of data/old directories (if rsync interrupted, state is corrupted)
- Safe modification:
  1. Use `--restore-from` flag only, remove interactive prompt
  2. Add `flock` on RESTORE_DIR to prevent parallel restores
  3. Test restore in CI on small database (DR-003 monthly drill exists)
- Test coverage: CI-006 smoke tests backup/restore but uses small DB

## Scaling Limits

**Single docker-compose orchestration (25 services)**
- Current capacity: Tested up to 23 containers healthy on 4GB RAM
- Limit: ~30 containers before orchestration becomes fragile. No built-in scale-out (no Kubernetes).
- Scaling path:
  1. For 50+ container deployments: migrate to docker compose with multiple compose files
  2. For multi-host: use Dokploy (partial support exists) or Kubernetes
  3. Split backend into separate compose file: `docker-compose.db.yml`, `docker-compose.api.yml`

**PostgreSQL connection pool**
- Current capacity: SQLALCHEMY_POOL_SIZE=30 (default)
- Limit: Each Dify worker uses 1-2 connections. 10+ workers exhaust pool.
- Scaling path:
  1. Increase SQLALCHEMY_POOL_SIZE to 100 if running 30+ workers
  2. Deploy pgBouncer sidecar for connection pooling
  3. Monitor with: `docker exec agmind-db psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"`

**Ollama model memory**
- Current capacity: 7-14B models fit in 8GB GPU memory. Larger models (30B+) OOM.
- Limit: Model size must fit in allocated GPU VRAM. No model swapping.
- Scaling path:
  1. For larger models: use quantized versions (Q4, Q5 instead of FP16)
  2. Deploy multiple ollama instances on different GPUs
  3. Route requests via load balancer based on model name

**Weaviate vector database**
- Current capacity: Tested with ~1M embeddings on 16GB RAM
- Limit: Vector index grows linearly with embedding count. No built-in sharding.
- Scaling path:
  1. For 10M+ embeddings: switch to Qdrant (already supported in config)
  2. For distributed: use Weaviate cloud or deploy custom sharding layer

## Dependencies at Risk

**Dify 1.13.0 — Breaking change window**
- Risk: Dify API v1 breaking changes occur between minor versions. Features/models API changed in 1.13.
- Impact:
  - import.py credential format may break in 1.14
  - Plugin API may change (Docling/Xinference integration)
  - Workflow format incompatible with older consoles
- Migration plan:
  1. Before bumping versions.env: test on staging with import.py dry-run
  2. Add version gating in import.py: detect Dify version and adjust credential schema
  3. Document breaking changes in COMPATIBILITY.md

**Ollama 0.6.2 — IPv6 bug in Go runtime**
- Risk: Go DNS resolver incompatibility (BUG-017). Upstream may change behavior in 0.7+.
- Impact: Model downloads may fail on future versions if Go runtime changes.
- Migration plan:
  1. Test ollama 0.7+ on IPv6-disabled host before bumping
  2. If bug persists: pin to 0.6.2 permanently, document in COMPATIBILITY.md
  3. Monitor Go release notes for dns changes

**Weaviate 1.27.6 — Database schema locked**
- Risk: Weaviate schema generated on 1.27.6. Upgrading to 1.28+ may require migration.
- Impact: Downtime during data migration. No automatic rollback.
- Migration plan:
  1. Before bumping: run full backup via `scripts/backup.sh`
  2. Test upgrade on backup copy: restore in parallel setup, test queries
  3. Run upgrade during maintenance window with rollback snapshot ready

**PostgreSQL 15.10-alpine — EOL risk**
- Risk: PostgreSQL 15 reaches EOL in Oct 2026. Security patches stop.
- Impact: Unpatched vulnerabilities. No auto-upgrade path in install.sh.
- Migration plan:
  1. 2026-09: Add migration step to install.sh for upgrading to PostgreSQL 16
  2. Test pg_dump | pg_restore flow on staging
  3. Update COMPATIBILITY.md with EOL dates

## Missing Critical Features

**No automated backup verification**
- Problem: Backups run via cron but nobody verifies they're valid until DR drill (monthly). Corruption goes unnoticed for 30 days.
- Blocks: Reliable disaster recovery. RPOΜ=1 day but RTO=unknown if backup corrupted.
- Fix approach:
  1. After each backup: extract and verify one random file from tarball
  2. Monthly: full restore test on shadow DB, verify data integrity
  3. Add to health.sh: `backup_verify()` function that runs after cron backup

**No multi-region failover**
- Problem: All data on single host. Network partition = total outage.
- Blocks: High availability SLA. RPO=0, RTO=hours.
- Fix approach:
  1. For HA: add read-only replica setup (PostgreSQL replication to standby)
  2. For multi-region: implement rsync-based async backup to secondary host
  3. Document in ROADMAP.md as Phase 8

**No automatic security patching**
- Problem: Pinned image versions never auto-update. CVEs in dependencies not patched.
- Blocks: Security compliance. Vulnerable images stay in production.
- Fix approach:
  1. Add `scripts/scan-cves.sh`: run Trivy daily, output vulnerability report
  2. Add to health.sh: alert if critical CVEs found
  3. Monthly: review update.sh to bump patch versions

**No configuration backup**
- Problem: `.env`, nginx.conf, redis.conf not backed up. Configuration loss = total reconfig.
- Blocks: Fast recovery. restore.sh recovers data but not configuration.
- Fix approach:
  1. Add to `scripts/backup.sh`: tar all config files separately
  2. Store in `/var/backups/agmind/config-<date>.tar.gz`
  3. Add restore step: extract config before running import.py

## Test Coverage Gaps

**No unit tests for lib/*.sh functions**
- What's not tested:
  - `generate_config()` with edge cases (special chars in passwords, long model names)
  - `validate_no_default_secrets()` (should catch all common passwords)
  - Error handling in `wait_for_ollama()` (does timeout actually work?)
- Files: `lib/config.sh`, `lib/models.sh`, `lib/security.sh`
- Risk: Silent failures during install, unnoticed regressions
- Priority: **High** — config generation is critical path

**No test for IPv6-disabled network (BUG-017)**
- What's not tested:
  - `ollama pull` on host without IPv6 route
  - DNS resolution fallback when IPv4 only
- Files: `lib/models.sh:39-51`
- Risk: Installation fails on most deployments. Only caught by manual testing.
- Priority: **High** — blocking most installs

**No test for reinstall idempotency**
- What's not tested:
  - `install.sh` run twice on same host (should not break)
  - Partial install recovery (phase 5 fails, phase 6 resumes)
  - Version upgrade path (install 1.0.0, then update to 1.1.0)
- Files: `install.sh:1-50` (lock handling)
- Risk: Users cannot retry failed installs. Must manual uninstall+reinstall.
- Priority: **High** — UX impact

**No test for restore with corrupted backup**
- What's not tested:
  - `restore.sh` with missing files in tarball
  - Partial database dump (restore -d before import complete)
  - Corrupted PostgreSQL pages in backup
- Files: `scripts/restore.sh`
- Risk: Restore appears successful but data is corrupted. Only noticed on usage.
- Priority: **Medium** — covered by monthly DR drill

**No test for large model downloads (Ollama)**
- What's not tested:
  - `pull_model()` with 10+GB models (network timeout, resumability)
  - Disk space check before downloading (error if < 5GB free)
  - Model pull on slow connection (>30 min timeout)
- Files: `lib/models.sh:24-51`
- Risk: Download hangs or fails silently. User has no feedback.
- Priority: **Medium** — UX impact, but manual timeout works

---

*Concerns audit: 2026-03-18*
