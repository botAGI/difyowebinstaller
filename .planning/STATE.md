---
gsd_state_version: 1.0
milestone: v2.6
milestone_name: Install Stability + Update Robustness
status: Awaiting plan-phase
stopped_at: Completed 33-01-PLAN.md
last_updated: "2026-03-30T05:54:02.200Z"
last_activity: "2026-03-30 — Phase 33 Plan 01 complete: 5 optional service definitions + version pins + SearXNG config"
progress:
  total_phases: 9
  completed_phases: 5
  total_plans: 14
  completed_plans: 13
  percent: 93
---

# State: AGmind Installer v2.8

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-29)

**Core value:** One command installs, secures, and monitors a production-ready AI stack

**Current focus:** v2.8 — new services (LiteLLM, SearXNG, Open Notebook, DB-GPT, Crawl4AI) + wizard simplification

## Current Position

Phase: 33 (Optional Services — SearXNG, Open Notebook, DB-GPT, Crawl4AI) — Plan 01 complete
Plan: 01 done
Status: Awaiting plan-phase
Last activity: 2026-03-30 — Phase 33 Plan 01 complete: 5 optional service definitions + version pins + SearXNG config

Progress: `[█████████░] 93%`

## Performance Metrics

### Velocity (historical)

- v2.0 phases: 5 complete (13 plans)
- v2.1 phases: 4 complete (8 plans)
- v2.2 phases: 2 complete (4 plans)
- v2.3 phases: 4 complete (5 plans)
- v2.4 phases: 3 complete (3 plans)
- v2.5 phases: 6 complete (9 plans)
- v2.6 phases: 3 complete (5 plans)
- v2.7 phases: 3 complete (8 plans)
- v2.8 phases: 3 planned (2 complete)

## Accumulated Context

### Decisions

- v2.0: installer never touches Dify API (three-layer boundary)
- v2.0: credentials only in credentials.txt, never stdout
- v2.3: Phase 13 added VRAM guard in `_wizard_vllm_model()`
- v2.4: Phase 17 expanded vLLM model list to 16 models (Qwen3, MoE)
- v2.4: Phase 18 added `agmind gpu` subcommand (status/assign/auto)
- v2.5: TEI_VRAM_OFFSET=2 is readonly constant; effective_vram used in both interactive and NON_INTERACTIVE VRAM guards
- v2.5: Xinference orphan cleanup in update.sh on pre-v2.5 -> v2.5+ upgrades
- v2.5: Wizard step order: LLM grouped before VectorDB/ETL, VRAM summary only for vLLM
- v2.6: _parse_gpu_progress() uses docker compose logs --tail=1; 60s inactivity marks stalled
- v2.6: letsencrypt TLS: nginx starts with self-signed placeholder, certbot obtains real cert post-compose
- v2.6: Squid RFC1918: LAN/Offline allow, VPS/VPN block; 169.254.x always blocked
- v2.6: PG major upgrade guard blocks update unless --force
- v2.6: Post-rollback doctor --json logs to install.log; failure is warning not fatal
- v2.7: release branch created from main; release = stable, main = dev
- v2.7: pre-pull validation uses HTTP HEAD (not docker manifest inspect) — avoids push scope bug docker/cli#4345
- v2.7: installer-generated files (.env, credentials.txt, checkpoints) must be in .gitignore before Phase 28 ships
- v2.7: Docling CUDA = quay.io/docling-project/docling-serve-cu128 (cu128 preferred over cu124/cu126)
- v2.7: RLBL-03 scoped to preflight checks only (prereqs/ports/disk/DNS) — full dry-run deferred to v3.0 (UXPL-02)
- v2.8: NSVC-01 (DB-GPT) and NSVC-02 (Open Notebook) moved from v3.0 to v2.8 as optional services
- [Phase 28]: TEI container port is 80 (not 8080) — credentials.txt uses correct port
- [Phase 28]: Model provider host-access URLs omitted in credentials.txt — no ports published to host
- [Phase 28]: UPDATE_BRANCH defaults to 'release'; --main sets it to 'main' for one-time dev fetch
- [Phase 28]: versions.env fetched from raw.githubusercontent.com branch URL instead of GitHub release assets
- [Phase 28]: GitHub API 403/429 non-fatal: log_warn and continue with branch-fetched versions.env
- [Phase 28]: display_bundle_diff() shows full RELEASE_NOTES without line limit (while-read loop)
- [Phase 29-docling-gpu-ocr]: GPU passthrough for Docling uses NVIDIA_VISIBLE_DEVICES env var, not deploy.resources.reservations — single service, no duplicate
- [Phase 29-docling-gpu-ocr]: DOCLING_SERVE_VERSION replaced by DOCLING_IMAGE_CPU and DOCLING_IMAGE_CUDA in versions.env; DOCLING_IMAGE in .env holds full image:tag
- [Phase 29-docling-gpu-ocr]: GPU option (item 3) in Docling wizard hidden unless nvidia container runtime detected via docker info
- [Phase 29-docling-gpu-ocr]: DOCLING_SERVE_VERSION removed from versions.env; replaced by DOCLING_IMAGE_CPU and DOCLING_IMAGE_CUDA full image:tag refs
- [Phase 29-docling-gpu-ocr]: OCR_LANG hardcoded to rus,eng; not user-configurable (DOCL-03)
- [Phase 30-reliability-validation]: Stage 6 verification positioned after tar creation to catch missing images before success message; exit 1 on missing images prevents misleading bundle complete output
- [Phase 30-reliability-validation]: Dify init retry sleep 30->60s; flock on agmind init-dify via fd 8; --dry-run runs preflight_checks and exits with its rc; DNS check uses getent hosts primary + nslookup fallback
- [Phase 30-reliability-validation]: HTTP HEAD (not docker manifest inspect, not GET) — avoids push scope bug docker/cli#4345 and rate-limit
- [Phase 30-reliability-validation]: validate_images_exist() blocks compose_pull() on 404; warn-only in update.sh (user may have custom images)
- [Phase 30-reliability-validation]: update.sh sources lib/compose.sh via _UPDATE_SCRIPT_DIR to get validate_images_exist() without code duplication
- [Phase 31]: VDS/VPS wizard choice executes git fetch+checkout agmind-caddy then exec install.sh --vds — process replacement, never returns
- [Phase 31]: Offline profile fully removed from codebase; LAN is now default choice 1 in simplified 2-choice wizard
- [Phase 31]: agmind-caddy branch created locally from main; user must push with git push origin agmind-caddy
- [Phase 32-litellm-ai-gateway]: LiteLLM nginx location at /litellm/ proxies to litellm/ui/ path (trailing slashes for path rewriting)
- [Phase 32-litellm-ai-gateway]: litellm added to critical_services (not gpu_services) in wait_healthy — CPU-only API gateway
- [Phase 33]: SurrealDB as Open Notebook backend (not PostgreSQL); DB-GPT routes through LiteLLM; SearXNG secret_key placeholder for install-time substitution

