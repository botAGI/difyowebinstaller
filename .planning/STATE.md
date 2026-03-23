---
gsd_state_version: 1.0
milestone: v2.5
milestone_name: Modular Model Selection + Xinference Removal
status: planning
stopped_at: Completed 20-02-PLAN.md
last_updated: "2026-03-23T08:08:25.460Z"
last_activity: 2026-03-23 — v2.5 roadmap created
progress:
  total_phases: 6
  completed_phases: 2
  total_plans: 4
  completed_plans: 4
  percent: 0
---

# State: AGmind Installer v2.5

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-23)

**Core value:** One command installs, secures, and monitors a production-ready AI stack

**Current focus:** Phase 19 — Bugfixes + GPU Enhancement

## Current Position

Phase: 19 (first of 6 in v2.5)
Plan: —
Status: Ready to plan
Last activity: 2026-03-23 — v2.5 roadmap created

Progress: `[░░░░░░░░░░] 0%`

## Performance Metrics

### Velocity (historical)

- v2.0 phases: 5 complete (13 plans)
- v2.1 phases: 4 complete (8 plans)
- v2.2 phases: 2 complete (4 plans)
- v2.3 phases: 4 complete (5 plans)
- v2.4 phases: 3 complete (3 plans)

### By Phase (v2.5)

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| TBD   | TBD   | —     | —        |

Updated after each plan completion.
| Phase 19-bugfixes-gpu-enhancement P01 | 2 | 2 tasks | 2 files |
| Phase 19 P02 | 102 | 2 tasks | 6 files |
| Phase 20-xinference-removal P02 | 16 | 2 tasks | 10 files |

## Accumulated Context

### Decisions

- v2.0: installer never touches Dify API (three-layer boundary)
- v2.0: credentials only in credentials.txt, never stdout
- v2.3: Phase 13 added VRAM guard in `_wizard_vllm_model()`
- v2.4: Phase 17 expanded vLLM model list to 16 models (Qwen3, MoE)
- v2.4: Phase 18 added `agmind gpu` subcommand (status/assign/auto)
- [Phase 19]: BFIX-43: preflight port check skips WARN when agmind nginx owns port 80/443 (docker compose ps check)
- [Phase 19]: GPUX-01: gpu status maps PIDs to container names via docker top + associative array, annotates vLLM/TEI with model from .env
- [Phase 19]: v2.5: TEI_VRAM_OFFSET=2 is readonly constant, not configurable; effective_vram used in both interactive and NON_INTERACTIVE VRAM guards
- [Phase 19]: v2.5: load_reranker() disabled as stub -- bce-reranker broken in Xinference v2.3.0, will use TEI in Phase 22
- [Phase 20-xinference-removal]: v2.5: Xinference orphan cleanup in update.sh stops agmind-xinference container and removes agmind_xinference_data volume on update from pre-v2.5 installations

### Architecture Notes

- `wizard.sh`: `_wizard_vllm_model()` has 16-model menu with VRAM guard
- `docker-compose.yml`: xinference in profile `etl`, coupled with Docling -- must decouple
- `lib/models.sh`: `load_reranker()` uses Xinference HTTP API -- must rewrite for TEI
- `lib/detect.sh`: `preflight_checks()` port 80/443 check doesn't filter agmind containers
- `docker-compose.yml`: CUDA_VISIBLE_DEVICES uses env vars

### Pending Todos

None.

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-03-23T08:08:25.458Z
Stopped at: Completed 20-02-PLAN.md
Resume file: None
