---
phase: 02-security-hardening-v2
verified: 2026-03-18T14:00:00Z
status: passed
score: 14/14 must-haves verified
re_verification:
  previous_status: gaps_found
  previous_score: 13/14
  gaps_closed:
    - "REQUIREMENTS.md SECV-02 text now accurately reflects Authelia bypass design (bypass + 10r/s rate)"
    - "ROADMAP.md Phase 2 Authelia deliverable corrected; 02-04-PLAN.md marked complete"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "Run bats tests/test_backup.bats on a Linux machine with bats-core installed"
    expected: "All 19 tests pass, exit code 0"
    why_human: "BATS is not available in the Windows dev environment; tests can only be validated by running them on a Linux CI host"
  - test: "Run install.sh in non-interactive mode (NON_INTERACTIVE=true) and inspect the terminal output during phase_complete()"
    expected: "No passwords appear on stdout; terminal shows only URLs and 'Credentials saved to: /opt/agmind/credentials.txt (chmod 600)' + 'View: cat ...'"
    why_human: "Runtime behavior — credential suppression cannot be fully verified by static grep alone (the code is correct, but runtime path through phase_complete() needs a live run to confirm)"
---

# Phase 02: Security Hardening v2 — Verification Report (Re-verification)

**Phase Goal:** Close all known security gaps. Fail2ban and backup must actually work. Credentials never leak to stdout.
**Verified:** 2026-03-18
**Status:** passed — all 14 must-haves verified, gap from initial verification now closed
**Re-verification:** Yes — after gap closure (02-04-PLAN.md executed)

---

## Re-verification Summary

The initial verification (13/14) identified one documentation gap: REQUIREMENTS.md SECV-02 still read "Authelia 2FA covers ALL Dify routes" when the implementation intentionally bypasses `/api/`, `/v1/`, `/files/`. Plan `02-04-PLAN.md` was created and executed to close this gap. This re-verification confirms the fix is in place and no regressions were introduced.

