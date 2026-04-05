---
phase: 27-ux-polish
plan: 01
subsystem: infra
tags: [bash, docker, models, vllm, tei, ollama, streaming, ux]

# Dependency graph
requires:
  - phase: 25-install-stability
    provides: _parse_gpu_progress pattern (polling docker compose logs), TIMEOUT_GPU_HEALTH var
  - phase: 22-reranker-wizard-docker-vram
    provides: TEI container name (agmind-tei), EMBED_PROVIDER=tei path
provides:
  - _stream_gpu_model_logs() helper in lib/models.sh (TTY + non-TTY streaming)
  - Provider-aware recovery commands in phase_models_graceful and run_phase_with_timeout
affects: [install-flow, models-phase, vllm-deployment, tei-deployment]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - TTY detection via [ -t 1 ] for streaming vs polling branch
    - docker logs -f background PID + health poll + inactivity guard
    - Provider-aware recovery messages keyed on LLM_PROVIDER / EMBED_PROVIDER

key-files:
  created: []
  modified:
    - lib/models.sh
    - install.sh

key-decisions:
  - "_stream_gpu_model_logs uses background docker logs -f PID in TTY mode; non-TTY polls --tail=1 every 10s to avoid log flood"
  - "Inactivity guard at 60s in TTY mode warns operator if container output stalls without killing the stream"
  - "On timeout: containers keep running, installer shows exact docker commands per provider (not generic)"
  - "pull_model() (Ollama) unchanged — it already has TTY/-t fallback via docker exec -t"
  - "phase_models_graceful and run_phase_with_timeout both use LLM_PROVIDER/EMBED_PROVIDER for conditional recovery messages"

patterns-established:
  - "GPU streaming pattern: background PID + health poll + inactivity guard for TTY; poll + tail for non-TTY"
  - "Provider-conditional recovery: check LLM_PROVIDER/EMBED_PROVIDER before showing recovery docker command"

requirements-completed: [UXPL-01]

# Metrics
duration: 15min
completed: 2026-03-25
---

# Phase 27 Plan 01: Streaming Model Download Progress Summary

**Real-time vLLM/TEI download streaming via docker logs -f (TTY) and 10s tail polling (non-TTY), with provider-aware timeout recovery commands replacing generic Russian-only messages.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-25T00:00:00Z
- **Completed:** 2026-03-25
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `_stream_gpu_model_logs()` to lib/models.sh: TTY path streams raw docker logs -f with background PID, health polling every 5s, and 60s inactivity guard; non-TTY path polls `--tail=1` every 10s with truncated status line
- `download_models()` now calls `_stream_gpu_model_logs` for agmind-vllm and agmind-tei instead of printing a static one-liner; shows model size hint from MODEL_SIZES; warns with exact `docker logs -f` commands on timeout
- `phase_models_graceful()` in install.sh updated with provider-conditional recovery commands (Ollama pull / vLLM logs / TEI logs) based on LLM_PROVIDER and EMBED_PROVIDER
- `run_phase_with_timeout` Models hard-timeout block updated with same provider-aware logic, replacing generic Ollama-only Russian message

## Task Commits

Each task was committed atomically:

1. **Task 1: Add _stream_gpu_model_logs and TTY-aware vLLM/TEI progress** - `dac8105` (feat)
2. **Task 2: Provider-aware recovery commands in phase_models_graceful** - `ace1a0b` (feat)

## Files Created/Modified

- `lib/models.sh` - Added _stream_gpu_model_logs() helper; updated download_models() vLLM/TEI blocks
- `install.sh` - Updated phase_models_graceful() and run_phase_with_timeout Models timeout block

## Decisions Made

- `_stream_gpu_model_logs` uses background `docker logs -f` PID in TTY mode rather than foreground (allows health polling to run in parallel and kill the stream cleanly when healthy)
- Non-TTY uses 10s poll interval (not 5s) to avoid excessive log churn in CI/piped contexts
- Inactivity guard warns at 60s but does NOT kill the stream — operator sees the warning and can decide
- `pull_model()` (Ollama) left unchanged as it already handles TTY via `docker exec -t` / fallback
- Recovery messages keyed on LLM_PROVIDER/EMBED_PROVIDER so vLLM operators don't see confusing `docker exec ollama` commands

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- `shellcheck` not installed in execution environment — verified manually via `bash -n` syntax check and grep-based acceptance criteria check instead. All patterns confirmed present.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Streaming model download UX complete for all providers (Ollama/vLLM/TEI)
- Recovery messages are provider-aware and actionable
- All scripts pass `bash -n` syntax check
- Ready for Phase 27 Plan 02 (if planned) or phase completion

---
*Phase: 27-ux-polish*
*Completed: 2026-03-25*
