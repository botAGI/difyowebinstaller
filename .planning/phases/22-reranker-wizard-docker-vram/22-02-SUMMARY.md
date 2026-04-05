---
phase: 22-reranker-wizard-docker-vram
plan: "02"
subsystem: docker-compose, compose profiles, config substitution, env templates
tags: [reranker, tei, docker-compose, compose-profiles, env-templates]
dependency_graph:
  requires: []
  provides: [tei-rerank-service, reranker-compose-profile, reranker-env-substitution]
  affects: [templates/docker-compose.yml, lib/compose.sh, lib/config.sh, all-env-templates]
tech_stack:
  added: []
  patterns: [TEI reranker container pattern mirrors TEI embed service, sed placeholder substitution pattern]
key_files:
  created: []
  modified:
    - templates/docker-compose.yml
    - lib/compose.sh
    - lib/config.sh
    - templates/env.lan.template
    - templates/env.vps.template
    - templates/env.vpn.template
    - templates/env.offline.template
decisions:
  - TEI reranker image reuses same TEI_VERSION tag as TEI embed (ghcr.io/huggingface/text-embeddings-inference)
  - No explicit ports mapping on tei-rerank (consistent with tei embed — internal network only)
  - Default RERANK_MODEL set to BAAI/bge-reranker-v2-m3 (multilingual v2)
  - TEI_RERANK_MEM_LIMIT defaults to 4g (smaller than TEI embed 8g — rerankers are lighter)
  - reranker profile added to compose_down and _cleanup_stale_containers for complete lifecycle management
metrics:
  duration: "~8 minutes"
  completed_date: "2026-03-23"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 7
---

# Phase 22 Plan 02: TEI Rerank Docker Service and Env Wiring Summary

**One-liner:** TEI reranker container added in `reranker` compose profile, wired through ENABLE_RERANKER flag in compose.sh, config.sh sed substitution, and all 4 env templates.

## Tasks Completed

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | Add tei-rerank service and reranker compose profile | b9dc63d | templates/docker-compose.yml, lib/compose.sh |
| 2 | Add ENABLE_RERANKER/RERANK_MODEL to config.sh and env templates | 56ebcc6 | lib/config.sh, 4x env.*.template |

## What Was Built

### Task 1: tei-rerank service + compose profile

Added `tei-rerank` service to `templates/docker-compose.yml` immediately after the `tei` service block:

- **Profile:** `reranker` (activated by `ENABLE_RERANKER=true`)
- **Image:** same `ghcr.io/huggingface/text-embeddings-inference:${TEI_VERSION:-cuda-1.9.2}` as TEI embed
- **Container name:** `agmind-tei-rerank`
- **Command:** `--model-id ${RERANK_MODEL:-BAAI/bge-reranker-v2-m3} --port 80`
- **Volume:** `agmind_tei_rerank_cache:/data` (separate from `agmind_tei_cache`)
- **Mem limit:** `${TEI_RERANK_MEM_LIMIT:-4g}` (rerankers are smaller than embedders)
- **GPU block:** `#__GPU__` commented pattern (consistent with tei and vllm)
- **Network:** `agmind-backend` only (no external ports — internal service)

`agmind_tei_rerank_cache` added to the volumes declaration section.

In `lib/compose.sh` `build_compose_profiles()`:
```bash
[[ "${ENABLE_RERANKER:-false}" == "true" ]] && profiles="${profiles:+$profiles,}reranker"
```

Also added `reranker` to the hardcoded profiles string in `compose_down()` and `_cleanup_stale_containers()` for correct container lifecycle management.

### Task 2: config.sh substitution + env templates

In `lib/config.sh`, added two safe_ variable declarations near existing model variables:
```bash
safe_enable_reranker="$(escape_sed "${ENABLE_RERANKER:-false}")"
safe_rerank_model="$(escape_sed "${RERANK_MODEL:-}")"
```

And two sed substitution lines in the atomic replacement block:
```bash
-e "s|__ENABLE_RERANKER__|${safe_enable_reranker}|g" \
-e "s|__RERANK_MODEL__|${safe_rerank_model}|g" \
```

In all 4 env templates (`env.lan`, `env.vps`, `env.vpn`, `env.offline`), added after `HF_TOKEN` line:
```
# --- Reranker ---
ENABLE_RERANKER=__ENABLE_RERANKER__
RERANK_MODEL=__RERANK_MODEL__
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical functionality] Added reranker to compose_down and _cleanup_stale_containers**
- **Found during:** Task 1
- **Issue:** The plan only required adding `reranker` to `build_compose_profiles()`, but `compose_down()` and `_cleanup_stale_containers()` use hardcoded profile lists. Without `reranker` in those lists, `docker compose down` would leave the tei-rerank container running.
- **Fix:** Added `reranker` to both hardcoded `COMPOSE_PROFILES=...` strings in `compose_down()` and `_cleanup_stale_containers()`
- **Files modified:** `lib/compose.sh`
- **Commit:** b9dc63d

## Verification Results

All 6 plan verification checks passed:
1. `tei-rerank:` service definition present in docker-compose.yml
2. `ENABLE_RERANKER` → reranker profile line in compose.sh
3. `__ENABLE_RERANKER__` sed substitution in config.sh
4. All 4 env templates contain both placeholder lines (2 matches each)
5. `bash -n lib/compose.sh && bash -n lib/config.sh` — no syntax errors
6. `agmind_tei_rerank_cache` volume declared (mount + declaration in docker-compose.yml)

## Self-Check: PASSED

- FOUND: templates/docker-compose.yml
- FOUND: lib/compose.sh
- FOUND: lib/config.sh
- FOUND: .planning/phases/22-reranker-wizard-docker-vram/22-02-SUMMARY.md
- FOUND commit: b9dc63d (feat(22-02): add tei-rerank service and reranker compose profile)
- FOUND commit: 56ebcc6 (feat(22-02): add ENABLE_RERANKER/RERANK_MODEL to config.sh and env templates)
