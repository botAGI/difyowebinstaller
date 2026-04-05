# Feature Landscape

**Domain:** AI stack installer — AGmind v2.7 new features
**Researched:** 2026-03-29
**Mode:** Ecosystem — how each feature works and expected behavior patterns

---

## Context: Existing Foundation (do not rebuild)

The following are already shipped and must not be regressed:
- 10-phase install with checkpoint resume
- agmind CLI (status, doctor, update via GitHub Releases bundle, gpu, restart, logs)
- VRAM-aware wizard, 4 deployment profiles (LAN/VPN/VPS/Offline)
- Compose profiles per provider (ollama/vllm/tei/reranker/docling)
- Telegram/webhook alerting, Authelia, Redis ACL, Squid SSRF proxy

All v2.7 features are **additive** — they extend, not replace, existing functionality.

---

## Table Stakes

Features users expect to be correct in a production installer.
Missing or broken = install feels untrustworthy.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Release branch install/update | Stable installs should not pull from `main`; dev commits break prod | Medium | `git clone --branch release` during fresh install; `git pull origin release` in `agmind update` |
| Pre-pull image validation | Pulling a non-existent tag causes mid-install failure; hard to diagnose | Low | `docker manifest inspect` returns non-zero on missing image; loop over versions.env before Phase 7/8 |
| install.sh --dry-run | Power users want to inspect what will happen before committing to a 30-min install | Medium | Print each phase action without executing; all filesystem, docker, and secret operations skipped |
| Dify init cron fallback | `MIGRATION_ENABLED=true` race condition causes worker/api to start before DB migration completes; causes silent failures on upgrades | Medium | Cron-style retry loop or `depends_on: condition: service_healthy` guard on worker; init container pattern known in Dify ecosystem |
| Docling CUDA image | CPU Docling is 4-6x slower; GPU users already have NVIDIA toolkit from vLLM/TEI setup | Low | Switch image tag: `ghcr.io/docling-project/docling-serve-cu126` or `cu128` based on CUDA version; add `deploy.resources.reservations.devices` stanza |

---

## Differentiators

Features that set AGmind apart from a plain Docker Compose file.
Not expected by default, but valued when present.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| DB-GPT as optional service (COMPOSE_PROFILE=dbgpt) | Text-to-SQL / chat-with-database capability added to the AI stack without manual setup | High | Requires its own SQLite/Chroma storage; uses `eosphorosai/dbgpt-openai` (CPU-only, ~2-4 GB image); port 5670; configured via Ollama or OpenAI proxy; no overlap with Dify's postgres |
| Open Notebook as optional service (COMPOSE_PROFILE=notebook) | NotebookLM-style research assistant with 100% local LLM support via Ollama | High | Requires SurrealDB sidecar; port 8502 (UI) + 5055 (API); `OPEN_NOTEBOOK_ENCRYPTION_KEY` required; `SURREAL_URL=ws://surrealdb:8000/rpc` |
| Docling Russian OCR with model preload | Russian-language enterprises need Cyrillic OCR; current RapidOCR defaults to Chinese/English | Medium | EasyOCR supports Russian via `lang: ["ru", "en"]`; model download at first use unless pre-pulled to persistent volume; requires custom `DOCLING_SERVE_OCR_ENGINE=easyocr` env var |
| Full release notes in `agmind update --check` | Users need to understand what they are updating to before pulling | Low | Fetch `body` field from GitHub Releases API response; truncate to ~20 lines with "Full changelog:" link |
| Telegram HTML escape for notifications | Angle brackets in container names or error messages break Telegram HTML parse mode | Low | sed/awk escape `<`, `>`, `&` before sending; already using HTML parse mode |

---

## Anti-Features

Features to explicitly NOT build in v2.7.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| DB-GPT with embedded LLM models | Full `eosphorosai/dbgpt` image is 15-20 GB and pulls its own model files — conflicts with existing Ollama and VRAM budget | Use `eosphorosai/dbgpt-openai` (CPU, proxy-only); point at existing Ollama via `LLM_MODEL_SERVICE=ollama://agmind-ollama:11434` |
| Open Notebook with cloud-only API keys | Contradicts offline/enterprise posture of AGmind | Configure Ollama as default provider; warn if no local model is loaded |
| SurrealDB port exposed to host | SurrealDB is internal-only; no admin UI needed for users | Keep SurrealDB on agmind-backend network only, no `ports:` mapping |
| Docling CUDA image without GPU guard | Silently falls back to CPU; worse than original if CUDA mismatch causes errors | Gate CUDA image selection behind `GPU_DETECTED=true` from `detect.sh`; fall back to CPU image if no GPU |
| install.sh --dry-run that also skips precondition checks | Dry run must still validate prerequisites (docker, docker compose, OS, memory) so users see real blockers | Only skip: filesystem writes, docker pulls, service starts, secret generation |
| Multiple optional services active by default | Increases cold-start memory from ~10 GB to 16+ GB if all enabled | All optional services (dbgpt, notebook) default ENABLE_* to false; wizard opt-in only |

