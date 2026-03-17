---
phase: 02-security-hardening-v2
plan: 02
subsystem: security
tags: [security, credentials, squid, authelia, admin-ui]
dependency_graph:
  requires: []
  provides: [SECV-01, SECV-02, SECV-03, SECV-04]
  affects: [install.sh, env-templates, authelia-config]
tech_stack:
  added: []
  patterns:
    - Portainer/Grafana bind to 127.0.0.1 by default (opt-in for LAN access)
    - Credentials suppressed from terminal stdout (written to chmod-600 file only)
    - Squid SSRF deny ACLs before allow rules (metadata, link-local, RFC1918)
    - Authelia bypass for API routes + two_factor for /console only
key_files:
  created: []
  modified:
    - install.sh
    - templates/env.lan.template
    - templates/env.vpn.template
    - templates/env.offline.template
    - templates/authelia/configuration.yml.template
decisions:
  - "ADMIN_UI_OPEN defaults to false; VPS always locked; non-interactive defaults to locked"
  - "Terminal summary shows URLs only; credentials.txt (chmod 600) is the single source of truth"
  - "Squid deny rules ordered before allow rules to prevent bypass"
  - "Authelia bypass rule for /api,/v1,/files placed before two_factor rule (first-match wins)"
metrics:
  duration: 4min
  completed: "2026-03-18"
  tasks_completed: 3
  files_modified: 5
---

# Phase 02 Plan 02: Security Hardening — Admin UI Lock, Credential Suppression, Squid SSRF, Authelia Summary

