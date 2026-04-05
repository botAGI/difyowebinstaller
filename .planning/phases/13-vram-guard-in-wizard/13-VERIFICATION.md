---
phase: 13-vram-guard-in-wizard
verified: 2026-03-23T00:00:00Z
status: passed
score: 6/6 must-haves verified
re_verification: false
---

# Phase 13: VRAM Guard in Wizard — Verification Report

**Phase Goal:** Wizard не позволяет молча выбрать модель vLLM, которая не помещается в VRAM — пользователь видит требования к памяти рядом с каждой моделью и получает предупреждение при попытке выбрать слишком большую.
**Verified:** 2026-03-23T00:00:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                   | Status     | Evidence                                                                 |
|----|-----------------------------------------------------------------------------------------|------------|--------------------------------------------------------------------------|
| 1  | Each vLLM model line in wizard shows required VRAM in GB                               | VERIFIED   | `_vllm_line` prints `[${vram_req[$idx]} GB VRAM]` for every model line  |
| 2  | Only the best-fitting model gets `[рекомендуется]` tag                                 | VERIFIED   | `rec_idx` found by descending loop `10..1`, tag applied only at match   |
| 3  | Selecting oversized model triggers warning with exact numbers + y/N confirmation        | VERIFIED   | Lines 432-444: YELLOW message with GB values + `read -rp "Продолжить?"` |
| 4  | DETECTED_GPU_VRAM=0/empty: all models shown without recommendation, one top warning    | VERIFIED   | Lines 386-388: YELLOW "GPU VRAM не определён..." printed when vram_gb=0 |
| 5  | NON_INTERACTIVE mode skips warning and uses selected model as-is                        | VERIFIED   | Line 435: `[[ "${NON_INTERACTIVE}" != "true" ]]` guards confirmation    |
| 6  | Custom model (option 11) has no VRAM check                                              | VERIFIED   | Lines 445-448: elif branch for REPLY=11, no vram_req comparison present |

**Score:** 6/6 truths verified

---

### Required Artifacts

| Artifact       | Expected                              | Status     | Details                                                              |
|----------------|---------------------------------------|------------|----------------------------------------------------------------------|
| `lib/wizard.sh` | VRAM-aware `_wizard_vllm_model()` function | VERIFIED | Lines 348-454: full implementation with `vram_req` array, display loop, recommendation logic, OOM guard |

**Level 1 (Exists):** File present at `lib/wizard.sh`.

**Level 2 (Substantive):** 74 lines added to function (commit `4e5e78c` shows +74 insertions). Contains:
- `local -a vram_req=(0 8 12 16 16 16 28 28 28 48 140)` — correct per CONTEXT.md
- `vram_gb=$(( DETECTED_GPU_VRAM / 1024 ))` — MB to GB conversion
- `effective_vram=$(( vram_gb - 2 ))` — TEI offset applied only to recommendation
- Descending loop `10 9 8 7 6 5 4 3 2 1` finds best-fit `rec_idx`
- Nested `_vllm_line()` helper with `${GREEN}[рекомендуется]${NC}` at matching index
- 10 preset model lines (AWQ x2, 7-8B x3, 14B x3, 32B+2)
- Option 11 custom model path with no VRAM check
- OOM guard: `vram_req[$REPLY] -gt vram_gb` with `read -rp "Продолжить? (y/N)"`
- Recursive re-show on "N" answer
- `unset -f _vllm_line` cleanup

**Level 3 (Wired):** Called from wizard dispatch at line 464: `vllm) _wizard_vllm_model;;`. VLLM_MODEL is set for all 11 options and consumed by downstream wizard flow. DETECTED_GPU_VRAM is exported from `lib/detect.sh` (lines 64-135) — variable is available at wizard runtime.

---

### Key Link Verification

| From            | To              | Via                              | Status   | Details                                                      |
|-----------------|-----------------|----------------------------------|----------|--------------------------------------------------------------|
| `lib/wizard.sh` | `lib/detect.sh` | `DETECTED_GPU_VRAM` variable (MB) | VERIFIED | `detect.sh` exports `DETECTED_GPU_VRAM` (lines 78, 84, 100, 111, 130, 135); `wizard.sh` reads `${DETECTED_GPU_VRAM:-0}` at line 353 |

---

### Requirements Coverage

| Requirement | Source Plan     | Description                                                                                                   | Status    | Evidence                                                                      |
|-------------|-----------------|---------------------------------------------------------------------------------------------------------------|-----------|-------------------------------------------------------------------------------|
| IREL-02     | 13-01-PLAN.md   | Wizard показывает требуемый VRAM рядом с каждой моделью vLLM и ставит `[рекомендуется]` только если VRAM >= требуемого; предупреждение при выборе слишком большой модели (BUG-036) | SATISFIED | All three aspects implemented: per-model VRAM labels, dynamic recommendation tag, OOM warning with confirmation |

**Orphaned requirements check:** REQUIREMENTS.md Traceability table maps only IREL-02 to Phase 13. No orphaned requirements.

---

### Anti-Patterns Found

| File            | Line | Pattern                   | Severity | Impact |
|-----------------|------|---------------------------|----------|--------|
| `lib/wizard.sh` | 321  | `"" # 0 placeholder`      | Info     | Intentional array index-0 padding in `vllm_models`, not a stub |
| `lib/wizard.sh` | 415  | `"" # 0 placeholder`      | Info     | Same pattern — duplicate of line 321 in different function (existing code) |

No blockers or warnings found. Both "placeholder" strings are intentional index-0 array elements, consistent with the pattern used in the Ollama model array at line 321.

---

### Human Verification Required

#### 1. Visual menu rendering

**Test:** Run `sudo bash install.sh` with LLM_PROVIDER=vllm on a machine with a known GPU (e.g. 24 GB). Observe the model selection menu.
**Expected:** Each model line shows `[N GB VRAM]` suffix. The model fitting 22 GB effective VRAM (24 - 2 TEI) gets a green `[рекомендуется]` tag — with 24 GB that would be option 8 (phi-4, 28 GB does NOT fit 22 GB) so option 5/6/7 at 16/28 — actually option 6 (Qwen2.5-14B, 28 GB would not fit 22 GB), option 5 (Llama-3.1-8B, 16 GB fits) should be recommended. Verify correct model is tagged.
**Why human:** Color output and visual alignment cannot be verified programmatically. The recommendation math should produce rec_idx=5 for 24 GB GPU (effective=22, largest fitting: 16 GB models → index 5 Llama, 4 Mistral, 3 Qwen7B — loop picks highest index = 5).

#### 2. OOM warning flow

**Test:** On a machine reporting 16 GB VRAM, select option 9 (Qwen2.5-32B, 48 GB). Verify warning text appears with exact numbers and y/N prompt. Press N and verify menu re-appears.
**Expected:** "Модель требует 48 GB VRAM, доступно 16 GB. Возможен OOM." + "Продолжить? (y/N):" → pressing N re-shows the full model menu.
**Why human:** Interactive read prompt cannot be automated in verification.

---

### Gaps Summary

No gaps. All 6 observable truths are verified, the sole artifact (`lib/wizard.sh`) passes all three levels (existence, substantive, wired), the key link from `wizard.sh` to `detect.sh` via `DETECTED_GPU_VRAM` is confirmed active, and IREL-02 is fully satisfied by the implementation.

Syntax validation via `bash -n lib/wizard.sh` passes (zero output, exit 0). Shellcheck was unavailable on the host machine during execution; the PLAN provides a manual fallback checklist which the executor confirmed satisfied (quoted variables, `$(( ))` arithmetic, no unbound vars).

---

_Verified: 2026-03-23T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