---

## Feature Dependencies

```
# Release branch workflow
release_branch_install --> agmind_update_from_release
agmind_update_from_release --> full_release_notes_in_check   # uses same fetch_release_info()

# Pre-pull validation
pre_pull_validation --> versions.env  # reads existing component list
pre_pull_validation --> docker_manifest_inspect  # docker CLI feature, no extra deps
pre_pull_validation BEFORE Phase 7 (pull) and Phase 8 (start)

# Docling GPU
detect.sh GPU_DETECTED --> docling_cuda_image_selection
GPU_DETECTED already feeds vLLM/TEI image selection (existing code)

# DB-GPT
DB-GPT optional service --> agmind-backend network (existing)
DB-GPT optional service --> Ollama running (soft dep — can also use OpenAI API key)
DB-GPT optional service --> dbgpt COMPOSE_PROFILE (new profile key)
DB-GPT optional service --> DBGPT_VERSION in versions.env (new entry)
DB-GPT optional service --> update.sh NAME_TO_VERSION_KEY mapping (extend existing map)

# Open Notebook
Open Notebook optional service --> SurrealDB sidecar (new container, not shared)
Open Notebook optional service --> Ollama running (soft dep — can use other LLM providers)
Open Notebook optional service --> notebook COMPOSE_PROFILE (new profile key)
Open Notebook optional service --> OPEN_NOTEBOOK_VERSION + SURREALDB_VERSION in versions.env
Open Notebook optional service --> OPEN_NOTEBOOK_ENCRYPTION_KEY in secret generation

# Dify init cron fallback
dify_init_cron_fallback --> existing docker-compose.yml healthcheck on `db` service
dify_init_cron_fallback --> MIGRATION_ENABLED env var (already present)

# install.sh --dry-run
DRY_RUN flag --> existing arg parser in main()
DRY_RUN flag --> DRY_RUN variable exported to lib/ functions
DRY_RUN flag --> run_cmd() wrapper in common.sh (new or extend existing)
```

---

## Feature Detail: How Each Feature Works

### 1. Release Branch Workflow

**Pattern:** Two-branch model — `main` (dev/unstable) and `release` (stable, tested).

**Install flow:**
- `install.sh` runs `git clone --branch release https://github.com/botAGI/AGmind.git /opt/agmind` (or git fetch + checkout on re-run)
- A `--main` flag exists for developers to opt into unstable branch
- `RELEASE` file records the version tag, not the branch name

**Update flow (`agmind update`):**
- `git -C /opt/agmind fetch origin release`
- `git -C /opt/agmind checkout release`
- `git -C /opt/agmind pull --ff-only origin release`
- Then proceed with existing bundle update (versions.env download, compose pull)

**Confidence:** HIGH — standard git pattern, no external dependency.

---

### 2. Pre-Pull Validation via `docker manifest inspect`

**Pattern:** Before pulling images in Phase 7, loop over every image:tag pair derived from versions.env and validate existence in registry.

**Mechanism:**
```bash
docker manifest inspect "ghcr.io/docling-project/docling-serve:${DOCLING_SERVE_VERSION}" \
  > /dev/null 2>&1 || { log_error "Image not found: ..."; exit 1; }
```

Exit code non-zero = image does not exist (returns "manifest unknown").

**Important caveats:**
- Requires `DOCKER_CLI_EXPERIMENTAL=enabled` on Docker < 23 (most modern installs have it)
- Private registries require prior `docker login` (not applicable here — all images are public)
- Does NOT check image size or pull layers — fast (~1-3s per image)
- Network timeout needed (use `--timeout 10s` or wrap with timeout command)

**Confidence:** HIGH — documented Docker CLI feature, verified against official docs.

---

### 3. DB-GPT as Optional Service (`COMPOSE_PROFILE=dbgpt`)

**Image:** `eosphorosai/dbgpt-openai` (CPU/proxy-only variant)
- SQLite default (no external DB required)
- Chroma optional (heavy; avoid in AGmind — Weaviate/Qdrant already present)
- Port 5670 (webserver UI)
- Default storage: SQLite at `/app/pilot/data` (needs persistent volume)

**Environment variables needed:**
- `LLM_MODEL_SERVICE` — point to Ollama: `http://agmind-ollama:11434/api` or OpenAI key
- `DB_GPT_DATA_DIR` — persistent storage path
- Optionally: `OPENAI_API_KEY` or `OPENAI_API_BASE` for external LLM

