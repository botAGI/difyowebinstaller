---
phase: 20-xinference-removal
plan: "01"
subsystem: docker-compose, lib/wizard, lib/compose, lib/config, lib/models, lib/health, env-templates
tags: [xinference, docling, etl, cleanup, backward-compat]
dependency_graph:
  requires: []
  provides: [xinference-removed, docling-profile, ENABLE_DOCLING-flag]
  affects: [all-profiles, LAN, VPS, VPN, Offline]
tech_stack:
  added: []
  patterns: [backward-compat-shim, variable-rename-migration]
key_files:
  created: []
  modified:
    - templates/docker-compose.yml
    - lib/wizard.sh
    - lib/compose.sh
    - lib/config.sh
    - lib/models.sh
    - lib/health.sh
    - templates/env.lan.template
    - templates/env.vps.template
    - templates/env.vpn.template
    - templates/env.offline.template
decisions:
  - "ETL_ENHANCED retained as fallback-only in ${ENABLE_DOCLING:-${ETL_ENHANCED:-false}} expansion for backward compat with existing .env files"
  - "load_reranker() fully deleted (was already a no-op stub since Xinference v2.3.0 broke bce-reranker)"
  - "Docling profile renamed from etl to docling — cleaner semantics, no Xinference coupling"
metrics:
  duration_seconds: 209
  completed_date: "2026-03-23"
  tasks_completed: 2
  files_modified: 10
---

# Phase 20 Plan 01: Xinference Removal Summary

**One-liner:** Removed Xinference service/volume from docker-compose, renamed profile etl→docling, and migrated ETL_ENHANCED to ENABLE_DOCLING with backward-compat shim across all lib/ scripts and env templates.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Remove Xinference from docker-compose + rename etl profile | 761831c | templates/docker-compose.yml |
| 2 | Migrate ETL_ENHANCED→ENABLE_DOCLING in lib/ + env templates | 7b2b673 | lib/wizard.sh, lib/compose.sh, lib/config.sh, lib/models.sh, lib/health.sh, 4x env templates |

## What Was Done

### Task 1: docker-compose.yml

- Deleted `xinference` service block (29 lines: image, healthcheck, volumes, GPU comments)
- Removed `agmind_xinference_data:` from volumes section
- Changed Docling service profile from `- etl` to `- docling`

### Task 2: lib/ scripts and env templates

**lib/wizard.sh:**
- Default: `ENABLE_DOCLING="${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}"` (backward compat)
- `_wizard_etl()`: all assignments use ENABLE_DOCLING
- `_wizard_summary()`: line now says `Docling` (not `Docling + Xinference`)
- `run_wizard()` export: ETL_ENHANCED replaced by ENABLE_DOCLING
- Header comment updated

**lib/compose.sh:**
- ETL block replaced: checks ENABLE_DOCLING with ETL_ENHANCED fallback, appends profile `docling` (not `etl`)

**lib/config.sh:**
- ETL type mapping uses `${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}` for backward compat with old .env files

**lib/models.sh:**
- Entire `XINFERENCE RERANKER` section removed (load_reranker function deleted)
- Two call sites of load_reranker() removed from download_models()
- Header comment updated

**lib/health.sh:**
- `services+=(docling xinference)` → `services+=(docling)` (xinference removed)

**All 4 env templates** (lan, vps, vpn, offline):
- Replaced `# --- Reranker (Xinference) ---` / `XINFERENCE_BASE_URL` / `RERANK_MODEL_NAME` comment block
- Added `# --- Document Processing ---` / `ENABLE_DOCLING=false`

## Verification Results

- `grep -rn "xinference|XINFERENCE" templates/docker-compose.yml lib/ templates/env.*.template` → 0 matches
- `grep -c "load_reranker" lib/models.sh` → 0
- `grep "ENABLE_DOCLING" lib/wizard.sh lib/compose.sh lib/config.sh` → matches in all three
- `grep "docling" lib/compose.sh` → shows profile `docling`
- `grep "profile.*etl|etl.*profile" templates/docker-compose.yml lib/compose.sh` → 0 matches
- ETL_ENHANCED appears only inside `${ETL_ENHANCED:-false}` backward compat expansions

## Deviations from Plan

None — plan executed exactly as written.

## Profiles Affected

All profiles (LAN, VPS, VPN, Offline) — env templates updated for all four.

## Self-Check: PASSED

- lib/wizard.sh: FOUND
- lib/compose.sh: FOUND
- lib/models.sh: FOUND
- templates/docker-compose.yml: FOUND
- 20-01-SUMMARY.md: FOUND
- Commit 761831c: FOUND
- Commit 7b2b673: FOUND
