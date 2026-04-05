# Domain Pitfalls

**Domain:** Docker Compose installer — v2.7 new features
**Project:** AGmind Installer
**Researched:** 2026-03-29
**Scope:** Adding git-based release branch updates, DB-GPT/Open Notebook services, Docling CUDA image switching, docker manifest inspect pre-pull validation, Dify init cron fallback, dry-run mode, offline bundle compatibility

---

## Critical Pitfalls

Mistakes that cause rewrites, data loss, or broken existing installations.

---

### Pitfall C-01: git pull Silently Overwrites User-Customised Files

**Feature:** Release branch update workflow (`agmind update` using `git pull`)

**What goes wrong:**
Users may have edited `docker-compose.yml`, `versions.env`, `.env`, or `nginx.conf` directly on the server. `git pull` will merge (or error on conflicts), but if the strategy is `git reset --hard origin/release` for simplicity, every local change is destroyed without warning. If the strategy is a normal merge, unresolved conflicts abort the pull and leave the repo in a broken mid-merge state — the installer cannot start.

**Why it happens:**
Switching from GitHub Releases bundle download (stateless, no git) to `git pull` introduces a stateful git repo on the server. Users have no habit of "don't edit tracked files". The repo previously was just a directory of scripts.

**Consequences:**
- Silent destruction of customised Nginx/Compose config (reset --hard path)
- Installer broken mid-merge if conflicts (merge path), requiring manual `git merge --abort`
- `set -euo pipefail` will EXIT the update script on any non-zero git exit, leaving compose down

**Prevention:**
1. Before any pull: `git stash push -m "agmind-update-$(date +%s)"` to stash all local changes.
2. After pull: `git stash pop` with explicit conflict detection.
3. Generate a list of tracked files the user has modified: `git diff --name-only HEAD` — warn before touching them.
4. Never use `git reset --hard` unless explicitly documented and confirmed.
5. Consider separating user-editable config (`.env`, `credentials.txt`) from tracked files to avoid this class entirely.

**Detection:** `git status` shows "modified" files in INSTALL_DIR; update.sh does not check this before pulling.

**Phase warning:** Phase covering release branch switch (RELBRANCH feature). This is the highest-risk integration point of all v2.7 features.

---

### Pitfall C-02: `docker manifest inspect` Requests PUSH Scope — Breaks Read-Only Tokens

**Feature:** Pre-pull image validation via `docker manifest inspect`

**What goes wrong:**
`docker manifest inspect` internally requests a token with both `push` AND `pull` scopes from the Docker registry. If the user's Docker Hub credentials are a read-only Personal Access Token (PAT) or a read-only registry mirror token, the command returns HTTP 401 "insufficient scope" and exits non-zero. With `set -euo pipefail`, this crashes the pre-pull validation phase entirely, blocking installation — even though the images are perfectly pullable.

