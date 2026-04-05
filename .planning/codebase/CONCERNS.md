# Codebase Concerns

**Analysis Date:** 2026-04-04

## Tech Debt

**Dry-run Mode Not Fully Implemented:**
- Issue: `install.sh --dry-run` only runs preflight checks (ports, disk, DNS), not full phase simulation
- Files: `install.sh` (lines 84-100), `lib/common.sh` (preflight_checks function)
- Impact: Users cannot validate the complete installation without actually deploying containers (UXPL-02 deferred to v3.0)
- Fix approach: Implement ~40-60 call sites for dry-run mode across all phases (Phase 34 candidate)

**Repeated Service Mapping Lists:**
- Issue: SERVICE_GROUPS and NAME_TO_SERVICES mappings duplicated across multiple scripts
- Files: `scripts/update.sh` (lines 27-88), `lib/health.sh` (get_service_list function)
- Impact: Service list changes require edits in multiple places; high risk of inconsistency
- Fix approach: Extract to shared `lib/service-names.sh` with single source of truth for component→service mapping

**Magic Constants in Model Sizes:**
- Issue: Hardcoded MODEL_SIZES array for download feedback, missing new models added in wizard
- Files: `lib/models.sh` (lines 13-45)
- Impact: Users see "size unknown" for recently added models (e.g., Qwen3 variants); impacts UX feedback
- Fix approach: Move to external JSON file in templates/, load at runtime; sync with wizard model list

**Registry Token Retry Logic Absent:**
- Issue: `_get_registry_token()` fails silently if auth.docker.io or GHCR token endpoint is rate-limited
- Files: `lib/compose.sh` (lines 91-117)
- Impact: Image validation may skip false positives; Docker Hub 429 responses silently treated as success
- Fix approach: Add explicit retry loop (3 attempts, 5s backoff) and log warnings for token failures

## Known Bugs

**COMPOSE_PROFILES Lost After Reboot (BUG-V3-029) — FIXED:**
- Symptoms: Systemd service restarts only core containers; profile-based services (monitoring, GPU, optional) not restarted
- Files: `lib/compose.sh` (line 384), `templates/agmind-stack.service.template`
- Root cause: COMPOSE_PROFILES built in memory during install but never written to `.env`; systemd service has no EnvironmentFile directive
- Fix implemented: Persist COMPOSE_PROFILES to `.env` and add EnvironmentFile to systemd unit template
- Status: Fixed as noted in code comment "BUG-V3-029"

**Image Validation Race on Slow Networks (BUG-V3-030):**
- Symptoms: Intermittent "image not found" errors on networks with >10s latency to registries
- Files: `lib/compose.sh` (_check_image_exists, max-time 10s)
- Root cause: HTTP HEAD timeout hardcoded to 10 seconds; some corporate proxies add 5-8s overhead
- Workaround: SKIP_IMAGE_VALIDATION=true environment variable
- Fix approach: Increase timeout to 20s or make configurable via IMAGE_VALIDATION_TIMEOUT env var

**Timezone Locale Bug in Update Script (BUG-V3-041):**
- Symptoms: `agmind update --check` fails on systems with non-C locale (e.g., ru_RU.UTF-8)
- Files: `scripts/update.sh` (line 8: `export LC_ALL=C`)
- Root cause: Version comparison regex depends on C locale for consistent field ordering
- Status: Fixed by setting LC_ALL=C at script start
- Impact: Prevents locale-dependent regex issues in version parsing

**Dify Init Retry Without Exponential Backoff (BUG-V3-043):**
- Symptoms: Init retries fail when API is under load; fixed 30s sleep globally insufficient for all scenarios
- Files: `lib/compose.sh` (compose_up function, lines ~430-450 approx, retry sleep 30s)
- Root cause: Static 30s wait between retries doesn't account for container startup variability
- Fix approach: Implement exponential backoff (attempt 1: 30s, 2: 60s, 3: 120s) with max 300s
- Status: Current STATE.md notes "Dify init retry sleep 30->60s" but still not fully exponential

**Release Tag Loss on Container Recreation (BUG-V3-044):**
- Symptoms: `agmind update --check` reports version mismatch after `docker compose up --force-recreate`
- Files: `install.sh` (line 515), `docker/` directory structure
- Root cause: Release tag written to temporary file, lost when container recreated; not persisted to volume
- Fix approach: Write RELEASE tag to `docker/volumes/` or config directory (outside compose rebuild)

