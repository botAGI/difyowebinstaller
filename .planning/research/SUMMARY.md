# Project Research Summary

**Project:** AGmind Installer v2.7
**Domain:** Enterprise AI stack installer — Docker Compose orchestration with optional services
**Researched:** 2026-03-29
**Confidence:** MEDIUM-HIGH

## Executive Summary

AGmind v2.7 is a targeted feature release that extends an already-mature (v2.6) enterprise RAG installer without rebuilding its foundation. The existing 10-phase install, 4 deployment profiles, and Compose-profiles-per-provider model are proven; all v2.7 changes are additive. Research confirms a clear priority order: infrastructure-hardening features (release branch workflow, pre-pull validation, Dify init fallback, Docling CUDA) must land before optional services (DB-GPT, Open Notebook), because the infrastructure changes create the testing and update foundations that optional services rely on. The `--dry-run` mode is the highest-effort, lowest-ROI feature and should remain deferred unless explicitly scoped to preflight-only output.

The recommended approach centres on three design principles that emerge consistently across all four research areas: (1) reuse existing infrastructure rather than adding new dependencies — DB-GPT uses SQLite, not MySQL; Open Notebook requires its own SurrealDB sidecar, not shared Postgres; both route through the existing nginx; (2) every new service is opt-in via COMPOSE_PROFILE and defaults to disabled to protect memory budgets on single-node hosts; (3) image selection is always driven by pinned versions in `versions.env` — the Docling CUDA images intentionally have no `:latest` tag, and `open_notebook` should be resolved to an explicit semver tag at release build time.

