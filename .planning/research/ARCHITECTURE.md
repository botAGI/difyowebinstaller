# Architecture Patterns: v2.7 Feature Integration

**Domain:** AGmind Installer — enterprise RAG stack on Docker Compose
**Researched:** 2026-03-29
**Mode:** Integration Architecture (subsequent milestone)
**Confidence:** HIGH for existing system, MEDIUM for new services

---

## Existing Architecture Snapshot (v2.6 baseline)

```
install.sh (10-phase orchestrator)
  lib/
    common.sh       — logging, secret gen, atomic writes
    detect.sh       — hardware detection, GPU, OS check
    wizard.sh       — interactive provider/model selection
    docker.sh       — Docker install, GPU runtime
    config.sh       — .env gen, nginx template, redis/sandbox
    compose.sh      — pull/start phases, build_compose_profiles()
    health.sh       — wait_healthy(), service health checks
    models.sh       — Ollama/vLLM/TEI model pull
    security.sh     — squid config, secrets rotation
    authelia.sh     — LDAP/Authelia config
    openwebui.sh    — admin user creation

templates/
    docker-compose.yml    — 1010-line Compose file
    nginx.conf.template   — #__COMMENT__-prefix conditional blocks
    versions.env          — source of truth for image tags
    env.{lan,vpn,vps,offline}.template
    release-manifest.json — image digest registry

scripts/
    agmind.sh        — day-2 CLI (status, doctor, update, gpu)
    update.sh        — GitHub Releases API → versions.env → docker pull
    check-upstream.sh — CI upstream version check
    build-offline-bundle.sh

Runtime layout at /opt/agmind:
    docker/
        docker-compose.yml
        .env
        nginx/nginx.conf
        volumes/...
    scripts/ (copied from installer at install time)
    versions.env
    release-manifest.json
    RELEASE (current version tag)
```

### Existing Compose Profiles

| Profile | Services activated |
|---------|-------------------|
| ollama | agmind-ollama |
| vllm | agmind-vllm |
| tei | agmind-tei (embed) |
| reranker | agmind-tei-rerank |
| docling | agmind-docling |
| weaviate | agmind-weaviate |
| qdrant | agmind-qdrant |
| monitoring | prometheus, alertmanager, loki, promtail, grafana, node-exporter, cadvisor |
| authelia | agmind-authelia |
| vps | agmind-certbot |

---

## Feature Integration Analysis

### 1. DB-GPT (NSVC-01)

**What it is:** Open-source agentic AI data assistant; allows SQL/CSV/API data exploration with LLM. Port 5670. Docker image: `eosphorosai/dbgpt` (also `eosphorosai/dbgpt-openai` for API-only use).

**Database dependency:** Default mode uses SQLite (no external database required). MySQL is only needed for multi-user production deployments. For AGmind's single-node installer, SQLite mode eliminates the need to add a MySQL service or share Postgres — HIGH confidence (confirmed from official docs.dbgpt.cn quickstart).

**Key environment variables:**
- `LOCAL_DB_PATH` — SQLite file path
- `LLM_MODEL` — model identifier
- `LANGUAGE` — `en` or `zh`
- `OLLAMA_API_BASE` or `OPENAI_API_KEY`-style env for LLM provider

**Integration points:**
- New compose profile: `dbgpt`
- Service communicates with agmind-ollama (or vLLM) on `agmind-backend` network
- Nginx: new `server` block on port 5670 or path `/dbgpt/` proxy — path proxy is problematic (DB-GPT does not support base path rewriting), so a **dedicated port** (e.g., 5670 exposed only on LAN interface) is correct
- Volume: `agmind_dbgpt_data` for SQLite + models cache
- `versions.env`: add `DBGPT_VERSION=v0.8.0`
- `update.sh` NAME_TO_VERSION_KEY: `[dbgpt]=DBGPT_VERSION`
- `compose.sh` build_compose_profiles(): add `[[ "${ENABLE_DBGPT:-false}" == "true" ]] && profiles+",dbgpt"`
- Security: `<<: *logging-defaults` (no sandbox/SSRF needed — DB-GPT is a frontend, not a code executor)
- `wizard.sh`: optional question "Enable DB-GPT data analysis? (y/N)"

