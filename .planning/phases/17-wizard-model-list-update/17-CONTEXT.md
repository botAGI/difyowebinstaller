# Phase 17: Wizard Model List Update - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Update vLLM model list in wizard to current landscape (Qwen3, MoE), fix VRAM requirements, update MODEL_SIZES.

</domain>

<decisions>
## Implementation Decisions

### New Model List (locked from task doc)
Models 1-16 + custom (17):

```
# AWQ (compact VRAM)
 1) Qwen/Qwen2.5-7B-Instruct-AWQ          [~5 GB]
 2) Qwen/Qwen3-8B-AWQ                     [~6 GB]
 3) Qwen/Qwen2.5-14B-Instruct-AWQ         [~10 GB]
 4) Qwen/Qwen3-14B-AWQ                    [~10 GB]
 5) Qwen/Qwen2.5-32B-Instruct-AWQ         [~20 GB]

# bf16 (full precision)
 6) Qwen/Qwen2.5-7B-Instruct              [~16 GB]
 7) Qwen/Qwen3-8B                         [~16 GB]
 8) mistralai/Mistral-7B-Instruct-v0.3    [~16 GB]
 9) meta-llama/Llama-3.1-8B-Instruct      [~16 GB] (HF_TOKEN)
10) Qwen/Qwen2.5-14B-Instruct             [~28 GB]
11) Qwen/Qwen3-14B                        [~28 GB]
12) microsoft/phi-4                        [~28 GB]
13) Qwen/Qwen2.5-32B-Instruct             [~48 GB]
14) meta-llama/Llama-3.3-70B-Instruct     [~140 GB] (HF_TOKEN)

# MoE (active params << total)
15) bullpoint/Qwen3-Coder-Next-AWQ-4bit   [~12 GB]  80B total, 14B active
16) stelterlab/NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ  [~4 GB]  30B total, 3B active

# Custom
17) Enter manually
```

### vram_req array
`local -a vram_req=(0 5 6 10 10 20 16 16 16 16 28 28 28 48 140 12 4)`

### Recommendation logic
- 8GB: model 1 (Qwen2.5-7B-AWQ)
- 12GB (10 effective with TEI): model 3 or 4 (14B AWQ)
- 16GB (14 effective): model 4 (Qwen3-14B-AWQ)
- 24GB (22 effective): model 5 (32B AWQ)
- 48GB+: model 13 (32B bf16)
- 80GB+: model 14 (70B bf16)
- Default (Enter) should be model 6 (Qwen2.5-7B-Instruct) not model 6=14B anymore

### _get_vllm_vram_req() update
Must be updated in Phase 16's new function to include all 16 models.

### MODEL_SIZES update (lib/models.sh)
Add approximate download sizes for new models:
- Qwen3-8B-AWQ: ~4.5 GB
- Qwen3-14B-AWQ: ~8 GB
- Qwen3-8B: ~16 GB
- Qwen3-Coder-Next-AWQ-4bit: ~8 GB
- Nemotron-3-Nano-30B-A3B-AWQ: ~2 GB

### Claude's Discretion
- Exact section headers formatting in menu
- MoE section description text
- Whether to change default Enter value from 6 to something else

</decisions>

<code_context>
## Existing Code Insights

### Key Files
- lib/wizard.sh:348-454 — _wizard_vllm_model() (current 10-model list)
- lib/wizard.sh:349-369 — _get_vllm_vram_req() (from Phase 16)
- lib/models.sh:13-27 — MODEL_SIZES associative array

### Integration Points
- _ask_choice range needs updating from "1 11" to "1 17"
- vllm_models array needs 16 entries + placeholder
- _get_vllm_vram_req() case statement needs 6 new entries

</code_context>

<specifics>
## Specific Ideas

Keep MoE models in separate section with note about active vs total params.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
