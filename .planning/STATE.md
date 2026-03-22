---
gsd_state_version: 1.0
milestone: v2.3
milestone_name: Stability & Reliability Bugfixes
status: Roadmap ready, awaiting plan-phase 12
stopped_at: Completed 15-pull-download-ux-01-PLAN.md
last_updated: "2026-03-22T22:02:15.896Z"
last_activity: 2026-03-22 — Roadmap phases 12-15 created
progress:
  total_phases: 4
  completed_phases: 4
  total_plans: 5
  completed_plans: 5
  percent: 0
---

# State: AGmind Installer v2.3

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-22)

**Core value:** One command installs, secures, and monitors a production-ready AI stack
**Current focus:** Stability & Reliability Bugfixes — fix BUG-035–040 + WISH-010/011

## Current Position

Phase: 12 (not started)
Plan: —
Status: Roadmap ready, awaiting plan-phase 12
Last activity: 2026-03-22 — Roadmap phases 12-15 created

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity (historical):**
- v2.0 phases: 5 complete (13 plans)
- v2.1 phases: 4 complete (8 plans), Phase 9 skipped
- v2.2 phases: 2 complete (4 plans)

**By Phase (v2.3):**

| Phase | Plans | Total | Avg/Plan |
| --- | --- | --- | --- |
| 12. Isolated Bugfixes | TBD | — | — |
| 13. VRAM Guard in Wizard | TBD | — | — |
| 14. DB Password Resume Safety | TBD | — | — |
| 15. Pull & Download UX | TBD | — | — |

*Updated after each plan completion*
| Phase 12 P02 | 2min | 2 tasks | 2 files |
| Phase 12-isolated-bugfixes P01 | 15 | 2 tasks | 2 files |
| Phase 13-vram-guard-in-wizard P01 | 8 | 2 tasks | 1 files |
| Phase 14-db-password-resume-safety P01 | 80 | 2 tasks | 2 files |
| Phase 15-pull-download-ux P01 | 20 | 2 tasks | 3 files |

## Accumulated Context

### Decisions

- v2.0: installer never touches Dify API (three-layer boundary)
- v2.0: credentials only in credentials.txt, never stdout
- v2.1: Phase 7 implemented per-component update with rollback — v2.2 replaces with bundle-based
- v2.2: Bundle-based updates via GitHub Releases API (Coolify-style)
- v2.2: --component kept as emergency mode with warning (EMRG-01, EMRG-02)
- v2.2: Phase 10+11 complete: GitHub Release v2.1.0, bundle update rewrite
- v2.3: Phase 12 groups 4 isolated bugfixes (lowest risk, no UX flow changes)
- v2.3: Phase 13 isolated — VRAM guard changes wizard UX flow, medium complexity
- v2.3: Phase 14 isolated — DB_PASSWORD resume touches critical install path
- v2.3: Phase 15 groups pull/download UX improvements (low risk, additive only)
- [Phase 12]: NO_V_PREFIX array in check-upstream.sh: strip v-prefix at report write time, not at comparison — preserves is_newer/classify_change logic
- [Phase 12]: Dify init fallback in _save_credentials: prints grep INIT_PASSWORD as operator instruction, not executed — consistent with credentials-only-in-file policy
- [Phase 12-isolated-bugfixes]: OPUX-01: SKIP (not FAIL) when .env is unreadable without sudo avoids false positives in diagnostics
- [Phase 12-isolated-bugfixes]: OPUX-02: Explicit Redis ACL blocklist (12 commands) instead of -@dangerous so CONFIG/INFO/KEYS remain allowed for monitoring
- [Phase 13]: IREL-02: TEI offset -2 GB for [recommended] only, not for OOM warning threshold
- [Phase 13]: IREL-02: Custom model (option 11) intentionally skips VRAM check — unknown model size
- [Phase 14]: IREL-03: Check PG_VERSION file (not directory) as PG data indicator; generate fresh secrets first then override with backup for safe fallback
- [Phase 14]: IREL-03: Restore only DB_PASSWORD/REDIS_PASSWORD/SECRET_KEY — other secrets not persisted in volumes, always fresh
- [Phase 15-pull-download-ux]: DLUX-01: Missing Docker images produce per-image ERROR with image:tag, installation continues with warning (not abort)
- [Phase 15-pull-download-ux]: DLUX-02: MODEL_SIZES hardcoded table for zero-overhead size hints; TTY passthrough via docker exec -t with fallback; phase_models_graceful() + timeout handler cooperate for non-fatal model phase

### Architecture Notes

- check-upstream.sh: check_component() writes raw tag_name — needs v-prefix strip for Weaviate/Postgres/Redis/Grafana (IREL-01)
- wizard.sh: _wizard_vllm_model() has no VRAM gate — detect.sh exposes DETECTED_GPU_VRAM (IREL-02)
- lib/config.sh: _generate_env_file() regenerates DB_PASSWORD unconditionally on resume (IREL-03)
- lib/compose.sh: sync_db_password() alternative path — also needs guard (IREL-03)
- install.sh: _init_dify_admin() has 150s timeout (30 retries x 5s) — needs 300s (60 retries) (IREL-04)
- scripts/agmind.sh: cmd_doctor() .env Completeness block reads .env without root check — causes false FAIL (OPUX-01)
- lib/config.sh: generate_redis_config() uses -@dangerous blocklist — blocks CONFIG/INFO/KEYS (OPUX-02)
- lib/compose.sh: _pull_with_progress() swallows pull errors (|| true) — missing image goes unnoticed (DLUX-01)
- lib/models.sh: pull_model() runs without tty passthrough — no progress visible (DLUX-02)
- install.sh: run_phase_with_timeout() calls fatal on model timeout — should be warning (DLUX-02)

### Pending Todos

- [ ] Plan Phase 12: Isolated Bugfixes (IREL-01, IREL-04, OPUX-01, OPUX-02)
- [ ] Plan Phase 13: VRAM Guard in Wizard (IREL-02)
- [ ] Plan Phase 14: DB Password Resume Safety (IREL-03)
- [ ] Plan Phase 15: Pull & Download UX (DLUX-01, DLUX-02)

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-03-22T22:02:15.894Z
Stopped at: Completed 15-pull-download-ux-01-PLAN.md
Resume file: None
