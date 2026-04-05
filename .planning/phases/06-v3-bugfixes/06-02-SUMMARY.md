---
phase: 06-v3-bugfixes
plan: 02
subsystem: infra
tags: [systemd, docker-compose, gpu, restart-policy, ollama, vllm, tei, xinference]

# Dependency graph
requires:
  - phase: 06-v3-bugfixes plan 01
    provides: plugin-daemon ordering and Redis lock-cleaner (stable base to build on)
provides:
  - systemd unit (agmind-stack.service) for auto-starting Docker Compose stack after reboot
  - GPU containers (ollama, vllm, tei, xinference) with unless-stopped restart policy
  - _install_systemd_service() wired into install.sh phase_complete
affects: [07-update-system, 08-health-ux, reboot-scenarios, gpu-profiles]

# Tech tracking
tech-stack:
  added: [systemd oneshot service with RemainAfterExit]
  patterns: [template with __INSTALL_DIR__ placeholder replaced by sed in installer]

key-files:
  created:
    - templates/agmind-stack.service.template
  modified:
    - install.sh
    - templates/docker-compose.yml

key-decisions:
  - "Type=oneshot + RemainAfterExit=yes chosen so systemctl status shows active even after docker compose up -d returns"
  - "ExecStartPre docker-info loop (30s) ensures Docker daemon is ready before compose up"
  - "nvidia-smi wait is best-effort (continues if not available) to support non-GPU profiles"
  - "GPU containers get unless-stopped (not always) so manual docker stop works without systemd fighting back"

patterns-established:
  - "Template placeholder pattern: __INSTALL_DIR__ replaced via sed at install time"
  - "Systemd service installed in phase_complete alongside crons for clean lifecycle"

requirements-completed: [STAB-03]

# Metrics
duration: 12min
completed: 2026-03-21
---

# Phase 6 Plan 02: GPU Reboot Auto-Start Summary

**systemd oneshot service (agmind-stack.service) for automatic Docker Compose stack start after host reboot, plus unless-stopped restart policy on all four GPU containers (ollama, vllm, tei, xinference)**

## Performance

- **Duration:** 12 min
- **Started:** 2026-03-21T~09:00Z
- **Completed:** 2026-03-21
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Created `templates/agmind-stack.service.template` — systemd unit that waits for docker.service and nvidia-persistenced, then runs `docker compose up -d`
- Added `_install_systemd_service()` to install.sh and wired it into `phase_complete()`
- Changed restart policy for ollama, vllm, tei, xinference from `on-failure:5` to `unless-stopped`

## Task Commits

Each task was committed atomically:

1. **Task 1: Create systemd service template and install function** - `740def1` (feat)
2. **Task 2: Change GPU container restart policies to unless-stopped** - `c257852` (feat)

**Plan metadata:** (docs commit to follow)

## Files Created/Modified
- `templates/agmind-stack.service.template` - systemd unit file with docker.service + nvidia wait + oneshot pattern
- `install.sh` - added `_install_systemd_service()` function and wired into `phase_complete()`
- `templates/docker-compose.yml` - restart policy changed to `unless-stopped` for ollama, vllm, tei, xinference

## Decisions Made
- Type=oneshot + RemainAfterExit=yes: ensures systemctl status shows active after one-shot command completes
- nvidia-smi wait is best-effort (continues if GPU not present) to keep non-GPU profiles working
- unless-stopped (not always): allows manual `docker stop` without systemd re-starting immediately
- ExecStartPre loop waits up to 30s for Docker daemon readiness before starting compose

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- python3 not on PATH on Windows dev machine — used `python` instead for YAML validation. Production Linux target is unaffected.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 6 runtime stability groundwork complete (plugin-daemon ordering, Redis locks, GPU reboot)
- Ready for Phase 7 (Update System) or Phase 8 (Health & UX Polish)
- Operators should verify reboot behavior: `sudo reboot` then `systemctl status agmind-stack.service` and `agmind status`

---
*Phase: 06-v3-bugfixes*
*Completed: 2026-03-21*
