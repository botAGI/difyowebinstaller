---
phase: 17-wizard-model-list-update
plan: "01"
subsystem: wizard
tags: [bash, vllm, models, qwen3, moe, vram]

# Dependency graph
requires:
  - phase: 16-critical-bugfixes
    provides: NON_INTERACTIVE VRAM guard in _wizard_llm_model + _get_vllm_vram_req hook

provides:
  - vLLM wizard menu with 16 models (5 AWQ + 4 bf16-7/8B + 3 bf16-14B + 2 bf16-32B+ + 2 MoE)
  - Corrected VRAM requirements (14B AWQ: 12->10 GB, 7B AWQ: 8->5 GB)
  - MODEL_SIZES download size entries for all 16 vLLM models

affects:
  - 18-gpu-management
  - wizard model selection UX

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "vLLM menu sections: AWQ / bf16-7/8B / bf16-14B / bf16-32B+ / MoE"
    - "MoE entries annotated with total/active param counts"
    - "MODEL_SIZES uses HuggingFace names for vLLM, Ollama names for Ollama"

key-files:
  created: []
  modified:
    - lib/wizard.sh
    - lib/models.sh

key-decisions:
  - "Qwen2.5-7B-Instruct (index 6) remains default Enter choice — balanced VRAM/performance"
  - "MoE section separate from bf16 32B+ to clarify active vs total params"
  - "VRAM fix: Qwen2.5-14B-AWQ corrected from 12 to 10 GB per hardware measurements"
  - "VRAM fix: Qwen2.5-7B-AWQ corrected from 8 to 5 GB per hardware measurements"
  - "NON_INTERACTIVE VRAM guard unchanged — _get_vllm_vram_req() now covers all 16 models automatically"

patterns-established:
  - "vram_req array indices must match vllm_models array indices (both 1-indexed, 0 is placeholder)"
  - "rec_idx loop iterates from max down to 1 to find largest fitting model"

requirements-completed: [WMOD-01, WMOD-02]

# Metrics
duration: 2min
completed: 2026-03-23
---

# Phase 17 Plan 01: Wizard Model List Update Summary

vLLM wizard expanded from 10 to 16 models across 5 sections (AWQ/bf16-7B/bf16-14B/bf16-32B+/MoE), with corrected VRAM requirements and MODEL_SIZES download sizes for all 16 models

## Performance

- **Duration:** ~2 min
- **Started:** 2026-03-23T10:54:29Z
- **Completed:** 2026-03-23T10:56:16Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Expanded vLLM model menu from 10 to 16 models with 5 structured sections
- Added 6 new models: Qwen3-8B-AWQ, Qwen3-14B-AWQ, Qwen2.5-32B-Instruct-AWQ, Qwen3-8B, Qwen3-Coder-Next-AWQ-4bit (MoE), Nemotron-3-Nano-30B-A3B-AWQ (MoE)
- Corrected VRAM requirements: Qwen2.5-14B-AWQ 12->10 GB, Qwen2.5-7B-AWQ 8->5 GB
- Added MoE section with active/total parameter annotations
- Added MODEL_SIZES entries for all 16 vLLM models (HuggingFace names)
- NON_INTERACTIVE VRAM guard covers all 16 models automatically via updated `_get_vllm_vram_req()`

## Task Commits

Each task was committed atomically:

1. **Task 1: Update wizard.sh -- expand vLLM model list to 16 models + fix VRAM** - `44e2365` (feat)
2. **Task 2: Update models.sh -- add MODEL_SIZES for new vLLM models** - `767a9ac` (feat)

**Plan metadata:** (docs commit below)

## Files Created/Modified

- `lib/wizard.sh` - _get_vllm_vram_req() with 16 models, _wizard_vllm_model() with 16-model menu
- `lib/models.sh` - MODEL_SIZES extended with 16 vLLM HuggingFace-name entries

## Decisions Made

- Default Enter=6 selects Qwen/Qwen2.5-7B-Instruct (index 6 in 16-model array) — balanced VRAM/performance
- MoE section separate from "32B+ bf16" section to clearly communicate active vs total params
- VRAM corrections per CONTEXT.md hardware measurements (not guesses)
- Qwen3-Coder-Next-AWQ-4bit under bullpoint/ org (community quantization)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 18 (GPU Management CLI) can proceed: wizard model list is stable
- All 16 vLLM models supported in VRAM guard, no further wizard.sh changes expected
- MODEL_SIZES ready to display download sizes in operator feedback

---
*Phase: 17-wizard-model-list-update*
*Completed: 2026-03-23*

## Self-Check: PASSED

- lib/wizard.sh: FOUND
- lib/models.sh: FOUND
- .planning/phases/17-wizard-model-list-update/17-01-SUMMARY.md: FOUND
- Commit 44e2365: FOUND
- Commit 767a9ac: FOUND
