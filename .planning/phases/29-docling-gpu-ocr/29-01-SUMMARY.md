---
phase: 29-docling-gpu-ocr
plan: 01
subsystem: infra
tags: [docling, wizard, gpu, cuda, ocr, env-template, sed-pipeline]

# Dependency graph
requires:
  - phase: 28-release-branch
    provides: "versions.env pattern, wizard export pattern, config.sh sed pipeline"
provides:
  - "Triple Docling choice wizard (None/CPU/GPU) with nvidia runtime detection"
  - "DOCLING_IMAGE_CPU and DOCLING_IMAGE_CUDA image refs in versions.env"
  - "DOCLING_IMAGE, OCR_LANG, NVIDIA_VISIBLE_DEVICES placeholders in all 4 env templates"
  - "sed replacements in config.sh for new Docling placeholders"
affects: [30-docling-compose, docker-compose-docling, install.sh]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "GPU runtime detection: check DETECTED_GPU==nvidia AND docker info | grep nvidia before offering GPU option"
    - "Image refs in versions.env as full image:tag (DOCLING_IMAGE_CPU/CUDA), not just version strings"
    - "Wizard sets NVIDIA_VISIBLE_DEVICES=all only for GPU Docling; empty string for CPU/off"
    - "OCR_LANG=rus,eng always set (including offline, where Docling disabled)"

key-files:
  created: []
  modified:
    - templates/versions.env
    - templates/env.lan.template
    - templates/env.vpn.template
    - templates/env.vps.template
    - templates/env.offline.template
    - lib/wizard.sh
    - lib/config.sh

key-decisions:
  - "GPU option (item 3) hidden from user if has_nvidia_runtime=false — no wrong choice possible"
  - "DOCLING_IMAGE_CPU/CUDA sourced from versions.env (already sourced in install.sh before wizard runs)"
  - "DOCLING_SERVE_VERSION removed from versions.env — replaced by two concrete image:tag refs"
  - "OCR_LANG hardcoded to rus,eng; not user-configurable in wizard (DOCL-03)"
  - "Offline profile skips Docling prompt entirely, sets all vars to safe defaults"

patterns-established:
  - "Runtime feature gate: DETECTED_GPU + docker info double-check before offering hardware-specific option"
  - "Image placeholder pattern: __DOCLING_IMAGE__ in template, substituted by sed in _generate_env_file"

requirements-completed: [DOCL-01, DOCL-02, DOCL-03]

# Metrics
duration: 12min
completed: 2026-03-29
---

# Phase 29 Plan 01: Docling GPU/CPU Wizard + Env Pipeline Summary

**Wizard triple Docling choice (None/CPU/GPU CUDA) with nvidia runtime gate, full image:tag refs in versions.env, and sed-pipeline substitution for DOCLING_IMAGE/OCR_LANG/NVIDIA_VISIBLE_DEVICES in all 4 env profiles**

## Performance

- **Duration:** 12 min
- **Started:** 2026-03-29T13:50:00Z
- **Completed:** 2026-03-29T14:02:00Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments

- versions.env: replaced single `DOCLING_SERVE_VERSION` with full `DOCLING_IMAGE_CPU` and `DOCLING_IMAGE_CUDA` image:tag refs
- All 4 env templates (lan/vpn/vps/offline): added `DOCLING_IMAGE`, `OCR_LANG`, `NVIDIA_VISIBLE_DEVICES` placeholders
- wizard.sh `_wizard_etl`: GPU option visible only when DETECTED_GPU=nvidia AND docker info confirms nvidia runtime
- wizard.sh: defaults, export, and summary updated for new variables
- config.sh: 3 new sed replacements for `__DOCLING_IMAGE__`, `__OCR_LANG__`, `__NVIDIA_VISIBLE_DEVICES__`

## Task Commits

Each task was committed atomically:

1. **Task 1: versions.env + env templates** - `4fb0e29` (feat)
2. **Task 2: wizard.sh triple choice + config.sh sed** - `637216f` (feat)

**Plan metadata:** will be added in final commit

## Files Created/Modified

- `templates/versions.env` - Replaced DOCLING_SERVE_VERSION with DOCLING_IMAGE_CPU and DOCLING_IMAGE_CUDA full refs
- `templates/env.lan.template` - Added DOCLING_IMAGE/OCR_LANG/NVIDIA_VISIBLE_DEVICES placeholders
- `templates/env.vpn.template` - Same placeholders
- `templates/env.vps.template` - Same placeholders
- `templates/env.offline.template` - Same placeholders
- `lib/wizard.sh` - _wizard_etl rewritten with triple choice; defaults + export + summary updated
- `lib/config.sh` - 3 new sed substitutions in _generate_env_file

## Decisions Made

- GPU pane (item 3) hidden unless `has_nvidia_runtime=true` — prevents user from selecting GPU Docling on hosts without nvidia container runtime
- `DOCLING_IMAGE_CPU/CUDA` read from `versions.env` at wizard runtime; no hardcoded image strings in wizard.sh
- `DOCLING_SERVE_VERSION` removed — two concrete image:tag refs are simpler and avoid version+registry duplication
- `OCR_LANG` not exposed as user choice — always `rus,eng` per DOCL-03 requirement
- Offline profile: Docling silently disabled (no prompt), `DOCLING_IMAGE=""`, `NVIDIA_VISIBLE_DEVICES=""`

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- wizard.sh and env pipeline ready; docker-compose.yml still needs `DOCLING_IMAGE` and `NVIDIA_VISIBLE_DEVICES` wired into docling service definition (Phase 29 Plan 02 or later)
- versions.env clean: CPU and CUDA image refs in place for future version bumps

## Self-Check: PASSED

All files and commits verified present.

---
*Phase: 29-docling-gpu-ocr*
*Completed: 2026-03-29*
