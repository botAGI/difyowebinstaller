---
phase: 01-mdns-reliability-fix-3-bugs-diagnostic-cli
plan: "02"
subsystem: mDNS/networking/testing
tags: [mdns, avahi, cli, unit-tests, integration-tests, shellcheck, smoke]
requirements: [MDNS-01, MDNS-02, MDNS-03, MDNS-04, MDNS-05]

dependency_graph:
  requires:
    - 01-01 (lib/detect.sh — _mdns_get_primary_ip + _assert_no_foreign_mdns)
  provides:
    - scripts/mdns-status.sh — 4-check mDNS diagnostic CLI
    - agmind mdns-status dispatch (scripts/agmind.sh)
    - tests/mocks/* — 5 fixture-driven PATH-shadow mocks
    - tests/unit/test_get_primary_ip.sh — MDNS-01 regression (5 cases)
    - tests/unit/test_foreign_mdns_assert.sh — MDNS-02 regression (7 assertions)
    - tests/unit/test_mdns_status.sh — MDNS-04 CLI coverage (12 cases)
    - tests/integration/test_mdns_reboot.sh — MDNS-03 reboot test (exit 77 w/o preconditions)
    - tests/run_all.sh — one-shot regression runner
    - install.sh STRICT smoke — hard exit 1 via agmind mdns-status
  affects:
    - install.sh _verify_post_install_smoke — new STRICT mDNS gate
    - lib/detect.sh — awk $5→$4 column fix in _assert_no_foreign_mdns

tech_stack:
  added: []
  patterns:
    - PATH-shadow mock pattern — tests/mocks/* intercept host binaries by PATH prepend
    - export-before-function pattern — env vars must be exported (not inline-prefixed) for bash functions
    - set +e / rc=$? / set -e guard — required for calling returning-1 functions under set -euo pipefail
    - hard exit 1 inside function — bypasses || true at call site

key_files:
  created:
    - scripts/mdns-status.sh
    - tests/mocks/ss
    - tests/mocks/avahi-resolve
    - tests/mocks/systemctl
    - tests/mocks/ip
    - tests/mocks/hostname
    - tests/unit/test_get_primary_ip.sh
    - tests/unit/test_foreign_mdns_assert.sh
    - tests/unit/test_mdns_status.sh
    - tests/integration/test_mdns_reboot.sh
    - tests/run_all.sh
  modified:
    - scripts/agmind.sh — mdns-status dispatch + help entry
    - install.sh — STRICT smoke block in _verify_post_install_smoke
    - lib/detect.sh — awk $5→$4 bug fix in _assert_no_foreign_mdns

decisions:
  - _check_info() non-fatal for non-root check (c) — operator can run diagnostics without root
  - export pattern required for bash function fixtures (inline VAR=val func only works for external cmds)
  - hard exit 1 in _verify_post_install_smoke — only way to bypass || true at call site
  - awk $4 (not $5) for Local Address:Port in ss -ulnp output (verified against real ss on DGX Spark)

metrics:
  duration_minutes: 10
  completed_date: "2026-04-21T19:35:50Z"
  tasks_completed: 9
  tasks_total: 9
  files_modified: 3
  files_created: 11
---

# Phase 01 Plan 02: mDNS CLI + Tests + STRICT Smoke Summary

`agmind mdns-status` diagnostic CLI (4 checks, --json, non-root INFO skip) + full unit/integration test suite covering all 5 MDNS requirements + STRICT post-install smoke gate wired via hard `exit 1` in `_verify_post_install_smoke`.

## One-liner

4-check mDNS diagnostic CLI with --json + fixture-driven unit/integration tests + hard-exit-1 STRICT smoke that bypasses || true call site

## Tasks Completed

| Task | Name | Commit | Key files |
|------|------|--------|-----------|
| 1 | scripts/mdns-status.sh + agmind dispatch | `78677a7` | scripts/mdns-status.sh, scripts/agmind.sh |
| 2 | tests/mocks/ (5 fixture files) | `094b986` | tests/mocks/{ss,avahi-resolve,systemctl,ip,hostname} |
| 3 | test_get_primary_ip.sh (MDNS-01) | `8aa00b9` | tests/unit/test_get_primary_ip.sh |
| 4 | test_foreign_mdns_assert.sh (MDNS-02) | `42462e4` | tests/unit/test_foreign_mdns_assert.sh, tests/mocks/ss, lib/detect.sh |
| 5 | test_mdns_status.sh (MDNS-04) | `9253e6b` | tests/unit/test_mdns_status.sh |
| 6 | test_mdns_reboot.sh integration (MDNS-03) | `8183098` | tests/integration/test_mdns_reboot.sh |
| 7 | tests/run_all.sh runner | `2c4096b` | tests/run_all.sh |
| 8 | STRICT smoke in install.sh | `aa18287` | install.sh |
| 9 | Final DoD (no code changes needed) | — | all files pass shellcheck + bash -n |

## What Was Built

### agmind mdns-status CLI

Four checks in a single command:
- **(a) Published names** — `avahi-resolve` each enabled `agmind-*.local` against primary uplink IP
- **(b) agmind-mdns.service** — `systemctl is-active` with actionable failure states
- **(c) UDP/5353 responder** — `_assert_no_foreign_mdns` (root only; non-root → INFO skip, non-fatal)
- **(d) Primary uplink ping** — `ping -c 1 -W 2 $primary_ip`

Exit code = number of issues (0 = all green, ≥1 = problem). `--json` flag emits machine-parseable JSON with `{issues, primary_ip, checks[]}`.

### Test infrastructure

5 mocks in `tests/mocks/` keyed by `MOCK_*_FIXTURE` env var — mock real binaries via `export PATH="tests/mocks:$PATH"`. No Docker, no root, no avahi needed for unit tests.

24 unit test assertions across 3 test files; 1 integration test (exit 77 if preconditions missing).

`bash tests/run_all.sh` = one-shot gate: shellcheck + unit suite. Output: `PASS: 5   SKIP: 1   FAIL: 0`.

### STRICT smoke

`install.sh::_verify_post_install_smoke` now calls `agmind mdns-status` after `_install_cli`. If it fails: `exit 1` (hard) — bypasses `|| true` at call site (`install.sh:198`). Silent broken mDNS no longer passes post-install.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed awk column $5→$4 in `_assert_no_foreign_mdns`**
- **Found during:** Task 4 (test_foreign_mdns_assert.sh failing — foreign process not detected)
- **Issue:** `ss -ulnp` real output has 6 fields: `State Recv-Q Send-Q Local:Port Peer:Port Process`. Local Address:Port is `$4`, not `$5`. The original code used `$5 ~ /:5353$/` which checked the Peer column — always `0.0.0.0:*`, never matching. Verified against `sudo ss -ulnp` on DGX Spark.
- **Fix:** `$5 ~ /:5353$/` → `$4 ~ /:5353$/` in `lib/detect.sh:424`
- **Files modified:** `lib/detect.sh`
- **Commit:** `42462e4`

**2. [Rule 1 - Bug] Fixed mock ss header — multi-word column split caused wrong NF**
- **Found during:** Task 4 (debugging awk column mismatch)
- **Issue:** Mock ss header `Local Address:Port Peer Address:Port` split into 8 awk fields; data lines had only 6 (matching real ss). Fixed header to `Local-Address:Port Peer-Address:Port` (single-word, 6 NF).
- **Fix:** Rewrote mock header lines in `tests/mocks/ss`
- **Files modified:** `tests/mocks/ss`
- **Commit:** `42462e4`

**3. [Rule 1 - Bug] Fixed JSON invalid control characters in --json output**
- **Found during:** Task 1 live smoke (`python3 json.load` failed)
- **Issue:** `systemctl is-active || echo "missing"` appended `"missing"` even when systemctl returned exit 3 (inactive state, not error). Result: `state="inactive\nmissing"` → newline in JSON detail field.
- **Fix:** Changed to `|| true` + `[[ -z "$state" ]] && state="missing"` pattern
- **Files modified:** `scripts/mdns-status.sh`
- **Commit:** part of `78677a7`

**4. [Rule 1 - Bug] env-prefix syntax doesn't work for bash functions**
- **Found during:** Task 3 (test_get_primary_ip cases 3+4 failing)
- **Issue:** `MOCK_IP_FIXTURE=no_route _assert_eq "label" "expected" "$(_mdns_get_primary_ip)"` — bash evaluates `$(_mdns_get_primary_ip)` subshell expansion BEFORE applying the env prefix to `_assert_eq`. The mock env var was not visible inside the function's `ip` call.
- **Fix:** Changed all test cases to use explicit `export MOCK_*_FIXTURE=...` before calling the function
- **Files modified:** `tests/unit/test_get_primary_ip.sh`
- **Commit:** `8aa00b9`

## Known Stubs

None — all checks produce real output; no placeholder data paths.

## Threat Flags

No new security surface introduced. Tests run locally only; `tests/mocks/` not deployed to runtime (glob-copy is `scripts/*.sh` only).

## Self-Check: PASSED

| Item | Status |
|------|--------|
| scripts/mdns-status.sh | FOUND |
| tests/mocks/* (5 files) | FOUND |
| tests/unit/test_get_primary_ip.sh | FOUND |
| tests/unit/test_foreign_mdns_assert.sh | FOUND |
| tests/unit/test_mdns_status.sh | FOUND |
| tests/integration/test_mdns_reboot.sh | FOUND |
| tests/run_all.sh | FOUND |
| install.sh (STRICT smoke) | FOUND |
| lib/detect.sh (awk fix) | FOUND |
| commit 78677a7 (mdns-status CLI) | FOUND |
| commit 094b986 (mocks) | FOUND |
| commit 8aa00b9 (test_get_primary_ip) | FOUND |
| commit 42462e4 (test_foreign_mdns_assert + awk fix) | FOUND |
| commit 9253e6b (test_mdns_status) | FOUND |
| commit 8183098 (test_mdns_reboot) | FOUND |
| commit 2c4096b (run_all.sh) | FOUND |
| commit aa18287 (STRICT smoke) | FOUND |
