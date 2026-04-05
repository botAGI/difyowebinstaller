---
phase: 17-wizard-model-list-update
verified: 2026-03-23T00:00:00Z
status: passed
score: 7/7 must-haves verified
re_verification: false
---

# Phase 17: Wizard Model List Update — Verification Report

**Phase Goal:** Список моделей vLLM в wizard отражает актуальный ландшафт (Qwen3, MoE-архитектуры), VRAM requirements для AWQ-моделей скорректированы до реальных значений, MODEL_SIZES в lib/models.sh охватывает все новые модели.
**Verified:** 2026-03-23T00:00:00Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                          | Status     | Evidence                                                                                     |
|----|-----------------------------------------------------------------------------------------------|------------|----------------------------------------------------------------------------------------------|
| 1  | Wizard vLLM menu shows 16 models + custom option (17 total choices)                           | VERIFIED   | `_ask_choice "Модель [1-17, Enter=6]: " 1 17 6` (line 446); `REPLY -le 16` / `REPLY -eq 17` |
| 2  | AWQ section contains 5 models: Qwen2.5-7B-AWQ, Qwen3-8B-AWQ, Qwen2.5-14B-AWQ, Qwen3-14B-AWQ, Qwen2.5-32B-AWQ | VERIFIED | Lines 417–421: _vllm_line 1–5 each reference correct AWQ model                              |
| 3  | bf16 section contains 9 models: 7-8B group (4) + 14B group (3) + 32B+ group (2)              | VERIFIED   | Lines 424–436: _vllm_line 6–9 (7-8B), 10–12 (14B), 13–14 (32B+) — 9 total                 |
| 4  | MoE section contains 2 models: Qwen3-Coder-Next-AWQ-4bit and Nemotron-3-Nano-30B-A3B-AWQ     | VERIFIED   | Lines 438–440: `-- MoE --` header + _vllm_line 15 (bullpoint) + _vllm_line 16 (stelterlab)  |
| 5  | Qwen2.5-14B-Instruct-AWQ shows 10 GB VRAM (not 12 GB)                                        | VERIFIED   | `"Qwen/Qwen2.5-14B-Instruct-AWQ") echo "10"` (line 356); vram_req index 3 = 10               |
| 6  | MODEL_SIZES in models.sh has entries for all 5 new vLLM models                                | VERIFIED   | Lines 29, 31, 34, 42, 43 in models.sh contain Qwen3-8B-AWQ, Qwen3-14B-AWQ, Qwen3-8B, bullpoint, stelterlab |
| 7  | NON_INTERACTIVE VRAM guard validates new models via _get_vllm_vram_req()                      | VERIFIED   | Line 526: `ni_vram_req="$(_get_vllm_vram_req "$VLLM_MODEL")"` inside NON_INTERACTIVE vllm block |

**Score:** 7/7 truths verified

---

### Required Artifacts

| Artifact       | Expected                                                              | Status     | Details                                                                                                    |
|----------------|-----------------------------------------------------------------------|------------|------------------------------------------------------------------------------------------------------------|
| `lib/wizard.sh` | Updated _wizard_vllm_model() with 16 models, _get_vllm_vram_req() with 16 entries | VERIFIED | bash -n passes; 16 case entries + wildcard; vram_req array exact match; `bullpoint/Qwen3-Coder-Next-AWQ-4bit` present |
| `lib/models.sh` | MODEL_SIZES with new vLLM model download sizes                        | VERIFIED   | bash -n passes; `Qwen3-8B-AWQ` present at line 29; all 16 vLLM models in MODEL_SIZES                      |

Both files pass `bash -n` syntax check.

---

### Key Link Verification

| From                                     | To                                     | Via                                                   | Status   | Details                                                                                        |
|------------------------------------------|----------------------------------------|-------------------------------------------------------|----------|-----------------------------------------------------------------------------------------------|
| `lib/wizard.sh:_wizard_vllm_model`       | `lib/wizard.sh:_get_vllm_vram_req`     | vram_req array indices match _get_vllm_vram_req values | VERIFIED | `vram_req=(0 5 6 10 10 20 16 16 16 16 28 28 28 48 140 12 4)` exactly matches plan; 16 case entries in _get_vllm_vram_req |
| `lib/wizard.sh:vllm_models array`        | `lib/wizard.sh:menu display`           | vllm_models indices 1-16 match menu numbers           | VERIFIED | Array has 16 real entries (indices 1-16) + index 0 placeholder; _vllm_line calls 1-16 match   |
| `lib/wizard.sh:_get_vllm_vram_req`       | `lib/wizard.sh:NON_INTERACTIVE VRAM guard` | ni_vram_req from _get_vllm_vram_req used in exit-1 check | VERIFIED | Line 526 calls `_get_vllm_vram_req "$VLLM_MODEL"`; result fed into guard at lines 532-535     |

---

### Requirements Coverage

| Requirement | Source Plan | Description                                                                                                                   | Status    | Evidence                                                                                  |
|-------------|-------------|-------------------------------------------------------------------------------------------------------------------------------|-----------|-------------------------------------------------------------------------------------------|
| WMOD-01     | 17-01-PLAN  | Список моделей vLLM обновлён: Qwen3-8B, Qwen3-8B-AWQ, Qwen3-14B-AWQ, Qwen3-Coder-Next MoE AWQ, Nemotron Nano MoE AWQ; vram_req скорректирован; рекомендации обновлены | SATISFIED | All 5 named models present in wizard.sh menu, vram_req array corrected, rec_idx loop covers all 16 |
| WMOD-02     | 17-01-PLAN  | MODEL_SIZES в lib/models.sh содержит approximate sizes для всех новых моделей                                                 | SATISFIED | lib/models.sh lines 27-43: all 16 vLLM models have HuggingFace-name entries in MODEL_SIZES |

---

### Anti-Patterns Found

| File            | Line | Pattern              | Severity | Impact  |
|-----------------|------|----------------------|----------|---------|
| `lib/wizard.sh` | 321, 449 | `"" # 0 placeholder` | Info   | Intentional — index-0 placeholder in two separate wizard model arrays; correct by design |

No blockers or warnings found.

---

### Human Verification Required

None. All observable truths were verified programmatically through file content inspection.

---

### Gaps Summary

No gaps. All 7 must-have truths are verified. Both artifacts exist, are substantive, and are wired correctly:

- `lib/wizard.sh` was expanded from 10-model to 16-model vLLM menu across 5 structured sections (AWQ / 7-8B bf16 / 14B bf16 / 32B+ bf16 / MoE) plus custom option (17).
- `_get_vllm_vram_req()` covers all 16 models with corrected values: Qwen2.5-14B-AWQ corrected 12→10 GB, Qwen2.5-7B-AWQ corrected 8→5 GB.
- `vram_req` array (indices 1-16) and `vllm_models` array (indices 1-16) are fully aligned with menu display.
- NON_INTERACTIVE VRAM guard at line 524-541 uses `_get_vllm_vram_req` and will correctly validate all 16 new models.
- `lib/models.sh` MODEL_SIZES was extended with all 16 vLLM HuggingFace-name entries, correctly separated from existing Ollama entries.
- Both files pass `bash -n` syntax validation.
- Commits 44e2365 and 767a9ac confirmed present in git history.
- WMOD-01 and WMOD-02 marked [x] complete in REQUIREMENTS.md.

---

_Verified: 2026-03-23T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
