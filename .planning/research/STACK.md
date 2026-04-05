# Technology Stack — v2.7 New Features

**Project:** AGmind Installer
**Researched:** 2026-03-29
**Scope:** Additions only — existing stack (Dify, Open WebUI, Ollama/vLLM/TEI, Weaviate/Qdrant,
Nginx, Authelia, Squid, monitoring) is NOT re-researched here.

---

## Recommended Stack Additions

### 1. DB-GPT (optional service, COMPOSE_PROFILE=dbgpt)

| Technology | Version / Image | Purpose | Why |
|---|---|---|---|
| `eosphorosai/dbgpt-openai` | `latest` (CPU-only proxy variant) | Agentic SQL/data assistant via external LLM API | Lightweight — no GPU needed when proxying to Dify/Ollama endpoints already in the stack |
| `eosphorosai/dbgpt` | `v0.7.4` (full variant, GPU profile) | Full DB-GPT with local model support | Only if user requests GPU-local mode; separate compose override |
| MySQL 8.0 (existing Postgres preferred) | reuse AGmind `db` (Postgres 15) | DB-GPT metadata store | DB-GPT supports Postgres as datasource — avoids adding MySQL dependency |

**Integration notes:**
- DB-GPT v0.7 is the current stable series (confirmed via Docker Hub and docs.dbgpt.cn). Uses `uv` for package management internally; this is irrelevant to the installer.
- Two official images: `dbgpt` (full, ~10 GB, needs local LLM or GPU) and `dbgpt-openai` (proxy-only, ~3 GB, CPU). AGmind should deploy `dbgpt-openai` by default, pointing to the existing Dify/Ollama endpoint via `LLM_MODEL_DRIVER=proxy/openai` and `PROXY_SERVER_URL=http://ollama:11434/v1`.
- Default compose in upstream uses MySQL — override to use existing Postgres 15 container to avoid adding a second database engine.
- Exposes port 5670 (web UI). Map behind existing nginx; do NOT expose directly.
- COMPOSE_PROFILE=`dbgpt` — opt-in only, not part of base install.

**Confidence: MEDIUM** — Version v0.7.4 confirmed via Docker Hub search results; image size and Postgres support inferred from official docs + GitHub (not directly fetched due to tool restrictions). Verify `eosphorosai/dbgpt-openai:v0.7.4` tag exists on Docker Hub before pinning.

---

### 2. Open Notebook (optional service, COMPOSE_PROFILE=notebook)

| Technology | Version / Image | Purpose | Why |
|---|---|---|---|
| `lfnovo/open_notebook` | `v1-latest` (multi-container) | Open-source NotebookLM replacement | Documented stable Docker tag; v1.4.0 released 2026-01-14 |
| `surrealdb/surrealdb` | `v2.3.1` | Graph/document database for Open Notebook | Required dependency of open-notebook; v2.3.1 is last stable v2.x (v3.0.0 dropped recently — avoid until open-notebook upgrades) |

**Integration notes:**
- Open Notebook provides two separate ports: **8502** (Next.js frontend), **5055** (REST API). Both routed through nginx.
- SurrealDB listens on **8000** internally — never expose externally.
- SurrealDB data volume: `surreal_data:/mydata` — must be a named volume in AGmind compose to survive updates.
- AI provider API keys are stored in the open-notebook Settings UI (encrypted with `OPEN_NOTEBOOK_ENCRYPTION_KEY`), NOT in environment files. Set the encryption key in AGmind secrets; leave provider keys empty — user configures via UI.
- Open Notebook supports Ollama out of the box — set `OLLAMA_BASE_URL=http://ollama:11434` so it can use the existing Ollama service.
- COMPOSE_PROFILE=`notebook` — opt-in only.
- `v1-latest` tag is semi-stable (tracks v1.x releases). For AGmind's pin-everything policy: resolve to a specific digest at release time or use explicit release tag (e.g., `v1.4.0`) when available on Docker Hub.

**Confidence: MEDIUM** — Port layout (8502/5055/8000), SurrealDB dependency, and v1.4.0 release date confirmed via multiple sources. SurrealDB version recommendation (v2.3.1 over v3.0.0) is a precautionary inference pending open-notebook's own upgrade path.

---

### 3. Docling — CUDA image switch

| Technology | Current Version | New Version / Image | Why |
|---|---|---|---|
| `quay.io/docling-project/docling-serve` | `v1.14.3` (CPU default) | `quay.io/docling-project/docling-serve-cu128:1.15.0` (GPU) | CUDA 12.8 is latest stable PyTorch-supported CUDA in docling-serve; cu128 has no GLIBC issues reported unlike cu124/cu126 |

