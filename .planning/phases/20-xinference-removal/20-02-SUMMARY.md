---
phase: 20-xinference-removal
plan: "02"
subsystem: scripts,templates,docs
tags: [xinference-removal, cleanup, update, maintenance]
dependency_graph:
  requires: [20-01]
  provides: [xinference-free-scripts, xinference-orphan-cleanup]
  affects: [scripts/update.sh, scripts/agmind.sh, scripts/uninstall.sh, scripts/check-upstream.sh, scripts/generate-manifest.sh, scripts/check-manifest-versions.py, templates/versions.env, templates/release-manifest.json, COMPONENTS.md, COMPATIBILITY.md]
tech_stack:
  added: []
  patterns: [orphan-container-cleanup-on-update]
key_files:
  created: []
  modified:
    - scripts/agmind.sh
    - scripts/check-upstream.sh
    - scripts/generate-manifest.sh
    - scripts/check-manifest-versions.py
    - scripts/update.sh
    - scripts/uninstall.sh
    - templates/versions.env
    - templates/release-manifest.json
    - COMPONENTS.md
    - COMPATIBILITY.md
decisions:
  - "Xinference orphan cleanup inserted in main() before perform_bundle_update to run on every agmind update on existing installations"
  - "cleanup block uses docker ps/volume ls with grep to safely no-op if container/volume absent"
metrics:
  duration: "~16 minutes"
  completed: "2026-03-23T08:07:34Z"
  tasks_completed: 2
  files_modified: 10
requirements: [XINF-01]
---

# Phase 20 Plan 02: Xinference Removal — Peripheral Scripts, Configs, and Docs Summary

**One-liner:** Removed all Xinference references from peripheral scripts, config files, and documentation, and added an orphan container/volume cleanup block to update.sh for smooth migration of existing installations.

## Tasks Completed

| Task | Description | Commit |
|------|-------------|--------|
| 1 | Remove Xinference from agmind.sh, check-upstream.sh, generate-manifest.sh, check-manifest-versions.py | 89526b3 |
| 2 | Xinference orphan cleanup in update.sh + uninstall.sh + configs + docs | 75a7ca0 |

## What Was Done

### Task 1: Peripheral script cleanup

- **scripts/agmind.sh**: Removed `xinference)  env_var="XINFERENCE_CUDA_DEVICE"` case from `_gpu_assign()`. Updated error message and help text to list only `vllm, tei`.
- **scripts/check-upstream.sh**: Removed `"Xinference|XINFERENCE_VERSION|xorbitsai/inference|gh"` from `DAILY_CHECKS` array.
- **scripts/generate-manifest.sh**: Removed `"xinference|docker.io|xprobe/xinference|${XINFERENCE_VERSION}|linux/amd64"` from image list.
- **scripts/check-manifest-versions.py**: Removed `"xinference"` from `required_services` set and `"xinference": "XINFERENCE_VERSION"` from `tag_to_version_key` dict.

### Task 2: Update flow + config + docs cleanup

- **scripts/update.sh**:
  - Removed `[xinference]=XINFERENCE_VERSION` from `NAME_TO_VERSION_KEY` associative array.
  - Removed `[xinference]="xinference"` from `NAME_TO_SERVICES` associative array.
  - Removed `"xinference"` from `perform_bundle_update` update_order list.
  - Added xinference orphan cleanup block in `main()` before `perform_bundle_update` — stops and removes `agmind-xinference` container and `agmind_xinference_data` volume if present on existing installations.
- **scripts/uninstall.sh**: Removed `_xinference_data$` from volume cleanup grep pattern.
- **templates/versions.env**: Removed `XINFERENCE_VERSION=v2.3.0` line.
- **templates/release-manifest.json**: Removed `xinference` entry block. JSON remains valid.
- **COMPONENTS.md**: Removed `| xinference | XINFERENCE_VERSION | Model serving |` row.
- **COMPATIBILITY.md**: Removed Xinference row from version compatibility table. Updated ARM64 note to exclude xinference.

## Verification Results

- `grep -rn "xinference|XINFERENCE" scripts/ templates/versions.env templates/release-manifest.json COMPONENTS.md COMPATIBILITY.md` — only cleanup block in update.sh remains
- `python -m json.tool templates/release-manifest.json` — exits 0 (valid JSON)
- All acceptance criteria passed

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

- scripts/agmind.sh modified: FOUND
- scripts/check-upstream.sh modified: FOUND
- scripts/generate-manifest.sh modified: FOUND
- scripts/check-manifest-versions.py modified: FOUND
- scripts/update.sh modified with cleanup block: FOUND (agmind-xinference, agmind_xinference_data)
- scripts/uninstall.sh modified: FOUND
- templates/versions.env XINFERENCE_VERSION removed: FOUND (count=0)
- templates/release-manifest.json xinference removed + JSON valid: FOUND
- COMPONENTS.md xinference removed: FOUND (count=0)
- COMPATIBILITY.md Xinference removed: FOUND (count=0)
- Commits 89526b3 and 75a7ca0: FOUND
