---
phase: 25-install-stability
plan: 02
subsystem: infra
tags: [tls, certbot, letsencrypt, nginx, squid, ssrf, credentials, docker-compose]

# Dependency graph
requires:
  - phase: 25-install-stability
    provides: Plan 01 — preflight + port-conflict fixes (if executed)
provides:
  - TLS letsencrypt race condition fix via self-signed placeholder cert
  - Squid LAN-aware RFC1918 config for Dify sandbox webhook calls
  - Bilingual disclaimer in credentials.txt about stale passwords
affects:
  - 25-install-stability plan 03 and beyond
  - All profiles using TLS_MODE=letsencrypt (VPS profile)
  - All profiles using Squid SSRF proxy (all profiles)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TLS bootstrap: generate self-signed placeholder first, certbot obtains real cert post-compose"
    - "Profile-aware config generation: DEPLOY_PROFILE conditional in _generate_squid_config"
    - "Certbot obtain via docker compose run --rm (one-shot) vs renewal loop service"

key-files:
  created: []
  modified:
    - lib/config.sh
    - install.sh

key-decisions:
  - "letsencrypt TLS: nginx starts with self-signed placeholder cert on /etc/nginx/ssl/cert.pem, certbot obtains real cert post-compose and switches nginx to /etc/letsencrypt/live paths via sed + reload"
  - "Squid RFC1918: LAN/Offline profiles allow 10.x and 192.168.x for Dify sandbox internal webhooks; VPS/VPN still block RFC1918 for SSRF protection; 169.254.x always blocked in all profiles"
  - "_obtain_letsencrypt_cert() called in phase_health after wait_healthy+check_critical — ensures nginx healthy before certbot webroot challenge"

patterns-established:
  - "Profile-aware config: use DEPLOY_PROFILE global var in config generation functions to conditionally apply security rules"
  - "Placeholder-then-real pattern: generate temporary cert for startup, replace with real cert after service is healthy"

requirements-completed:
  - ISTB-02
  - ISTB-03
  - ISTB-05

# Metrics
duration: 2min
completed: 2026-03-25
---

# Phase 25 Plan 02: Install Stability — TLS + Squid + Credentials Summary

**Self-signed placeholder cert eliminates letsencrypt nginx deadlock; Squid now profile-aware allowing RFC1918 in LAN for Dify webhooks; credentials.txt has bilingual stale-password disclaimer**

## Performance

- **Duration:** ~2 min
- **Started:** 2026-03-25T13:17:53Z
- **Completed:** 2026-03-25T13:20:00Z
- **Tasks:** 3
- **Files modified:** 2

## Accomplishments

- Fixed TLS_MODE=letsencrypt deadlock: nginx no longer fails on missing cert at startup — placeholder cert generated via _generate_self_signed_cert, certbot obtains real cert post-compose via _obtain_letsencrypt_cert()
- Fixed Squid blocking Dify sandbox webhook calls in LAN profile: _generate_squid_config() is now profile-aware, RFC1918 allowed for lan/offline, blocked for vps/vpn
- Added bilingual (RU+EN) disclaimer at the bottom of credentials.txt warning that passwords may become stale after UI changes

## Task Commits

Each task was committed atomically:

1. **Task 1: Self-signed placeholder cert for letsencrypt + post-compose certbot** - `e8f027d` (fix)
2. **Task 2: Squid RFC1918 allow for LAN profile** - `5879969` (fix)
3. **Task 3: Credentials disclaimer in credentials.txt** - `026463d` (fix)

## Files Created/Modified

- `lib/config.sh` — handle_tls_config letsencrypt case: calls _generate_self_signed_cert; generate_nginx_config: letsencrypt uses placeholder cert path; _generate_squid_config: profile-aware RFC1918 rules
- `install.sh` — new _obtain_letsencrypt_cert() function (certbot webroot obtain + nginx reload); phase_health calls it after wait_healthy; _save_credentials: bilingual disclaimer appended

## Decisions Made

- letsencrypt TLS uses same /etc/nginx/ssl/cert.pem path as self-signed for initial startup — avoids needing two nginx config templates; _obtain_letsencrypt_cert patches paths via sed after real cert obtained
- _obtain_letsencrypt_cert runs inside phase_health (after nginx healthy) not phase_complete — ensures certbot webroot challenge can succeed since nginx must already be serving /.well-known/acme-challenge/
- Squid defaults to VPS profile behavior (block RFC1918) when DEPLOY_PROFILE is unset — safe conservative default for unknown environments

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Plan 02 complete: three install stability issues fixed
- Ready for Phase 25 Plan 03 (if exists) or Phase 25 completion
- Profiles affected: VPS (letsencrypt TLS fix), LAN/Offline (Squid webhook fix), all profiles (credentials disclaimer)

---
*Phase: 25-install-stability*
*Completed: 2026-03-25*
