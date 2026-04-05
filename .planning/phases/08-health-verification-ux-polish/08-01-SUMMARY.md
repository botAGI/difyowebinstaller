---
phase: 08-health-verification-ux-polish
plan: "01"
subsystem: health-verification
tags: [health, ux, post-install, portainer, ssh-tunnel, verify-services]
dependency_graph:
  requires: []
  provides: [verify_services-function, portainer-tunnel-hint, post-install-http-status]
  affects: [install.sh, lib/health.sh, scripts/agmind.sh]
tech_stack:
  added: []
  patterns: [profile-conditional-curl-checks, global-results-array, retry-with-sleep]
key_files:
  created: []
  modified:
    - lib/health.sh
    - install.sh
decisions:
  - "verify_services() returns number of failures (0=all OK) — caller uses '|| true' so failed checks never abort install"
  - "VERIFY_RESULTS global array avoids re-running curl in _show_final_summary — checks run once in phase_complete"
  - "Internal services (vLLM, Ollama, TEI, Weaviate, Qdrant) use 127.0.0.1 — they bind locally; Open WebUI and Dify use $domain (nginx reverse proxy)"
  - "Portainer SSH tunnel hint skipped when ADMIN_UI_OPEN=true — direct 0.0.0.0:9443 access available in that case"
metrics:
  duration: "~16 minutes"
  completed_date: "2026-03-21"
  tasks_completed: 2
  files_modified: 2
---

# Phase 08 Plan 01: Service HTTP Verification + Portainer SSH Tunnel Summary

**One-liner:** Real curl liveness checks for all profile-specific services post-install, with per-service Russian troubleshoot hints and Portainer SSH tunnel guidance in credentials.txt and summary.

## What Was Built

### Task 1 — `verify_services()` in `lib/health.sh`

Added `verify_services()` function after `check_all()` (before SEND ALERT section):

- Always checks: Open WebUI (`http://$domain/`), Dify Console (`http://$domain:3000/console/api/setup`)
- Profile-conditional: vLLM (`/v1/models`), Ollama (`/api/tags`), TEI (`/info`), Weaviate (`/v1/.well-known/ready`), Qdrant (`/readyz`)
- Per-URL: `curl -sf --max-time 5`, retry once after `sleep 10` on failure
- Populates `VERIFY_RESULTS` global array: `"Name|URL|OK|FAIL"` entries
- Prints colored `[OK]` / `[FAIL]` per service with Russian troubleshoot hints (`agmind logs <service>`)
- Returns number of failed checks (0 = all OK)

### Task 2 — `install.sh` integration

**Part A** — `phase_complete()` now calls `verify_services || true` before `_show_final_summary`

**Part B** — `_show_final_summary()` reads `VERIFY_RESULTS` and shows `[OK]/[FAIL]` per service before the "Профиль:" line

**Part C** — `_save_credentials()` includes Portainer SSH tunnel in `credentials.txt` (inside `MONITORING_MODE==local`, guarded by `ADMIN_UI_OPEN!=true`)

**Part D** — `_show_final_summary()` shows yellow Portainer SSH tunnel warning (inside `MONITORING_MODE==local`, guarded by `ADMIN_UI_OPEN!=true`)

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | ece6cb8 | feat(08-01): add verify_services() to lib/health.sh |
| 2 | 3f41d5b | feat(08-01): integrate verify_services + Portainer SSH tunnel into install.sh |

## Verification Results

All plan checks passed:
1. `bash -n lib/health.sh` — PASS
2. `bash -n install.sh` — PASS
3. `verify_services` defined in health.sh — PASS
4. `verify_services || true` called in `phase_complete()` — PASS
5. `VERIFY_RESULTS` iterated in `_show_final_summary()` — PASS
6. `ssh -L 9443:127.0.0.1:9443` present in both `_save_credentials()` and `_show_final_summary()` — PASS (2 occurrences)
7. Both tunnel hints guarded by `ADMIN_UI_OPEN!=true` — PASS

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

Files exist:
- `lib/health.sh` — verify_services() at line ~203
- `install.sh` — verify_services || true in phase_complete at line 134

Commits exist:
- ece6cb8 feat(08-01): add verify_services() to lib/health.sh
- 3f41d5b feat(08-01): integrate verify_services + Portainer SSH tunnel into install.sh