**Integration notes:**
- CUDA images from docling-project intentionally have NO `latest` tag — always pin explicit semver (e.g., `1.15.0`). The CPU image has `latest`; the CUDA variant does not.
- Existing `DOCLING_SERVE_VERSION=v1.14.3` in `versions.env` uses CPU image. Switch variable to `1.15.0` and add `DOCLING_CUDA_IMAGE=quay.io/docling-project/docling-serve-cu128` controlled by the existing `docling` compose profile.
- Models are pre-baked into the image at `/opt/app-root/src/.cache/docling/models` — no separate model download step needed. However, a persistent volume (`docling_models`) should be mounted to that path to avoid re-extraction on container restart (already done in v2.6 per PROJECT.md hotfixes).
- Russian OCR: Docling uses EasyOCR under the hood. GPU variant accelerates EasyOCR. No additional image or package needed — included in `docling-serve-cu128`.
- GPU passthrough: add `deploy.resources.reservations.devices` with `driver: nvidia` to the docling service when CUDA image is selected. Gate this behind `DOCLING_ENABLE_GPU=true` env var checked in install wizard.
- Keep CPU image as fallback when no GPU detected (wizard already has VRAM guard logic).

**Confidence: HIGH** — Confirmed via docling-project GitHub and official documentation. cu128 recommended over cu124/cu126 based on issue tracker findings. v1.15.0 confirmed as current stable from PyPI and GitHub.

---

### 4. Git-based update mechanism (release branch workflow)

| Component | Mechanism | Why |
|---|---|---|
| Clone target | `git clone --single-branch --branch release --depth=1 <repo>` | Shallow clone of release branch only; faster, smaller |
| Update pull | `git fetch origin release && git reset --hard origin/release` | Deterministic — no merge conflicts, no dirty state |
| Dev override | `--main` flag → `git fetch origin main && git reset --hard origin/main` | For operators testing pre-release |
| Branch env var | `AGMIND_UPDATE_BRANCH=release` (default) in install config | Allows override without code changes |

**Integration notes:**
- This is pure Bash + Git — no new dependencies. Git is already a system requirement (used for offline bundle fetch).
- `git reset --hard` is intentional: installer scripts must NOT have local modifications tracked by git. User config lives in `.env`/`credentials.txt` outside the repo working tree.
- `agmind update` currently pulls a tarball from GitHub Releases. New behavior: prefer git pull from release branch; fall back to tarball if git is not initialized (upgrades from v2.6 that used tarball method).
- Migration path: on first `agmind update` after v2.7, detect whether install dir is a git repo (`git -C $INSTALL_DIR rev-parse --git-dir 2>/dev/null`). If not, perform initial `git clone` into temp dir, copy scripts, then track as git repo going forward.
- Rollback: retain existing tarball snapshot mechanism as rollback point. Git branch switching is forward-only in the automated path.

**Confidence: HIGH** — Git shallow clone/reset pattern is standard, well-documented, widely used in installer scripts. No library research needed — pure shell.

---

### 5. Pre-pull image validation via `docker manifest inspect`

| Component | Tool | Why |
|---|---|---|
| Image existence check | `docker manifest inspect <image>:<tag>` | Returns exit code 0 if image/tag exists in registry, non-zero if not |
| Experimental flag | None required (Docker 24+) | `docker manifest inspect` graduated from experimental in Docker 24.0; all supported Ubuntu/Debian hosts will have Docker 25+ |

**Integration notes:**
- Pattern for Bash validation function:
  ```bash
  validate_image() {
    local image="$1"
    if ! docker manifest inspect "$image" > /dev/null 2>&1; then
      log_error "Image not found in registry: $image"
      return 1
    fi
  }
  ```
- Call before each `docker pull` phase in install.sh and before `agmind update` applies new versions.env.
- Private/air-gapped registries: skip manifest check if `AGMIND_REGISTRY_OFFLINE=true` (offline profile already has this concept).
- Rate limiting: Docker Hub unauthenticated manifest inspect is subject to pull rate limits (same as pull). For installs with many images (23-34 containers), do validation only for changed images on update, not full validation on fresh install (fresh install validates implicitly when pulling).
- Authentication: `docker manifest inspect` respects credentials from `docker login`. No special handling needed.

