# Phase 13: VRAM Guard in Wizard - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Add VRAM-aware model selection in vLLM wizard. Show required VRAM per model, dynamically place `[recommended]` tag, warn when selection exceeds available GPU memory.

</domain>

<decisions>
## Implementation Decisions

### VRAM Requirements Table
- AWQ-7B (Qwen2.5-7B-AWQ): 8 GB
- AWQ-14B (Qwen2.5-14B-AWQ): 12 GB
- 7B bf16 (Qwen2.5-7B, Mistral-7B, Llama-3.1-8B): 16 GB
- 14B bf16 (Qwen2.5-14B, Qwen3-14B, phi-4): 28 GB
- 32B bf16 (Qwen2.5-32B): 48 GB
- 70B bf16 (Llama-3.3-70B): 140 GB

### Display Format
- Each model line shows required VRAM: `Qwen/Qwen2.5-14B-Instruct [28 GB VRAM]`
- If VRAM detected and sufficient: append `[recommended]` to the BEST fitting model
- If VRAM detected and insufficient for a model: no special marker (user can still choose)
- If no GPU detected (DETECTED_GPU_VRAM=0 or empty): show all models without `[recommended]`, print one warning at top "GPU VRAM не определён"

### TEI Offset
- If EMBED_PROVIDER=tei: subtract 2 GB from available VRAM before recommending (TEI bge-m3 takes ~1.5-2 GB)
- This affects only the `[recommended]` placement, not blocking

### Warning on Oversized Selection
- If user selects model requiring more VRAM than available: show warning with numbers: "Модель требует X GB VRAM, доступно Y GB. Возможен OOM."
- Ask confirmation: "Продолжить? (y/n)" — default n
- If user says no: re-show model menu
- NON_INTERACTIVE mode: skip warning, use selected model as-is

### Custom Model (option 11)
- No VRAM check for custom models — user knows what they're doing

### Claude's Discretion
- Exact formatting of VRAM labels (color, alignment)
- Which model gets `[recommended]` when multiple fit (pick the largest that fits)
- How to handle edge case where VRAM exactly equals requirement

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `DETECTED_GPU_VRAM` from lib/detect.sh (line ~89-100) — already populated during phase_diagnostics
- `recommend_model()` in lib/detect.sh (lines 233-261) — existing Ollama recommendation logic (uses effective_mem thresholds)
- `_ask_choice` helper in lib/wizard.sh — used for menu selection

### Established Patterns
- wizard.sh uses echo statements for menu display with indentation
- _wizard_vllm_model() at line 348 — current function to modify
- EMBED_PROVIDER variable available at wizard time

### Integration Points
- lib/wizard.sh:348-394 — _wizard_vllm_model() function
- lib/detect.sh — DETECTED_GPU_VRAM variable
- lib/config.sh:487-493 — vLLM+TEI memory utilization adjustment (downstream, not modified here)

</code_context>

<specifics>
## Specific Ideas

From bug report: "Рядом с каждой моделью — требуемый VRAM. [рекомендуется] ставить только если VRAM >= требуемого. Если vLLM + TEI на одной GPU — вычитать 2GB на TEI. При несовпадении — warning + предложить AWQ вариант."

</specifics>

<deferred>
## Deferred Ideas

- Multi-GPU support (split models across GPUs) — v3.0+
- Auto-detect model quantization format — v3.0+

</deferred>