## Security Considerations

**Hardcoded Redis ACL Rules:**
- Risk: Redis ACL blocklist approach requires manual maintenance for new commands; default deny would be safer
- Files: `lib/config.sh` (lines 516-526)
- Current mitigation: Explicit +@all with command blacklist; blocks FLUSHALL, DEBUG, CLUSTER, FAILOVER, etc.
- Recommendations: 
  1. Switch to allowlist approach (`+INFO +CONFIG GET ~* &*`) — explicit is safer than blacklist
  2. Add quarterly audit task to check for new dangerous Redis commands
  3. Consider separate read-only user for Celery broker (redis:// URI lacks auth)

**Sandbox Code Execution Without Limits:**
- Risk: CODE_MAX_* settings allow up to 80KB strings and 30 items per array; no execution timeout enforced
- Files: `templates/docker-compose.yml` (lines 103-111)
- Current mitigation: Docker memory limits per container (API_MEM_LIMIT, WORKER_MEM_LIMIT)
- Recommendations:
  1. Add CODE_EXECUTION_TIMEOUT env var (default 30s, configurable)
  2. Document max execution memory per code block in COMPONENTS.md
  3. Monitor CPU usage on worker container; add alert if sandbox process > 5min

**SSH Tunnel Key Generation Without Backup Reminder (BUG-S001):**
- Risk: `ssh-keygen -t ed25519 ... -N ""` creates unencrypted key; user must back it up manually
- Files: `lib/tunnel.sh` (lines 47-63)
- Current mitigation: Script prints instructions to `authorized_keys`; no automated backup
- Recommendations:
  1. Require confirmation: "Backup this key before proceeding: `ssh-keygen -l ...`"
  2. Optional: Encrypt key with passphrase prompt
  3. Add key fingerprint to credentials.txt for recovery verification

**Admin Password Stored in Plain Text in File:**
- Risk: `.admin_password` file contains plaintext password, readable by root/owner
- Files: `lib/config.sh` (lines 413-418), `lib/openwebui.sh` (line 31)
- Current mitigation: File mode 600 (readable by owner only), chowned to root
- Recommendations:
  1. Consider using age encryption (already in place for SOPS secrets; extend to .admin_password)
  2. Remove plaintext file after first login; replace with secure prompt on reuse
  3. Add reminder to credentials.txt: "Password stored in `.admin_password`; delete after first login"

**HuggingFace Token Not Rate-Limited:**
- Risk: HF_TOKEN used in wizard without rate limit guidance; token exhaustion during model downloads
- Files: `lib/wizard.sh` (lines 735-750 approx), `lib/config.sh` (line 247)
- Current mitigation: Token passed to Ollama/vLLM but no request throttling
- Recommendations:
  1. Document recommended HF token quotas for different deployment sizes in SPEC.md
  2. Add warning if HF token has no quota (public-only token)
  3. Monitor failed model pulls; retry with backoff if 429 received

## Performance Bottlenecks

**Synchronous Image Validation Blocks Install:**
- Problem: `validate_images_exist()` makes HTTP HEAD requests serially to all images (10+ containers = 100+ seconds)
- Files: `lib/compose.sh` (lines 164-215)
- Cause: No concurrency; each registry request waits for previous to complete
- Improvement path:
  1. Parallelize with background jobs (max 5 concurrent curl requests)
  2. Cache token responses for same registry (avoid duplicate auth requests)
  3. Add --skip-validation flag to bypass on repeated installs (speeds up update.sh calls)

**Health Check Poll Interval Fixed at 10 Seconds:**
- Problem: `wait_healthy()` polls every 30 seconds; containers that become healthy in 5 seconds wait until next 30s cycle
- Files: `lib/health.sh` (lines 262, 319)
- Cause: Conservative polling interval to avoid CPU churn; but wastes user time on fast networks
- Improvement path:
  1. Adaptive polling: start at 5s, increase to 30s after 5 cycles
  2. Implement container event subscription (docker events API) instead of polling
  3. Default timeout could be reduced from 300s to 180s if polling is smarter

**Docker Compose Pull Inactivity Timeout vs. Network Latency:**
- Problem: `_run_docker_pull_with_inactivity_timeout()` kills pull if no output for 120s; slow networks may have legitimate multi-minute pauses
- Files: `lib/compose.sh` (lines 313-345)
- Cause: Conservative timeout to prevent hangs; but brittle on WAN/VPN links
- Improvement path:
  1. Make timeout configurable (PULL_INACTIVITY_TIMEOUT env var, default 180s)
  2. Add minimum inactivity events (e.g., "pull X of Y layers" counts as activity)
  3. Log pull rate (MB/s) to identify actual stalls vs. legitimate slow progress

## Fragile Areas

**Wizard Model Selection Without VRAM Overflow Checks:**
- Files: `lib/wizard.sh` (_wizard_vllm_model function), `lib/models.sh` (_get_vram_offset)
- Why fragile: VRAM guard checks total VRAM but doesn't verify after model load; post-load OOM possible if embedding + reranker models exceed available memory
- Safe modification:
  1. Add post-load health check: monitor GPU memory after model download
  2. Add warning if post-load VRAM > 90% of available
  3. Test with actual model combinations (Qwen 32B + mxbai-embed-large + reranker)
- Test coverage: No unit tests for VRAM guard; only manual e2e testing

**Service Dependency Graph Not Validated:**
- Files: `templates/docker-compose.yml` (depends_on keys), `lib/health.sh` (hardcoded service list)
- Why fragile: Manually maintained service dependencies; easy to add a service without updating depends_on
- Safe modification:
  1. Extract depends_on to schema validation script (validate-compose.py)
  2. Add CI check: ensure all services in health.sh get_service_list() exist in docker-compose.yml
  3. Document service startup order in ARCHITECTURE.md

**Backup Script Assumes PostgreSQL Always Online:**
- Files: `scripts/backup.sh` (lines 22-71)
- Why fragile: Backup called during installation; if DB not ready, backup fails silently
- Safe modification:
  1. Add pre-backup health check: wait_container_healthy "db" 60 seconds
  2. If DB not healthy, skip backup with warning (don't fail install)
  3. Store backup status flag in .env for later inspection

**Update Rollback Without Idempotency Check:**
- Files: `scripts/update.sh` (rollback section, ~lines 380-420)
- Why fragile: Rollback replaces image tags but doesn't verify previous version was actually available before starting
- Safe modification:
  1. Validate all rollback images exist before executing rollback (use validate_images_exist)
  2. Atomic swap: don't touch running containers until all images are pulled
  3. Log rollback details to update_history.log for audit trail

## Scaling Limits

**Monitoring Stack Not Scalable Beyond 50 Containers:**
- Current capacity: Prometheus scrape interval 30s, retention 7 days → ~35 GB disk for 50 containers
- Limit: Node Exporter + cAdvisor + Prometheus default config without tuning; Loki uncompressed logs grow unbounded
- Scaling path:
  1. Add compression to Prometheus (STORAGE_TSDB_COMPRESSION=snappy in v2.50+)
  2. Reduce scrape interval to 60s on large deployments (PROM_SCRAPE_INTERVAL env var)
  3. Enable Loki log retention limits (max 7 days, configurable)
  4. Document: monitoring stack adds ~1.5 GB RAM minimum; not recommended for <8 GB machines

**LiteLLM Request Queue Unbounded:**
- Current capacity: No max_tokens_per_request or queue length limit in litellm-config.yaml
- Limit: If upstream API is down, requests queue indefinitely; memory leak possible if thousands accumulate
- Scaling path:
  1. Add queue length limit in litellm-config.yaml (max 100 pending requests)
  2. Add timeout per request (default 300s, configurable)
  3. Monitor litellm memory usage; add alert if > 50% of container limit

**Database Pool Size Not Tuned for GPU Services:**
- Current capacity: SQLALCHEMY_POOL_SIZE=30 (default from docker-compose)
- Limit: GPU model loading generates many concurrent DB writes; pool exhaustion possible with 5+ GPU containers
- Scaling path:
  1. Increase pool size for GPU deployments (SQLALCHEMY_POOL_SIZE=50-100)
  2. Add connection pool monitoring (log pool wait times in debug mode)
  3. Document: GPU deployments should use SQLALCHEMY_POOL_SIZE >= 2*num_gpu_services

## Dependencies at Risk

**Docker Compose Version Lock Absent:**
- Risk: docker-compose binary may be newer than installed version; compose file syntax may not be compatible
- Impact: `docker compose config --images` may fail if version mismatch
- Migration plan:
  1. Add docker-compose version check in `install.sh` (require >= 2.20.0)
  2. Version detect in `lib/docker.sh` or separate `detect.sh` function
  3. Document minimum Docker Compose version in README

**vLLM Dependency on CUDA/ROCm Not Validated:**
- Risk: vLLM image assumes CUDA 12.x; if system has CUDA 11.x or no GPU, silent failure
- Impact: GPU task runs on CPU (1000x slower); user assumes hardware is available
- Migration plan:
  1. Add docker info check: verify NVIDIA runtime presence before vLLM selection
  2. Add device mapping validation: nvidia-smi --query-gpu output matches expected GPUs
  3. Document: vLLM CPU-only fallback not supported; use Ollama for CPU-only deployments

**Dify Version Pinning Fragile:**
- Risk: DIFY_VERSION=main pulls latest master branch; rolling container updates if no tag specified
- Impact: Unexpected Dify behavior changes after reboot
- Migration plan:
  1. Enforce DIFY_VERSION from versions.env (error if =main)
  2. Add version validation: curl GitHub API to verify tag exists before pulling
  3. Document: always use release tags, never =main or =latest

## Missing Critical Features

**No Automatic Backup Scheduling:**
- Problem: Backup run only at install time (line 412 in install.sh); no cron job created for ongoing backups
- Blocks: Users cannot backup manually or on schedule without adding custom cron rules
- Workaround: `scripts/backup.sh` can be invoked manually, but no discovery mechanism
- Fix approach: Create `/etc/cron.d/agmind-backup` with daily 2 AM trigger; add `agmind backup` command to agmind.sh CLI

**No Graceful Shutdown Path:**
- Problem: No safe way to shut down stack without losing in-flight jobs; Celery workers not drained
- Blocks: Updates require kill+restart approach; data loss possible if task mid-execution
- Workaround: Manual `docker compose pause` before stop
- Fix approach: Add `agmind stop --graceful` (drains Celery tasks before stopping)

**No Health Alert Integration Testing:**
- Problem: Alertmanager+Telegram configured but no test mechanism to validate webhook works
- Blocks: Admins can't verify alerts fire until real outage occurs
- Workaround: Manual curl to Alertmanager API
- Fix approach: Add `agmind test-alert --channel telegram` to send test notification

**No Automatic Log Rotation for Installation Logs:**
- Problem: `install.log` and `update.log` grow unbounded; no logrotate configuration
- Blocks: On long-running deployments, logs consume significant disk space
- Workaround: Manual log cleanup
- Fix approach: Include `logrotate-agmind.conf` in templates/ and install to `/etc/logrotate.d/agmind`

## Test Coverage Gaps

**No Integration Tests for Profile Combinations:**
- What's not tested: Specific service pairs (e.g., docling + qdrant + vllm, open-notebook + dbgpt)
- Files: `lib/health.sh`, `lib/compose.sh`
- Risk: Profile incompatibilities silently fail; user reports bug weeks after install
- Priority: Medium — affects optional service users only
- Fix: Add CI matrix test for all 2^4 optional service combinations

**No E2E Tests for Update Rollback:**
- What's not tested: Full update→verify→rollback cycle with actual image pulls
- Files: `scripts/update.sh`
- Risk: Rollback syntax errors discovered only after user attempts recovery
- Priority: High — impacts availability
- Fix: Add CI job to test rollback with v2.7→v2.8 image versions

**No Offline Bundle Validation Tests:**
- What's not tested: Offline bundle build completeness; OCI image references correct
- Files: Not present (removed in Phase 31); legacy test gaps
- Risk: Offline deployments fail in field with incomplete bundle
- Priority: Low — offline profile removed in v2.8; document as v3.0 concern

**No Security Scanning for Image Vulnerabilities:**
- What's not tested: Container images against CVE databases
- Files: CI/CD (not in codebase; external)
- Risk: Deploying known-vulnerable images (Dify old versions, expired base images)
- Priority: High — security critical
- Fix: Add trivy scan to CI pipeline; block release if critical vulns detected

**No Load Testing for LiteLLM Failover Chain:**
- What's not tested: Actual failover behavior under simultaneous requests
- Files: `lib/config.sh` (litellm-config.yaml generation, ~lines 720-750)
- Risk: Failover chain syntax correct but runtime behavior untested; request loss on fallback
- Priority: Medium — affects users with multiple LLM providers
- Fix: Add chaos test: kill primary LLM provider, verify requests route to fallback

---

*Concerns audit: 2026-04-04*
