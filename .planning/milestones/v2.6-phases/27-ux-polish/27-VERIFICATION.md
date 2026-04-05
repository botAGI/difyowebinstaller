---
phase: 27-ux-polish
verified: 2026-03-25T00:00:00Z
status: passed
score: 3/3 must-haves verified
re_verification: false
---

# Phase 27: UX Polish — Verification Report

**Phase Goal:** Оператор видит наглядный прогресс при скачивании моделей и может безопасно проверить конфигурацию установки без запуска контейнеров.
**Scope note:** UXPL-02 (--dry-run) was deferred to backlog v3.0+ during discuss-phase. Only UXPL-01 is in scope for this phase.
**Verified:** 2026-03-25
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Operator sees real-time model download progress in TTY mode (Ollama native progress, vLLM/TEI raw docker logs) | VERIFIED | `lib/models.sh:69` — `[ -t 1 ]` branches to `docker logs -f --since=0s "$container" 2>&1 &` (background PID); Ollama `pull_model()` unchanged at line 183 using `docker exec -t` |
| 2 | In non-TTY mode only status messages appear (no raw log streaming) | VERIFIED | `lib/models.sh:106-131` — non-TTY path polls `--tail=1` every 10s and emits a single `log_info "${label}: ${summary}"` line; background `docker logs -f` PID is never spawned |
| 3 | On timeout the container keeps running, installer continues with WARNING and shows recovery docker commands | VERIFIED | `install.sh:155-181` (`phase_models_graceful`) and `install.sh:112-127` (`run_phase_with_timeout` Models block) — both check `LLM_PROVIDER`/`EMBED_PROVIDER` and emit provider-specific `docker logs -f` or `docker exec ollama pull` commands; both `return 0` (non-fatal) |

**Score:** 3/3 truths verified

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/models.sh` | Streaming download for vLLM/TEI, TTY-aware pull_model, timeout recovery messages | VERIFIED | Contains `_stream_gpu_model_logs()` (lines 56-132); `download_models()` calls it for `agmind-vllm` (line 274) and `agmind-tei` (line 285); passes `bash -n` |
| `install.sh` | Updated `phase_models_graceful` with provider-specific recovery commands | VERIFIED | `phase_models_graceful()` lines 155-181 contains provider-conditional `docker logs -f agmind-vllm` and `docker logs -f agmind-tei`; `run_phase_with_timeout` Models block lines 112-127 similarly updated; passes `bash -n` |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/models.sh:download_models` | `docker logs -f` | `_stream_gpu_model_logs` helper | WIRED | `_stream_gpu_model_logs` defined at line 56; called at lines 274 and 285 inside `download_models()`; function body contains `docker logs -f --since=0s "$container"` at line 71 |
| `install.sh:phase_models_graceful` | `lib/models.sh:download_models` | function call via `phase_models` | WIRED | `phase_models_graceful()` calls `phase_models` (line 157); `phase_models` is `{ download_models; }` (line 154); called at install.sh:579 inside `run_phase_with_timeout` |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| UXPL-01 | 27-01-PLAN.md | Скачивание моделей стримит docker logs -f с progress bar; при таймауте — warning + инструкция docker команд для ручного pull | SATISFIED | `_stream_gpu_model_logs()` in lib/models.sh implements TTY streaming + non-TTY polling; timeout recovery messages with exact `docker logs -f` commands exist in both `phase_models_graceful` and `run_phase_with_timeout` Models block |
| UXPL-02 | N/A — deferred | install.sh --dry-run режим | DEFERRED — backlog v3.0+ | Confirmed deferred in 27-CONTEXT.md; REQUIREMENTS.md line 67 shows "Backlog v3.0+" status |

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `install.sh` | 405, 424 | Word "placeholder" | Info | Unrelated to Phase 27 — refers to nginx self-signed cert and health.json bootstrap; pre-existing, not introduced by this phase |

No blockers. No warnings related to Phase 27 scope.

---

## Bash Syntax and Shellcheck

| Check | File | Result |
|-------|------|--------|
| `bash -n` | `lib/models.sh` | PASS |
| `bash -n` | `install.sh` | PASS |
| Shellcheck note | Both | `shellcheck` not available in execution environment; `bash -n` syntax checks confirm no syntax errors |

---

## Git Commits Verified

Both commits documented in SUMMARY.md exist in git history:

- `dac8105` — feat(27-01): Add _stream_gpu_model_logs and TTY-aware vLLM/TEI progress
- `ace1a0b` — feat(27-01): Provider-aware recovery commands in phase_models_graceful

---

## Human Verification Required

### 1. TTY streaming output quality

**Test:** Run installer in a real TTY with `LLM_PROVIDER=vllm`, trigger the model phase while `agmind-vllm` container is downloading a model.
**Expected:** Raw HuggingFace download lines from `docker logs -f agmind-vllm` stream to the terminal in real time. Progress lines (tqdm bars, download percentages) are visible and readable.
**Why human:** Cannot verify visual terminal output programmatically. Requires an actual GPU host with vLLM container running.

### 2. Non-TTY log cleanliness

**Test:** Run installer piped to a file (`sudo bash install.sh | tee install.log`) with `LLM_PROVIDER=tei`, observe install.log during model phase.
**Expected:** No raw tqdm/carriage-return characters in the log file. Only periodic `log_info "TEI: ..."` status lines (one per 10 seconds).
**Why human:** `\r`-character suppression in non-TTY mode is implemented but terminal/file rendering differences require manual inspection.

### 3. Timeout recovery message visibility

**Test:** Set `TIMEOUT_GPU_HEALTH=10` (short timeout), run model phase with `LLM_PROVIDER=vllm`.
**Expected:** After 10 seconds, installer prints `Monitor: docker logs -f agmind-vllm`, continues to next phase without error exit.
**Why human:** Requires a live environment to trigger the timeout path end-to-end.

---

## Gaps Summary

No gaps. All three observable truths are verified. Both required artifacts exist, are substantive, and are wired correctly into the install flow. UXPL-01 is satisfied. UXPL-02 is correctly deferred (backlog v3.0+) and does not constitute a gap for this phase.

---

_Verified: 2026-03-25_
_Verifier: Claude (gsd-verifier)_