**Data flow:**
```
User browser → port 5670 → agmind-dbgpt
agmind-dbgpt → agmind-ollama:11434 (LLM queries)
agmind-dbgpt → agmind_dbgpt_data (SQLite, uploaded files)
```

**Does NOT need:** SSRF proxy, Postgres, Redis, plugin daemon.

**Memory estimate:** 1-2 GB container RAM (without model). LLM lives in Ollama/vLLM.

---

### 2. Open Notebook (NSVC-02)

**What it is:** Self-hosted NotebookLM alternative. Multi-source document knowledge base with podcast-style synthesis. Source: `github.com/lfnovo/open-notebook`. Docker image: `lfnovo/open_notebook`. Port 8502 (UI), 5055 (API).

**Database dependency:** Requires **SurrealDB v2** (dedicated container). SurrealDB uses RocksDB storage (persistent). This is an entirely separate database technology from Postgres — it cannot be shared with existing services. The installer must spawn a `surrealdb` sidecar container.

**Key environment variables:**
```
OPEN_NOTEBOOK_ENCRYPTION_KEY  # required, used for encrypting API keys
SURREAL_URL=ws://surrealdb:8000/rpc
SURREAL_USER=root
SURREAL_PASSWORD=<generated secret>
SURREAL_NAMESPACE=open_notebook
SURREAL_DATABASE=open_notebook
```

**Integration points:**
- New compose profile: `notebook`
- Two new services in docker-compose.yml: `surrealdb` + `open-notebook`
- `surrealdb` image: `surrealdb/surrealdb:v2`; port 8000 (internal only, no external exposure)
- `open-notebook` depends on `surrealdb` (service_healthy)
- Nginx: Open Notebook is a Streamlit app — requires WebSocket upgrade. Expose on a **dedicated port** (e.g., 8502 via nginx `server` block bound to `127.0.0.1` for LAN, or behind auth). Path proxy is unreliable with Streamlit.
- Volumes: `agmind_notebook_data` (Streamlit uploads), `agmind_surrealdb_data` (RocksDB)
- `versions.env`: add `OPEN_NOTEBOOK_VERSION=latest-stable`, `SURREALDB_VERSION=v2`
- `update.sh`: add both components to NAME_TO_VERSION_KEY
- `compose.sh` build_compose_profiles(): add `[[ "${ENABLE_NOTEBOOK:-false}" == "true" ]] && profiles+",notebook"`
- Security: SurrealDB must NOT be exposed on host network. Internal container-to-container only.
- `OPEN_NOTEBOOK_ENCRYPTION_KEY` must be generated by `_generate_secrets()` in config.sh and stored in `.env`
- `wizard.sh`: optional question "Enable Open Notebook (NotebookLM alternative)? (y/N)"

**Data flow:**
```
User browser → port 8502 → agmind-open-notebook (Streamlit)
agmind-open-notebook ↔ agmind-surrealdb:8000 (RocksDB via WebSocket)
agmind-open-notebook → external LLM API (user configures in UI)
             OR → agmind-ollama:11434 (if Ollama profile active)
```

**Memory estimate:** Open Notebook 1 GB; SurrealDB 512 MB.

**Risk:** Open Notebook currently has no stable pinned Docker tag beyond `latest` — MEDIUM confidence on version pinning. Must verify tag availability before adding to versions.env.

---

### 3. Docling CUDA / GPU / Russian OCR (ETL enhancement)

**What it is:** The existing `docling` profile currently uses the CPU image. v2.7 adds:
- CUDA image variant for GPU-accelerated layout detection and table parsing
- Russian language OCR model preload at container startup
- Persistent volumes for downloaded models

**Current state:**
```yaml
docling:
  image: ghcr.io/docling-project/docling-serve:${DOCLING_SERVE_VERSION:-v1.14.3}
  volumes:
    - agmind_docling_cache:/home/docling/.cache
```

**CUDA image naming:** `quay.io/docling-project/docling-serve-cu128` (CUDA 12.8) or `docling-serve-cu130` (CUDA 13.0). CUDA images do NOT carry a `latest` tag — only explicit semver and `main`. The image registry is `quay.io`, not `ghcr.io`. This is a critical distinction.

