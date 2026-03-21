---
phase: 08-health-verification-ux-polish
plan: 03
subsystem: security
tags: [ssh, hardening, lockout-prevention, apache-license, open-source]

# Dependency graph
requires:
  - phase: 08-health-verification-ux-polish
    provides: UX polish context and phase scaffold
provides:
  - harden_ssh() function with lockout prevention warning in lib/security.sh
  - Apache 2.0 LICENSE file with AGMind Contributors copyright
affects: [future-security-phases, public-release]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "SSH hardening with guard variable ENABLE_SSH_HARDENING (default true = opt-out)"
    - "Non-interactive safety: skip SSH password disable if no authorized_keys found"
    - "systemctl reload (not restart) to keep active SSH sessions alive during hardening"
    - "Timestamped backup before any sshd_config modification"

key-files:
  created:
    - LICENSE
  modified:
    - lib/security.sh

key-decisions:
  - "ENABLE_SSH_HARDENING defaults to true (opt-out) — SSH key-only auth is a security best practice"
  - "Non-interactive mode skips password disable if no SSH key found — prevents lockout on automated installs"
  - "systemctl reload used instead of restart — keeps existing SSH sessions alive after hardening"
  - "ChallengeResponseAuthentication also disabled alongside PasswordAuthentication to prevent password fallback"
  - "logname / SUDO_USER used to detect real login user, not root running sudo"
  - "Apache 2.0 chosen for open-source compatibility; copyright AGMind Contributors 2024-2026"

patterns-established:
  - "SSH safety pattern: warn prominently, detect keys, instruct, confirm, backup, apply, reload"
  - "Security guard pattern: ENABLE_<FEATURE>=false to skip, true to apply (consistent with ENABLE_UFW, ENABLE_FAIL2BAN)"

requirements-completed:
  - UXPL-01
  - UXPL-03

# Metrics
duration: 2min
completed: 2026-03-21
---

# Phase 8 Plan 03: SSH Lockout Prevention and Apache LICENSE Summary

**SSH hardening with prominent Russian lockout warning, authorized_keys detection, and ssh-keygen/ssh-copy-id instructions added to lib/security.sh; Apache 2.0 LICENSE created for public GitHub release**

## Performance

- **Duration:** 2 min
- **Started:** 2026-03-21T17:04:05Z
- **Completed:** 2026-03-21T17:06:15Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `harden_ssh()` function to `lib/security.sh` with full lockout prevention UX
- Prominent box-drawn WARNING banner (ВНИМАНИЕ: ОТКЛЮЧЕНИЕ SSH ПАРОЛЕЙ) shown before disabling PasswordAuthentication
- Detects `authorized_keys` for real login user; shows `ssh-keygen` + `ssh-copy-id` instructions when no key found
- Non-interactive mode safely skips password disable if no SSH key is present (prevents automated lockout)
- `setup_security()` chain updated: `configure_ufw → configure_fail2ban → harden_ssh → harden_docker_compose → encrypt_secrets`
- Created full Apache 2.0 LICENSE file (194 lines) with AGMind Contributors copyright for public release

## Task Commits

Each task was committed atomically:

1. **Task 1: Add harden_ssh() with lockout prevention** - `e879578` (feat)
2. **Task 2: Create Apache 2.0 LICENSE file** - `94c9268` (chore)

## Files Created/Modified

- `lib/security.sh` - Added `harden_ssh()` function (102 lines) and updated `setup_security()` call chain
- `LICENSE` - Full Apache License Version 2.0 text with AGMind Contributors copyright (194 lines)

## Decisions Made

- `ENABLE_SSH_HARDENING` defaults to `true` (opt-out model) — consistent with security-by-default philosophy of the project
- Non-interactive mode only disables passwords when `authorized_keys` exists — prevents lockout on CI/automation installs
- `systemctl reload` instead of `restart` — keeps all active SSH sessions alive during hardening
- `ChallengeResponseAuthentication` also disabled to close password fallback via PAM
- `logname 2>/dev/null || "${SUDO_USER:-root}"` detects real operator user even when running as sudo
- Apache 2.0 for maximum open-source compatibility (permissive, patent grant included)

## Deviations from Plan

None - план выполнен точно в соответствии со спецификацией.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- SSH hardening is fully integrated into the `setup_security()` chain and will activate on next installer run
- Operators running `ENABLE_SSH_HARDENING=false sudo bash install.sh` can opt out
- LICENSE file is present for public GitHub release
- Phase 8 plans 01-03 complete; ready for final phase verification

## Self-Check: PASSED

- `lib/security.sh` — FOUND
- `LICENSE` — FOUND
- `08-03-SUMMARY.md` — FOUND
- Commit `e879578` (Task 1) — FOUND
- Commit `94c9268` (Task 2) — FOUND

---
*Phase: 08-health-verification-ux-polish*
*Completed: 2026-03-21*
