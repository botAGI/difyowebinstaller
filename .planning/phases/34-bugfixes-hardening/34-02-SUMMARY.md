---
phase: 34-bugfixes-hardening
plan: "02"
subsystem: service-mapping
tags: [refactor, deduplication, maintainability, bash]
dependency_graph:
  requires: []
  provides: [lib/service-map.sh]
  affects: [lib/health.sh, scripts/update.sh, lib/compose.sh]
tech_stack:
  added: []
  patterns: [single-source-of-truth, double-source-guard, bash-source]
key_files:
  created:
    - lib/service-map.sh
  modified:
    - lib/health.sh
    - lib/compose.sh
    - scripts/update.sh
decisions:
  - "service-map.sh uses _SERVICE_MAP_LOADED guard to prevent double-source errors when compose.sh is sourced by update.sh (which also sources service-map.sh)"
  - "compose.sh uses lazy-load pattern (if _SERVICE_MAP_LOADED empty, source) — safe for callers that source compose.sh without first loading service-map.sh"
  - "ALL_COMPOSE_PROFILES includes docling (was missing from compose.sh hardcoded strings)"
metrics:
  duration_seconds: 130
  completed_date: "2026-04-04"
  tasks_completed: 2
  tasks_total: 2
  files_changed: 4
---

# Phase 34 Plan 02: Service Map Deduplication Summary

**One-liner:** Extracted duplicated service-name-to-version-key/container/profile mappings from update.sh and compose.sh into a single canonical `lib/service-map.sh`, eliminating maintenance drift between files.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Create lib/service-map.sh | a539627 | lib/service-map.sh (new) |
| 2 | Wire service-map.sh into health.sh, update.sh, compose.sh | 47c619e | lib/health.sh, lib/compose.sh, scripts/update.sh |

## What Was Done

### Task 1 — lib/service-map.sh created

New file with:
- `declare -A NAME_TO_VERSION_KEY` — 32 entries (vs 29 in old update.sh — added litellm, searxng, surrealdb, open-notebook, dbgpt, crawl4ai from phases 32-33)
- `declare -A NAME_TO_SERVICES` — 32 entries with matching additions
- `declare -A SERVICE_GROUPS` — dify group
- `ALL_COMPOSE_PROFILES` string for compose down --remove-orphans
- Double-source guard via `_SERVICE_MAP_LOADED=1`

### Task 2 — Consumers updated

**scripts/update.sh:**
- Removed 3 inline `declare -A` blocks (~67 lines eliminated)
- Added `source "${_UPDATE_SCRIPT_DIR}/../lib/service-map.sh"` before compose.sh source

**lib/health.sh:**
- Added `source "${_HEALTH_SCRIPT_DIR}/service-map.sh"` after fallback colors block
- `get_service_list()` logic unchanged (reads .env dynamically — correct behavior)

**lib/compose.sh:**
- `compose_down()`: replaced hardcoded `COMPOSE_PROFILES=vps,monitoring,...` with lazy-load + `COMPOSE_PROFILES="${ALL_COMPOSE_PROFILES}"`
- `_cleanup_stale_containers()`: same replacement
- Both functions use lazy-load guard so they work even when compose.sh is sourced standalone

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing functionality] docling profile absent from compose.sh hardcoded string**
- **Found during:** Task 2
- **Issue:** The hardcoded `COMPOSE_PROFILES=vps,monitoring,...` in compose.sh was missing `docling` — present in service-map.sh ALL_COMPOSE_PROFILES (which was copied verbatim from the plan spec)
- **Fix:** ALL_COMPOSE_PROFILES includes `docling`; compose.sh now uses ALL_COMPOSE_PROFILES so the fix is automatically applied
- **Files modified:** lib/service-map.sh (spec included docling), lib/compose.sh
- **Commit:** 47c619e

## Verification Results

```
grep -rn 'declare -A NAME_TO_VERSION_KEY' lib/ scripts/
  → lib/service-map.sh:14 (only one occurrence)

grep -rn 'declare -A NAME_TO_SERVICES' lib/ scripts/
  → lib/service-map.sh:53 (only one occurrence)

grep -rn 'declare -A SERVICE_GROUPS' lib/ scripts/
  → lib/service-map.sh:90 (only one occurrence)

grep -rn 'source.*service-map.sh' lib/ scripts/
  → lib/compose.sh:468,489 (lazy-load in two functions)
  → lib/health.sh:22
  → scripts/update.sh:34

grep -rn 'ALL_COMPOSE_PROFILES' lib/ scripts/
  → lib/compose.sh:471,492 (used in compose_down + _cleanup_stale_containers)
  → lib/service-map.sh:95 (definition)
```

## Self-Check: PASSED

- [x] `lib/service-map.sh` exists: D:/Agmind/difyowebinstaller/lib/service-map.sh
- [x] Commit a539627 exists: feat(34-02): create lib/service-map.sh
- [x] Commit 47c619e exists: feat(34-02): wire service-map.sh into health.sh, update.sh, compose.sh
- [x] No inline declare -A blocks remain in scripts/update.sh
- [x] All three consumers source lib/service-map.sh
- [x] ALL_COMPOSE_PROFILES used in both compose_down() and _cleanup_stale_containers()
