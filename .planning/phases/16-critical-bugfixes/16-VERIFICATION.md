---
phase: 16-critical-bugfixes
verified: 2026-03-23T12:00:00Z
status: passed
score: 4/4 must-haves verified
re_verification: false
---

# Phase 16: Critical Bugfixes — Verification Report

**Phase Goal:** VRAM guard работает в NON_INTERACTIVE режиме и не позволяет запустить модель больше GPU; resume установки всегда инициализирует DETECTED_OS/DETECTED_GPU_VRAM независимо от стартовой фазы.
**Verified:** 2026-03-23T12:00:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                                      | Status     | Evidence                                                                                                                                                          |
|----|------------------------------------------------------------------------------------------------------------|------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | NON_INTERACTIVE install with VLLM_MODEL exceeding GPU VRAM exits with error instead of silently continuing | VERIFIED   | `_wizard_llm_model()` lines 502-521: guard fires when `NON_INTERACTIVE=true && LLM_PROVIDER=vllm && ni_vram_req > ni_vram_gb`, calls `exit 1` with error message |
| 2  | NON_INTERACTIVE install with default VLLM_MODEL (Qwen2.5-14B) validates VRAM and exits if insufficient     | VERIFIED   | Default `VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct"` assigned at line 499; same guard block runs immediately after (BFIX-41 comment confirms intent)                 |
| 3  | Resume install from phase >= 2 always initializes DETECTED_OS and DETECTED_GPU_VRAM                        | VERIFIED   | `install.sh` lines 465-468: `if [[ $start -gt 1 ]]; then run_diagnostics \|\| true; fi` executes before phase table; `run_diagnostics()` in `lib/detect.sh:267` sets both vars |
| 4  | Resume from phase >= 2 with no GPU sets DETECTED_GPU_VRAM=0 without unbound variable errors                | VERIFIED   | `lib/detect.sh:64`: `DETECTED_GPU_VRAM="0"` is the unconditional default before any GPU detection attempt; `\|\| true` on resume call prevents crash on partial failure |

**Score:** 4/4 truths verified

---

### Required Artifacts

| Artifact        | Expected                                       | Status   | Details                                                                                       |
|-----------------|------------------------------------------------|----------|-----------------------------------------------------------------------------------------------|
| `lib/wizard.sh` | VRAM guard for NON_INTERACTIVE path in `_wizard_llm_model()`, contains `_get_vllm_vram_req` | VERIFIED | Function defined at line 351, called at line 506; `bash -n` passes; 10 model mappings present (lines 354-364) |
| `install.sh`    | Always-run diagnostics on resume, contains `run_diagnostics` | VERIFIED | Resume block present at lines 461-468 with `BFIX-42` comment; `bash -n` passes; `run_diagnostics` appears 3 times (line 136 in `phase_diagnostics`, lines 462/467 in new resume block) |

---

### Key Link Verification

| From                                    | To                                   | Via                           | Status   | Details                                                                                              |
|-----------------------------------------|--------------------------------------|-------------------------------|----------|------------------------------------------------------------------------------------------------------|
| `lib/wizard.sh:_wizard_llm_model()`     | `lib/wizard.sh:_get_vllm_vram_req()` | shared VRAM lookup function   | WIRED    | Function defined at line 351; called at line 506 inside `_wizard_llm_model()` — confirmed by grep   |
| `install.sh:main()`                     | `lib/detect.sh:run_diagnostics()`    | unconditional call before phase table on resume | WIRED | `run_diagnostics` called at line 467 when `start > 1`; `lib/detect.sh` sourced at `install.sh:22`; `run_diagnostics()` defined at `lib/detect.sh:267` |

---

### Requirements Coverage