**Confidence: HIGH** — Command behavior and graduation from experimental confirmed via Docker docs (Docker 24.0 release notes reference) and multiple community sources.

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|---|---|---|---|
| DB-GPT image | `dbgpt-openai` (proxy, CPU) | `dbgpt` (full, local LLM) | Full image is 10+ GB, requires GPU; AGmind already serves LLMs via Ollama/vLLM — redundant |
| DB-GPT database | Reuse existing Postgres 15 | Add MySQL 8.0 | Adding MySQL doubles DB infrastructure; DB-GPT supports Postgres |
| Open Notebook database | SurrealDB v2.3.1 | SurrealDB v3.0.0 | v3.0.0 very recently released; open-notebook not yet tested against it; v2.3.x is proven |
| Open Notebook image tag | `v1.4.0` explicit | `v1-latest` | AGmind pins all images; `v1-latest` drifts — resolve to explicit tag at release build time |
| Docling CUDA base | cu128 | cu124, cu126 | cu124 has memory leak reports (issue #233 on docling-serve); cu126 has GLIBC_2.38 not found on some hosts (issue #2386) |
| Git update mechanism | `git reset --hard origin/release` | `git pull --ff-only` | `--ff-only` fails if local state diverges; reset --hard is deterministic for automated scripts |
| Image validation | `docker manifest inspect` | `skopeo inspect` | skopeo is not a standard package on Ubuntu/Debian; manifest inspect requires only Docker CLI already present |

---

## versions.env Additions

```bash
# --- Optional Services ---
DBGPT_VERSION=v0.7.4
DBGPT_IMAGE=eosphorosai/dbgpt-openai

OPEN_NOTEBOOK_VERSION=v1.4.0
OPEN_NOTEBOOK_IMAGE=lfnovo/open_notebook
SURREALDB_VERSION=v2.3.1

# --- Docling CUDA (replaces CPU when docling+GPU profile active) ---
DOCLING_SERVE_CUDA_VERSION=1.15.0
DOCLING_SERVE_CUDA_IMAGE=quay.io/docling-project/docling-serve-cu128

# --- Update Branch ---
AGMIND_UPDATE_BRANCH=release
```

Note: `DOCLING_SERVE_VERSION=v1.14.3` remains the CPU default. The install wizard selects
between `DOCLING_SERVE_VERSION` (CPU) and `DOCLING_SERVE_CUDA_VERSION` (GPU) based on
detected VRAM and user confirmation.

---

## What NOT to Add

| Component | Reason |
|---|---|
| MySQL / MariaDB | DB-GPT can use existing Postgres; adding MySQL is scope creep and resource waste |
| Redis for Open Notebook | open-notebook does not require Redis (uses SurrealDB for all storage) |
| Separate nginx instance for new services | Route through existing nginx via upstream blocks |
| SurrealDB v3.0.0 | Too new; open-notebook not validated against it |
| `skopeo` | Not a standard system package; `docker manifest inspect` covers the same use case |
| `manifest-tool` (estesp) | Third-party binary; adds installation complexity for no benefit over native Docker CLI |

---

## Sources

- DB-GPT Docker Hub: [eosphorosai/dbgpt](https://hub.docker.com/r/eosphorosai/dbgpt), [eosphorosai/dbgpt-openai](https://hub.docker.com/r/eosphorosai/dbgpt-openai)
- DB-GPT docs: [Docker Deployment](http://docs.dbgpt.cn/docs/installation/docker/)
- DB-GPT GitHub: [eosphoros-ai/DB-GPT](https://github.com/eosphoros-ai/DB-GPT)
- Open Notebook GitHub: [lfnovo/open-notebook](https://github.com/lfnovo/open-notebook)
- Open Notebook Docker Hub: [lfnovo/open_notebook](https://hub.docker.com/r/lfnovo/open_notebook)
- Open Notebook Docker Compose: [docker-compose.md](https://github.com/lfnovo/open-notebook/blob/main/docs/1-INSTALLATION/docker-compose.md)
- SurrealDB Docker Hub: [surrealdb/surrealdb](https://hub.docker.com/r/surrealdb/surrealdb)
- Docling GPU docs: [GPU support](https://docling-project.github.io/docling/usage/gpu/)
- Docling serve GitHub: [docling-project/docling-serve](https://github.com/docling-project/docling-serve)
- Docling cu128 GLIBC issue: [#2386](https://github.com/docling-project/docling/issues/2386)
- Docling cu124 memory leak: [#233](https://github.com/docling-project/docling-serve/issues/233)
- Docker manifest inspect docs: [docker manifest inspect](https://docs.docker.com/reference/cli/docker/manifest/inspect/)
- Git shallow clone: [git-clone docs](https://git-scm.com/docs/git-clone)
