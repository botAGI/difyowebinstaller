---
phase: 19-bugfixes-gpu-enhancement
plan: "02"
subsystem: wizard, models, env-templates
tags: [bugfix, vram-guard, reranker, tei, xinference]
dependency_graph:
  requires: []
  provides: [TEI_VRAM_OFFSET, disabled-reranker]
  affects: [lib/wizard.sh, lib/models.sh, templates/env.*.template]
tech_stack:
  added: []
  patterns: [readonly-constant, effective-vram-calculation, early-return-guard]
key_files:
  created: []
  modified:
    - lib/wizard.sh
    - lib/models.sh
    - templates/env.lan.template
    - templates/env.vps.template
    - templates/env.vpn.template
    - templates/env.offline.template
decisions:
  - "TEI_VRAM_OFFSET=2 is hardcoded readonly constant, not user-configurable (per prior decision)"
  - "load_reranker() kept as stub to avoid breaking callers in download_models()"
  - "RERANK_MODEL_NAME commented (not deleted) in templates for traceability"
metrics:
  duration: "~2 minutes"
  completed: 2026-03-23
---

# Phase 19 Plan 02: VRAM Guard TEI Offset + Disable Reranker Summary

**One-liner:** VRAM guard subtracts 2 GB TEI offset via `readonly TEI_VRAM_OFFSET=2`; broken bce-reranker disabled with log_warn stub.

## Tasks Completed

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | BFIX-45 — Apply TEI VRAM offset in VRAM guard | fd0e227 | lib/wizard.sh |
| 2 | BFIX-44 — Disable broken Xinference reranker | 426c5cf | lib/models.sh, lib/wizard.sh, 4x templates |

## What Was Built

### Task 1: TEI VRAM offset (BFIX-45)

Added `readonly TEI_VRAM_OFFSET=2` before `_get_vllm_vram_req()` in `lib/wizard.sh`.

Three guard paths updated:
- **[recommended] tag calculation** (already had `effective_vram`): now uses `TEI_VRAM_OFFSET` instead of hardcoded `2`
- **Interactive VRAM guard** (`_wizard_vllm_model`): added `effective_vram_check = vram_gb - TEI_VRAM_OFFSET`; compares `vram_req[$REPLY]` against `effective_vram_check`; warning message shows breakdown `(24 GB - 2 GB TEI)`
- **NON_INTERACTIVE guard** (`_wizard_llm_model`): added `ni_effective_vram = ni_vram_gb - TEI_VRAM_OFFSET`; exits 1 when model exceeds `ni_effective_vram`; error message shows `effective available: N GB (M GB - 2 GB TEI)`

### Task 2: Disable broken reranker (BFIX-44)

**lib/models.sh:** `load_reranker()` body replaced with early-return stub — logs `log_warn "Reranker disabled: bce-reranker-base_v1 is broken in Xinference v2.3.0"` and returns 0. Curl logic, wait loop and docker exec removed. Function signature preserved to avoid breaking callers.

**lib/wizard.sh:** `_wizard_etl()` prompts updated — removed "Xinference reranker" and "bce-reranker-base_v1". Option 2 now reads "Docling (улучшенный парсинг документов)".

**4 env templates:** `RERANK_MODEL_NAME=bce-reranker-base_v1` commented out with annotation `# BROKEN in xinference v2.3.0 -- reranker via TEI in Phase 22`. `XINFERENCE_BASE_URL` kept uncommented (still needed if Xinference service runs).

## Decisions Made

1. `TEI_VRAM_OFFSET=2` hardcoded as `readonly` — not configurable (prevents accidental override, consistent with prior architecture decision)
2. `load_reranker()` kept as stub, not deleted — callers in `download_models()` continue to work without changes
3. `RERANK_MODEL_NAME` commented (not deleted) — traceability for Phase 22 implementation

## Deviations from Plan

None — plan executed exactly as written.

The `_wizard_vllm_model()` already had a partial `effective_vram` variable (from a prior commit) used only for the [рекомендуется] tag. Task 1 unified the constant name and extended the same logic to the actual VRAM guard comparison.

## Verification Results

```
readonly TEI_VRAM_OFFSET=2                          ✓ defined
effective_vram_check in interactive guard           ✓ used
ni_effective_vram in NON_INTERACTIVE guard          ✓ used
log_warn "Reranker disabled..."                     ✓ in models.sh
curl -X POST removed from load_reranker()           ✓ confirmed
ETL wizard: no "bce-reranker-base_v1"               ✓ confirmed
ETL wizard: "Docling (улучшенный парсинг)"         ✓ confirmed
# RERANK_MODEL_NAME ... BROKEN in all 4 templates  ✓ confirmed
bash -n lib/wizard.sh                               ✓ syntax OK
bash -n lib/models.sh                               ✓ syntax OK
```

## Self-Check: PASSED
