---
phase: 30-reliability-validation
plan: "01"
subsystem: install-reliability
tags: [dify-init, retry, flock, dry-run, preflight, dns]
dependency_graph:
  requires: []
  provides: [dify-init-retry-60s, agmind-init-dify-flock, dry-run-preflight]
  affects: [install.sh, scripts/agmind.sh, lib/detect.sh]
tech_stack:
  added: []
  patterns: [flock-fd-pattern, bash-dry-run-early-exit, getent-hosts-dns-fallback]
key_files:
  modified:
    - install.sh
    - scripts/agmind.sh
    - lib/detect.sh
decisions:
  - "sleep 30 -> sleep 60 in _init_dify_admin() retry loop for slow servers"
  - "flock uses fd 8 and /var/lock/agmind-init-dify.lock (mirrors _acquire_lock pattern)"
  - "dry-run re-runs preflight_checks after phase_diagnostics to capture exit code"
  - "DNS check uses getent hosts as primary, nslookup as fallback — no extra packages needed"
  - "port 5432 check: WARN (in use), agmind nginx exempt only for 80/443"
metrics:
  duration: "~20 min"
  completed_date: "2026-03-30"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 3
---

# Phase 30 Plan 01: Dify Init Retry + Dry-Run Preflight Summary

**One-liner:** Dify init retry increased to 60s with [dify-init] log prefix, flock guard on agmind init-dify, and --dry-run flag that runs preflight (prereqs/ports/disk/DNS) and exits before container start.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Dify init retry 60s + flock | 3532e1c | install.sh, scripts/agmind.sh |
| 2 | --dry-run preflight + DNS check | 4bb2689 | install.sh, lib/detect.sh |

## Changes Made

### Task 1: Dify Init Retry 60s + flock

**install.sh — _init_dify_admin():**
- Changed `sleep 30` to `sleep 60` (line 330) — gives slow servers more settle time between retry attempts
- Added `[dify-init]` prefix to all 8 log messages inside _init_dify_admin() for easier log filtering

**scripts/agmind.sh — cmd_init_dify():**
- Added flock guard using fd 8 and `/var/lock/agmind-init-dify.lock`
- Mirrors the existing `_acquire_lock()` pattern in install.sh (fd 9 → fd 8 for different lock file)
- Guard wrapped in `uname != Darwin` check for cross-platform safety

### Task 2: --dry-run Preflight + DNS Check

**install.sh — main():**
- Added `--dry-run) DRY_RUN=true;;` to argument parser
- Updated `--help` text to include `--dry-run`
- After phase_diagnostics (which already calls preflight_checks), if DRY_RUN=true: calls preflight_checks again to get exit code, logs "Dry-run complete", exits with preflight_rc
- No `local` on `preflight_rc` — used in main() function body correctly

**lib/detect.sh — preflight_checks():**
- Added check 11: DNS resolution for hub.docker.com and ghcr.io
  - Primary: `getent hosts` (available on all Linux without extra packages)
  - Fallback: `nslookup`
  - DNS failure = `[FAIL]` + `errors++` (not WARN — no DNS = no image pulls)
  - Skipped with `[SKIP]` for offline profile
- Port check loop extended: `for port in 80 443 5432`
  - Port 5432 always shows WARN if in use (agmind nginx exempt logic skips 5432)

## Verification Results

```
sleep 60          — found in install.sh line 330
[dify-init] count — 8 occurrences in install.sh
flock -n 8        — found in scripts/agmind.sh
DRY_RUN           — 2 occurrences in install.sh
getent hosts      — found in lib/detect.sh
bash -n           — ALL PASS (install.sh, lib/detect.sh, scripts/agmind.sh)
```

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

- FOUND: .planning/phases/30-reliability-validation/30-01-SUMMARY.md
- FOUND: commit 3532e1c (feat(30-01): Dify init retry 60s + [dify-init] log prefix + flock)
- FOUND: commit 4bb2689 (feat(30-01): --dry-run preflight exit + DNS check)
- REQUIREMENTS.md: RLBL-01, RLBL-03 marked complete
- ROADMAP.md: phase 30 updated (2/3 plans)
- STATE.md: decision added, progress 88%, session recorded
