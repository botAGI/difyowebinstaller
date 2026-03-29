---
phase: 29-docling-gpu-ocr
plan: 02
subsystem: infra
tags: [docling, docker-compose, gpu, ocr, offline-bundle, nvidia]

# Dependency graph
requires: []
provides:
  - "Docling docker-compose service uses ${DOCLING_IMAGE} from .env (not hardcoded)"
  - "NVIDIA_VISIBLE_DEVICES env var controls GPU passthrough to Docling container"
  - "OCR_LANG=rus,eng passed to Docling container by default"
  - "versions.env has DOCLING_IMAGE_CPU and DOCLING_IMAGE_CUDA entries"
  - "build-offline-bundle.sh supports INCLUDE_DOCLING_CUDA=true for +5-8 GB CUDA image"
affects: [29-03, 29-04]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "GPU passthrough via NVIDIA_VISIBLE_DEVICES env var (not deploy.resources.reservations)"
    - "Docling image selection via single DOCLING_IMAGE variable in .env"
    - "Offline bundle optional heavy image via INCLUDE_* env flag pattern"

key-files:
  created: []
  modified:
    - templates/docker-compose.yml
    - scripts/build-offline-bundle.sh
    - templates/versions.env

key-decisions:
  - "GPU passthrough for Docling uses NVIDIA_VISIBLE_DEVICES env var, NOT #__GPU__ deploy.resources pattern — keeps single docling service"
  - "DOCLING_IMAGE in .env holds full image:tag (wizard sets it, compose reads it)"
  - "Offline bundle always includes CPU image; CUDA image optional via INCLUDE_DOCLING_CUDA=true"
  - "DOCLING_SERVE_VERSION replaced by DOCLING_IMAGE_CPU and DOCLING_IMAGE_CUDA in versions.env"

patterns-established:
  - "INCLUDE_*=true pattern for optional heavy images in offline bundle"

requirements-completed: [DOCL-01, DOCL-04]

# Metrics
duration: 15min
completed: 2026-03-29
---

# Phase 29 Plan 02: Docker-compose Docling GPU/OCR + Offline Bundle Summary

**Docling service switched to dynamic ${DOCLING_IMAGE} variable with NVIDIA_VISIBLE_DEVICES GPU passthrough and OCR_LANG=rus,eng; offline bundle gains INCLUDE_DOCLING_CUDA flag for optional CUDA image (+5-8 GB)**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-29T00:00:00Z
- **Completed:** 2026-03-29
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Docling docker-compose service now reads image from `${DOCLING_IMAGE:-ghcr.io/.../docling-serve:v1.14.3}` instead of hardcoded `DOCLING_SERVE_VERSION`
- GPU access controlled via `NVIDIA_VISIBLE_DEVICES` env var (empty = CPU, "all" = GPU) — no deploy.resources block needed
- OCR language `rus,eng` passed to container; user can override in .env without restart
- versions.env updated: `DOCLING_SERVE_VERSION` replaced by `DOCLING_IMAGE_CPU` and `DOCLING_IMAGE_CUDA` (cu128 variant)
- Offline bundle: CPU image always included; `INCLUDE_DOCLING_CUDA=true` adds CUDA image

## Task Commits

Each task was committed atomically:

1. **Task 1: docker-compose.yml — Docling dynamic image, GPU env, OCR_LANG** - `8b3298c` (feat)
2. **Task 2: build-offline-bundle.sh — INCLUDE_DOCLING_CUDA flag** - `d1037a2` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `templates/docker-compose.yml` - Docling service: image var, environment block with NVIDIA_VISIBLE_DEVICES + OCR_LANG
- `templates/versions.env` - Replaced DOCLING_SERVE_VERSION with DOCLING_IMAGE_CPU + DOCLING_IMAGE_CUDA
- `scripts/build-offline-bundle.sh` - INCLUDE_DOCLING_CUDA flag, DOCLING_IMAGE_* parser, conditional CUDA pull/save

## Decisions Made

- GPU passthrough via `NVIDIA_VISIBLE_DEVICES` env var (not `deploy.resources.reservations`) — single service, no duplicate docling-cuda service needed
- `DOCLING_IMAGE` in .env holds full `image:tag` for maximum transparency
- CPU image always in bundle; CUDA image optional via env flag (consistent with other "big optional" patterns)

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Task 1 (docker-compose) and Task 2 (offline bundle) complete — ready for Phase 29 Plan 03 (wizard GPU/CPU selection step)
- Plan 03 will use `DOCLING_IMAGE_CPU` and `DOCLING_IMAGE_CUDA` from versions.env to populate wizard menu options
- Plan 04 will update env templates and config.sh to wire `DOCLING_IMAGE` and `OCR_LANG` placeholders

---
*Phase: 29-docling-gpu-ocr*
*Completed: 2026-03-29*