| Closed gap | Evidence |
|-----------|----------|
| REQUIREMENTS.md SECV-02 text updated | Line now reads: "Authelia 2FA on /console/* (human login). API routes (/api/, /v1/, /files/) bypass Authelia — protected by Dify API key auth + nginx rate limiting (10r/s)." |
| ROADMAP.md Authelia deliverable updated | Phase 2 key deliverables: "Authelia 2FA on /console/* (human login); API routes bypass Authelia (Dify API key auth + rate limiting)" |
| 02-04-PLAN.md marked complete in ROADMAP.md | `[x] 02-04-PLAN.md — Gap closure: SECV-02 documentation drift fix (SECV-02)` |
| Stale text removed | `grep -c "covers all Dify routes" .planning/REQUIREMENTS.md` = 0 |

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Fail2ban nginx jail removed; only SSH jail remains | VERIFIED | `grep -c "agmind-nginx" lib/security.sh` = 0; `[sshd]` section present at line 64 |
| 2 | Login endpoint rate limited to 1r/10s with burst=3 | VERIFIED | `templates/nginx.conf.template` line 39: `zone=login:10m rate=1r/10s`; line 159: `limit_req zone=login burst=3 nodelay` |
| 3 | /v1/ and /files/ routes have rate limiting (zone=api burst=20 nodelay) | VERIFIED | Lines 198 and 211 in nginx.conf.template both contain `limit_req zone=api burst=20 nodelay` |
| 4 | Existing /console/api and /api rate limits preserved | VERIFIED | Lines 172 and 185: both blocks retain `limit_req zone=api burst=20 nodelay`; total `limit_req zone=` count = 5 |
| 5 | Portainer and Grafana bind to 127.0.0.1 by default on all profiles | VERIFIED | All 4 templates (lan/vpn/offline/vps) confirmed `GRAFANA_BIND_ADDR=127.0.0.1` and `PORTAINER_BIND_ADDR=127.0.0.1` |
| 6 | Wizard asks admin-UI bind question on LAN/VPN/Offline profiles (not VPS) | VERIFIED | `install.sh`: `if [[ "$DEPLOY_PROFILE" != "vps" ]]` guards the question; VPS branch sets `ADMIN_UI_OPEN=false` |
| 7 | Non-interactive mode defaults to 127.0.0.1 (locked down) | VERIFIED | `admin_ui_choice="${ADMIN_UI_BIND_ADDR:+yes}"` + default "no"; `ADMIN_UI_OPEN=false` globally initialized |
| 8 | Credentials (passwords) never appear on terminal stdout | VERIFIED | `grep "summary+=" install.sh` contains no references to `owui_pass`, `init_password`, or `grafana_pass` in printf lines |
| 9 | Terminal shows only URLs and path to credentials.txt file | VERIFIED | Lines in `phase_complete()`: `"Credentials saved to: ${INSTALL_DIR}/credentials.txt (chmod 600)"` and `"View: cat ${INSTALL_DIR}/credentials.txt"` |
| 10 | Squid SSRF proxy blocks 169.254.169.254, 169.254.0.0/16, 192.168.0.0/16 | VERIFIED | `install.sh:create_squid_config()` has all three `acl` definitions and `http_access deny` rules in correct order (deny before allow) |
| 11 | Authelia 2FA applied to /console/* only; /api/*, /v1/*, /files/* bypass | VERIFIED | `templates/authelia/configuration.yml.template`: `policy: bypass` for API routes, `policy: two_factor` for `/console.*$`; bypass rule before two_factor |
| 12 | Restore uses /opt/agmind/.restore_tmp as tmpdir (same filesystem) | VERIFIED | `scripts/restore.sh`: `RESTORE_TMP="${INSTALL_DIR}/.restore_tmp"`; no `mktemp` calls remain |
| 13 | Restore tmpdir cleaned on EXIT trap | VERIFIED | `cleanup_restore()` has `if [[ -d "${RESTORE_TMP:-}" ]]; then rm -rf "$RESTORE_TMP"`; trap on EXIT INT TERM; also cleaned on success path |
| 14 | REQUIREMENTS.md text for SECV-02 reflects actual implementation (API routes bypass Authelia) | VERIFIED | REQUIREMENTS.md line 21: "Authelia 2FA on /console/* (human login). API routes (/api/, /v1/, /files/) bypass Authelia — protected by Dify API key auth + nginx rate limiting (10r/s)." |

**Score: 14/14 truths verified**

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/security.sh` | Fail2ban SSH jail only, no nginx jail | VERIFIED | `[sshd]` present, `agmind-nginx` = 0 matches, `filter.d` = 0 matches, `configure_fail2ban()` with `ENABLE_FAIL2BAN` guard intact |
| `templates/nginx.conf.template` | Rate limiting on all API routes including /v1/ and /files/ | VERIFIED | 5 `limit_req zone=` directives; `rate=1r/10s` login zone; all location blocks protected |
| `install.sh` | Wizard admin-UI opt-in + credential suppression + Squid ACL | VERIFIED | `ADMIN_UI_OPEN` variable, wizard question, `phase_config()` sed override, Squid deny rules, no passwords in summary block |
| `templates/env.lan.template` | `GRAFANA_BIND_ADDR=127.0.0.1` | VERIFIED | Confirmed present |
| `templates/env.vpn.template` | `GRAFANA_BIND_ADDR=127.0.0.1` | VERIFIED | Confirmed present |
| `templates/env.offline.template` | `GRAFANA_BIND_ADDR=127.0.0.1` | VERIFIED | Confirmed present |
| `templates/authelia/configuration.yml.template` | Bypass for API routes, 2FA for /console | VERIFIED | `policy: bypass` confirmed, `policy: two_factor` confirmed, correct ordering |
| `scripts/restore.sh` | Fixed restore with tmpdir pattern and pipefail | VERIFIED | `RESTORE_TMP` defined, no `mktemp`, cleanup trap, `set -euo pipefail`, `--auto-confirm` and `--help` flags |
| `tests/test_backup.bats` | Backup/restore cycle BATS test | VERIFIED | File exists, 19 `@test` blocks (requirement >= 15) |
| `.planning/REQUIREMENTS.md` | SECV-02 text matches actual implementation | VERIFIED | "bypass Authelia" and "(10r/s)" both present; stale "covers all Dify routes" text absent |
| `.planning/ROADMAP.md` | Phase 2 Authelia deliverable accurate; 02-04-PLAN.md listed | VERIFIED | "bypass Authelia" in key deliverables; 02-04-PLAN.md marked `[x]` |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/security.sh:configure_fail2ban()` | fail2ban jail config | writes `/etc/fail2ban/jail.d/agmind.conf` with `[sshd]` only | WIRED | `[sshd]` at line 64; called by `setup_security()` |
| `templates/nginx.conf.template` | rate limit zones | `limit_req_zone` at http level, `limit_req` in location blocks | WIRED | Zones defined; applied at 5 location blocks |
| `install.sh:phase_wizard()` | env templates BIND_ADDR values | sed substitution in `phase_config()` when `ADMIN_UI_OPEN=true` | WIRED | `phase_config()` sed flips `127.0.0.1` to `0.0.0.0` when opted in |
| `install.sh:phase_complete()` | credentials.txt | passwords written to file, not terminal | WIRED | File-write block with `chmod 600` intact; no passwords in `summary+=` lines |
| `install.sh:create_squid_config()` | Squid ACL | deny rules before allow rules | WIRED | Deny rules confirmed before allow rules |
| `scripts/restore.sh` | data volumes | tmpdir copy pattern on same filesystem | WIRED | `RESTORE_TMP="${INSTALL_DIR}/.restore_tmp"` used throughout |
| `tests/test_backup.bats` | `scripts/backup.sh` and `scripts/restore.sh` | BATS tests validate script patterns | WIRED | 19 tests reference both scripts |
| `.planning/REQUIREMENTS.md:SECV-02` | `templates/authelia/configuration.yml.template` | documentation accuracy — bypass design | WIRED | Both now say "bypass Authelia"; no contradiction |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| SECV-01 | 02-02-PLAN | Portainer/Grafana bind 127.0.0.1 by default, opt-in to open | SATISFIED | All 4 env templates locked to 127.0.0.1; wizard opt-in in `install.sh` |
| SECV-02 | 02-02-PLAN / 02-04-PLAN | Authelia 2FA on /console/* only; API routes bypass (accepted design pivot) | SATISFIED | Implementation correct; REQUIREMENTS.md now accurately describes the bypass design |
| SECV-03 | 02-02-PLAN | Credentials written only to credentials.txt, not printed to stdout | SATISFIED | No passwords in `summary+=` lines; file-write block with `chmod 600` intact |
| SECV-04 | 02-02-PLAN | SSRF sandbox blocks RFC1918 + link-local + cloud metadata | SATISFIED | Squid ACLs for 169.254.169.254, 169.254.0.0/16, 192.168.0.0/16 with deny-before-allow ordering |
| SECV-05 | 02-01-PLAN | Fail2ban nginx jail replaced with nginx rate limiting | SATISFIED | `agmind-nginx` jail fully removed; nginx rate limiting covers all 5 routes |
| SECV-06 | 02-03-PLAN | Backup/restore fixed (tmpdir copy, parser flags, pipefail) | SATISFIED | `RESTORE_TMP` pattern, `--auto-confirm`, `--help`, no `mktemp`; `cleanup_restore()` on EXIT trap |
| SECV-07 | 02-01-PLAN | Rate limiting on nginx API routes (/v1/chat/completions, /console/api/) | SATISFIED | 5 location blocks rate-limited; login at 1r/10s; /v1 and /files at 10r/s zone=api |

**Orphaned requirements check:** No Phase 2 requirements in REQUIREMENTS.md fall outside the four plan files. All 7 SECV-* IDs are accounted for. REQUIREMENTS.md traceability table confirms all 7 as Complete.

---

## Anti-Patterns Found

No code anti-patterns detected. All modified files are clean of TODO/FIXME/placeholder markers, empty handlers, or stub implementations.

The documentation anti-pattern from the initial verification (stale SECV-02 text) is now resolved.

---

## Human Verification Required

### 1. BATS Test Suite Execution

**Test:** On a Linux host with bats-core installed, run `bats tests/test_backup.bats` from the project root.
**Expected:** All 19 tests pass, exit code 0. Key tests: "restore.sh uses .restore_tmp not mktemp", "restore.sh cleans RESTORE_TMP in cleanup trap", "restore.sh validates INSTALL_DIR path", both `bash -n` syntax checks.
**Why human:** BATS is not available in the Windows development environment; the test file and the patterns it validates are statically confirmed correct, but execution must be done on Linux CI.

### 2. Credential Suppression Runtime Check

**Test:** Execute `sudo bash install.sh` (or dry-run simulation) through a full run, observing terminal output during `phase_complete()`.
**Expected:** Terminal displays only: Open WebUI URL, Dify Console URL, Grafana URL, Portainer URL, service info lines, then "Credentials saved to: /opt/agmind/credentials.txt (chmod 600)" and "View: cat /opt/agmind/credentials.txt". No password values visible on terminal.
**Why human:** Static analysis confirms passwords are not in `summary+=` lines, but runtime behavior (log redirection, sub-shell escapes, color codes) can only be fully verified by running the installer.

---

## Commit Verification

All commits documented in summaries confirmed in git history:

| Commit | Plan | Description |
|--------|------|-------------|
| `08af236` | 02-01 | feat: extend nginx rate limiting to /v1/ and /files/, tighten login rate |
| `40f0748` | 02-01 | fix: remove broken fail2ban nginx jail, keep SSH jail only |
| `9f5f12a` | 02-02 | feat: suppress credentials from terminal + Squid SSRF ACLs |
| `1bb404c` | 02-02 | feat: Authelia 2FA on /console/* only, API routes bypass |
| `e377b2a` | 02-03 | fix: restore.sh — tmpdir pattern, pipefail comment, CLI flags |
| `f4c9a26` | 02-03 | feat: add BATS tests for backup/restore validation |
| `068a865` | 02-04 | docs: fix SECV-02 documentation drift in REQUIREMENTS.md and ROADMAP.md |
| `cb41615` | 02-04 | docs: complete SECV-02 documentation gap closure plan — Phase 2 fully complete |

All 8 commits verified present in `git log`.

---

_Verified: 2026-03-18_
_Verifier: Claude (gsd-verifier)_
_Re-verification: Yes — gap from initial verification (13/14) closed by 02-04-PLAN.md execution_
