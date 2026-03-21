---
gsd_state_version: 1.0
milestone: v2.1
milestone_name: Bugfixes + Improvements
status: planning
stopped_at: Completed 08-02-PLAN.md
last_updated: "2026-03-21T17:16:14.784Z"
last_activity: 2026-03-20 — Roadmap created, v2.1 phases 6-8 defined
progress:
  total_phases: 4
  completed_phases: 3
  total_plans: 8
  completed_plans: 8
  percent: 0
---

# State: AGmind Installer v2.1

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-20)

**Core value:** One command installs, secures, and monitors a production-ready AI stack
**Current focus:** Phase 6 — Runtime Stability (plugin-daemon ordering, Redis locks, GPU reboot)

## Current Position

Phase: 6 of 8 (Runtime Stability)
Plan: 0 of TBD in current phase
Status: Ready to plan
Last activity: 2026-03-20 — Roadmap created, v2.1 phases 6-8 defined

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity (v2.0 baseline):**
- Total plans completed: 13 (v2.0)
- v2.0 phases: 5, all complete

**By Phase (v2.1):**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 6. Runtime Stability | TBD | - | - |
| 7. Update System | TBD | - | - |
| 8. Health & UX Polish | TBD | - | - |

*Updated after each plan completion*
| Phase 06-v3-bugfixes P01 | 15 | 2 tasks | 3 files |
| Phase 06-v3-bugfixes P02 | 12 | 2 tasks | 3 files |
| Phase 06-v3-bugfixes P03 | 15 | 2 tasks | 3 files |
| Phase 07-update-system P01 | 20 | 2 tasks | 2 files |
| Phase 07-update-system P02 | 2 | 2 tasks | 2 files |
| Phase 08-health-verification-ux-polish P01 | 16 | 2 tasks | 2 files |
| Phase 08-health-verification-ux-polish P03 | 2 | 2 tasks | 2 files |
| Phase 08-health-verification-ux-polish P02 | 2 | 1 tasks | 1 files |

## Accumulated Context

### Decisions

- v2.0: installer never touches Dify API (three-layer boundary)
- v2.0: credentials only in credentials.txt, never stdout
- v2.1: BUG-V3-024 merged into UPDT-01 (component update command)
- v2.1: BUG-V3-023 (auto model provider config) deferred to v2.2 — boundary violation
- [Phase 06-v3-bugfixes]: redis-lock-cleaner reuses redis image (no new pull for offline profile)
- [Phase 06-v3-bugfixes]: healthcheck upgraded to psql query verifying dify_plugin DB existence before plugin-daemon starts
- [Phase 06-v3-bugfixes]: GPU containers get unless-stopped (not always) so manual docker stop works without systemd fighting back
- [Phase 06-v3-bugfixes]: agmind-stack.service uses Type=oneshot+RemainAfterExit=yes so systemctl status shows active after one-shot command completes
- [Phase 06-v3-bugfixes]: EnvironmentFile uses '-' prefix so systemd does not fail before first installer run
- [Phase 06-v3-bugfixes]: sed -i dedup removes existing COMPOSE_PROFILES before append to avoid duplicates on re-runs
- [Phase 07-update-system]: fetch_remote_versions() replaces load_new_versions() — fetches from GitHub raw URL, not local versions.env
- [Phase 07-update-system]: NAME_TO_VERSION_KEY maps 28 component short names; shared-image groups (dify-*) trigger group confirmation
- [Phase 07-update-system]: Offline graceful degradation: shows current versions + suggests --version flag for manual update
- [Phase 07-update-system]: rollback_component() reads version from .rollback/dot-env.bak — ensures rollback is to pre-update state, not current
- [Phase 07-update-system]: MANUAL_ROLLBACK log prefix distinguishes user-initiated rollbacks from automatic healthcheck-triggered rollbacks (ROLLBACK prefix)
- [Phase 08-health-verification-ux-polish]: verify_services() returns failure count; caller uses '|| true' — failed checks never abort install
- [Phase 08-health-verification-ux-polish]: VERIFY_RESULTS global array avoids re-running curl in summary — checks run once in phase_complete
- [Phase 08-health-verification-ux-polish]: Portainer SSH tunnel hint skipped when ADMIN_UI_OPEN=true — direct 0.0.0.0:9443 access available in that case
- [Phase 08-health-verification-ux-polish]: ENABLE_SSH_HARDENING defaults to true (opt-out) — SSH key-only auth is a security best practice, skips safely in non-interactive if no authorized_keys found
- [Phase 08-health-verification-ux-polish]: systemctl reload (not restart) used for sshd after hardening — keeps existing SSH sessions alive
- [Phase 08-health-verification-ux-polish]: Apache 2.0 LICENSE created with AGMind Contributors copyright 2024-2026 for public GitHub release
- [Phase 08-health-verification-ux-polish]: verify_services() output suppressed in doctor (>/dev/null) — cmd_doctor uses _check for its own formatted output
- [Phase 08-health-verification-ux-polish]: lock-cleaner init-container skipped in exited check — expected to exit after one-shot Redis lock cleanup
- [Phase 08-health-verification-ux-polish]: Docker Disk summary rendered in text-only mode — docker system df table not parseable as JSON

### Pending Todos

None yet.

### Blockers/Concerns

None yet.

## Session Continuity

Last session: 2026-03-21T17:11:19.737Z
Stopped at: Completed 08-02-PLAN.md
Resume file: None
