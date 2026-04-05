---
phase: 07-update-system
verified: 2026-03-21T00:00:00Z
status: human_needed
score: 9/9 must-haves verified
re_verification: false
human_verification:
  - test: "Run: sudo agmind update --check on a server with network access"
    expected: "Table showing COMPONENT / CURRENT / AVAILABLE / STATUS columns. STATUS shows OK or UPDATE for each component. No crash, no 'failed to update .env'."
    why_human: "Requires network + live versions.env on GitHub raw URL. Cannot simulate with grep."
  - test: "Run: sudo agmind update --component ollama --version 0.0.1 on running stack (intentionally bad version)"
    expected: "update_service() pulls 0.0.1, container starts, healthcheck shows unhealthy within 120s, rollback_service() is called automatically, ollama returns to original version, log entry appears in update_history.log with 'failed healthcheck, rolled back to'"
    why_human: "Requires Docker runtime and a running stack. Core UPDT-03 behavior cannot be verified by grep."
  - test: "Run: sudo agmind update --rollback ollama after performing a successful update"
    expected: "rollback_component() reads .rollback/dot-env.bak, patches .env with old version, restarts ollama service, logs 'MANUAL_ROLLBACK | ollama: <new> -> <old>' to update_history.log"
    why_human: "Requires Docker runtime and pre-existing .rollback/dot-env.bak state."
  - test: "Run: sudo agmind update --component dify-api --version 99.99.99 (bad version, shared-image group)"
    expected: "Confirmation prompt for 'api worker web sandbox plugin_daemon' group. On 'yes', first service fails healthcheck, remaining group services are skipped, .env restored to pre-update state, group all back on old version."
    why_human: "Requires Docker runtime. Tests multi-service group rollback on partial failure."
---

# Phase 7: Update System Verification Report

**Phase Goal:** Operators can check for available version updates and update any single component without touching the rest of the stack, with automatic rollback if the updated container fails its healthcheck.
**Verified:** 2026-03-21
**Status:** human_needed (all automated checks pass; 4 runtime behaviors need human testing)
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|----------|
| 1  | `agmind update --check` fetches remote versions.env from GitHub and displays diff table | VERIFIED | `REMOTE_VERSIONS_URL` at line 18; `fetch_remote_versions()` at line 242; `display_version_diff()` at line 343; `--check` branch at line 749 |
| 2  | `agmind update --check` gracefully handles offline/unreachable GitHub | VERIFIED | `fetch_remote_versions()` else-branch at line 257: "Cannot reach GitHub -- showing current versions only"; copies CURRENT_VERSIONS to NEW_VERSIONS so diff shows all OK |
| 3  | `agmind update --component dify-api` updates only dify-api service group | VERIFIED | `NAME_TO_SERVICES[dify-api]="api worker web sandbox plugin_daemon"` at line 58; `update_component()` at line 572 iterates over that service list |
| 4  | `agmind update --component dify-api --version 1.4.0` sets specific version tag | VERIFIED | `--component` + `--version` branch at line 735 calls `update_component "$COMPONENT" "$TARGET_VERSION"` directly without remote fetch |
| 5  | Service group confirmation shown when updating shared-image components | VERIFIED | `resolve_component()` at line 559: `service_count -gt 1 && AUTO_UPDATE != "true"` triggers `read -rp "Also updating these services. Continue?"` |
| 6  | `agmind update` without flags shows remote diff table then asks to update all | VERIFIED | Full update flow in main(): fetch -> display_version_diff -> `read -rp "Update all components? (yes/no)"` at line 771 |
| 7  | `agmind update --auto` skips confirmation | VERIFIED | `AUTO_UPDATE=true` set at line 137; checked at lines 559 (group confirm) and 770 (full update confirm) |
| 8  | Healthcheck failure triggers automatic rollback | VERIFIED | `update_service()` at lines 441-444: `unhealthy\|exit` -> `rollback_service "$service" "$old_image"`; line 458-459: `failed to start` -> `rollback_service` |
| 9  | `agmind update --rollback <component>` restores previous version from .rollback/ | VERIFIED | `rollback_component()` at line 490 reads `${ROLLBACK_DIR}/dot-env.bak`, patches `.env`, restarts affected services, logs `MANUAL_ROLLBACK` |

