---
phase: 23-llm-model-list-effective-vram
plan: 01
subsystem: infra
tags: [vllm, vram, wizard, gpu, embed, reranker]

# Dependency graph
requires:
  - phase: 22-reranker-wizard-docker-vram
    provides: "RERANKER_VRAM_OFFSET=1 and TEI_VRAM_OFFSET=2 constants, all 3 VRAM guard callsites"
  - phase: 21-embeddings-wizard-docker
    provides: "EMBED_PROVIDER variable wired into wizard flow"
provides:
  - "_get_vram_offset() function computing GPU offset dynamically from EMBED_PROVIDER + ENABLE_RERANKER"
  - "All 3 VRAM guard callsites updated to call _get_vram_offset() instead of hardcoded constants"
  - "Verified consistency of 16 vLLM models across vram_req[], _get_vllm_vram_req(), MODEL_SIZES"
affects:
  - wizard-vllm-model
  - vram-guard

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "_get_vram_offset() dynamic function pattern — offset computed from active service config rather than hardcoded constants"
    - "Safe fallback EMBED_PROVIDER to tei in case default — overestimates rather than underestimates"

key-files:
  created: []
  modified:
    - lib/wizard.sh

key-decisions:
  - "_get_vram_offset() defaults EMBED_PROVIDER to tei (safe conservative fallback) in case statement — overestimates offset rather than underestimates"
  - "Interactive VRAM guard warning simplified from 'X GB TEI + Y GB reranker' to single total offset number — simpler message, breakdown handled inside function"
  - "NON_INTERACTIVE guard error message follows same simplification pattern for consistency"
  - "vLLM model VRAM audit (Task 2): all 3 data sources (vram_req[], _get_vllm_vram_req(), MODEL_SIZES) confirmed consistent — no code changes needed"

patterns-established:
  - "Dynamic offset pattern: GPU services compute their VRAM cost centrally in one function, callsites just call it"

requirements-completed:
  - LLMM-01
  - LLMM-02

# Metrics
duration: 12min
completed: 2026-03-23
---

# Phase 23 Plan 01: LLM Model List Effective VRAM Summary

**Dynamic _get_vram_offset() replaces TEI_VRAM_OFFSET=2 and RERANKER_VRAM_OFFSET=1 constants: offset now computed from active EMBED_PROVIDER and ENABLE_RERANKER, all 3 VRAM guard callsites updated, 16 vLLM model VRAM values verified consistent across all data sources**

## Performance

- **Duration:** 12 min
- **Started:** 2026-03-23T09:40:00Z
- **Completed:** 2026-03-23T09:52:00Z
- **Tasks:** 2
- **Files modified:** 1 (lib/wizard.sh; lib/models.sh audit-only, no changes)

## Accomplishments

- Replaced two hardcoded `readonly` constants (`TEI_VRAM_OFFSET=2`, `RERANKER_VRAM_OFFSET=1`) with a single `_get_vram_offset()` function
- Function dynamically computes GPU offset: TEI embed = +2 GB, non-TEI embed = +0 GB, reranker = +1 GB when active
- Updated all 3 VRAM guard callsites (recommended tag, interactive guard, NON_INTERACTIVE guard) to call `_get_vram_offset()`
- Audited all 16 vLLM models across three data sources — confirmed full consistency, no discrepancies found

## Task Commits

Each task was committed atomically:

1. **Task 1: Replace VRAM offset constants with _get_vram_offset() function** - `2602e7a` (feat)
2. **Task 2: Audit vLLM model VRAM values for consistency** - no commit (audit only — no code changes required)

## Files Created/Modified

- `lib/wizard.sh` - Replaced TEI_VRAM_OFFSET/RERANKER_VRAM_OFFSET constants with _get_vram_offset(), updated 3 callsites

## Decisions Made

- `_get_vram_offset()` defaults `EMBED_PROVIDER` to `tei` via `${EMBED_PROVIDER:-tei}` in case statement — conservative safe fallback: overestimates offset rather than underestimates, preventing OOM
- Interactive VRAM guard warning simplified: instead of "X GB TEI + Y GB reranker" now shows total offset as one number — the function handles the breakdown internally
- NON_INTERACTIVE guard follows same pattern for consistency
- Task 2 audit result: all three data sources are consistent, no MODEL_SIZES entries missing, all 16 vLLM models present

## Deviations from Plan

None — plan executed exactly as written. Task 2 audit confirmed no code changes were needed.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- VRAM computation is now correctly dynamic: when user switches EMBED_PROVIDER from tei to ollama/external, effective VRAM for model selection automatically increases by 2 GB
- ENABLE_RERANKER correctly subtracts 1 GB only when reranker is active
- All 16 vLLM model VRAM values verified as consistent across vram_req[], _get_vllm_vram_req(), and MODEL_SIZES

---
*Phase: 23-llm-model-list-effective-vram*
*Completed: 2026-03-23*