| Requirement | Source Plan | Description                                                                                                          | Status    | Evidence                                                                                                         |
|-------------|-------------|----------------------------------------------------------------------------------------------------------------------|-----------|------------------------------------------------------------------------------------------------------------------|
| BFIX-41     | 16-01-PLAN  | NON_INTERACTIVE + VLLM_MODEL из env — VRAM guard проверяет и exit 1 если превышает; дефолт Qwen2.5-14B тоже проверяется | SATISFIED | `_wizard_llm_model()` falls through for vllm instead of early-returning; VRAM guard with `exit 1` at line 515   |
| BFIX-42     | 16-01-PLAN  | Resume с phase >= 2 — run_diagnostics выполняется всегда для инициализации DETECTED_OS/DETECTED_GPU_VRAM             | SATISFIED | Resume block `if [[ $start -gt 1 ]]; then run_diagnostics \|\| true; fi` at install.sh lines 465-468            |

Both requirements marked `[x]` (complete) in `.planning/REQUIREMENTS.md` lines 12-13 and confirmed at lines 231-232.

---

### Anti-Patterns Found

None found in the sections modified by this phase. No TODO/FIXME/HACK/PLACEHOLDER comments. No stub returns. No empty implementations.

---

### Regression Checks

| Check                                                      | Status   | Evidence                                                                                           |
|------------------------------------------------------------|----------|----------------------------------------------------------------------------------------------------|
| Interactive vllm path still calls `_wizard_vllm_model()`  | VERIFIED | `lib/wizard.sh:488`: `vllm) _wizard_vllm_model;;` in the `else` (interactive) branch              |
| `phase_diagnostics` still runs for fresh install (start=1) | VERIFIED | `install.sh:472`: `[[ $start -le 1 ]] && run_phase 1 $t "Diagnostics" phase_diagnostics`         |
| `_wizard_vllm_model()` recursive VRAM guard for interactive still intact | VERIFIED | Lines 451-464 of wizard.sh: existing warn/re-show-menu logic untouched                    |

---

### Human Verification Required

The following behaviors cannot be verified programmatically and require a manual test run to fully confirm:

#### 1. NON_INTERACTIVE VRAM overflow triggers exit 1

**Test:** `NON_INTERACTIVE=true LLM_PROVIDER=vllm VLLM_MODEL="meta-llama/Llama-3.3-70B-Instruct" DETECTED_GPU_VRAM=16384 bash -c 'source lib/wizard.sh; _wizard_llm_model'`
**Expected:** Script exits with code 1 and prints error message referencing "140 GB VRAM" vs "16 GB"
**Why human:** Requires sourcing wizard.sh in a controlled env with mocked DETECTED_GPU_VRAM; not safe to run in this context

#### 2. Resume from phase 3 populates DETECTED_GPU_VRAM

**Test:** Create `.install_phase` with value `3`, then run `sudo bash install.sh` — observe logs
**Expected:** Log line "Resume: re-running system diagnostics..." appears before phase 3 starts; subsequent phases can reference `$DETECTED_GPU_VRAM` without "unbound variable" errors
**Why human:** Requires actual install environment with `.install_phase` file and full script execution

---

### Commit Verification

Both commits documented in SUMMARY.md exist and are valid:

- `6eeb86a` — `fix(16-01): BFIX-41 -- add VRAM guard to NON_INTERACTIVE vllm path`
- `a16832b` — `fix(16-01): BFIX-42 -- always run diagnostics on resume before phase table`

---

## Summary

Both critical bugs from v2.3 are fixed. The implementation exactly matches the plan:

**BFIX-41:** `_wizard_llm_model()` no longer early-returns for `vllm` in NON_INTERACTIVE mode. Instead it falls through to the default assignment block and then executes the VRAM guard which calls `_get_vllm_vram_req()` (a new shared function mapping all 10 known models). If the model requires more VRAM than available, `exit 1` is called with a clear error. Unknown custom models get a warning only (no exit), matching interactive behavior. The interactive path (`_wizard_vllm_model()`) is unchanged.

**BFIX-42:** `install.sh main()` now calls `run_diagnostics || true` unconditionally when `start > 1` (resume case), positioned between the `.env` load block and the phase table. This populates all `DETECTED_*` variables before any resumed phase can reference them. No-GPU systems get `DETECTED_GPU_VRAM=0` from `detect.sh`'s safe default. Fresh installs (start=1) are unaffected — `phase_diagnostics` still runs normally at phase 1.

---

_Verified: 2026-03-23T12:00:00Z_
_Verifier: Claude (gsd-verifier)_
