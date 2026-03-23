---
phase: 24-wizard-restructure-vram-summary-profiles
plan: 01
subsystem: wizard
tags: [wizard, vram, vllm, tei, profiles, bash]

requires:
  - phase: 23-llm-model-list-effective-vram
    provides: "_get_vram_offset() and _get_vllm_vram_req() helpers used in VRAM summary block"
  - phase: 22-reranker-wizard-docker-vram
    provides: "ENABLE_RERANKER, RERANK_MODEL, TEI reranker pattern"
  - phase: 21-embeddings-wizard-docker
    provides: "EMBED_PROVIDER=tei, EMBEDDING_MODEL, TEI embed pattern"

provides:
  - "Wizard steps reordered: LLM -> Embeddings -> Reranker -> VectorDB -> ETL (model choices grouped)"
  - "VRAM plan table in _wizard_summary() for vLLM setups: vLLM + TEI-embed + TEI-rerank lines with total vs available"
  - "Yellow overflow warning when total VRAM exceeds detected GPU VRAM"
  - "VRAM block hidden for Ollama users (Ollama manages VRAM internally)"
  - "build_compose_profiles() verified correct for NON_INTERACTIVE mode (tei, reranker, docling)"

affects:
  - wizard step UX
  - vLLM installation flow
  - NON_INTERACTIVE mode consumers

tech-stack:
  added: []
  patterns:
    - "VRAM budget display gated by LLM_PROVIDER=vllm to avoid irrelevant output for Ollama users"
    - "DETECTED_GPU_VRAM (MB) divided by 1024 for human-readable GB comparison in wizard summary"

key-files:
  created: []
  modified:
    - lib/wizard.sh

key-decisions:
  - "Wizard step order: LLM provider/model grouped before VectorDB/ETL — users configure inference stack first, then storage"
  - "VRAM block only shown for vLLM — Ollama manages VRAM internally so budget display is irrelevant for Ollama users"
  - "build_compose_profiles() verified — no changes needed, all three profiles (tei, reranker, docling) already correct"

patterns-established:
  - "VRAM summary: sum individual components (vLLM + TEI-embed + TEI-rerank) and compare to DETECTED_GPU_VRAM"

requirements-completed:
  - WIZS-01
  - WIZS-02
  - PROF-01

duration: 1min
completed: 2026-03-23
---

# Phase 24 Plan 01: Wizard Restructure + VRAM Summary + Profiles Summary

**Wizard steps reordered (model choices first), VRAM budget table added to summary for vLLM setups with overflow warning, and NON_INTERACTIVE profile generation verified correct**

## Performance

- **Duration:** ~1 min
- **Started:** 2026-03-23T09:54:47Z
- **Completed:** 2026-03-23T09:55:55Z
- **Tasks:** 2
- **Files modified:** 1 (lib/wizard.sh — Task 2 was verification only, no code changes)

## Accomplishments

- Reordered `run_wizard()` so LLM provider/model/embeddings/reranker are grouped before VectorDB and ETL (WIZS-01)
- Added VRAM plan table in `_wizard_summary()` gated by `LLM_PROVIDER=vllm` showing per-component breakdown (WIZS-02)
- Verified `build_compose_profiles()` in `lib/compose.sh` correctly handles tei, reranker, docling profiles for NON_INTERACTIVE mode (PROF-01)

## Task Commits

Each task was committed atomically:

1. **Task 1: Reorder wizard steps and add VRAM summary block** - `b7ae614` (feat)
2. **Task 2: Verify COMPOSE_PROFILES in NON_INTERACTIVE mode** — verification only, no code changes (no separate commit needed)

**Plan metadata:** (docs commit — see state updates below)

## Files Created/Modified

- `lib/wizard.sh` — Reordered steps in `run_wizard()` and inserted VRAM plan block in `_wizard_summary()`

## Decisions Made

- Wizard step order: LLM provider/model grouped before VectorDB/ETL — users configure inference stack first, then storage. This makes model-related choices contiguous and avoids context switching between LLM and storage questions.
- VRAM block only shown for vLLM — Ollama manages VRAM internally, so displaying a budget for Ollama users would be misleading.
- `build_compose_profiles()` needed no changes — it already reads `EMBED_PROVIDER`, `ENABLE_RERANKER`, and `ENABLE_DOCLING` env vars directly, so it works identically in interactive and NON_INTERACTIVE modes.

## Deviations from Plan

None — plan executed exactly as written. Task 2 confirmed the expected "no changes needed" outcome.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Phase 24 Plan 01 complete. Wizard restructure (WIZS-01, WIZS-02, PROF-01) fully implemented.
- lib/wizard.sh and lib/compose.sh both pass `bash -n` syntax checks.
- Ready for next plan in phase 24 if applicable.

---
*Phase: 24-wizard-restructure-vram-summary-profiles*
*Completed: 2026-03-23*