**Score:** 9/9 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/update.sh` | Remote version fetching, component targeting, short-name mapping, service groups | VERIFIED | 823 lines; syntax OK (`bash -n`); contains all required functions |
| `tests/test_update.bats` | Structural validation tests (BATS) | VERIFIED | 47 `@test` blocks; valid BATS file; no Docker runtime required |
| `scripts/agmind.sh` | CLI help documents all new update flags | VERIFIED | Lines 284-288: --check, --component, --version, --rollback, --auto documented |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `scripts/update.sh` | `https://raw.githubusercontent.com/botAGI/difyowebinstaller/main/versions.env` | `curl` in `fetch_remote_versions()` | WIRED | Line 18: `REMOTE_VERSIONS_URL=...raw.githubusercontent.com...`; line 250: `curl -sfL --max-time "$REMOTE_FETCH_TIMEOUT" "$REMOTE_VERSIONS_URL"` |
| `scripts/update.sh` | `${INSTALL_DIR}/docker/.env` | `load_current_versions()` | WIRED | Line 14: `ENV_FILE="${INSTALL_DIR}/docker/.env"`; line 233: `load_current_versions()` reads `_VERSION=` entries from `$ENV_FILE` |
| `update_service()` | `rollback_service()` | healthcheck failure | WIRED | Lines 441-444: `unhealthy\|exit` status -> `rollback_service "$service" "$old_image"`; line 459: failed to start -> same |
| `update_component()` | `${INSTALL_DIR}/.rollback/` | save and restore `.env` state | WIRED | Line 585: `save_rollback_state` before patch; lines 611-612: restores `dot-env.bak` on failure; `rollback_component()` line 510 reads `dot-env.bak` |
| `log_update()` | `${INSTALL_DIR}/logs/update_history.log` | append with timestamp | WIRED | Line 701-705: `echo "$(date ...) | ${status} | ${details}" >> "$LOG_FILE"`; 6 call sites: MANUAL_ROLLBACK (539), ROLLBACK (624), SUCCESS x2 (630, 811), SKIP (745), PARTIAL_FAILURE (817) |
| `scripts/agmind.sh` | `scripts/update.sh` | `exec "${SCRIPTS_DIR}/update.sh" "$@"` | WIRED | Line 310: `exec "${SCRIPTS_DIR}/update.sh" "$@"` — all args forwarded |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| UPDT-01 | 07-01-PLAN.md | `agmind update --component <name> --version <tag>` updates single component (pull + restart + healthcheck) | SATISFIED | `update_component()` + `update_service()` + `NAME_TO_VERSION_KEY` / `NAME_TO_SERVICES` mappings all present and wired |
| UPDT-02 | 07-01-PLAN.md | `agmind update --check` shows current vs available versions from remote source | SATISFIED | `fetch_remote_versions()` + `display_version_diff()` + `--check` flag all wired; old `load_new_versions()` absent (confirmed via grep) |
| UPDT-03 | 07-02-PLAN.md | Rollback on failed healthcheck after component update | SATISFIED | `update_service()` calls `rollback_service()` on `unhealthy\|exit` status; `update_component()` restores `.env` and restarts group on any service failure; `rollback_component()` for manual `--rollback` |

No orphaned requirements — all three UPDT-0x IDs declared in plan frontmatter appear in REQUIREMENTS.md and are mapped to Phase 7.

### Anti-Patterns Found

None. No TODO/FIXME/XXX/HACK/placeholder strings found in `scripts/update.sh`, `scripts/agmind.sh`, or `tests/test_update.bats`.

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | — |

### Human Verification Required

#### 1. Live --check against GitHub

**Test:** On a server with internet access, run `sudo agmind update --check`.
**Expected:** Table with COMPONENT / CURRENT / AVAILABLE / STATUS columns renders correctly. Components with newer versions show "UPDATE" in yellow; up-to-date components show "OK" in green. Exit 0, no errors.
**Why human:** Requires live network access to `raw.githubusercontent.com` and a running install at `$INSTALL_DIR`. Cannot mock with grep.

#### 2. Automatic rollback on healthcheck failure (UPDT-03 core)

**Test:** On a running stack, run `sudo agmind update --component ollama --version 0.0.1 --auto` (intentionally bad version tag).
**Expected:** `update_service()` pulls 0.0.1, container starts in unhealthy state within 120s, `rollback_service()` is triggered automatically, ollama returns to its previous version, `update_history.log` contains an entry like `ROLLBACK | ollama: 0.0.1 failed healthcheck, rolled back to <previous>`.
**Why human:** Requires Docker runtime and a running ollama container. The healthcheck-to-rollback path (lines 441-459) cannot be exercised by structural grep checks.

#### 3. Manual rollback via --rollback

**Test:** After any successful update, run `sudo agmind update --rollback <component>`.
**Expected:** `rollback_component()` reads `.rollback/dot-env.bak`, restores old version key in `.env`, pulls old image, restarts affected services. `update_history.log` shows `MANUAL_ROLLBACK | <name>: <new> -> <old>`.
**Why human:** Requires `.rollback/` state created by a prior update invocation and Docker runtime.

#### 4. Shared-image group confirmation and partial rollback

**Test:** Run `sudo agmind update --component dify-api --version 99.99.99` (bad version, group component).
**Expected:** Prompt "Component 'dify-api' shares image with: api worker web sandbox plugin_daemon. Continue?". On "yes": first service in group fails healthcheck, remaining services are skipped (not started on bad version), `.env` restored to pre-update state.
**Why human:** Requires Docker runtime and a running Dify stack. Tests group rollback coordination in `update_component()` loop (lines 598-626).

### Gaps Summary

No gaps found. All automated checks pass:

- `scripts/update.sh` passes `bash -n` (823 lines, substantive)
- All 9 derived truths are satisfied by code evidence
- All 3 key links from 07-02-PLAN.md are wired
- Requirements UPDT-01, UPDT-02, UPDT-03 all satisfied
- 4 documented commits (2f0261c, 72a2f99, 1e41448, 11f0cf5) confirmed in git log
- 47 structural BATS tests cover all three requirements
- No anti-patterns or stubs detected

The phase is blocked only on runtime verification (4 items above) which require a live Docker environment.

---

_Verified: 2026-03-21_
_Verifier: Claude (gsd-verifier)_
