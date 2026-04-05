---
phase: 16-critical-bugfixes
plan: "01"
subsystem: infra
tags: [wizard, vllm, vram, diagnostics, resume, non-interactive, bash]

# Dependency graph
requires: []
provides:
  - "_get_vllm_vram_req() shared VRAM lookup function in lib/wizard.sh"
  - "NON_INTERACTIVE vllm path exits with error when VRAM insufficient"
  - "Resume from phase >= 2 always initializes DETECTED_* variables"
affects:
  - 17-wizard-model-list-update
  - 18-gpu-management-cli

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Shared VRAM lookup via _get_vllm_vram_req() case statement -- single source of truth for model VRAM requirements"
    - "Fall-through guard pattern: NON_INTERACTIVE skips interactive menu but still runs validation"
    - "Resume-safe diagnostics: run_diagnostics (no prompts) called unconditionally before phase table on resume"

key-files:
  created: []
  modified:
    - lib/wizard.sh
    - install.sh

key-decisions:
  - "Unknown custom models in NON_INTERACTIVE get warning only (no exit) -- matches existing interactive behavior"
  - "On resume use run_diagnostics (not phase_diagnostics) to avoid preflight_checks user prompts"
  - "|| true on run_diagnostics resume call: partial detection failure sets safe defaults, install continues"

patterns-established:
  - "VRAM validation must run for vllm regardless of NON_INTERACTIVE flag"
  - "All DETECTED_* vars must be populated before any phase >= 2 uses them"

requirements-completed:
  - BFIX-41
  - BFIX-42

# Metrics
duration: 15min
completed: 2026-03-23
---

# Phase 16 Plan 01: Critical Bugfixes Summary

**NON_INTERACTIVE VRAM guard and resume diagnostics gap fixed: vllm OOM deployments and unbound-variable crashes on resume eliminated**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-22T23:28:00Z
- **Completed:** 2026-03-22T23:43:27Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `_get_vllm_vram_req()` function -- single source of truth mapping all 10 known vLLM models to VRAM requirements
- Refactored `_wizard_llm_model()` to fall through to VRAM guard for vllm in NON_INTERACTIVE mode instead of early-returning
- Added `run_diagnostics || true` call in `install.sh main()` before phase table when resuming (start > 1)

## Task Commits

Each task was committed atomically:

1. **Task 1: BFIX-41 -- VRAM guard for NON_INTERACTIVE vllm path** - `6eeb86a` (fix)
2. **Task 2: BFIX-42 -- Always run diagnostics on resume** - `a16832b` (fix)

**Plan metadata:** (docs commit below)

## Files Created/Modified

- `lib/wizard.sh` -- Added `_get_vllm_vram_req()` before `_wizard_vllm_model()`; refactored `_wizard_llm_model()` with new VRAM guard block
- `install.sh` -- Added resume diagnostics block between `.env` load and phase table

## Decisions Made

- Unknown custom VLLM_MODEL in NON_INTERACTIVE: emit warning, no exit. Matches existing interactive behavior where custom model (option 11) skips VRAM check.
- Use `run_diagnostics` (not `phase_diagnostics`) on resume: avoids `preflight_checks` which may prompt user interactively.
- `|| true` on `run_diagnostics` resume call: systems without nvidia-smi or with partial GPU detection should still continue; detect.sh sets DETECTED_GPU_VRAM=0 as safe default.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 16 complete, Phase 17 (Wizard Model List Update) can proceed
- `_get_vllm_vram_req()` will need updating when Phase 17 adds new models to the wizard
- `DETECTED_GPU_VRAM` is now reliably available for all phases, enabling Phase 18 GPU management CLI

---
*Phase: 16-critical-bugfixes*
*Completed: 2026-03-23*
