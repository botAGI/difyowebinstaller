---
phase: 06-v3-bugfixes
plan: "03"
subsystem: installer
tags: [bugfix, gap-closure, redis, systemd, compose-profiles]
dependency_graph:
  requires: ["06-01", "06-02"]
  provides: ["redis-lock-cleaner-working", "systemd-reboot-profiles"]
  affects: ["install.sh", "lib/compose.sh", "templates/agmind-stack.service.template"]
tech_stack:
  added: []
  patterns: ["EnvironmentFile systemd", "sed dedup before append"]
key_files:
  created: []
  modified:
    - install.sh
    - lib/compose.sh
    - templates/agmind-stack.service.template
decisions:
  - "EnvironmentFile uses '-' prefix so systemd does not fail before first installer run"
  - "sed -i dedup removes existing COMPOSE_PROFILES before append to avoid duplicates on re-runs"
metrics:
  duration_minutes: 15
  completed_date: "2026-03-21"
  tasks_completed: 2
  files_modified: 3
requirements: [STAB-02, STAB-03]
---

# Phase 06 Plan 03: UAT Gap Closure (redis-lock + systemd reboot) Summary

**One-liner:** Fixed two UAT blockers: redis-lock-cleanup.sh now copied by installer (Docker bind mount works), and systemd reads COMPOSE_PROFILES from .env so profile containers start after reboot.

## Objective

Close two production bugs discovered during UAT:
1. (blocker) redis-lock-cleanup.sh not copied — Docker created a directory instead of mounting the file
2. (major) systemd service had no COMPOSE_PROFILES — only core containers started after reboot

## Tasks Completed

| Task | Description | Commit | Files |
|------|-------------|--------|-------|
| 1 | Add redis-lock-cleanup.sh to _copy_runtime_files, persist COMPOSE_PROFILES to .env | 59f4ca8 | install.sh, lib/compose.sh |
| 2 | Add EnvironmentFile directive to systemd service template | 8a27224 | templates/agmind-stack.service.template |

## Changes Made

### install.sh — _copy_runtime_files()

Added `redis-lock-cleanup.sh` to the scripts array. The script is now copied from `${INSTALLER_DIR}/scripts/` to `${INSTALL_DIR}/scripts/` during phase 4 (config), before phase 5 (start) runs docker compose. This ensures the bind mount target exists as a file, not a directory.

### lib/compose.sh — compose_up()

After `build_compose_profiles()` resolves the profile string, the new block:
1. Removes any existing `COMPOSE_PROFILES=` line from `.env` (dedup via `sed -i`)
2. Appends `COMPOSE_PROFILES=${profiles}` to `.env`

This persists the profile selection so systemd can read it on subsequent reboots.

### templates/agmind-stack.service.template

Added `EnvironmentFile=-__INSTALL_DIR__/docker/.env` in the `[Service]` section, after `WorkingDirectory` and before `ExecStartPre`. The `-` prefix makes the directive non-fatal if `.env` does not exist (first boot before installer completes). After installer runs, systemd reads `COMPOSE_PROFILES` from `.env` and passes it to `docker compose up -d`.

## End-to-End Fix Chain

```
install.sh phase 4 → _copy_runtime_files() copies redis-lock-cleanup.sh
install.sh phase 5 → compose_up() writes COMPOSE_PROFILES to .env
install.sh phase 9 → systemd service installed with EnvironmentFile pointing to .env

On reboot:
  systemd reads .env → COMPOSE_PROFILES is set
  docker compose up -d starts ALL containers including profile-based ones

On container restart:
  redis-lock-cleanup.sh is a real file → bind mount works → lock cleaner runs
```

## Verification Results

```
Check 1: grep "redis-lock-cleanup.sh" install.sh  → PASS (in _copy_runtime_files scripts array)
Check 2: grep 'COMPOSE_PROFILES=.*>>' lib/compose.sh  → PASS (append to .env)
Check 3: grep "EnvironmentFile" templates/agmind-stack.service.template  → PASS
```

## Deviations from Plan

None — plan executed exactly as written.

## Profiles Affected

All profiles (LAN, VPN, VPS, Offline) — systemd and redis-lock-cleaner are common to all.

## Self-Check: PASSED

- `install.sh` — modified, committed (59f4ca8)
- `lib/compose.sh` — modified, committed (59f4ca8)
- `templates/agmind-stack.service.template` — modified, committed (8a27224)
