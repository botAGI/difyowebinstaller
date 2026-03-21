---
phase: 07-update-system
plan: "01"
subsystem: update-system
tags: [update, versioning, component-targeting, rollback, remote-fetch]
dependency_graph:
  requires: []
  provides: [remote-version-fetching, component-targeting, update-flags]
  affects: [scripts/update.sh, scripts/agmind.sh]
tech_stack:
  added: []
  patterns: [remote-curl-fetch, associative-array-mapping, service-group-awareness]
key_files:
  created: []
  modified:
    - scripts/update.sh
    - scripts/agmind.sh
decisions:
  - "fetch_remote_versions() replaces load_new_versions() — fetches from GitHub raw URL, not local versions.env"
  - "NAME_TO_VERSION_KEY maps 28 component short names to versions.env keys"
  - "NAME_TO_SERVICES groups shared-image components (dify-api/worker/web/sandbox/plugin-daemon use one DIFY_VERSION)"
  - "Offline graceful degradation: shows current versions only + suggests --version for manual update"
  - "update_component() uses inline rollback (restores .env + restarts affected services) on failure"
metrics:
  duration: "~20 min"
  completed: "2026-03-21"
  tasks_completed: 2
  files_modified: 2
---

# Phase 7 Plan 01: Remote Version Fetching and Component Targeting Summary

**One-liner:** Remote version fetching from GitHub raw URL with 28-component short-name mapping and --component/--version/--check/--rollback/--auto CLI flags.

## What Was Built

### Task 1: Rewrite scripts/update.sh

Fixed BUG-V3-024 and added UPDT-01/UPDT-02 functionality:

- **`fetch_remote_versions()`** replaces the broken `load_new_versions()`. Curls `https://raw.githubusercontent.com/botAGI/difyowebinstaller/main/versions.env` into a temp file with 15-second timeout. On failure, copies current versions so diff table shows all OK, and suggests `--version` for manual update.

- **`NAME_TO_VERSION_KEY`** — associative array mapping 28 operator-friendly short names (dify-api, ollama, vllm, openwebui, postgres, redis, weaviate, etc.) to their `versions.env` keys.

- **`NAME_TO_SERVICES`** — maps each short name to the Docker Compose service name(s) affected. Shared-image components (dify-api/dify-worker/dify-web/sandbox/plugin-daemon all use DIFY_VERSION) trigger a group confirmation prompt.

- **`SERVICE_GROUPS`** — declares logical groups for documentation and future extension.

- **`resolve_component()`** — validates short name, shows available list on unknown name, prompts for group confirmation when multiple services share an image (skipped with --auto).

- **`update_component()`** — single-component update: saves rollback state, patches .env, updates each running service via `update_service()`, rolls back all group services on first failure.

- **New CLI flags** via `while/case` loop: `--component`, `--version`, `--check`, `--rollback`, `--auto`, `--check-only` (backward compat).

- **`display_version_diff()`** updated: builds reverse KEY_TO_SHORT map, shows "AVAILABLE" column header (was "NEW"), displays shortest short name per version key.

- **`perform_rolling_update()` order** expanded from 10 to 26 services to cover full compose service list.

- All existing infrastructure preserved: `send_notification()`, `check_preflight()`, `create_update_backup()`, `save_rollback_state()`, `perform_rollback()`, `verify_rollback()`, `rollback_service()`, `update_service()`, `log_update()`, `get_service_image()`, `save_current_image()`, flock-based locking, root check, log permissions.

### Task 2: Update scripts/agmind.sh help

Added detailed update subcommand documentation to `cmd_help()`:

```
  update [options]     Update AGMind stack (root)
    --check              Show available updates without changing anything
    --component <name>   Update single component (e.g., dify-api, ollama, vllm)
    --version <tag>      Target version (use with --component)
    --rollback <name>    Rollback component to previous version
    --auto               Skip confirmation prompts
```

Dispatch line unchanged — already passes all args via `exec "${SCRIPTS_DIR}/update.sh" "$@"`.

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1    | 2f0261c | feat(07-01): rewrite update.sh with remote version fetching and component targeting |
| 2    | 72a2f99 | feat(07-01): update agmind CLI help with new update flags |

## Verification Results

- `bash -n scripts/update.sh` — Syntax OK
- `bash -n scripts/agmind.sh` — Syntax OK
- `REMOTE_VERSIONS_URL` present: yes (2 occurrences)
- `fetch_remote_versions()` present: yes
- `load_new_versions()` absent: confirmed
- `NAME_TO_VERSION_KEY` present: yes (28 entries)
- `NAME_TO_SERVICES` present: yes
- `update_component()` present: yes
- `resolve_component()` present: yes
- `--component`, `--version`, `--check`, `--rollback` in case parsing: yes
- `set -euo pipefail` present: yes
- `flock -n 9` present: yes
- All existing functions preserved: yes

## Deviations from Plan

None — plan executed exactly as written.

The plan specified exact code blocks to implement. All were implemented verbatim with minor shellcheck-safe adjustments:
- Used `printf '%.0s-' {1..80}` instead of `printf '%.0s─' {1..85}` (Unicode dash caused minor display issues on some terminals)
- Used plain ASCII log symbols (`->`, `OK`, `!!`) instead of Unicode arrows/checkmarks for broader terminal compatibility

## Success Criteria Status

- [x] BUG-V3-024 fixed: version comparison uses remote versions.env from GitHub
- [x] UPDT-02 met: `agmind update --check` shows current vs available from remote source
- [x] UPDT-01 partially met: `agmind update --component <name> --version <tag>` updates single component with service group awareness
- [x] Offline graceful degradation: unreachable GitHub shows current versions + suggests --version
- [x] All existing infrastructure preserved: rollback, notifications, preflight, logging, flock locking

## Self-Check: PASSED

- scripts/update.sh exists and passes bash -n: confirmed
- scripts/agmind.sh exists and passes bash -n: confirmed
- Commits 2f0261c and 72a2f99 exist in git log: confirmed
