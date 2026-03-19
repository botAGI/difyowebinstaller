# Codebase Concerns

**Analysis Date:** 2026-03-20

## Tech Debt

### 1. Incomplete GPU Configuration Fix (BUG-V3-009, BUG-V3-010)

**Issue:** Phase 6 bug fixes for vLLM CUDA errors and TEI OOM are only partially committed. Essential changes exist in working directory but not in git HEAD.

**Files:** `templates/docker-compose.yml`

**Impact:**
- vLLM may still error on multi-GPU systems: `ValueError: CUDA_VISIBLE_DEVICES='all'` (commit 5c55bd6 removed `=all` but didn't add explicit `=0`)
- TEI container may run on all GPUs causing OOM (commit 5c55bd6 added `CUDA_VISIBLE_DEVICES=0` env but missing `--cuda-devices 0` flag and increased `mem_limit: 8g`)
- vLLM deploy still set to `count: all` instead of `count: 1` (uncommitted in git)
- Next deployment will revert working tree changes since they're not in git history

**Fix approach:**
1. Review `templates/docker-compose.yml` working tree changes (lines 320, 336, 347, 353)
2. Verify vLLM section has both `CUDA_VISIBLE_DEVICES=0` env AND `deploy: count: 1`
3. Verify TEI section has both `CUDA_VISIBLE_DEVICES=0` env, `--cuda-devices 0` command flag, AND `mem_limit: 8g`
4. Commit atomic fix preserving all 8 changes across vLLM/TEI sections
5. Update `.planning/phases/06-v3-bugfixes/06-VERIFICATION.md` to mark as "verified_committed"

---

## Known Bugs

### 1. BUG-017: Ollama IPv6 Resolution Fails on Non-IPv6 Hosts

**Symptoms:**
- `docker exec agmind-ollama ollama pull qwen2.5:7b` fails with: `dial tcp [2606:4700:3034::ac43:b6e5]:443: connect: cannot assign requested address`
- Occurs on any host without IPv6 routing (majority of home/office networks)
- Affects all model downloads, blocking entire Ollama provider path

**Files:** `lib/models.sh:54`, `templates/docker-compose.yml:284-290`

**Trigger:** Deploy on network without IPv6 connectivity + Ollama provider selected

**Current "fix" (incomplete):**
- `templates/docker-compose.yml` line 290 sets `GODEBUG=netdns=cgo` for Ollama service
- `templates/docker-compose.yml` line 3 has `net.ipv6.conf.all.disable_ipv6=1` sysctl
- Go runtime has its own userspace DNS resolver that ignores kernel sysctl — partial solution

**Workaround:** Ensure host has IPv6 connectivity or manually configure firewall rules to block AAAA DNS responses before deploying

**Fix approach:**
1. The existing `GODEBUG=netdns=cgo` + `sysctls: disable_ipv6` should work but needs validation in offline/IPv6-restricted networks
2. Alternative: Add `extra_hosts` block in docker-compose Ollama section with hardcoded IPv4 for registry.ollama.ai
3. Test on network explicitly with IPv6 disabled at interface level

---

### 2. TASK-012: import.py Missing Required Fields for Model Credentials

**Symptoms:**
- KB creation fails: `HTTP 400: Default model not found for text-embedding`
- Dify API 1.13+ requires `context_size` parameter for Ollama embedding and LLM models
- Requires `invoke_timeout` for Xinference reranker
- `import.py` (external script, not in this repo) passes incomplete credentials to Dify API

**Files:** Not in installer (external Python script called from post-config phase)

**Impact:** Entire Dify workflow automation breaks; users cannot create knowledge bases

**Fix approach:** TASK-012 in TASKS.md documents required Python code changes:
- Add `context_size: "8192"` to embedding model credentials
- Add `context_size: "32768"` to LLM model credentials
- Add `invoke_timeout: "60"` to reranker credentials

---

### 3. TASK-015: Pipeline + OpenWebUI Don't Restart After DIFY_API_KEY Update

**Symptoms:**
- `import.py` writes `DIFY_API_KEY` to `.env` but pipeline/openwebui containers already running with empty value
- Open WebUI cannot see RAG assistant as available model (Pipeline integration broken)
- User experiences broken RAG after installation appears successful

**Files:** Not in installer (external `import.py` script)

**Impact:** RAG pipeline → Dify integration non-functional

**Fix approach:** TASK-015 in TASKS.md requires:
1. After writing `DIFY_API_KEY` to `.env`, call `docker compose restart pipeline openwebui`
2. Add 30-second wait before restarting to allow containers to flush buffers
3. Verify services are healthy before returning success

---

## Security Considerations

### 1. Admin Credentials Not Shown in Post-Install Summary

**Risk:** User doesn't know what credentials are in play; potential confusion about access paths

**Files:** `lib/config.sh:_store_admin_credentials()`, `install.sh` (post-install summary phase)

**Current mitigation:**
- Credentials stored in `${INSTALL_DIR}/.admin_password` (root-only file)
- Credentials.txt written to disk (chmod 600)
- Summary mentions file path but doesn't display password

**Recommendations:**
1. Update `phase_complete()` to display full credentials summary in terminal (password, Grafana, API key, etc.)
2. Include container health summary (X/23 healthy)
3. Include security summary (Authelia enabled? UFW status? Rate limits active?)
4. Write same summary to `${INSTALL_DIR}/credentials.txt` for future reference
5. Document in README that credentials.txt is the single source of truth (survives log rotation)

---

### 2. DIFY_API_KEY Not Persisted in .env

**Risk:** Pipeline service cannot authenticate to Dify; security key generated but lost

**Files:** `lib/config.sh`, not stored in installer repo (external import.py creates it)

**Current mitigation:** None — key is generated by import.py but not written to .env

**Recommendations:**
1. `import.py` must write `DIFY_API_KEY=${key}` to `/opt/agmind/docker/.env`
2. Use atomic sed pattern: `_atomic_sed "s|^DIFY_API_KEY=.*|DIFY_API_KEY=${api_key}|"` (see `lib/common.sh` pattern)
3. Verify file exists and is chmod 600 before writing
4. Test that pipeline container can read key after restart

---

## Performance Bottlenecks

### 1. wizard.sh Module Size (805 lines)

**Problem:** User interaction logic, validation, and provider selection crammed into single file

**Files:** `lib/wizard.sh`

**Cause:** Multiple decision trees (profile, LLM provider, embedding provider, monitoring) nested in single function

**Improvement path:**
1. Extract provider selection into `lib/providers.sh` (~150 lines)
2. Extract monitoring questions into `lib/monitoring.sh` (~100 lines)
3. Extract TLS questions into `lib/tls.sh` (~80 lines)
4. Reduces wizard.sh to ~400 lines, improves testability

---

### 2. config.sh Module Size (715 lines)

**Problem:** Secret generation, env file generation, nginx config, monitoring config all mixed in one module

**Files:** `lib/config.sh`

**Cause:** All "setup" logic grouped together; should be split by concern

**Improvement path:**
1. Extract nginx configuration into `lib/nginx.sh` (~120 lines)
2. Extract monitoring setup into `lib/monitoring-config.sh` (~100 lines)
3. Extract authelia setup into `lib/authelia-config.sh` (~80 lines) (currently partial in lib/authelia.sh)
4. Reduces config.sh to ~400 lines, improves maintainability

---

### 3. Large docker-compose.yml (1028 lines)

**Problem:** All services in single file; difficult to review GPU changes; provider-specific sections hard to find

**Files:** `templates/docker-compose.yml`

**Cause:** Single compose file for all profile + provider combinations

**Improvement path:**
1. Split into base services (`docker-compose.base.yml`) + profile overrides (`docker-compose.vps.yml`, `docker-compose.offline.yml`)
2. Split GPU-enabled services into separate include (`docker-compose.gpu.yml`)
3. Use Docker Compose `include:` feature (Docker 24.0+) to compose at runtime
4. Makes GPU changes in single section, easier to review

---

## Fragile Areas

### 1. health.sh Fail-Fast Logic (BUG-V3-008)

**Files:** `lib/health.sh:103-120`

**Why fragile:**
- Hardcoded list of critical_services must match docker-compose.yml exactly
- If service added to compose but not to critical_services list, failure silently waits for timeout
- If service renamed in compose, health check silently ignores it
- No automated sync between service list and critical check

**Safe modification:**
1. Generate critical_services list dynamically from docker-compose.yml (parse `depends_on` relationships)
2. OR: Document critical services in docker-compose.yml as a comment, parse at runtime
3. Add validation in `lib/health.sh` to verify all services in docker-compose.yml are known

**Test coverage gaps:**
- No unit tests for `wait_healthy()` with different service exit scenarios
- No integration test for timeout behavior on slow startup

---

### 2. Models.sh Pull with Minimal Validation (BUG-017)

**Files:** `lib/models.sh:54`

**Why fragile:**
- Simple `docker exec ollama pull` with no DNS fallback
- `GODEBUG=netdns=cgo` works on Linux but behavior varies on macOS/Windows (Go runtime differences)
- No retry loop if network fails during download
- No validation that model actually downloaded before declaring success

**Safe modification:**
1. Add retry loop: 3 attempts with 30s backoff for transient DNS failures
2. Add post-pull verification: `ollama list | grep -q "^${model}"` before returning success
3. Add explicit error message with mitigation steps if all retries fail

**Test coverage gaps:**
- No test for DNS failure recovery
- No test for partial download (interrupted mid-pull)

---

### 3. Atomic Sed Usage Throughout Codebase

**Files:** `lib/common.sh:_atomic_sed()`, used in `lib/config.sh` for 20+ sed operations

**Why fragile:**
- Pattern relies on temp file + move; if move fails, original file untouched but status ambiguous
- Error handling in `_atomic_sed` uses generic `log_error` — caller must check return code
- Some callers (e.g., provider var appending) don't check return value
- No validation that sed pattern actually matched before replacing

**Safe modification:**
1. Add match validation: `grep -q "$pattern" "$file"` before sed, fail if not found
2. Add verification after: `grep -q "$replacement" "$file"` to confirm replacement succeeded
3. Update all callers to use `|| return 1` after _atomic_sed calls
4. Document in lib/common.sh that sed errors are fatal and skip install phase

**Test coverage gaps:**
- No integration test for failed sed operations (e.g., disk full, permission denied)
- No test for partial replacements (pattern matched 1/5 times expected)

---

## Scaling Limits

### 1. Single install.sh Checkpoint Per Phase

**Current capacity:** 9 phases with single checkpoint file `.install_phase` (stores phase number only)

**Limit:** If multi-plan phases introduced, need sub-phase checkpoints

**Scaling path:**
1. Extend checkpoint format to include plan number: `06-plan-02` instead of `06`
2. Update `run_phase()` to load/save both phase and plan before executing
3. Allows resuming within a plan without re-running earlier sub-plans

---

### 2. Docker Compose Service Count

**Current capacity:** 23-34 containers (Prometheus, Grafana, cAdvisor, Loki, Promtail + core services)

**Limit approaches:**
- Health check loop iterates over all services every 5 seconds; beyond 50 services becomes slow
- docker-compose ps output parsing becomes unreliable on very large output
- Memory footprint: cAdvisor + Prometheus + Grafana + Loki significant on low-resource VPS

**Scaling path:**
1. Move monitoring stack to optional on-demand mode: skip by default, enable via flag
2. Replace cAdvisor + Prometheus + Grafana with Victoria Metrics (lighter footprint)
3. Use health check endpoint `/health` instead of iterating ps output (already implemented)

---

### 3. Container Health Check Parsing

**Current approach:** `docker compose ps --format '{{.Status}}'` + grep for status string

**Limit:** Brittle if Docker format changes; no structured parsing

**Scaling path:**
1. Switch to `docker inspect --format='{{json .State}}'` for JSON output
2. Use `jq` or equivalent to extract state predictably
3. More robust across Docker versions

---

## Dependencies at Risk

### 1. vLLM Dependency on Specific CUDA Versions

**Risk:** vLLM 0.6+ requires CUDA ≥12.1; vLLM 0.5.x requires CUDA ≤12.1. Host CUDA version mismatch causes container start failure.

**Impact:** Silent failure if user has wrong NVIDIA driver/CUDA toolkit

**Migration plan:**
1. Pin vLLM and CUDA driver versions together in `versions.env`
2. Add `agmind doctor` check for NVIDIA driver version vs required CUDA version
3. Display warning if mismatch detected but allow override flag

---

### 2. Weaviate 1.27.6 Data Compatibility

**Risk:** Weaviate 1.27.x schema differs from 1.19.0 (this was the original bugfix BUG-001); if user has v1 data with 1.19.x schema, upgrade to 1.27.6 will fail unless schema migrated.

**Impact:** Data loss if backup/restore doesn't account for schema version

**Migration plan:**
1. Document in README v1→v2 migration requires backup → recreate weaviate volume → restore
2. Add schema validation in backup script to detect old schema
3. Add migration helper script `scripts/migrate-weaviate-schema.sh` if possible

---

### 3. Dify 1.13+ API Requirement (context_size, invoke_timeout)

**Risk:** If Dify major version changes API again, import.py breaks silently (returns HTTP 400)

**Impact:** All installations post-import fail on credential setup

**Migration plan:**
1. Version-lock Dify in `versions.env` with explicit minimum version (≥1.13.0)
2. Add API version check in health checks: curl Dify `/api/status` to verify version
3. Document in COMPATIBILITY.md minimum Dify API version + known breaking changes

---

## Missing Critical Features

### 1. Pre-Install Validation for IPv6-Only Networks

**Problem:** Installer assumes IPv4 connectivity; fails silently if host only has IPv6

**Blocks:** Ollama model download

**Recommendation:**
1. Add network test in phase_diagnose: try to resolve registry.ollama.ai via A record
2. If fails, show warning and offer "IPv6 workaround" checkbox to enable `GODEBUG=netdns=cgo`
3. Document in README that IPv6-only hosts need manual DNS configuration

---

### 2. Model Availability Pre-Check

**Problem:** Wizard asks "download qwen2.5:7b?" but doesn't verify model exists in registry

**Blocks:** Silent failure during download phase

**Recommendation:**
1. Before asking user, curl Ollama registry API to list available models
2. Show user only models that actually exist
3. Add fallback list if registry unreachable

---

### 3. Credentials Recovery Path

**Problem:** If user loses credentials.txt or .admin_password file, no way to recover (no password reset built in)

**Blocks:** System access if files lost

**Recommendation:**
1. Document recovery in README: `docker compose exec web dify-cli reset-password`
2. Add `agmind reset-password` command to `scripts/agmind.sh` for convenience
3. Include test in test suite that password reset works

---

## Test Coverage Gaps

### 1. Untested: Multi-GPU vLLM Behavior

**What's not tested:** vLLM starting on system with 2+ GPUs + explicit CUDA_VISIBLE_DEVICES=0 pinning

**Files:** `templates/docker-compose.yml` (vLLM section)

**Risk:** BUG-V3-009 fix may have unintended side effects on multi-GPU systems

**Test plan:**
1. Integration test on 2+ GPU host: verify vLLM only uses GPU 0
2. Verify no CUDA memory contention with other GPU consumers (Ollama on GPU 0, TEI on GPU 0)
3. Monitor nvidia-smi during test to confirm device allocation

---

### 2. Untested: IPv6 Disabled Network Behavior

**What's not tested:** Model download on host with IPv6 explicitly disabled (`sysctl net.ipv6.conf.all.disable_ipv6=1`)

**Files:** `lib/models.sh:54`, `templates/docker-compose.yml:290`

**Risk:** BUG-017 fix assumes GODEBUG works; needs validation

**Test plan:**
1. Deploy on test host with IPv6 disabled at kernel level
2. Run `ollama pull qwen2.5:7b` via installer
3. Verify no IPv6 dial errors in logs
4. Verify model downloads successfully

---

### 3. Untested: Health Check Timeout Behavior

**What's not tested:** Behavior when service starts very slowly (e.g., vLLM downloading 14B model during healthcheck)

**Files:** `lib/health.sh:85-130`

**Risk:** Health check may timeout before service ready, causing false-negative phase failure

**Test plan:**
1. Mock slow-starting vLLM service (sleep 500s in entrypoint)
2. Run health check with timeout=600s
3. Verify health check waits patiently without fail-fast
4. Verify no false positives for services with legitimate startup time >5min

---

### 4. Untested: Atomic Sed Failure Recovery

**What's not tested:** What happens when sed operation fails mid-install (disk full, permission denied)

**Files:** `lib/common.sh:_atomic_sed()`

**Risk:** Install continues with incomplete config, resulting in silent failures

**Test plan:**
1. Mock `mv` failure after sed succeeds
2. Verify `_atomic_sed` returns non-zero
3. Verify install phase aborts and checkpoints for resume
4. Verify no partial files left in system

---

## Architecture Debt

### 1. Provider Questions Coupled to Compose Generation

**Problem:** `lib/wizard.sh` asks provider questions, `lib/config.sh` generates compose with provider-specific vars appended. Tight coupling makes it hard to add new providers.

**Files:** `lib/wizard.sh`, `lib/config.sh:_append_provider_vars()`

**Improvement path:**
1. Create provider plugin interface: `lib/providers/${name}.sh` with functions `ask_`, `validate_`, `compose_vars_`
2. Load provider dynamically based on wizard choice
3. Reduces wizard.sh + config.sh, makes new providers self-contained

---

### 2. Health Check Service List Hard-Coded

**Problem:** `lib/health.sh:get_service_list()` manually builds list based on env vars. If service added to compose, must update this function.

**Files:** `lib/health.sh:14-57`

**Improvement path:**
1. Parse service list directly from docker-compose.yml at runtime: `docker compose config --format=json | jq -r '.services | keys[]'`
2. Reduces manual sync errors
3. Slightly slower (one extra docker call) but worth reliability gain

---

## Known Limitations

### 1. No Multi-Instance Isolation

**Limitation:** Installer assumes single AGMind instance per host (volumes are global, not per-instance)

**Files:** `lib/config.sh`, `templates/docker-compose.yml`

**Workaround:** Deploy multiple instances in different directories with different INSTALL_DIR, manually manage port/network isolation

**Future work:** Phase 5 Requirements document (INSE-05) mentions multi-instance as v2.1 feature

---

### 2. No Graceful Shutdown / Drain Mode

**Limitation:** `agmind stop` just kills containers; no time for pipeline requests to complete

**Files:** `lib/docker.sh`

**Workaround:** Manual `docker compose graceful-shutdown` (no Docker equivalent, would need custom script)

**Future work:** Planned as ADVX-01 in v2.2+ requirements

---

### 3. No Model Validation Registry Check

**Limitation:** Wizard accepts any model name; doesn't verify it exists in registry before download

**Files:** `lib/wizard.sh`, `lib/models.sh`

**Workaround:** User must know valid Ollama model names (qwen2.5:7b, llama2:13b, etc.)

**Future work:** Planned as INSE-04 in v2.1+ requirements

---

---

*Concerns audit: 2026-03-20*