**Integration changes:**
- `versions.env`: add `DOCLING_SERVE_CUDA_VERSION=v1.14.3` (separate key for CUDA variant)
- `docker-compose.yml`: the docling service image line needs conditional selection:
  - CPU: `ghcr.io/docling-project/docling-serve:${DOCLING_SERVE_VERSION}`
  - CUDA: `quay.io/docling-project/docling-serve-cu128:${DOCLING_SERVE_CUDA_VERSION}`
  - Selection driven by environment variable `DOCLING_USE_CUDA=true`
  - Implementation: two separate service definitions, each with its profile (`docling` vs `docling-cuda`), or use `DOCLING_IMAGE` env var that config.sh sets based on GPU detection
- **Recommended approach:** Single docling service with image controlled by `DOCLING_IMAGE` env var. `config.sh` sets `DOCLING_IMAGE` based on `GPU_AVAILABLE` and `ENABLE_DOCLING_CUDA` wizard choice.
- Russian OCR: `DOCLING_SERVE_LOAD_MODELS_AT_BOOT=true` plus OCR language config. The existing RapidOCR in CUDA image defaults to Chinese models — this is a **known upstream issue** (GitHub issue #434). Workaround: set `OCR_LANG=ru,en` via env var (EasyOCR-based builds support this; RapidOCR builds may need manual patch). LOW confidence that this works without a custom image — needs phase-specific investigation.
- GPU deploy block: same `#__GPU__` comment pattern as vLLM/TEI — uncommented by `enable_gpu_compose()` in lib/config.sh when `GPU_AVAILABLE=true`
- `wizard.sh`: when Docling is selected AND GPU detected, offer "Use GPU-accelerated Docling? (y/N)"

**Data flow:**
```
Dify worker → agmind-docling:8765 (ETL_TYPE=unstructured_api)
agmind-docling → agmind_docling_cache (model cache, persistent)
             → /dev/nvidia* (GPU passthrough when CUDA enabled)
```

**New volume:** `agmind_docling_models` separate from `agmind_docling_cache` (cache is transient artifacts; models are large and should survive container recreation).

---

### 4. Git-Based Release Branch Workflow

**What it is:** Currently `update.sh` fetches from `https://api.github.com/repos/botAGI/AGmind/releases/latest`. The `RELEASE` file tracks the current tag. v2.7 introduces a `release` branch on GitHub as the stable deployment source.

**Current mechanism:**
```
GitHub Releases API → latest release tag → download versions.env asset
```

**New mechanism:**
```
GitHub `release` branch → always contains latest stable versions.env
GitHub Releases → still used for tagged releases (changelog, assets)
```

**Integration points:**

**Option A: Branch-based versions.env fetch (RECOMMENDED)**
- `update.sh` gains `--branch` parameter (default: `release`, override: `--main` for dev)
- Raw URL pattern: `https://raw.githubusercontent.com/botAGI/AGmind/{branch}/templates/versions.env`
- No dependency on GitHub Releases API for version data — simpler, always up-to-date
- Releases API still used only for `--check` to get human-readable release notes
- `RELEASE` file: write the commit SHA or tag from which versions.env was fetched

**Modified fetch_release_info() flow:**
```bash
# Default: fetch versions.env from release branch
BRANCH="${UPDATE_BRANCH:-release}"
VERSIONS_URL="https://raw.githubusercontent.com/botAGI/AGmind/${BRANCH}/templates/versions.env"

# Still fetch release notes from Releases API (for --check display)
NOTES_URL="https://api.github.com/repos/botAGI/AGmind/releases/latest"
```

**Option B: Keep Releases API, add branch as fallback** — more complex, no clear benefit.

**Changes required:**
- `scripts/update.sh`:
  - Add `--branch <branch>` / `--main` flag parsing
  - Replace `RELEASE_VERSIONS_URL` discovery (currently searches release assets) with direct raw GitHub URL
  - `GITHUB_API_URL` still used for release notes
  - Default `UPDATE_BRANCH=release`
- `install.sh`: add `--branch` pass-through to `agmind update` if called
- `RELEASE` file: update format to include branch context (e.g., `v2.7.0@release`)
- Offline bundles: unaffected (bundle always contains versions.env directly)

**`--main` flag behavior:**
```bash
agmind update --main    # fetches from main branch (dev/bleeding edge)
agmind update           # fetches from release branch (stable, default)
agmind update --check   # checks and displays diff, no apply
```

---

### 5. Pre-Pull Validation via `docker manifest inspect`

**What it is:** Before `docker pull`, validate that all required images actually exist in their registries. Prevents mid-install failures where an image was deleted, tag renamed, or network connectivity is partial.

**Integration point:** `lib/compose.sh`, inside `_pull_with_progress()`, before the actual pull loop.

**Implementation pattern:**
```bash
validate_images_exist() {
    local profiles="${1:-}"
    local docker_dir="${INSTALL_DIR}/docker"
    cd "$docker_dir"

    local images_raw
    if [[ -n "$profiles" ]]; then
        images_raw="$(COMPOSE_PROFILES="$profiles" docker compose config --images 2>/dev/null)"
    else
        images_raw="$(docker compose config --images 2>/dev/null)"
    fi

    local failed=0
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        if ! docker manifest inspect "$image" >/dev/null 2>&1; then
            log_error "Image not found in registry: ${image}"
            failed=$((failed + 1))
        fi
    done <<< "$images_raw"

    if [[ $failed -gt 0 ]]; then
        log_error "${failed} image(s) not found. Check versions.env or network."
        return 1
    fi
    log_success "All ${#images_raw} images validated in registry"
}
```

**Called from:** `compose_pull()` after `ensure_bind_mount_files` and before `_pull_with_progress`. Also called from `update.sh` before applying new versions.

**Performance note:** `docker manifest inspect` makes a remote API call per image — can take 2-5s per image with 20+ services this adds 40-100s to install. Call in parallel with `&` + `wait` to reduce wall-clock time (but requires collecting exit codes carefully). Alternatively, validate only version-changed images during updates.

**Timeout:** Each `docker manifest inspect` call should use `--max-time 15` via wrapper, or use `timeout 15 docker manifest inspect ...`.

**Where it lives:**
- New function `validate_images_exist()` in `lib/compose.sh`
- Called from `compose_pull()` (install path)
- Called from `update.sh` `apply_update()` (update path)
- Skipped when `DEPLOY_PROFILE=offline`

---

### 6. `install.sh --dry-run`

**What it is:** Run all install phases but skip any operations that modify the system. Print what would happen.

**Pattern:** A global `DRY_RUN` boolean controls all side-effecting operations.

**Implementation approach — thin wrapper via `_run` helper:**
```bash
# In common.sh or install.sh
DRY_RUN="${DRY_RUN:-false}"

_run() {
    # If DRY_RUN: print command, don't execute
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}
```

This approach requires wrapping all side-effecting calls. Given the existing codebase scale (~200KB of shell), this is intrusive. A more surgical approach:

**Recommended: Flag-based skip at phase boundaries**

The 10-phase structure already exists. With `--dry-run`, phases 1-3 (diagnostics, wizard, system checks) run normally (read-only), and phases 4-10 (config write, docker pull, start, health, models, backups, complete) each check `DRY_RUN` at their entry point and print a summary instead of executing:

```bash
phase_config() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would generate config for profile: ${DEPLOY_PROFILE}"
        log_info "[DRY-RUN] Services: $(build_compose_profiles && echo $COMPOSE_PROFILE_STRING)"
        return 0
    fi
    # ... real implementation
}
```

**What each phase prints in dry-run:**
- Phase 4 (Config): profile, services enabled, URLs, secrets would-be-generated
- Phase 5 (Pull): image list from `docker compose config --images`
- Phase 6 (Start): services that would start
- Phase 7 (Health): healthcheck commands that would run
- Phase 8 (Models): model names that would download
- Phase 9 (Backups): cron schedule, backup path
- Phase 10 (Complete): credential file path, CLI install path

**Changes required:**
- `install.sh`: add `--dry-run` to argument parser, set `DRY_RUN=true`; export to lib functions
- Each phase function: add `[[ "$DRY_RUN" == "true" ]] && { ... print summary; return 0; }` guard
- `wizard.sh`: runs normally in dry-run (needs user input to know what to simulate)
- No changes needed to `lib/compose.sh`, `lib/health.sh`, etc. — guards live in install.sh phase wrappers

---

## Component Boundaries: New vs Modified

### New Components

| Component | File(s) | Type |
|-----------|---------|------|
| DB-GPT service | `templates/docker-compose.yml` | New compose service block |
| Open Notebook service | `templates/docker-compose.yml` | New compose service block (×2: surrealdb + open-notebook) |
| SurrealDB service | `templates/docker-compose.yml` | New compose service block |
| DB-GPT nginx block | `templates/nginx.conf.template` | New server block (port 5670) |
| Open Notebook nginx block | `templates/nginx.conf.template` | New server block (port 8502) |
| `validate_images_exist()` | `lib/compose.sh` | New function |
| `agmind_dbgpt_data` volume | `templates/docker-compose.yml` | New named volume |
| `agmind_notebook_data` volume | `templates/docker-compose.yml` | New named volume |
| `agmind_surrealdb_data` volume | `templates/docker-compose.yml` | New named volume |
| `agmind_docling_models` volume | `templates/docker-compose.yml` | New named volume |

### Modified Components

| Component | File(s) | What Changes |
|-----------|---------|--------------|
| `versions.env` | `templates/versions.env` | Add DBGPT_VERSION, OPEN_NOTEBOOK_VERSION, SURREALDB_VERSION, DOCLING_SERVE_CUDA_VERSION |
| `compose.sh` build_compose_profiles() | `lib/compose.sh` | Add dbgpt, notebook profile conditions |
| `install.sh` arg parser | `install.sh` | Add `--dry-run` flag |
| install.sh phase functions | `install.sh` | Add dry-run guards to phases 4-10 |
| `update.sh` fetch_release_info() | `scripts/update.sh` | Switch to branch-based versions.env fetch, add `--branch`/`--main` flags |
| `update.sh` NAME_TO_VERSION_KEY | `scripts/update.sh` | Add dbgpt, open-notebook, surrealdb |
| `update.sh` NAME_TO_SERVICES | `scripts/update.sh` | Add dbgpt, open-notebook, surrealdb service names |
| `update.sh` SERVICE_GROUPS | `scripts/update.sh` | Add notebook group (surrealdb + open-notebook) |
| `update.sh` apply_update() | `scripts/update.sh` | Add pre-pull validation call |
| `wizard.sh` | `lib/wizard.sh` | Add ENABLE_DBGPT, ENABLE_NOTEBOOK, ENABLE_DOCLING_CUDA questions |
| `config.sh` generate_config() | `lib/config.sh` | Add DBGPT/notebook env vars, OPEN_NOTEBOOK_ENCRYPTION_KEY secret generation, DOCLING_IMAGE selection logic |
| `agmind.sh` status | `scripts/agmind.sh` | Show DB-GPT / Open Notebook status + endpoints when enabled |
| `release-manifest.json` | `templates/release-manifest.json` | Add new image entries |

---

## Data Flow Changes

### Install Flow (modified with pre-pull validation)

```
install.sh
  Phase 1: diagnostics + preflight
  Phase 2: wizard → sets ENABLE_DBGPT, ENABLE_NOTEBOOK, ENABLE_DOCLING_CUDA
  Phase 3: Docker setup
  Phase 4: config → generate_config()
    → generates OPEN_NOTEBOOK_ENCRYPTION_KEY
    → sets DOCLING_IMAGE based on GPU + wizard
    → writes DB-GPT env vars to .env
  Phase 5: PRE-PULL VALIDATION (new)
    → validate_images_exist() per profile
  Phase 5: compose_pull() → pull images
  Phase 6: compose_start()
  ...
```

### Update Flow (modified with branch fetch + pre-pull validation)

```
agmind update [--branch release|--main] [--check]
  → fetch versions.env from raw.githubusercontent.com/{branch}/templates/versions.env
  → fetch release notes from GitHub Releases API (for --check display)
  → diff CURRENT_VERSIONS vs NEW_VERSIONS
  → validate_images_exist() for changed images (pre-pull, new step)
  → backup → pull → restart affected services
```

### DB-GPT Data Flow

```
User:5670 → nginx(5670) → agmind-dbgpt:5670
agmind-dbgpt → agmind_dbgpt_data/sqlite3.db
agmind-dbgpt → agmind-backend → agmind-ollama:11434
```

### Open Notebook Data Flow

```
User:8502 → nginx(8502) → agmind-open-notebook:8502 (Streamlit)
agmind-open-notebook → agmind-surrealdb:8000 (ws)
agmind-open-notebook → agmind_notebook_data (uploads)
agmind-surrealdb → agmind_surrealdb_data (RocksDB)
```

### Docling CUDA Data Flow

```
Dify worker → agmind-docling:8765 (ETL_TYPE=unstructured_api)
agmind-docling (CUDA) → /dev/nvidia0 (GPU passthrough)
agmind-docling → agmind_docling_cache (temp artifacts)
agmind-docling → agmind_docling_models (layout/OCR models, persistent)
```

---

## Suggested Build Order

The build order respects these dependencies:
1. `versions.env` changes must happen before any docker-compose or update.sh changes
2. `compose.sh` profile builder must be updated before new services are testable
3. New compose services must be defined before nginx routing can reference them
4. `--dry-run` and pre-pull validation are infrastructure features — build before optional services to validate them during testing
5. Docling CUDA extends existing service — lower risk, do first among service features
6. DB-GPT: no external DB dependency (SQLite) — simpler integration, do before Open Notebook
7. Open Notebook: requires SurrealDB sidecar, secret generation change — most complex, do last among services
8. Release branch workflow touches update.sh core logic — do early to unblock testing against branch

**Recommended sequence:**

| Step | Feature | Files Changed | Risk |
|------|---------|--------------|------|
| 1 | Release branch update workflow | `scripts/update.sh`, `install.sh`, `RELEASE` | MEDIUM — core update path |
| 2 | `--dry-run` mode | `install.sh` | LOW — additive only, guards at phase entry |
| 3 | Pre-pull validation | `lib/compose.sh`, `scripts/update.sh` | LOW — additive, skipped offline |
| 4 | Docling CUDA + models | `docker-compose.yml`, `versions.env`, `lib/config.sh`, `lib/wizard.sh` | MEDIUM — extends existing service |
| 5 | DB-GPT service | `docker-compose.yml`, `versions.env`, `nginx.conf.template`, `lib/wizard.sh`, `lib/compose.sh`, `scripts/update.sh`, `scripts/agmind.sh` | MEDIUM — new optional service |
| 6 | Open Notebook service | `docker-compose.yml`, `versions.env`, `nginx.conf.template`, `lib/wizard.sh`, `lib/compose.sh`, `lib/config.sh`, `scripts/update.sh`, `scripts/agmind.sh` | MEDIUM-HIGH — SurrealDB + secret gen |

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Shared Postgres for New Services

**What:** Attempting to have DB-GPT or Open Notebook reuse the existing `agmind-db` Postgres container.

**Why bad:** DB-GPT uses MySQL dialect by default (SQLAlchemy). Open Notebook requires SurrealDB — not a Postgres-compatible wire protocol. Forced sharing would require custom DB-GPT config and an impossible SurrealDB migration.

**Instead:** DB-GPT runs SQLite (no extra DB container). Open Notebook runs its own SurrealDB sidecar.

---

### Anti-Pattern 2: Path-Based Nginx Proxy for New Services

**What:** Routing `/dbgpt/` → DB-GPT and `/notebook/` → Open Notebook in the existing server blocks.

**Why bad:**
- DB-GPT serves static assets at root-relative paths (`/static/`, `/api/`) with no base-path rewriting support
- Open Notebook is a Streamlit app that generates absolute root-relative WebSocket URLs — path prefixing breaks WebSocket connections
- Both would require patching application code or using complex nginx `sub_filter` rewriting

**Instead:** Dedicated `server` blocks on separate ports (`listen 5670;` and `listen 8502;`). These ports can be restricted to `127.0.0.1` for LAN, or left open for internal access.

---

### Anti-Pattern 3: `DOCLING_IMAGE=:latest` for CUDA Variant

**What:** Using the CUDA image's `latest` tag or `main` tag in versions.env.

**Why bad:** Docling-project explicitly does NOT publish a `latest` tag for CUDA images — this would break the versioning contract and produce unpredictable behavior across installs.

**Instead:** Pin to explicit semver `DOCLING_SERVE_CUDA_VERSION=v1.14.3` (same version as CPU). Use `quay.io/docling-project/docling-serve-cu128:${DOCLING_SERVE_CUDA_VERSION}`.

---

### Anti-Pattern 4: Unconditional `docker manifest inspect` in CI/Offline Mode

**What:** Running pre-pull validation unconditionally, including in offline mode or CI environments with no registry access.

**Why bad:** In offline mode there is no registry connectivity by design. In CI, rate limiting or private registries cause false failures.

**Instead:** Skip validation when `DEPLOY_PROFILE=offline`. Provide `SKIP_IMAGE_VALIDATION=true` escape hatch for CI.

---

### Anti-Pattern 5: Blocking Dry-Run on Wizard

**What:** Skipping wizard in dry-run mode, using defaults everywhere.

**Why bad:** The value of `--dry-run` is seeing what _your chosen configuration_ would do. Running with defaults silently misleads users who are planning a non-default deployment.

**Instead:** Wizard runs normally. `--dry-run` only suppresses write operations, not read/decision operations.

---

## Scalability Considerations

| Concern | Single node (current) | With DB-GPT + Open Notebook |
|---------|----------------------|----------------------------|
| Container count | 23-34 | 25-37 (+2-3 optional) |
| Memory overhead | ~16-24 GB (with GPU services) | +1.5 GB (DB-GPT SQLite) / +1.5 GB (SurrealDB + Open Notebook) |
| Port exposure | 80, 443, 3000 (+ 9443, 3001 when admin_ui) | +5670 (DB-GPT) / +8502 (Open Notebook) |
| Disk (models) | Per Ollama/vLLM model | Docling OCR models: +500MB-2GB |
| Docker Compose start time | ~5-10 min cold | Unchanged for optional-off profiles |

---

## Integration Checklist per Feature

### DB-GPT
- [ ] `docker-compose.yml` — new `dbgpt` profile service block
- [ ] `versions.env` — `DBGPT_VERSION`
- [ ] `templates/nginx.conf.template` — server block port 5670 with `#__DBGPT__` conditional prefix pattern
- [ ] `lib/compose.sh` — `build_compose_profiles()`: add dbgpt condition
- [ ] `lib/wizard.sh` — ENABLE_DBGPT question
- [ ] `lib/config.sh` — write DBGPT_* vars to .env
- [ ] `scripts/update.sh` — NAME_TO_VERSION_KEY + NAME_TO_SERVICES
- [ ] `scripts/agmind.sh` — status endpoint display
- [ ] `templates/release-manifest.json` — dbgpt image entry

### Open Notebook
- [ ] `docker-compose.yml` — `notebook` profile: surrealdb + open-notebook services
- [ ] `versions.env` — `OPEN_NOTEBOOK_VERSION`, `SURREALDB_VERSION`
- [ ] `templates/nginx.conf.template` — server block port 8502 with `#__NOTEBOOK__` conditional
- [ ] `lib/compose.sh` — `build_compose_profiles()`: add notebook condition
- [ ] `lib/wizard.sh` — ENABLE_NOTEBOOK question
- [ ] `lib/config.sh` — `OPEN_NOTEBOOK_ENCRYPTION_KEY` secret generation + SurrealDB creds
- [ ] `scripts/update.sh` — both components registered
- [ ] `scripts/agmind.sh` — status endpoint display
- [ ] `templates/release-manifest.json` — both image entries
- [ ] Document: SurrealDB credentials stored in credentials.txt

### Docling CUDA
- [ ] `versions.env` — `DOCLING_SERVE_CUDA_VERSION`
- [ ] `docker-compose.yml` — `DOCLING_IMAGE` env var substitution, GPU deploy block, new `agmind_docling_models` volume
- [ ] `lib/config.sh` — detect GPU + set DOCLING_IMAGE, DOCLING_USE_CUDA
- [ ] `lib/wizard.sh` — ENABLE_DOCLING_CUDA question (shown only when GPU detected + Docling selected)
- [ ] Investigate Russian OCR (MEDIUM risk, track as separate sub-task)

### Release Branch Workflow
- [ ] `scripts/update.sh` — `--branch`/`--main` flags, branch-based versions.env URL
- [ ] `templates/versions.env` — no change (is the source)
- [ ] GitHub: create `release` branch from current main, set as update source
- [ ] `install.sh` — no change needed (install always uses local installer files)
- [ ] Document: `agmind update` (stable) vs `agmind update --main` (bleeding edge)

### Pre-Pull Validation
- [ ] `lib/compose.sh` — `validate_images_exist()` function
- [ ] `lib/compose.sh` — call from `compose_pull()`
- [ ] `scripts/update.sh` — call before apply_update()
- [ ] Skip when `DEPLOY_PROFILE=offline`
- [ ] `SKIP_IMAGE_VALIDATION=true` env escape hatch

### `--dry-run`
- [ ] `install.sh` — `--dry-run` arg parser, export `DRY_RUN`
- [ ] `install.sh` — guards in each `phase_*` function (phases 4-10)
- [ ] Export `DRY_RUN` so lib functions can check if needed

---

## Confidence Assessment

| Area | Confidence | Source | Notes |
|------|------------|--------|-------|
| DB-GPT SQLite mode (no external DB) | HIGH | docs.dbgpt.cn quickstart | Explicit in official docs |
| DB-GPT port 5670, image tag | HIGH | hub.docker.com/r/eosphorosai/dbgpt | Confirmed |
| Open Notebook ports 8502/5055 | HIGH | GitHub lfnovo/open-notebook docker-compose.yml | Confirmed from official repo |
| SurrealDB v2 requirement | HIGH | open-notebook docker-compose.full.yml | Official repo |
| SURREAL_* env vars | HIGH | open-notebook official docs | Confirmed |
| Open Notebook: no stable pinned tag | MEDIUM | Docker Hub inspection not available | Needs verification at implementation time |
| Docling CUDA image at quay.io | HIGH | deepwiki + GitHub issues confirming quay.io/docling-project/docling-serve-cu128 | Registry is quay.io not ghcr.io |
| Docling Russian OCR via env var | LOW | GitHub issue #434 indicates RapidOCR defaults to Chinese; workaround unclear | Needs deeper research at implementation phase |
| `docker manifest inspect` validation | HIGH | Docker official docs, standard pattern | Well-established approach |
| Branch-based versions.env fetch | HIGH | Standard GitHub raw content URL pattern | raw.githubusercontent.com always available |
| --dry-run phase-guard pattern | HIGH | Well-established bash pattern | No external dependencies |

---

## Sources

- DB-GPT Docker Compose: [github.com/eosphoros-ai/DB-GPT/blob/main/docker-compose.yml](https://github.com/eosphoros-ai/DB-GPT/blob/main/docker-compose.yml)
- DB-GPT official docs: [docs.dbgpt.cn/docs/installation/docker_compose/](http://docs.dbgpt.cn/docs/installation/docker_compose/)
- DB-GPT Docker Hub: [hub.docker.com/r/eosphorosai/dbgpt](https://hub.docker.com/r/eosphorosai/dbgpt)
- Open Notebook GitHub: [github.com/lfnovo/open-notebook](https://github.com/lfnovo/open-notebook)
- Open Notebook docker-compose.full.yml: [github.com/lfnovo/open-notebook/blob/main/docker-compose.full.yml](https://github.com/lfnovo/open-notebook/blob/main/docker-compose.full.yml)
- Open Notebook Docker Hub: [hub.docker.com/r/lfnovo/open_notebook](https://hub.docker.com/r/lfnovo/open_notebook)
- Docling CUDA container images: [deepwiki.com/docling-project/docling-serve/6.1-container-images](https://deepwiki.com/docling-project/docling-serve/6.1-container-images)
- Docling RapidOCR GPU issue #434: [github.com/docling-project/docling-serve/issues/434](https://github.com/docling-project/docling-serve/issues/434)
- docker manifest inspect: [docs.docker.com/reference/cli/docker/manifest/inspect/](https://docs.docker.com/reference/cli/docker/manifest/inspect/)
- SurrealDB Docker: [hub.docker.com/r/surrealdb/surrealdb](https://hub.docker.com/r/surrealdb/surrealdb)