**Compose service pattern:**
```yaml
dbgpt:
  image: eosphorosai/dbgpt-openai:${DBGPT_VERSION}
  profiles: [dbgpt]
  expose: ["5670"]     # internal only; nginx proxies externally if needed
  volumes:
    - agmind_dbgpt_data:/app/pilot/data
  networks:
    - agmind-backend
```

**Complexity note:** DB-GPT has its own model management layer separate from Ollama. The `dbgpt-openai` image delegates to an OpenAI-compatible endpoint — pointing it at existing Ollama is the correct integration. Do NOT attempt to use `eosphorosai/dbgpt` (full image with embedded models) — it is 15+ GB and pulls its own Llama weights.

**Confidence:** MEDIUM — Docker Hub confirms image and port; full environment variable spec needs validation against official docker-compose.yml.

---

### 4. Open Notebook as Optional Service (`COMPOSE_PROFILE=notebook`)

**Image:** `lfnovo/open_notebook` (Docker Hub) or `ghcr.io/lfnovo/open-notebook`
**Sidecar required:** `surrealdb/surrealdb:v2` (graph/document store, not interchangeable with Postgres/Redis)

**Ports:**
- 8502 — Streamlit web UI
- 5055 — REST API

**Required environment variables:**
- `OPEN_NOTEBOOK_ENCRYPTION_KEY` — user-specific secret; must be in AGmind secret generation
- `SURREAL_URL=ws://surrealdb:8000/rpc`
- `SURREAL_USER=root`, `SURREAL_PASSWORD=root` (or generated credentials)
- `SURREAL_NAMESPACE=open_notebook`, `SURREAL_DATABASE=open_notebook`
- LLM provider: e.g., `OLLAMA_HOST=http://agmind-ollama:11434` for local use

**Compose pattern:**
```yaml
surrealdb:
  image: surrealdb/surrealdb:${SURREALDB_VERSION}
  profiles: [notebook]
  command: start --log trace file:/data/database.db
  volumes: [agmind_surrealdb_data:/data]
  networks: [agmind-backend]

open-notebook:
  image: lfnovo/open_notebook:${OPEN_NOTEBOOK_VERSION}
  profiles: [notebook]
  depends_on: {surrealdb: {condition: service_healthy}}
  expose: ["8502", "5055"]
  networks: [agmind-backend]
```

**Complexity note:** SurrealDB is a distinct, niche database (not widely used in AGmind ecosystem). Its `restart: always` + `pull_policy: always` defaults in upstream compose must be overridden to match AGmind's pinned-version policy.

**Confidence:** MEDIUM — Docker Hub image confirmed, env vars verified from GitHub repo; SurrealDB healthcheck pattern needs testing.

---

### 5. Docling CUDA Acceleration

**Image selection logic:**
- CPU (default): `ghcr.io/docling-project/docling-serve:${DOCLING_SERVE_VERSION}`
- CUDA 12.6: `ghcr.io/docling-project/docling-serve-cu126:${DOCLING_SERVE_VERSION}`
- CUDA 12.8: `ghcr.io/docling-project/docling-serve-cu128:${DOCLING_SERVE_VERSION}`

Note: CUDA images intentionally omit `:latest` to avoid accidentally pulling deprecated CUDA variants.

**Compose GPU stanza:**
```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: 1
          capabilities: [gpu]
```

**Environment for GPU:**
- `NVIDIA_VISIBLE_DEVICES=all` (or specific GPU index)
- `DOCLING_SERVE_ENABLE_UI=false` (keep headless in server mode)