One-liner: Portainer/Grafana default to 127.0.0.1 with wizard opt-in; credentials removed from terminal stdout; Squid blocks cloud metadata and RFC1918 SSRF targets; Authelia 2FA restricted to /console only.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Lock env templates to 127.0.0.1 + wizard admin-UI opt-in | (already in HEAD at plan start) | templates/env.{lan,vpn,offline}.template, install.sh |
| 2 | Suppress credentials from terminal, add Squid deny rules | 9f5f12a | install.sh |
| 3 | Update Authelia access control policy for /console/* only | 1bb404c | templates/authelia/configuration.yml.template |

## What Was Built

### Task 1 — Admin UI Bind Address Lock (SECV-01)

Templates `env.lan.template`, `env.vpn.template`, `env.offline.template` changed from `GRAFANA_BIND_ADDR=0.0.0.0` and `PORTAINER_BIND_ADDR=0.0.0.0` to `127.0.0.1`. `env.vps.template` was already at `127.0.0.1` (unchanged).

`install.sh` received:
- Global variable `ADMIN_UI_OPEN=false` in global state section
- Wizard question "Открыть доступ из локальной сети?" for non-VPS profiles, with `NON_INTERACTIVE` guard (`ADMIN_UI_BIND_ADDR` env var triggers yes in non-interactive mode)
- `phase_config()` override: when `ADMIN_UI_OPEN=true`, sed flips `127.0.0.1` back to `0.0.0.0` in the generated `.env`

Note: Task 1 changes were already committed in a prior session (same phase). The Edit operations were idempotent.

### Task 2 — Credential Suppression (SECV-03) + Squid SSRF (SECV-04)

**Credential suppression** in `phase_complete()`:
- Removed `WebUI pass`, `Dify init pwd`, and `Grafana pass` printf lines from terminal summary box
- Renamed summary header from `CREDENTIALS & URLS` to `URLS & STATUS`
- Added `echo "Credentials saved to: .../credentials.txt (chmod 600)"` and `echo "View: cat .../credentials.txt"` after the box
- Removed old duplicate `echo -e "${YELLOW}Credentials saved to:..."` line at function end
- File-write block (`credentials.txt`) is **unchanged** — all passwords still written to disk

**Squid SSRF ACLs** in `create_squid_config()`:
Added before `http_access deny !Safe_ports`:
```
acl metadata dst 169.254.169.254
acl link_local dst 169.254.0.0/16
acl rfc1918_192 dst 192.168.0.0/16
http_access deny metadata
http_access deny link_local
http_access deny rfc1918_192
```
Deny-before-allow order preserved.

### Task 3 — Authelia API Bypass (SECV-02)

`templates/authelia/configuration.yml.template` `access_control` block updated:
- Added `bypass` rule for `^/api/.*$`, `^/v1/.*$`, `^/files/.*$` (Dify API routes use API key auth + nginx rate limiting)
- `bypass` rule placed BEFORE `two_factor` rule (Authelia first-match wins)
- `two_factor` rule retained for `^/console.*$`
- `default_policy: one_factor` unchanged
- All other template sections unchanged

## Verification Results

```
grep "GRAFANA_BIND_ADDR=127.0.0.1" templates/env.lan.template templates/env.vpn.template templates/env.offline.template  — PASS (3 matches)
grep "PORTAINER_BIND_ADDR=127.0.0.1" templates/env.lan.template templates/env.vpn.template templates/env.offline.template — PASS (3 matches)
grep "GRAFANA_BIND_ADDR=127.0.0.1" templates/env.vps.template — PASS (unchanged)
grep "ADMIN_UI_OPEN" install.sh — PASS (5 occurrences)
grep "Открыть доступ" install.sh — PASS
no passwords in summary+= lines — PASS
grep "Credentials saved to.*chmod 600" install.sh — PASS
grep "View: cat.*credentials.txt" install.sh — PASS
grep "WebUI pass.*owui_pass" install.sh (file-write) — PASS (credentials still in file)
grep "acl metadata dst 169.254.169.254" install.sh — PASS
grep "acl link_local dst 169.254.0.0/16" install.sh — PASS
grep "acl rfc1918_192 dst 192.168.0.0/16" install.sh — PASS
grep "http_access deny metadata" install.sh — PASS
grep "http_access deny link_local" install.sh — PASS
grep "http_access deny rfc1918_192" install.sh — PASS
deny before allow order — PASS
grep "policy: bypass" templates/authelia/configuration.yml.template — PASS
grep "policy: two_factor" templates/authelia/configuration.yml.template — PASS
bypass before two_factor (line order) — PASS
bash -n install.sh — PASS
```

## Security Threats Closed

| Threat | Mechanism | Closed By |
|--------|-----------|-----------|
| Portainer/Grafana exposed on LAN by default | BIND_ADDR=0.0.0.0 → 127.0.0.1 | Task 1 (SECV-01) |
| Credentials leaked to terminal/logs | Passwords in summary box | Task 2 (SECV-03) |
| SSRF to EC2 metadata endpoint (169.254.169.254) | Squid allows all destinations | Task 2 (SECV-04) |
| SSRF to link-local / RFC1918 via Squid | Missing deny ACLs | Task 2 (SECV-04) |
| Dify API calls blocked by Authelia one_factor | Missing bypass rule | Task 3 (SECV-02) |

## Deviations from Plan

### Task 1 — Pre-existing

Task 1 changes (templates + wizard + sed override) were already committed in a prior session when Phase 02 plans were initially created and executed. The Edit operations in this session were idempotent (no diff). No functional deviation.

## Self-Check: PASSED

- `templates/env.lan.template` — GRAFANA_BIND_ADDR=127.0.0.1 confirmed
- `templates/env.vpn.template` — GRAFANA_BIND_ADDR=127.0.0.1 confirmed
- `templates/env.offline.template` — GRAFANA_BIND_ADDR=127.0.0.1 confirmed
- `install.sh` — ADMIN_UI_OPEN, wizard question, Squid ACLs, credential suppression all confirmed
- `templates/authelia/configuration.yml.template` — bypass + two_factor confirmed
- Commits 9f5f12a and 1bb404c exist in git log
- `bash -n install.sh` exits 0
