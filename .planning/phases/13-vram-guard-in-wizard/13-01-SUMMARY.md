---
phase: 13-vram-guard-in-wizard
plan: 01
subsystem: ui
tags: [vllm, wizard, vram, gpu, shell, bash]

# Dependency graph
requires:
  - phase: 12-isolated-bugfixes
    provides: detect.sh exposes DETECTED_GPU_VRAM in MB
provides:
  - VRAM-aware _wizard_vllm_model() in lib/wizard.sh
  - Per-model VRAM labels [N GB VRAM] in vLLM model selection menu
  - Dynamic [рекомендуется] tag on best-fitting model (TEI -2 GB offset)
  - OOM warning with exact numbers + y/N confirmation on oversized selection
  - DETECTED_GPU_VRAM=0 fallback: no recommendation, one-time yellow warning
affects: [14-db-password-resume-safety, 15-pull-download-ux]

# Tech tracking
tech-stack:
  added: none
  patterns:
    - Nested helper function (_vllm_line) for uniform menu line formatting, cleaned up with unset -f
    - VRAM guard pattern: detect in MB → convert to GB → subtract TEI offset → find best-fit → warn on oversized

key-files:
  created: []
  modified:
    - lib/wizard.sh

key-decisions:
  - "TEI offset -2 GB applied only to [recommended] calculation, not to OOM warning threshold (TEI not confirmed yet)"
  - "Recursive _wizard_vllm_model() call on N answer re-shows full menu cleanly"
  - "Custom model option 11 has no VRAM check by design (unknown model size)"
  - "NON_INTERACTIVE silently uses selected model even if it exceeds VRAM"
  - "unset -f _vllm_line cleans nested helper to avoid namespace pollution"

patterns-established:
  - "Nested shell functions for display helpers: define inside parent, unset after use"
  - "VRAM guard: compare vram_req[$REPLY] > vram_gb (raw MB/1024, no TEI offset) for warning"

requirements-completed: [IREL-02]

# Metrics
duration: 8min
completed: 2026-03-23
---

# Phase 13 Plan 01: VRAM Guard in Wizard Summary

**Dynamic VRAM labels and OOM guard added to vLLM model wizard: per-model GB requirement, [рекомендуется] tag on best-fitting model, y/N oversized confirmation, graceful unknown-GPU fallback**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-03-23T00:00:00Z
- **Completed:** 2026-03-23
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Rewrote `_wizard_vllm_model()` with `vram_req` array (indices 1-10: 8/12/16/16/16/28/28/28/48/140 GB)
- Each model line now shows `[N GB VRAM]` and GREEN `[рекомендуется]` on best-fit (effective_vram = detected - 2 GB TEI)
- VRAM guard warns with exact numbers ("требует X GB, доступно Y GB. Возможен OOM.") + y/N confirmation; recursive re-show on N
- NON_INTERACTIVE bypasses confirmation; custom option 11 has no VRAM check
- When DETECTED_GPU_VRAM=0: no recommendation shown, single YELLOW warning at top of menu
- bash -n syntax check passes; shellcheck not installed on host (noted in acceptance criteria as acceptable)

## Task Commits

1. **Task 1+2: Rewrite _wizard_vllm_model() + shellcheck** - `4e5e78c` (feat)

## Files Created/Modified

- `lib/wizard.sh` — `_wizard_vllm_model()` completely rewritten with VRAM guard, labels, recommendation logic

## Decisions Made

- TEI offset applied only to `[recommended]` threshold (not OOM guard) — TEI not confirmed at wizard step
- Nested `_vllm_line()` helper keeps menu code DRY and readable; cleaned up with `unset -f`
- Recursive call on "N" avoids code duplication for menu re-display
- Custom model (11) intentionally skips VRAM check — model size unknown

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

- shellcheck not available on host machine. Used `bash -n` for syntax validation instead. All manual review criteria from plan section 2 were verified manually (quoted vars, arithmetic with `$(( ))`, no unbound vars, set -euo pipefail compatibility). Shellcheck noted as "not available" per plan's fallback path.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Phase 13 complete: VRAM guard active in vLLM wizard flow
- Phase 14 ready: DB Password Resume Safety (IREL-03) — independent of this change
- No regressions in existing wizard flow (NON_INTERACTIVE, custom model, all 10 preset models confirmed)

---
*Phase: 13-vram-guard-in-wizard*
*Completed: 2026-03-23*