**Known issue (MEDIUM confidence):** RapidOCR in CUDA images defaults to CPU-only ONNX Runtime for OCR even when GPU is available (GitHub issue #434). Workaround: switch OCR engine to EasyOCR via `DOCLING_SERVE_OCR_ENGINE=easyocr` (supports GPU and multilingual).

**Russian OCR:** EasyOCR natively supports Russian (`lang: ["ru", "en"]`). RapidOCR requires custom model files for Russian. EasyOCR is the correct choice for Russian-language use.

**Model preload:** Official CUDA images embed models at `/opt/app-root/src/.cache/docling/models`. Persistent volume at `/home/docling/.cache` already configured in current AGmind compose (confirmed in codebase). On first container start, EasyOCR downloads language models (~100 MB for `ru`+`en`) unless pre-seeded.

**Confidence:** HIGH (image names from official registry) / MEDIUM (CUDA activation path, RapidOCR GPU issue).

---

### 6. Dify Init Cron Fallback

**Problem:** `MIGRATION_ENABLED=true` causes the Dify `api` and `worker` containers to run `flask db upgrade` on startup. On slow hosts or during upgrades, the Postgres container may not be fully ready when this runs, causing a one-time silent failure. The worker then stays up but with an un-migrated schema.

**Observed failure mode (from GitHub issues #14620, #17927):** plugin_daemon and worker start before `db` service_healthy; migrations fail; containers appear running but refuse requests.

**Current AGmind mitigation:** `depends_on: db: condition: service_healthy` is presumably set (need to verify in compose). The cron fallback is a secondary safety net.

**Cron fallback pattern:**
- Add a cron job inside the api container (or a sidecar) that checks migration status every 5 minutes and re-runs `flask db upgrade` if pending
- Alternatively: healthcheck that returns unhealthy until migration succeeds, combined with `restart: on-failure:3`
- Simplest safe approach: `restart: on-failure:3` on `api` + `worker` services so Docker re-attempts startup if migration fails

**Confidence:** MEDIUM — race condition confirmed in GitHub issues; exact fix pattern needs testing against AGmind's specific compose setup.

---

### 7. install.sh --dry-run

**Standard pattern in Bash installers:**
```bash
DRY_RUN=false
# Parse args:
--dry-run) DRY_RUN=true ;;

# Wrapper function in lib/common.sh:
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}
```

**Scope of dry-run (what to skip):**
- Docker pulls and starts (`docker compose pull`, `docker compose up`)
- Filesystem writes (`/opt/agmind`, volumes, secrets, config files)
- Secret generation (show placeholder values)
- Cron installs, SSH hardening, firewall rules

**What dry-run MUST still execute (real behavior, not mocked):**
- Prerequisite checks: OS version, docker/compose version, available RAM/disk
- GPU detection and VRAM calculation (read-only)
- Deployment profile selection logic
- Showing the full install plan with phase names and estimated durations

**Complexity:** This is the highest implementation complexity of all v2.7 features. Every side-effecting function call in `install.sh` and `lib/*.sh` must be wrapped with `run_cmd` or a similar guard. Estimate: ~40-60 call sites across 10 lib files.

**Confidence:** HIGH — well-established pattern; complexity is in scope of changes, not in the technique.

---

## MVP Recommendation

**Build first (blocking / table stakes):**
1. Release branch workflow — simple git change, zero risk, high trust signal
2. Pre-pull validation — low complexity, prevents mid-install failures
3. Dify init cron fallback — fixes known race condition in upgrades
4. Docling CUDA image — trivially gates on existing `GPU_DETECTED` var

**Build second (differentiators, medium complexity):**
5. DB-GPT optional service — new compose service, new profile, new wizard question
6. Open Notebook optional service — new compose service + sidecar, new secret
7. Full release notes in `agmind update --check` — extend existing `fetch_release_info()`
8. Telegram HTML escape — one-liner fix, zero risk

**Defer (highest complexity, lowest user impact):**
9. install.sh --dry-run — touches every lib file; ROI low vs effort; schedule for v3.0 as originally planned
   - Exception: if the team wants it as a "trust signal" feature for enterprise demos, scope it to only Phase 1 (prereq check) output without mocking all 10 phases

**Defer absolutely:**
- Docling Russian OCR EasyOCR integration — works but adds ~100 MB model download on first use; needs explicit user opt-in via wizard; separate from CUDA image selection

---

## Sources

- [eosphorosai/dbgpt-openai Docker Hub](https://hub.docker.com/r/eosphorosai/dbgpt-openai)
- [DB-GPT GitHub docker-compose.yml](https://github.com/eosphoros-ai/DB-GPT/blob/main/docker-compose.yml)
- [lfnovo/open_notebook Docker Hub](https://hub.docker.com/r/lfnovo/open_notebook)
- [open-notebook docker-compose.md](https://github.com/lfnovo/open-notebook/blob/main/docs/1-INSTALLATION/docker-compose.md)
- [SurrealDB in open-notebook-boilerplate — DeepWiki](https://deepwiki.com/lfnovo/open-notebook-boilerplate/5.2-surrealdb-database)
- [docling-serve Container Images — DeepWiki](https://deepwiki.com/docling-project/docling-serve/6.1-container-images)
- [Docling RTX GPU Getting Started](https://docling-project.github.io/docling/getting_started/rtx/)
- [Docling GPU Support docs](https://docling-project.github.io/docling/usage/gpu/)
- [RapidOCR CUDA issue in docling-serve #434](https://github.com/docling-project/docling-serve/issues/434)
- [docker manifest inspect — Docker Docs](https://docs.docker.com/reference/cli/docker/manifest/inspect/)
- [Dify plugin_daemon race condition issue #17927](https://github.com/langgenius/dify/issues/17927)
- [Dify docker-init_permissions hang issue #29669](https://github.com/langgenius/dify/issues/29669)
- [RapidOCR custom models — Docling docs](https://docling-project.github.io/docling/examples/rapidocr_with_custom_models/)
- [open-notebook AI providers docs](https://github.com/lfnovo/open-notebook/blob/main/docs/5-CONFIGURATION/ai-providers.md)
