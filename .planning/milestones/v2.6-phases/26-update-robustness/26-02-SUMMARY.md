---
phase: 26-update-robustness
plan: "02"
subsystem: CI / release automation
tags: [ci, github-actions, release-manifest, python, gitignore]
dependency_graph:
  requires: []
  provides: [auto-manifest-sync-on-release]
  affects: [templates/release-manifest.json, .github/workflows/sync-release.yml]
tech_stack:
  added: [scripts/update-release-manifest.py]
  patterns: [python script invoked from CI rather than inline python3 -c]
key_files:
  created:
    - scripts/update-release-manifest.py
  modified:
    - .github/workflows/sync-release.yml
    - .gitignore
decisions:
  - "Extracted python logic into scripts/update-release-manifest.py instead of python3 -c inline to avoid YAML multi-line quoting issues"
  - "Narrowed .gitignore 'workflows/' pattern to '/workflows/' to stop it matching .github/workflows/"
metrics:
  duration_seconds: 178
  completed_date: "2026-03-25"
  tasks_completed: 1
  files_changed: 3
---

# Phase 26 Plan 02: Release Manifest CI Sync Summary

CI workflow extended to auto-update `release-manifest.json` from `versions.env` on every GitHub Release publish via dedicated Python helper script.

## What Was Built

When a maintainer publishes a GitHub Release with a `versions.env` asset attached, the `sync-release` CI job now:

1. Downloads `versions.env` from the release (existing step, unchanged)
2. Copies `versions.env` to `templates/versions.env` and writes `RELEASE` (existing, unchanged)
3. Calls `python3 scripts/update-release-manifest.py "$TAG" "${RELEASE_DATE:-}"` to patch `release-manifest.json`
4. Stages `templates/versions.env templates/release-manifest.json RELEASE` and commits with updated message

The Python helper (`scripts/update-release-manifest.py`) maps 25 `_VERSION` keys from `versions.env` to their corresponding image entries in the manifest, sets `version` to the release tag, and sets `release_date` to the publish date.

## Tasks

| # | Name | Status | Commit | Files |
|---|------|--------|--------|-------|
| 1 | Add manifest sync step to sync-release CI workflow | Done | 3130c83 (26-01), ebf7192 (26-02) | `.github/workflows/sync-release.yml`, `scripts/update-release-manifest.py`, `.gitignore` |

## Decisions Made

1. **Python script as separate file** — `python3 -c "..."` with multi-line code inside a YAML `run: |` block causes YAML parse errors in strict validators. Moving the logic to `scripts/update-release-manifest.py` is cleaner, testable, and avoids any quoting/indentation problems.

2. **No digest resolution** — `generate-manifest.sh` uses `docker manifest inspect` which requires Docker Hub auth unavailable in a basic CI runner. Digests left as empty strings (they are not used by the installer at runtime). This is an intentional trade-off.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed overly broad `.gitignore` pattern for `workflows/`**
- **Found during:** Task 1 — `git add .github/workflows/sync-release.yml` was silently rejected
- **Issue:** `.gitignore` contained `workflows/` (bare pattern), which Git interprets as matching any directory named `workflows` at any depth, including `.github/workflows/`
- **Fix:** Changed to `/workflows/` (anchored to repo root), so only the top-level `workflows/` local-dev directory is ignored
- **Files modified:** `.gitignore`
- **Commit:** ebf7192

**2. [Rule 3 - Blocking] Moved Python code from inline `python3 -c` to separate script**
- **Found during:** Task 1 write — IDE YAML parser reported 50+ errors for multi-line Python embedded in `run: |`
- **Issue:** Multi-line `python3 -c "..."` is valid for bash but causes YAML parse failures due to quotes and colons inside the string
- **Fix:** Created `scripts/update-release-manifest.py` and called it with `python3 scripts/update-release-manifest.py "$TAG" "${RELEASE_DATE:-}"`
- **Files modified:** `.github/workflows/sync-release.yml`, `scripts/update-release-manifest.py` (new)
- **Commit:** 3130c83 (committed as part of 26-01 execution batch)

## Self-Check

- [x] `.github/workflows/sync-release.yml` exists and contains `git add ... release-manifest.json`
- [x] `scripts/update-release-manifest.py` exists with KEY_MAP, version/release_date update, sys.argv args
- [x] Workflow trigger remains `on: release: types: [published]`
- [x] Existing `versions.env` + `RELEASE` sync preserved
- [x] `.gitignore` uses `/workflows/` (root-anchored)

## Self-Check: PASSED