**Why it happens:**
Known Docker CLI bug: [docker/cli#4345](https://github.com/docker/cli/issues/4345). The `manifest inspect` subcommand incorrectly requests write scope for a read-only operation. Confirmed still present as of 2025.

**Consequences:**
- Pre-pull validation crashes on legitimate read-only credentials
- Entire installation aborted at validation phase
- Users with corporate read-only mirrors (very common) are blocked

**Prevention:**
1. Wrap every `docker manifest inspect` call with `|| true` in the validation function — treat failure as "could not verify, proceeding with pull attempt" rather than fatal.
2. Alternatively, use the Docker Hub registry API directly with a HEAD request to `/v2/<image>/manifests/<tag>` — HEAD requests do NOT count against rate limits and work with read-only tokens.
3. Log a warning (not an error) when manifest inspect fails; let the actual `docker pull` surface real errors.
4. Never let pre-pull validation be a hard gate that prevents install; it should be advisory.

**Detection:** `docker manifest inspect <image>` returns 401 even though `docker pull <image>` succeeds.

**Phase warning:** Phase implementing pre-pull validation (PREPULL feature). Must test with both authenticated and unauthenticated scenarios.

---

### Pitfall C-03: Docling CUDA Image Auto-Selection Picks Wrong CUDA Version for Host Driver

**Feature:** Docling CPU→CUDA image switching with GPU auto-detection

**What goes wrong:**
The installer detects `DETECTED_GPU=nvidia` and switches to the CUDA Docling image (e.g. `ghcr.io/docling-project/docling-serve-cu126`). The container starts, but processing fails with `torch.AcceleratorError: CUDA error: no kernel image is available for execution on the device`. Root cause: the image was built for CUDA 12.6 but the host driver supports a different compute capability.

A separate failure: the CUDA image is ~10GB. On a slow connection or the offline bundle, this causes enormous pull times or a missing image.

**Why it happens:**
Docling ships separate images per CUDA version (cu121, cu124, cu126, cu128). `detect_gpu()` already reads `DETECTED_GPU_COMPUTE` (sm version) but does not map it to a CUDA compatibility matrix. Simple "GPU detected → use CUDA image" logic ignores this.

Confirmed real issue: [docling-project/docling#2528](https://github.com/docling-project/docling/issues/2528) — users report cu126 image failing on hosts with CUDA 13.0 capability.

**Consequences:**
- Docling starts but all OCR/PDF jobs fail silently
- 10GB+ wasted pull for an incompatible image
- Offline bundle built with wrong CUDA image variant

**Prevention:**
1. Map `DETECTED_GPU_COMPUTE` (e.g. "8.9", "12.0") to required minimum CUDA version:
   - sm 8.x (Ampere) → CUDA 11.6+ → cu124 or cu126 safe
   - sm 9.x (Hopper/Ada) → CUDA 12.0+ → cu126 or cu128
   - sm 10.x/12.x → CUDA 12.6+ → only cu128
2. Always provide CPU fallback if compute capability cannot be determined.
3. Log which image variant was selected and why.
4. Offline bundle builder must detect GPU on the build machine and include the correct variant — document this clearly.

**Detection:** After container start, `docker exec docling python -c "import onnxruntime as ort; print(ort.get_available_providers())"` should show `CUDAExecutionProvider`. If only `CPUExecutionProvider` appears, CUDA is not active.

**Phase warning:** Phase covering Docling CUDA (DOCLING feature). Needs table of sm→CUDA version mapping baked into detect.sh or wizard.sh.

---

### Pitfall C-04: Offline Bundle Missing New Service Images

**Feature:** Offline bundle compatibility with DB-GPT, Open Notebook, Docling CUDA

**What goes wrong:**
The offline bundle builder (`build-offline-bundle.sh`) is not updated to include images for DB-GPT, Open Notebook, and the Docling CUDA variant. An Offline-profile deploy silently fails to start these services because `docker compose up` with `--pull never` (or equivalent) finds no local image. Docker returns "image not found" and the service enters a restart loop.

**Why it happens:**
New services are added to `docker-compose.yml` with `profiles: [dbgpt]` / `profiles: [notebook]` but the bundle builder script iterates over a hardcoded list or only active profiles. Optional service images are not included.

**Consequences:**
- Offline install appears healthy (mandatory services up) but optional services silently missing
- User activates DB-GPT profile post-install on an air-gapped machine — fails with no internet fallback
- No error during bundle build; error only surfaced at deploy time

**Prevention:**
1. Offline bundle builder must pull ALL profile variants, not just the default `COMPOSE_PROFILES` value.
2. Add explicit list of "offline-required images" to `build-offline-bundle.sh` that includes all optional service images.
3. Bundle manifest should include checksums for each image; verify before deploy.
4. Add an `--offline-validate` flag to the installer that checks all required images are present before starting.

**Detection:** After bundle build, `docker images | grep dbgpt` should show the image. Missing = bundle is incomplete.

**Phase warning:** Phase covering Offline bundle e2e test (TEST-01). Bundle builder must be updated before offline test is meaningful.

---

## Moderate Pitfalls

---

### Pitfall M-01: DB-GPT Port and Database Namespace Conflicts with Existing Stack

**Feature:** DB-GPT as optional service

**What goes wrong:**
DB-GPT ships with its own internal database requirements and may default to port 5670 (HTTP) or attempt to use a local SQLite/PostgreSQL. If DB-GPT's default compose definition is imported naively, it may conflict with the AGmind stack's existing PostgreSQL on 5432, or attempt to bind a port already occupied by another service (e.g. 5001 used by Dify API).

DB-GPT also has significant resource requirements — it ships with its own LLM inference layers that duplicate Ollama/vLLM functionality already in the stack.

**Why it happens:**
DB-GPT is designed as a standalone stack. Its Docker Compose definitions assume it owns its own database and inference services. Integrating as a `profiles: [dbgpt]` overlay requires explicit override of every conflicting default.

**Prevention:**
1. DB-GPT must use the shared AGmind PostgreSQL via explicit `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD` environment variables — create a dedicated database `dbgpt` in init scripts.
2. All DB-GPT-internal inference endpoints must be pointed at the existing Ollama/vLLM service endpoints, not internal defaults.
3. Port audit: verify DB-GPT's default exposed ports do not conflict. Add to `detect_ports()` check list if needed.
4. Resource guard: warn if activating DB-GPT + vLLM simultaneously on <32GB VRAM.

**Detection:** `docker compose --profile dbgpt config` to inspect resolved config before `up`. Check for duplicate port bindings.

**Phase warning:** Phase implementing DB-GPT service (NSVC-01).

---

### Pitfall M-02: Docker Compose Profiles and `depends_on` Cross-Profile Dependencies

**Feature:** DB-GPT / Open Notebook as optional profiles with `depends_on: db`, `depends_on: redis`

**What goes wrong:**
A service in profile `dbgpt` with `depends_on: db` will work when the `dbgpt` profile is active. However, if `db` (PostgreSQL) is also gated behind a profile (even the default empty profile = always-on), the dependency chain works. The trap is the reverse: adding a health check dependency from a profiled service to another profiled service that might not be active. Docker Compose v2.20+ raises errors for cross-profile `depends_on` with `condition: service_healthy` when the dependency is not started.

**Prevention:**
1. Core services (db, redis, nginx) must have NO profiles — always started.
2. Optional services may only `depends_on` always-on core services, never on other profiled services.
3. Test: `docker compose --profile dbgpt config` must show no unresolvable dependency warnings.
4. Run `docker compose --profile dbgpt up --dry-run` once available in the installed Compose version.

**Detection:** `docker compose config` output; warnings about service dependencies not in active profiles.

**Phase warning:** Phases implementing DB-GPT (NSVC-01) and Open Notebook (NSVC-02).

---

### Pitfall M-03: git pull on Release Branch Fails When Installer Directory Has Uncommitted Changes from Install Process

**Feature:** Release branch workflow

**What goes wrong:**
The `install.sh` run writes state files, generates `.env`, writes `credentials.txt`, etc. Some of these may be in tracked directories. When `agmind update` later runs `git pull`, git may refuse to pull due to "Your local changes to the following files would be overwritten by merge". This is NOT a user customisation — it is the installer's own output. The update fails immediately.

**Prevention:**
1. All installer-generated files (`.env`, `credentials.txt`, `docker/.env`, phase checkpoints) must either:
   - Live in paths listed in `.gitignore`, OR
   - Never be tracked in the release branch
2. Verify `.gitignore` covers every path that `install.sh` writes to before shipping the release branch feature.
3. In `agmind update`: check `git status --porcelain` before pull; auto-stash any untracked installer outputs.

**Detection:** After install, `git status` in INSTALL_DIR should show "clean" (no modified tracked files).

**Phase warning:** Phase implementing release branch workflow (RELBRANCH). Must audit all write paths in install.sh against .gitignore.

---

### Pitfall M-04: Docker Hub GET Manifest Requests Count Against Rate Limits — 10 Services = 10 Quota Units

**Feature:** Pre-pull validation via `docker manifest inspect`

**What goes wrong:**
Each `docker manifest inspect` call issues a GET request to `index.docker.io/v2/<image>/manifests/<tag>`. Every GET counts against the Docker Hub rate limit quota. The AGmind stack has 23-34 services. Pre-pull validating all of them in one pass consumes 23-34 quota units per installation attempt. With April 2025 limits (10 pulls/hour unauthenticated, 100/hour personal authenticated), running the installer twice in an hour on an unauthenticated host will hit the limit on the second run.

**Prevention:**
1. Use HTTP HEAD requests (not GET) to check existence — HEAD does NOT count against pull rate limits (confirmed in Docker Hub docs).
2. Implementation: use `curl -s -o /dev/null -w "%{http_code}" -X HEAD "https://registry-1.docker.io/v2/<image>/manifests/<tag>"` with an auth token instead of `docker manifest inspect`.
3. Only validate images that will actually be pulled for the current profile, not the full image list.
4. Skip validation entirely if `DEPLOY_PROFILE=offline`.

**Detection:** Check remaining rate limit via `docker system info` or registry API `RateLimit-Remaining` response header.

**Phase warning:** Phase implementing pre-pull validation (PREPULL). HEAD-based approach should be evaluated over `docker manifest inspect`.

---

### Pitfall M-05: dry-run Mode Produces False "Clean" Output When Side-Effect Functions Are Not Factored Out

**Feature:** `install.sh --dry-run`

**What goes wrong:**
The naive dry-run implementation wraps every action in `if [[ "$DRY_RUN" == "true" ]]; then echo "would do X"; else do_x; fi`. This produces 200+ conditional blocks spread across 10 phases and all lib/*.sh files. The real trap: functions that both check state AND write state (e.g. "check if postgres user exists; if not, create it") cannot be cleanly dry-run-simulated because the check depends on the side effect. Dry-run shows "would create postgres user" but cannot actually verify whether the user would need creating, producing output that is either always-positive or duplicates real checks.

Additionally, dry-run output becomes stale quickly as new phases are added, creating a maintenance burden.

**Why it happens:**
`set -euo pipefail` means any unguarded command that would fail during a real run (e.g. a port check) ALSO fails during dry-run, making the output unreliable unless every check is also dry-run-aware.

**Prevention:**
1. Define a single `run_cmd()` wrapper function: in dry-run mode it prints the command; in normal mode it executes it. Use this wrapper for all side-effecting calls only (file writes, docker calls, service starts).
2. Read-only checks (disk space, RAM, port detection) run unconditionally in both modes — they are safe.
3. Dry-run scope: validate prerequisites only (disk, RAM, ports, network, Docker). Do NOT attempt to simulate compose service startup order — too complex and misleading.
4. Document clearly what dry-run covers and what it does NOT cover.

**Detection:** Run `install.sh --dry-run` on a clean machine then on an existing install — output should differ (idempotent checks show pass/skip correctly).

**Phase warning:** Phase implementing dry-run mode (UXPL-02 deferred from v2.6). Scope should be explicitly limited to preflight + config generation preview, not full installation simulation.

---

### Pitfall M-06: Dify Init Cron Fallback Fires Multiple Times — Double Init Race

**Feature:** Dify init cron fallback

**What goes wrong:**
If the cron job that retries Dify initialisation (admin password set, workspace creation) runs while a previous init attempt is still in progress (or in a transient failure state), two concurrent init calls hit the Dify API simultaneously. Dify's init endpoint is not idempotent for all operations — a second workspace creation attempt may silently succeed with a duplicate or fail with a 409 that the cron treats as "not yet initialised, retry again".

**Prevention:**
1. Use a lock file (`/tmp/agmind-dify-init.lock`) checked via `flock` or file existence before running the cron init command.
2. After successful init, write a sentinel file (e.g. `/opt/agmind/.dify-init-complete`). Cron checks this first; if present, exits immediately without API call.
3. Cron retry interval must be longer than Dify API response timeout (set to at least 60s interval, not 10s).
4. Log every cron attempt with timestamp to `/opt/agmind/logs/dify-init.log`.

**Detection:** Multiple simultaneous `curl` processes to the Dify init endpoint in `ps aux`; duplicate workspace entries in Dify UI.

**Phase warning:** Phase implementing Dify init cron fallback.

---

## Minor Pitfalls

---

### Pitfall N-01: Docling CUDA Image Downloads ML Models at First Start, Not at Pull Time

**What goes wrong:**
Even with the CUDA Docling image pulled, the first PDF processing request triggers a HuggingFace model download (~137 seconds for a 4-page PDF on first call). On air-gapped (Offline profile) machines this hangs or fails silently.

**Prevention:**
Pre-bake the HuggingFace models into the Docling CUDA persistent volume during install phase 9 (model preloading). Add `DOCLING_ARTIFACTS_PATH` to force local model path and disable runtime downloads. Add `TRANSFORMERS_OFFLINE=1` and `HF_DATASETS_OFFLINE=1` environment variables for offline deployments.

**Phase warning:** Docling phase and offline bundle builder.

---

### Pitfall N-02: Open Notebook Service — Database Migration on Multi-Worker Start

**What goes wrong:**
If Open Notebook is started with multiple uvicorn workers (e.g. `UVICORN_WORKERS=2`), both workers attempt to run DB schema migrations simultaneously, leading to race conditions or schema corruption.

**Prevention:**
Start with `UVICORN_WORKERS=1` for first-time startup to let migrations complete, then allow scaling. Document this in the compose override for the `notebook` profile.

**Phase warning:** NSVC-02 (Open Notebook).

---

### Pitfall N-03: Telegram Notification HTML Escape Scope — Partial Escaping Creates Malformed Messages

**What goes wrong:**
HTML escaping only the user-supplied parts of Telegram messages (e.g. release version) while leaving template strings unescaped is insufficient. If any upstream value contains `<`, `>`, or `&` (e.g. a service name or docker image tag), the HTML parse mode in Telegram's Bot API fails with "can't parse entities" and the notification is silently dropped.

**Prevention:**
Apply HTML escaping (`sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'`) to ALL dynamic values injected into Telegram message templates, not just the release version string.

**Phase warning:** Telegram notification hardening (part of security hardening phase).

---

### Pitfall N-04: `agmind update --check` Release Notes Fetch Fails on GitHub API Rate Limit

**What goes wrong:**
GitHub's unauthenticated API rate limit is 60 requests/hour per IP. On CI/CD machines or shared-IP deployments, `agmind update --check` (which calls `GITHUB_API_URL` for release info) may receive HTTP 429/403. The current update.sh does not handle rate-limited responses gracefully — it silently shows "no update available" instead of "could not check".

**Prevention:**
Check HTTP status code of GitHub API response explicitly. On non-200 responses, log the actual status and message, and display "update check unavailable (GitHub API rate limit or network error)" rather than a false "up to date" result.

**Phase warning:** RELBRANCH phase (release notes in `agmind update --check`).

---

### Pitfall N-05: New Services Not Added to `NAME_TO_VERSION_KEY` and `NAME_TO_SERVICES` Maps in update.sh

**What goes wrong:**
`update.sh` maintains two hardcoded `declare -A` maps: `NAME_TO_VERSION_KEY` and `NAME_TO_SERVICES`. DB-GPT and Open Notebook are not in these maps. Running `agmind update --component dbgpt` silently does nothing — no error, no update, no explanation.

**Prevention:**
Add DB-GPT and Open Notebook entries to both maps in `update.sh` as part of the NSVC-01 and NSVC-02 implementation. Write a test that verifies all compose service names have a corresponding entry in `NAME_TO_SERVICES`.

**Phase warning:** Phases NSVC-01 and NSVC-02.

---

### Pitfall N-06: GPU Detection Passes But NVIDIA Container Toolkit Not Installed

**What goes wrong:**
`detect_gpu()` correctly detects `DETECTED_GPU=nvidia` via `nvidia-smi`. The installer selects the CUDA Docling image and adds `runtime: nvidia` or `deploy.resources.reservations.devices` to the compose service. Docker Compose starts the container, but it exits immediately with "could not select device driver nvidia with capabilities: [[gpu]]". Root cause: NVIDIA Container Toolkit (`nvidia-container-toolkit`) is not installed, even though the GPU driver and `nvidia-smi` work on the host.

**Prevention:**
Add a separate `detect_nvidia_container_toolkit()` check: `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi` (or check for `/usr/bin/nvidia-container-runtime`). If toolkit missing, warn and fall back to CPU image. Do NOT assume nvidia-smi working = container GPU passthrough working.

**Detection:** `docker info | grep -i runtime` should list `nvidia`. If only `runc` appears, toolkit is missing.

**Phase warning:** Docling CUDA phase.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Release branch workflow (RELBRANCH) | C-01: user file overwrites on git pull | Stash/restore tracked configs; audit .gitignore |
| Release branch workflow (RELBRANCH) | M-03: installer-generated files in tracked paths | Add all install outputs to .gitignore before shipping |
| Release branch workflow (RELBRANCH) | N-04: GitHub API rate limit on --check | Handle non-200 HTTP explicitly |
| Pre-pull validation (PREPULL) | C-02: manifest inspect needs push scope | Use HEAD requests or catch 401 as non-fatal |
| Pre-pull validation (PREPULL) | M-04: GET manifests consume rate limit quota | HEAD-based approach; skip in offline profile |
| Docling CUDA switch | C-03: wrong CUDA version for host | Map sm_XX to required CUDA version; CPU fallback |
| Docling CUDA switch | N-06: nvidia-smi works but container toolkit missing | Separate toolkit detection check |
| Docling CUDA switch | N-01: models not preloaded in volume | HF_OFFLINE=1 + model preload in install phase |
| DB-GPT service (NSVC-01) | M-01: port/DB conflicts with existing stack | DB-GPT must use shared AGmind Postgres; port audit |
| DB-GPT service (NSVC-01) | M-02: cross-profile depends_on fails | Only depend on always-on core services |
| DB-GPT service (NSVC-01) | N-05: not in update.sh maps | Add to NAME_TO_VERSION_KEY and NAME_TO_SERVICES |
| Open Notebook (NSVC-02) | M-02: cross-profile depends_on | Same pattern as DB-GPT |
| Open Notebook (NSVC-02) | N-02: multi-worker migration race | Start with UVICORN_WORKERS=1 first run |
| Open Notebook (NSVC-02) | N-05: not in update.sh maps | Add to NAME_TO_VERSION_KEY and NAME_TO_SERVICES |
| Offline bundle e2e (TEST-01) | C-04: new service images not in bundle | Bundle builder must include all profile variants |
| Offline bundle e2e (TEST-01) | N-01: HF model download at runtime | Preload models into volume; set OFFLINE env vars |
| Dry-run mode (UXPL-02) | M-05: dry-run/real divergence | Scope to preflight only; use run_cmd() wrapper |
| Dify init cron fallback | M-06: double init race | Lock file + sentinel file pattern |
| Security hardening | N-03: partial Telegram HTML escape | Escape ALL dynamic values in Telegram templates |

---

## Sources

- [docker/cli#4345 — docker manifest inspect requires push permission](https://github.com/docker/cli/issues/4345) — HIGH confidence (official repo issue, confirmed open)
- [moby/moby#45726 — insufficient scopes with Docker Hub PAT](https://github.com/moby/moby/issues/45726) — HIGH confidence
- [Unexpected Docker Hub rate limit for HEAD requests](https://www.augmentedmind.de/2024/12/15/docker-hub-rate-limit-head-request/) — MEDIUM confidence (single source, aligned with Docker Hub docs)
- [Docker Hub pull usage and limits](https://docs.docker.com/docker-hub/usage/pulls/) — HIGH confidence (official)
- [docker manifest inspect — Docker Docs](https://docs.docker.com/reference/cli/docker/manifest/inspect/) — HIGH confidence (official)
- [docling-project/docling#2528 — CUDA version mismatch](https://github.com/docling-project/docling/issues/2528) — HIGH confidence (official repo issue)
- [Docling RTX GPU setup guide](https://docling-project.github.io/docling/getting_started/rtx/) — HIGH confidence (official docs)
- [Reducing size of Docling PyTorch Docker image](https://shekhargulati.com/2025/02/05/reducing-size-of-docling-pytorch-docker-image/) — MEDIUM confidence (~10GB image size confirmed)
- [Docker Compose profiles — official docs](https://docs.docker.com/compose/how-tos/profiles/) — HIGH confidence
- [AWS and Docker Hub Limits — April 2025 changes](https://dev.to/aws-builders/aws-and-docker-hub-limits-smart-strategies-for-april-2025-changes-1514) — MEDIUM confidence
- [How to write idempotent Bash scripts](https://arslan.io/2019/07/03/how-to-write-idempotent-bash-scripts/) — MEDIUM confidence (dry-run scope guidance)
- [Open WebUI migration pitfalls — UVICORN_WORKERS](https://deepwiki.com/open-webui/open-webui/3.2-docker-deployment-options) — MEDIUM confidence (applies to Open Notebook similarly)
- [In praise of --dry-run — Hacker News discussion](https://news.ycombinator.com/item?id=27263136) — LOW confidence (community wisdom only)
- [CVE-2025-48384 — git arbitrary file write via submodules](https://securitylabs.datadoghq.com/articles/git-arbitrary-file-write/) — HIGH confidence (patched in git v2.49.1+; relevant if using --recursive clone)