The principal risks are concentrated in two areas. The release branch update workflow introduces a stateful git repo on the server for the first time: `git reset --hard` would silently destroy user-customised configs, and installer-generated files not covered by `.gitignore` will cause `git pull` to refuse. Both failure modes must be addressed before the feature ships. The second risk cluster surrounds pre-pull validation: `docker manifest inspect` has a known bug that requests push scope and breaks read-only tokens (docker/cli#4345), and its GET requests consume Docker Hub rate-limit quota. The mitigation — use HTTP HEAD requests to the registry API — is well-understood and should be implemented from the start, not as a follow-up fix.

---

## Key Findings

### Recommended Stack

All new stack additions are additive overlays on top of the existing v2.6 base. No existing service is replaced or significantly changed.

**Core new technologies:**

- `eosphorosai/dbgpt-openai:v0.7.4` — DB-GPT proxy-only CPU image (~3 GB vs 10+ GB for the full variant); uses existing Ollama endpoint as LLM backend; stores metadata in SQLite (no new DB engine required)
- `lfnovo/open_notebook:v1.4.0` — Open-source NotebookLM alternative; requires `surrealdb/surrealdb:v2.3.1` sidecar (RocksDB-backed, not a Postgres-compatible protocol)
- `quay.io/docling-project/docling-serve-cu128:1.15.0` — CUDA 12.8 variant of existing Docling service; registry is `quay.io` not `ghcr.io`; no `:latest` tag exists for CUDA variants
- Git release branch workflow — pure Bash + Git; no new dependencies; `git reset --hard origin/release` is intentional for determinism in automated scripts
- `docker manifest inspect` (Docker 24+, no experimental flag needed) — used for pre-pull validation; graduated from experimental in Docker 24.0

**Critical version constraints:**
- SurrealDB: pin to v2.3.1, NOT v3.0.0 (too new; open-notebook not validated against it)
- Docling CUDA: `cu128` preferred over `cu124` (memory leak issue #233) and `cu126` (GLIBC_2.38 missing on some hosts, issue #2386)
- DB-GPT: `dbgpt-openai` image only — the full `dbgpt` image is 15+ GB and embeds its own LLM weights that conflict with the existing Ollama VRAM budget

### Expected Features

**Must have (table stakes):**
- Release branch install/update — stable installs must not pull from `main`; this is a trust signal for enterprise operators
- Pre-pull image validation — prevents mid-install failures from missing tags; current tarball-based update has no equivalent guard
- Dify init cron fallback — fixes known `MIGRATION_ENABLED` race condition documented in GitHub issues #14620 and #17927
- Docling CUDA image — GPU users already have NVIDIA toolkit from vLLM/TEI; 4-6x speedup makes this a correctness issue, not a nice-to-have

**Should have (differentiators):**
- DB-GPT optional service (`COMPOSE_PROFILE=dbgpt`) — text-to-SQL without manual setup; unique in the AGmind ecosystem
- Open Notebook optional service (`COMPOSE_PROFILE=notebook`) — 100% local NotebookLM alternative; significant enterprise value
- Full release notes in `agmind update --check` — extends existing `fetch_release_info()` with minimal effort
- Telegram HTML escape hardening — one-liner fix for silent notification drops on container names with angle brackets

**Defer (keep out of v2.7):**
- `install.sh --dry-run` full simulation — touches 40-60 call sites across 10 lib files; scope only to preflight output if included at all
- Docling Russian OCR via EasyOCR — works but adds ~100 MB model download on first use; needs explicit wizard opt-in; track as separate sub-task
- SurrealDB v3.0.0 upgrade — wait for open-notebook to validate compatibility

### Architecture Approach

The architecture is an extension of the existing modular shell library pattern: `install.sh` orchestrates 10 phases by calling functions from `lib/*.sh`, new services are added as Compose profile blocks in `templates/docker-compose.yml`, and day-2 operations go through `scripts/agmind.sh` and `scripts/update.sh`. The key architectural decisions for v2.7 are: (1) DB-GPT and Open Notebook must use **dedicated nginx server blocks on separate ports** (5670 and 8502 respectively) — path-based proxying breaks both applications due to root-relative asset paths and Streamlit WebSocket URL generation; (2) Docling image selection should use a single service with `DOCLING_IMAGE` environment variable set by `config.sh` based on GPU detection, rather than two separate service definitions; (3) pre-pull validation lives in `lib/compose.sh` as `validate_images_exist()` and is called from both `compose_pull()` and `update.sh apply_update()`.

**Major components touched by v2.7:**
1. `templates/docker-compose.yml` — adds dbgpt, surrealdb, open-notebook service blocks and agmind_docling_models volume
2. `scripts/update.sh` — release branch fetch replaces GitHub Releases API asset download; adds NAME_TO_VERSION_KEY entries for new services
3. `lib/compose.sh` — `validate_images_exist()` function; `build_compose_profiles()` extended for dbgpt and notebook
4. `lib/config.sh` — DOCLING_IMAGE selection logic; OPEN_NOTEBOOK_ENCRYPTION_KEY secret generation
5. `lib/wizard.sh` — ENABLE_DBGPT, ENABLE_NOTEBOOK, ENABLE_DOCLING_CUDA questions
6. `templates/nginx.conf.template` — server blocks for ports 5670 and 8502 with `#__DBGPT__` / `#__NOTEBOOK__` conditional prefix pattern

### Critical Pitfalls

1. **git pull overwrites user-customised files (C-01)** — Use `git stash push` before pull; restore after; audit `.gitignore` to ensure all installer-generated output files are listed before shipping. Never use `git reset --hard` without explicit stash/restore wrapper. This is the highest-risk change in all of v2.7.

2. **`docker manifest inspect` requires push scope, breaks read-only tokens (C-02)** — Confirmed Docker CLI bug (docker/cli#4345). Use HTTP HEAD requests to registry API instead (`curl -s -o /dev/null -w "%{http_code}" -X HEAD ...`). Treat manifest check failures as advisory warnings, never as install-blocking errors.

3. **Docling CUDA image selected for wrong host CUDA version (C-03)** — Map `DETECTED_GPU_COMPUTE` (sm version) to required minimum CUDA version before selecting image. Always fall back to CPU image if compute capability cannot be determined. Separately check that NVIDIA Container Toolkit is installed (`docker info | grep nvidia` in runtime list) — nvidia-smi working does not imply container GPU passthrough works (N-06).

4. **Offline bundle missing new service images (C-04)** — `build-offline-bundle.sh` must explicitly include all optional profile image variants (dbgpt, notebook, docling-cuda). Bundle builder currently iterates active profiles only; new services need explicit addition.

5. **Installer-generated files in tracked git paths block `git pull` (M-03)** — After install, `git status` in INSTALL_DIR must be clean. All paths written by `install.sh` (`.env`, `credentials.txt`, phase checkpoints, docker config) must be in `.gitignore` before the release branch feature ships.

---

## Implications for Roadmap

Based on combined research, the suggested phase structure follows the dependency order identified in ARCHITECTURE.md: infrastructure before services, simpler services before complex ones.

### Phase 1: Release Branch Workflow and Update Infrastructure

**Rationale:** Switching from GitHub Releases tarball to git branch fetch is a prerequisite for reliable updates of all subsequent features. Must land first so that all future `agmind update` calls use the new path. Also unblocks the testing workflow — developers can push to `release` branch and verify update behaviour before optional services are merged.

**Delivers:** `agmind update` fetches `versions.env` from `raw.githubusercontent.com/{branch}/templates/versions.env`; `--main` flag for bleeding-edge testing; full release notes displayed in `agmind update --check`; GitHub API rate-limit error handled explicitly.

**Features addressed:** Release branch install/update, full release notes in `--check`, Telegram HTML escape hardening (low-effort, bundle with this phase).

**Pitfalls to avoid:** C-01 (user file overwrite — stash/restore pattern), M-03 (installer outputs in .gitignore), N-04 (GitHub API rate limit on --check).

**Research flag:** Standard git patterns — no phase-specific research needed. Implementation risk is in `.gitignore` audit, not in the technique.

---

### Phase 2: Pre-Pull Validation

**Rationale:** Depends on Phase 1 completing the update.sh refactor (validation is called from `apply_update()`). Must exist before optional services are added, so all new image entries in `versions.env` are validated on first pull.

**Delivers:** `validate_images_exist()` in `lib/compose.sh`; called before `compose_pull()` and before `apply_update()`; skipped when `DEPLOY_PROFILE=offline`; `SKIP_IMAGE_VALIDATION=true` escape hatch for CI.

**Features addressed:** Pre-pull image validation.

**Pitfalls to avoid:** C-02 (manifest inspect push-scope bug — use HEAD requests), M-04 (GET requests count against Docker Hub rate limit quota — HEAD requests are free).

**Research flag:** Known pitfall with confirmed workaround. No additional research needed; implement with HEAD-based approach from day one.

---

### Phase 3: Docling CUDA and GPU Hardening

**Rationale:** Extends an existing service with low structural risk — only image selection logic and a new volume change. Must precede optional services because it validates that the GPU detection → image selection pattern works correctly, and this pattern is referenced in DB-GPT and Open Notebook wizard flows.

**Delivers:** CUDA image variant selected by `config.sh` based on `GPU_DETECTED` and `DETECTED_GPU_COMPUTE`; `DOCLING_IMAGE` env var drives single compose service; `agmind_docling_models` persistent volume added; GPU deploy block gated behind `DOCLING_ENABLE_GPU=true`; CPU fallback when no GPU or compute capability uncertain.

**Features addressed:** Docling CUDA image, GPU hardening (separate NVIDIA Container Toolkit check).

**Pitfalls to avoid:** C-03 (wrong CUDA version — sm-to-CUDA mapping table in detect.sh), N-06 (nvidia-smi vs container toolkit — check `docker info` runtime list), N-01 (HF model download at runtime — `TRANSFORMERS_OFFLINE=1` + preload in install phase).

**Research flag:** Russian OCR via EasyOCR has LOW confidence (GitHub issue #434 confirms RapidOCR GPU limitation but workaround path unclear). Track as separate sub-task; do NOT include in this phase.

---

### Phase 4: Dify Init Race Condition Fix

**Rationale:** Independent of Phases 1-3 but logically grouped here as it fixes an existing reliability issue before new services add more startup complexity. Quick win: `restart: on-failure:3` on api + worker services, plus lock file + sentinel file for cron retry.

**Delivers:** `restart: on-failure:3` on Dify `api` and `worker` services; cron fallback with flock lock file and `/opt/agmind/.dify-init-complete` sentinel; retry interval >= 60 seconds; attempt log at `/opt/agmind/logs/dify-init.log`.

**Features addressed:** Dify init cron fallback.

**Pitfalls to avoid:** M-06 (double init race — lock file prevents concurrent execution).

**Research flag:** Pattern is well-understood; exact fix needs verification against AGmind's specific compose setup. Low-cost to test before shipping.

---

### Phase 5: DB-GPT Optional Service

**Rationale:** First new optional service. No external DB dependency (SQLite) makes it the simpler of the two optional services. Establishes the pattern for COMPOSE_PROFILE optional services that Open Notebook will follow.

**Delivers:** `dbgpt` compose profile with `eosphorosai/dbgpt-openai:v0.7.4`; dedicated nginx server block on port 5670; `agmind_dbgpt_data` volume; wizard question `ENABLE_DBGPT`; `DBGPT_VERSION` in versions.env; entries in `update.sh` NAME_TO_VERSION_KEY and NAME_TO_SERVICES; `agmind status` shows DB-GPT endpoint when enabled.

**Features addressed:** DB-GPT as optional service.

**Pitfalls to avoid:** M-01 (port conflicts — port audit before adding; DB-GPT uses SQLite not shared Postgres per research), M-02 (cross-profile depends_on — DB-GPT may only depend on always-on core services), N-05 (must add to update.sh maps).

**Research flag:** Full DB-GPT environment variable spec needs verification against official `docker-compose.yml` at implementation time. MEDIUM confidence on exact env var names — verify before coding.

---

### Phase 6: Open Notebook Optional Service

**Rationale:** Most complex new service: requires SurrealDB sidecar, secret generation change, Streamlit WebSocket routing, and SURREAL_* credential management. Must be last among new services because it touches the most files and introduces the most new failure modes.

**Delivers:** `notebook` compose profile with `lfnovo/open_notebook:v1.4.0` + `surrealdb/surrealdb:v2.3.1` sidecar; dedicated nginx server block on port 8502 with WebSocket upgrade; `agmind_notebook_data` and `agmind_surrealdb_data` volumes; `OPEN_NOTEBOOK_ENCRYPTION_KEY` generated by `_generate_secrets()` in config.sh; SURREAL_* credentials stored in credentials.txt; wizard question `ENABLE_NOTEBOOK`; both components in update.sh maps.

**Features addressed:** Open Notebook as optional service.

**Pitfalls to avoid:** M-02 (cross-profile depends_on — surrealdb and open-notebook are in the same notebook profile, so internal depends_on is valid; neither should depend on services from other optional profiles), N-02 (migration race — `UVICORN_WORKERS=1` for initial startup), N-05 (both components in update.sh maps).

**Research flag:** Open Notebook has no stable pinned Docker tag beyond `v1-latest` on Docker Hub as of research date. Resolve to explicit digest or explicit release tag at build time. MEDIUM confidence on tag availability — verify before publishing release.

---

### Phase 7: Offline Bundle and E2E Testing

**Rationale:** Validates the full install stack including all new optional services. Offline bundle builder must be updated to include all new image variants before this phase. Cannot be run meaningfully until Phases 5-6 are complete.

**Delivers:** Updated `build-offline-bundle.sh` including dbgpt, open-notebook, surrealdb, and docling-cuda images; offline install validation for all new services; `--offline-validate` flag checking all required images present before start.

**Features addressed:** Offline bundle compatibility for all v2.7 additions.

**Pitfalls to avoid:** C-04 (bundle missing new service images — explicit image list, not profile-derived), N-01 (HF model download at runtime in offline mode — verify `TRANSFORMERS_OFFLINE=1` propagates to Docling container).

**Research flag:** Offline bundle testing always requires a dedicated test environment with no internet access. Plan for this infrastructure need.

---

### Phase Ordering Rationale

- Phases 1-2 are infrastructure prerequisites: git update path and image validation must exist before optional services add more images to validate and update
- Phase 3 (Docling CUDA) before optional services because its GPU detection pattern is referenced in wizard flows for DB-GPT and Open Notebook
- Phase 4 (Dify fix) is independent but logically placed before new services increase startup complexity
- Phase 5 before Phase 6 because DB-GPT's simpler integration establishes the COMPOSE_PROFILE optional service pattern
- Phase 7 (bundle testing) necessarily last — validates the complete v2.7 stack

### Research Flags

Phases needing deeper research during planning:
- **Phase 5 (DB-GPT):** Full environment variable spec (MEDIUM confidence — verify against upstream docker-compose.yml before implementation)
- **Phase 6 (Open Notebook):** Stable Docker tag availability; SurrealDB healthcheck pattern (MEDIUM confidence — verify at implementation time)
- **Phase 3 (Docling CUDA):** Russian OCR via EasyOCR has LOW confidence — treat as separate tracked task, not part of this roadmap

Phases with well-documented patterns (skip research-phase):
- **Phase 1 (Release branch workflow):** Standard git shallow clone + raw GitHub URL pattern
- **Phase 2 (Pre-pull validation):** Well-documented Docker CLI feature; HEAD-request workaround is standard
- **Phase 4 (Dify init fallback):** Lock file + sentinel pattern is standard Bash idiom
- **Phase 7 (Offline bundle):** Extends existing bundle builder with explicit image list

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM-HIGH | DB-GPT and Open Notebook image names confirmed via Docker Hub; exact env var specs need verification at implementation time; Docling CUDA registry (quay.io) and cu128 recommendation are HIGH confidence |
| Features | HIGH | Feature boundaries clearly drawn from upstream docs and GitHub issues; MVP priority order is unambiguous based on complexity and dependency analysis |
| Architecture | HIGH | All integration patterns (separate nginx server blocks, single DOCLING_IMAGE env var, validate_images_exist placement) are confirmed against existing codebase structure and upstream application constraints |
| Pitfalls | HIGH | Two critical pitfalls (C-01, C-02) confirmed against official GitHub issues and Docker docs; CUDA version mismatch (C-03) confirmed via docling issue #2528; offline bundle gap (C-04) is structural, not speculative |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **DB-GPT exact environment variables:** Research names `LLM_MODEL_SERVICE`, `DB_GPT_DATA_DIR`, `OLLAMA_API_BASE` but notes MEDIUM confidence; verify against `github.com/eosphoros-ai/DB-GPT/blob/main/docker-compose.yml` before implementing Phase 5
- **Open Notebook pinned tag:** `v1.4.0` confirmed as latest release but Docker Hub tag availability not directly inspected; verify tag exists before adding to versions.env
- **Docling Russian OCR:** RapidOCR GPU limitation confirmed (issue #434) but the EasyOCR workaround path is LOW confidence; do not include in roadmap — track as a future sub-task
- **SurrealDB healthcheck pattern:** Compose `service_healthy` condition requires a healthcheck in the surrealdb service definition; exact command needs testing (`surreal is-ready --conn ws://localhost:8000 --user root --pass root`)
- **`.gitignore` audit:** All paths written by install.sh must be confirmed absent from the release branch tracking before Phase 1 ships; this is a code audit task, not research

---

## Sources

### Primary (HIGH confidence)
- docker/cli#4345 — `docker manifest inspect` push-scope bug (confirmed open as of 2025)
- Docker Hub official docs — pull rate limits, HEAD request behaviour
- docling-project/docling#2528 — CUDA version mismatch confirmed issue
- docling-project/docling-serve official docs — cu128 recommendation, quay.io registry
- lfnovo/open-notebook GitHub — port layout (8502/5055), SurrealDB dependency, env vars
- eosphoros-ai/DB-GPT Docker Hub and docs.dbgpt.cn — SQLite mode, port 5670, image variants
- Docker manifest inspect official docs — command behaviour, experimental graduation in Docker 24.0

### Secondary (MEDIUM confidence)
- Docker Hub inspection — Open Notebook tag availability (not directly verified in research)
- docling-project/docling-serve#434 — RapidOCR GPU issue (confirmed) / EasyOCR workaround path (inferred)
- AWS and Docker Hub Limits post — April 2025 rate limit changes
- AGmind v2.6 codebase structure — existing lib/ function names and patterns

### Tertiary (LOW confidence)
- Hacker News discussion — dry-run scope guidance (community wisdom, not technical docs)
- UVICORN_WORKERS Open WebUI migration pitfalls — applied by analogy to Open Notebook

---
*Research completed: 2026-03-29*
*Ready for roadmap: yes*
