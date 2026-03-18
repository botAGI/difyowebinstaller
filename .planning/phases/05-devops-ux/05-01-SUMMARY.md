---
phase: 05-devops-ux
plan: "01"
subsystem: cli
tags: [agmind-cli, bash, day2-ops, status, doctor]
dependency_graph:
  requires: [lib/health.sh, lib/detect.sh, scripts/backup.sh, scripts/restore.sh, scripts/update.sh, scripts/uninstall.sh, scripts/rotate_secrets.sh]
  provides: [scripts/agmind.sh, cmd_status, cmd_doctor, cmd_help, CLI dispatch]
  affects: [install.sh phase_complete() — symlink creation planned in Plan 02]
tech_stack:
  added: []
  patterns: [case-dispatch CLI, dual text/JSON output, _check() severity accumulator, _read_env helper, exec delegation to backend scripts]
key_files:
  created: [scripts/agmind.sh]
  modified: []
decisions:
  - "cmd_doctor implemented in same commit as cmd_status (not as separate stub+fill cycle) — no behavioral difference from plan outcome"
  - "INSTALL_DIR exported before sourcing health.sh to prevent COMPOSE_DIR scoping issue at source time"
  - "_status_as_json() does NOT call check_all() or other text-output functions — avoids ANSI escape sequences in JSON output"
  - "GPU skip in doctor when both LLM_PROVIDER=external AND EMBED_PROVIDER=external to prevent false FAIL on CPU-only VPS"
  - "source detect.sh uses || true — graceful fallback when running from installer source tree without installed copy"
metrics:
  duration: "2min"
  completed_date: "2026-03-18"
  tasks_completed: 2
  files_created: 1
  lines_written: 525
---

# Phase 5 Plan 01: agmind CLI Entry Point Summary

**One-liner:** Unified `agmind` CLI dispatcher with status dashboard + JSON, doctor diagnostics with severity accumulator, and full subcommand dispatch to existing backend scripts.

## What Was Built

`scripts/agmind.sh` — 525-line Bash CLI tool providing:

- `agmind status` — colored dashboard with Services, GPU, Models (Ollama only), Endpoints, Backup, Credentials sections reusing `health.sh` functions
- `agmind status --json` — pure JSON output matching `{status, timestamp, services, gpu, endpoints, backup}` schema without calling colored-text functions
- `agmind doctor` — 4-category diagnostics: Docker+Compose versions, DNS+Network reachability, GPU driver availability (skippable), Ports+Disk+RAM thresholds; post-install checks when `.agmind_installed` present
- `agmind doctor --json` — JSON output with `{status, errors, warnings, checks[]}` schema
- Full subcommand dispatch: backup/restore/update/uninstall/rotate-secrets delegate via `exec` to existing `scripts/*.sh`; logs delegates to `docker compose logs`
- `_require_root()` guard with Russian-language error for privileged subcommands
- `agmind help` listing all 9 subcommands

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create agmind.sh with CLI dispatch, cmd_status, cmd_help | c10a274 | scripts/agmind.sh |
| 2 | Implement cmd_doctor in agmind.sh | c10a274 | scripts/agmind.sh (combined) |

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written.

### Implementation Notes

**Task 2 combined with Task 1:** The plan described cmd_doctor as a "stub" in Task 1 to be filled in Task 2. Both tasks were implemented in a single file creation. This is a deviation in process only (no separate stub commit), with identical outcome. The plan's purpose — full cmd_doctor implementation — is achieved.

## Self-Check

Files created:
- `scripts/agmind.sh` — 525 lines, executable, syntax-verified

Commits:
- `c10a274` — feat(05-01): create agmind.sh with CLI dispatch, cmd_status, and cmd_help

Verification results:
- `bash -n scripts/agmind.sh` — exits 0 (PASS)
- All 7+ required functions present: cmd_status, cmd_doctor, cmd_help, _status_dashboard, _status_as_json, _require_root, _read_env
- Case dispatch covers all 9 subcommands: status, doctor, backup, restore, update, uninstall, rotate-secrets, logs, help
- _status_as_json does NOT call check_all (PASS)
- exec pattern used for all backend dispatches (PASS)
- Only mention of /opt/agmind is in help text as default value description (PASS)

## Self-Check: PASSED
