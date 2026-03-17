---
phase: 02-security-hardening-v2
plan: 01
subsystem: infra
tags: [nginx, fail2ban, rate-limiting, security, brute-force]

# Dependency graph
requires:
  - phase: 01-surgery-remove-dify-api-automation
    provides: clean install.sh without Dify API automation; nginx.conf.template baseline
provides:
  - nginx rate limiting on all Dify API routes (/console/api/login, /console/api, /api, /v1, /files)
  - login endpoint tightened to 1r/10s with burst=3
  - fail2ban SSH-only jail (nginx jail removed)
affects: [03-provider-architecture, 04-installer-redesign, 05-devops-ux]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "nginx limit_req_zone zones: api(10r/s) and login(1r/10s) — apply per-location"
    - "fail2ban SSH-only on VPS profile — nginx handles HTTP brute-force via rate limiting"

key-files:
  created: []
  modified:
    - templates/nginx.conf.template
    - lib/security.sh

key-decisions:
  - "Login rate at 1r/10s burst=3: 1 attempt per 10s blocks dictionary attacks; burst=3 allows genuine typos without lockout"
  - "Dedicated /console/api/login location BEFORE /console/api block: nginx uses longest prefix match, so login gets the stricter zone"
  - "Fail2ban nginx jail removed entirely: Docker logpath /opt/agmind/docker/volumes/nginx/logs/access.log never exists on host — jail was silently useless; nginx rate limiting is the correct fix"
  - "filter.d/agmind-nginx.conf creation removed: no nginx jail means no need for filter file"

patterns-established:
  - "API route protection: always add limit_req directive as first line in location block"
  - "fail2ban scope: SSH jail only on this project; HTTP brute-force handled by nginx"

requirements-completed: [SECV-05, SECV-07]

# Metrics
duration: 2min
completed: 2026-03-18
---

# Phase 2 Plan 01: Security Hardening v2 — nginx Rate Limiting + Fail2ban Cleanup Summary

**nginx rate limiting extended to all 5 Dify API routes with login tightened to 1r/10s; broken fail2ban nginx jail removed, SSH jail preserved**

## Performance

- **Duration:** 2 min
- **Started:** 2026-03-17T23:21:06Z
- **Completed:** 2026-03-17T23:22:48Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Login endpoint now rate limited to 1 attempt per 10 seconds (burst=3) — blocks brute-force while allowing human typos
- All Dify API routes now rate limited: /console/api/login (login zone), /console/api, /api, /v1, /files (api zone at 10r/s)
- Broken fail2ban nginx jail removed — nginx rate limiting replaces it as the authoritative HTTP brute-force defense

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend nginx rate limiting to /v1/ and /files/, tighten login rate** - `08af236` (feat)
2. **Task 2: Remove fail2ban nginx jail, keep SSH jail only** - `40f0748` (fix)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `templates/nginx.conf.template` — Added /console/api/login location block (zone=login burst=3 nodelay); changed login zone rate from 3r/s to 1r/10s; added limit_req to /v1 and /files blocks
- `lib/security.sh` — Removed filter.d/agmind-nginx.conf creation block; removed [agmind-nginx] jail section; kept [sshd] jail with maxretry=3, bantime=864000

## Decisions Made

- Login rate at 1r/10s burst=3: 1 attempt per 10s blocks dictionary attacks; burst=3 allows 3 fast retries for genuine typos before throttle kicks in
- Dedicated /console/api/login location placed BEFORE /console/api: nginx longest-prefix match ensures login gets the stricter zone, not the general api zone
- Fail2ban nginx jail removed entirely (not just disabled): the filter and jail were silently non-functional because Docker runs nginx in a container and the logpath /opt/agmind/docker/volumes/nginx/logs/access.log never exists on the host. No point keeping dead config.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required. Changes take effect on next `install.sh` run or nginx container restart.

## Next Phase Readiness

- nginx rate limiting is complete for Phase 2 Plan 01 scope
- Remaining Phase 2 plans: credential suppression (SECV-03), backup/restore fixes (SECV-06), Squid ACL hardening (SECV-04), Authelia route policy (SECV-02), wizard opt-in for admin UIs (SECV-01)
- No blockers for subsequent plans

## Self-Check: PASSED

- templates/nginx.conf.template: FOUND
- lib/security.sh: FOUND
- 02-01-SUMMARY.md: FOUND
- Commit 08af236: FOUND
- Commit 40f0748: FOUND

---
*Phase: 02-security-hardening-v2*
*Completed: 2026-03-18*
