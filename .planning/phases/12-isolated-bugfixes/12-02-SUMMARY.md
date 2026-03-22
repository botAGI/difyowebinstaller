---
phase: 12-isolated-bugfixes
plan: "02"
subsystem: check-upstream.sh + install.sh
tags: [bugfix, check-upstream, dify-init, v-prefix, credentials, timeout]
dependency_graph:
  requires: []
  provides: [IREL-01-fix, IREL-04-fix]
  affects: [scripts/check-upstream.sh, install.sh]
tech_stack:
  added: []
  patterns: [associative-array-lookup, bash-parameter-expansion]
key_files:
  created: []
  modified:
    - scripts/check-upstream.sh
    - install.sh
decisions:
  - "NO_V_PREFIX associative array pattern chosen over per-component if-chain for clarity and extensibility"
  - "report_latest local var preserves original $latest for comparison logic — strip only at write time"
  - "Fallback block in _save_credentials uses literal grep command as operator instruction, not executed"
metrics:
  duration: "~2 min"
  completed: "2026-03-23"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 2
---

# Phase 12 Plan 02: Upstream v-prefix strip + Dify init 5-min timeout Summary

**One-liner:** Strip v-prefix from upstream report for Docker-bare-tag components and extend Dify init retry loop from 30 to 60 attempts (150s to 300s) with fallback credentials block.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Strip v-prefix in check-upstream.sh report for no-v components (IREL-01) | f2f5a5d | scripts/check-upstream.sh |
| 2 | Increase Dify init timeout to 5 min + fallback credentials (IREL-04) | 15e03d0 | install.sh |

## What Was Built

### Task 1 — v-prefix strip in check-upstream.sh

Added `declare -A NO_V_PREFIX` associative array listing components whose Docker Hub images use bare tags (no `v` prefix) while GitHub Releases use `v`-prefixed tags:

- Weaviate, Grafana, Prometheus, Alertmanager, Loki, Promtail, Node Exporter, cAdvisor

In `check_component()`, before writing to `UPDATES[]`, a local `report_latest` variable is computed: if the component is in `NO_V_PREFIX`, the `v` prefix is stripped via `${latest#v}`. The original `$latest` is still passed to `is_newer()` and `classify_change()`, so comparison logic is unaffected.

**Effect:** Weaviate update from `v1.36.6` is now reported as `1.36.6` (Docker-compatible tag).

### Task 2 — Extended Dify init timeout + fallback credentials

Two changes in `install.sh`:

1. `_init_dify_admin()`: while loop condition changed `30` → `60`, timeout check changed `30` → `60`, log_warn message updated to "not ready after 5 min". Effective timeout: 300 seconds (5 minutes).

2. `_save_credentials()`: Added conditional block — if `${INSTALL_DIR}/.dify_initialized` does NOT exist (auto-init failed or was skipped), `credentials.txt` gets a "Dify Admin (ручная настройка)" section with manual `/install` URL and a copy-paste command to retrieve `INIT_PASSWORD` from `.env`.

## Decisions Made

- **NO_V_PREFIX array vs if-chain:** Array lookup is O(1), scales cleanly when adding new components, and is idiomatic Bash for set membership.
- **report_latest separation:** Keeping `$latest` unchanged for `is_newer`/`classify_change` avoids subtle double-strip bugs and keeps the fix surgical.
- **Fallback as operator instruction:** The `grep INIT_PASSWORD` command in credentials.txt is printed as literal text for the operator to run manually — it is not evaluated during credential generation. This is consistent with project security policy (no credential stdout).

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

| Item | Status |
|------|--------|
| scripts/check-upstream.sh | FOUND |
| install.sh | FOUND |
| .planning/phases/12-isolated-bugfixes/12-02-SUMMARY.md | FOUND |
| commit f2f5a5d (Task 1) | FOUND |
| commit 15e03d0 (Task 2) | FOUND |
