# Phase 16: Critical Bugfixes - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Two isolated bugfixes: (1) VRAM guard for NON_INTERACTIVE mode; (2) always run diagnostics on resume.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase.

**BUG-041 (BFIX-41) — VRAM guard in NON_INTERACTIVE:**
1. In `_wizard_llm_model()` (lib/wizard.sh:457-476): the early return at line 458 for NON_INTERACTIVE bypasses `_wizard_vllm_model()` entirely — VRAM guard never runs
2. Fix: AFTER the early return and AFTER the default assignment at line 474, add VRAM validation
3. Read `DETECTED_GPU_VRAM`, compute `vram_gb`, find matching `vram_req` for the selected VLLM_MODEL
4. If model exceeds VRAM: `log_error` with model name, required vs available VRAM, recommendation for smaller model, then `exit 1`
5. The vram_req array and vllm_models array from `_wizard_vllm_model()` need to be accessible — either duplicate the lookup or extract to a shared function
6. For unknown models (custom from env): skip VRAM check

**BUG-042 (BFIX-42) — Resume diagnostics:**
1. In `install.sh` main() (line ~456-459): when `start > 1`, phase_diagnostics is skipped
2. `run_diagnostics` sets DETECTED_OS, DETECTED_GPU_VRAM, DETECTED_GPU_COUNT etc. — needed by later phases
3. Fix: Before the phase table (line ~462), if `start > 1`: call `run_diagnostics || true` unconditionally
4. This is lightweight (just detection, no install) and safe to re-run
5. Don't re-run preflight_checks (those may prompt user) — only `run_diagnostics`

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `DETECTED_GPU_VRAM` from lib/detect.sh — already populated during phase_diagnostics/run_diagnostics
- vram_req array in _wizard_vllm_model() — needs to be accessible outside the function
- `run_diagnostics` function in lib/detect.sh — lightweight detection

### Established Patterns
- wizard.sh: NON_INTERACTIVE early return pattern at function top
- install.sh: resume loads .env at line 457-458

### Integration Points
- lib/wizard.sh:456-476 — _wizard_llm_model() NON_INTERACTIVE path
- install.sh:462-469 — phase table (resume start point)
- lib/detect.sh — run_diagnostics function

</code_context>

<specifics>
## Specific Ideas

From task doc: exit 1 with diagnostic message for NON_INTERACTIVE VRAM violation. Always `run_diagnostics || true` before phase table on resume.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
