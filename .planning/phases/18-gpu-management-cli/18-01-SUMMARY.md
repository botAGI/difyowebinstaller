---
phase: 18-gpu-management-cli
plan: 01
subsystem: infra
tags: [gpu, nvidia, cuda, docker-compose, agmind-cli, bash]

# Dependency graph
requires: []
provides:
  - agmind gpu status command (per-GPU VRAM table + container assignments + processes)
  - agmind gpu assign command (manual + --auto distribution)
  - docker-compose.yml env-var substitution for CUDA_VISIBLE_DEVICES
affects:
  - docker-compose deployment (vLLM, TEI profiles)
  - agmind.sh CLI interface
  - docker/.env (VLLM_CUDA_DEVICE, TEI_CUDA_DEVICE vars)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - LC_ALL=C prefix for grep/sed in _set_env_var (locale safety, established in Phase 10)
    - nvidia-smi direct query pattern (more detailed than detect_gpu, multi-GPU aware)
    - ${VAR:-default} docker compose env substitution for GPU assignment

key-files:
  created: []
  modified:
    - scripts/agmind.sh
    - templates/docker-compose.yml

key-decisions:
  - "_gpu_status does not require root (nvidia-smi readable without root, .env read-only); _gpu_assign requires root (writes to .env)"
  - "xinference supported in _gpu_assign (XINFERENCE_CUDA_DEVICE) but NOT in --auto (uses count:all by design)"
  - "_gpu_status calls nvidia-smi directly instead of detect_gpu() - provides per-GPU detail and multi-GPU support"
  - "Multi-GPU auto-assign: vLLM -> biggest free VRAM GPU, TEI -> smallest free VRAM GPU (tie-break: 0/1)"

patterns-established:
  - "_set_env_var pattern: LC_ALL=C grep to check existence, LC_ALL=C sed -i to update in-place, echo >> to append if missing"
  - "GPU management CLI pattern: cmd_gpu dispatcher -> {_gpu_status, _gpu_assign} -> _gpu_auto_assign"

requirements-completed: [GPUM-01, GPUM-02, GPUM-03]

# Metrics
duration: 2min
completed: 2026-03-23
---

# Phase 18 Plan 01: GPU Management CLI Summary

**agmind gpu CLI with status/assign/--auto commands and docker-compose.yml ${VLLM_CUDA_DEVICE:-0}/${TEI_CUDA_DEVICE:-0} env-var substitution for multi-GPU server support**

## Performance

- **Duration:** 2 min
- **Started:** 2026-03-23T09:08:32Z
- **Completed:** 2026-03-23T09:10:17Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Replaced hardcoded `CUDA_VISIBLE_DEVICES=0` in vLLM and TEI docker-compose services with `${VLLM_CUDA_DEVICE:-0}` and `${TEI_CUDA_DEVICE:-0}` — existing installs unaffected (default=0)
- Added `_gpu_status` function: queries nvidia-smi for per-GPU name/VRAM/utilization table, reads container assignments from .env, shows active GPU compute processes
- Added `_gpu_assign` + `_gpu_auto_assign`: manual assignment with validation (service name, GPU ID range) and auto-distribution on multi-GPU (vLLM->biggest free VRAM, TEI->smallest)
- Added `_set_env_var` helper with `LC_ALL=C` locale safety for in-place .env updates
- Updated dispatch case and help text with `gpu [subcommand]` documentation

## Task Commits

Each task was committed atomically:

1. **Task 1: Replace hardcoded CUDA_VISIBLE_DEVICES with env-var substitution** - `27295ee` (feat)
2. **Task 2: Add cmd_gpu with _gpu_status and _gpu_assign to agmind.sh** - `0963f63` (feat)

**Plan metadata:** (docs commit below)

## Files Created/Modified

- `templates/docker-compose.yml` - vLLM line 320: CUDA_VISIBLE_DEVICES=0 -> ${VLLM_CUDA_DEVICE:-0}; TEI line 352: CUDA_VISIBLE_DEVICES=0 -> ${TEI_CUDA_DEVICE:-0}
- `scripts/agmind.sh` - Added _set_env_var helper, GPU MANAGEMENT section (_gpu_status, _gpu_auto_assign, _gpu_assign, cmd_gpu), gpu) dispatch branch, help text update

## Decisions Made

- `_gpu_status` does not require root: nvidia-smi works without root, .env is read-only access — user convenience
- `xinference` supported in `_gpu_assign` (XINFERENCE_CUDA_DEVICE) but NOT in `--auto` because xinference uses `count: all` GPU deploy block by design
- Used direct nvidia-smi queries in `_gpu_status` instead of `detect_gpu()` from detect.sh — provides per-GPU multi-GPU detail, detect_gpu only reads first GPU
- Multi-GPU tie-break in `_gpu_auto_assign`: if biggest_gpu == smallest_gpu (all equal free VRAM), spread 0/1 to ensure distinct assignment

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required. Existing installs continue to work with default CUDA_VISIBLE_DEVICES=0 behavior.

## Next Phase Readiness

- Phase 18 complete. All requirements GPUM-01, GPUM-02, GPUM-03 addressed.
- Milestone v2.4 (Phases 16-18) complete — ready for `git tag v2.4.0` and GitHub Release.
- To test GPU assignment on a multi-GPU server: `sudo agmind gpu assign --auto` or `sudo agmind gpu assign vllm 1`.

## Self-Check: PASSED

- FOUND: templates/docker-compose.yml
- FOUND: scripts/agmind.sh
- FOUND: .planning/phases/18-gpu-management-cli/18-01-SUMMARY.md
- FOUND: commit 27295ee (Task 1)
- FOUND: commit 0963f63 (Task 2)

---
*Phase: 18-gpu-management-cli*
*Completed: 2026-03-23*
