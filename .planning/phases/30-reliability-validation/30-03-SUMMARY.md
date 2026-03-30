---
phase: 30-reliability-validation
plan: "03"
subsystem: infra
tags: [offline-bundle, docker, verification, airgap]

requires:
  - phase: 29-docling-gpu-ocr
    provides: DOCLING_IMAGE_CPU and DOCLING_IMAGE_CUDA vars in versions.env

provides:
  - Build-time bundle verification in build-offline-bundle.sh Stage 6
  - Image manifest with human-readable sizes printed to stdout
  - exit 1 on missing images (airgap safety)
  - INCLUDE_DOCLING_CUDA=true support in verification expected list

affects:
  - offline-bundle
  - build-offline-bundle.sh

tech-stack:
  added: []
  patterns:
    - "Stage 6 verification runs after tar creation but before final success message"
    - "Fallback: if tar manifest parse fails, check docker image inspect for locally pulled images"
    - "printf used instead of echo -e for multiline string building (printf '%s\n%s')"

key-files:
  created: []
  modified:
    - scripts/build-offline-bundle.sh

key-decisions:
  - "Stage 6 positioned after tar creation (Stage 5) but before final success echo — exit 1 prevents misleading 'bundle created!' when images are missing"
  - "Two-path actual_images detection: tar manifest.json parse primary, docker image inspect fallback"
  - "actual_images file name corrected to agmind-images.tar.gz (plan had docker-images.tar.gz)"
  - "echo -e replaced with printf '%s\\n%s' for blank-safe multiline merging of image lists"

patterns-established:
  - "Bundle verification pattern: expected vs actual with [OK]/[MISSING]/[EXTRA] colour status"
  - "Image manifest table: %-60s aligned columns with human-readable size (MB/GB)"

requirements-completed: [RLBL-02]

duration: 10min
completed: "2026-03-30"
---

# Phase 30 Plan 03: Bundle Verification + Manifest Summary

**Stage 6 bundle verification added to build-offline-bundle.sh: compares compose-derived expected image list against bundle contents, prints sized manifest, exits 1 on any missing image**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-03-30T00:00:00Z
- **Completed:** 2026-03-30T00:10:00Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Stage 6 "Bundle Verification" added after tar creation, before final success message
- Expected image list built from `docker compose config --images` across all profiles (tei, reranker, docling)
- Docling CPU image always added to expected list; CUDA image conditionally added when INCLUDE_DOCLING_CUDA=true
- [OK] / [MISSING] / [EXTRA] per-image status printed with ANSI colour codes
- Image manifest table with human-readable sizes (MB/GB) printed via docker image inspect
- exit 1 when missing > 0, preventing "bundle created!" mislead on incomplete bundle

## Task Commits

1. **Task 1: Bundle verification + manifest** - `8489a54` (feat)

## Files Created/Modified

- `scripts/build-offline-bundle.sh` - Added Stage 6 (109 lines): expected vs actual comparison, manifest table, exit 1 on missing

## Decisions Made

- Stage 6 positioned after tar (Stage 5, line 282) but before final echo block — exit 1 fires before success message
- Plan mentioned `docker-images.tar.gz`; actual file is `agmind-images.tar.gz` — corrected in implementation
- Used `printf '%s\n%s'` instead of `echo -e "${a}\n${b}"` to avoid literal `\n` issues in multiline merging
- `grep -oP` used for tar manifest JSON parsing; fallback via docker image inspect for locally pulled images

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Corrected tar filename from docker-images.tar.gz to agmind-images.tar.gz**
- **Found during:** Task 1 (reading Stage 2 code)
- **Issue:** Plan used `docker-images.tar.gz` but Stage 5 creates `agmind-images.tar.gz`
- **Fix:** Used correct filename `agmind-images.tar.gz` in Stage 6 check
- **Files modified:** scripts/build-offline-bundle.sh
- **Verification:** File path matches Stage 5 tar creation
- **Committed in:** 8489a54 (Task 1 commit)

**2. [Rule 1 - Bug] Replaced echo -e multiline with printf for safe image list merging**
- **Found during:** Task 1 (implementing expected_images accumulation)
- **Issue:** `echo -e "${a}\n${b}"` can produce literal `\n` in some bash versions
- **Fix:** Used `printf '%s\n%s' "$a" "$b"` for reliable newline insertion
- **Files modified:** scripts/build-offline-bundle.sh
- **Verification:** bash -n passes; no syntax issues
- **Committed in:** 8489a54 (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (both Rule 1 - bug corrections)
**Impact on plan:** Corrections necessary for correct filename and portable string handling. No scope creep.

## Issues Encountered

None beyond the two auto-fixed deviations above.

## Next Phase Readiness

- RLBL-02 complete: offline bundle now self-validates at build time
- Operators see missing images immediately during `build-offline-bundle.sh`, not at airgapped install time
- Ready for remaining Phase 30 plans

---
*Phase: 30-reliability-validation*
*Completed: 2026-03-30*