### Architecture Notes

- `wizard.sh`: `_wizard_vllm_model()` has 16-model menu with VRAM guard
- `lib/models.sh`: `_get_vram_offset()` returns dynamic offset based on EMBED_PROVIDER + ENABLE_RERANKER
- `docker-compose.yml`: CUDA_VISIBLE_DEVICES uses env vars `${VLLM_CUDA_DEVICE:-0}` / `${TEI_CUDA_DEVICE:-0}`
- `docker-compose.yml`: profiles tei, reranker, docling fully wired to ENABLE_* flags
- `update.sh`: Xinference orphan cleanup on pre-v2.5 -> v2.5+ upgrades
- `lib/compose.sh`: will receive `validate_images_exist()` in Phase 30
- `scripts/update.sh`: will be refactored for git branch fetch in Phase 28

### Phase 28 Critical Pitfalls (from research)

- C-01: `git pull` can overwrite user-customised files — use `git stash push` before pull, restore after
- M-03: installer-generated files must be in .gitignore before branch switch ships — audit required
- N-04: GitHub API rate limit on --check — handle 403/429 explicitly

### Phase 29 Critical Pitfalls (from research)

- C-03: Docling CUDA image selected for wrong host CUDA version — map sm version to CUDA before selecting image
- N-06: nvidia-smi working does not imply container GPU passthrough works — check `docker info` runtime list

### Phase 30 Critical Pitfalls (from research, ex-Phase 31)

- C-02: `docker manifest inspect` requires push scope, breaks read-only tokens (docker/cli#4345) — use HTTP HEAD
- M-04: GET requests count against Docker Hub rate limit — HEAD requests are free

### Pending Todos

None.

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-03-30T05:54:02.197Z
Stopped at: Completed 33-01-PLAN.md
Resume file: None
Next step: `/gsd:plan-phase 31`
