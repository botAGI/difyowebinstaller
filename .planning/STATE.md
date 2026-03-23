---
gsd_state_version: 1.0
milestone: v2.4
milestone_name: Wizard Models + GPU Management
status: Roadmap ready, awaiting plan-phase 16
stopped_at: Completed 17-wizard-model-list-update-01-PLAN.md
last_updated: "2026-03-22T23:57:28.118Z"
last_activity: "2026-03-23 — Roadmap v2.4 created: Phases 16-18"
progress:
  total_phases: 3
  completed_phases: 2
  total_plans: 2
  completed_plans: 2
  percent: 0
---

# State: AGmind Installer v2.4

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-23)

**Core value:** One command installs, secures, and monitors a production-ready AI stack

**Current focus:** Wizard Models + GPU Management

## Current Position

Phase: 16 (next to execute)
Plan: — (not yet planned)
Status: Roadmap ready, awaiting plan-phase 16
Last activity: 2026-03-23 — Roadmap v2.4 created: Phases 16-18

Progress: `[░░░░░░░░░░] 0% (0/3 phases)`

## Performance Metrics

### Velocity (historical)

- v2.0 phases: 5 complete (13 plans)
- v2.1 phases: 4 complete (8 plans)
- v2.2 phases: 2 complete (4 plans)
- v2.3 phases: 4 complete (5 plans)

### By Phase (v2.4)

| Phase                        | Plans | Total | Avg/Plan |
|------------------------------|-------|-------|----------|
| 16. Critical Bugfixes        | TBD   | —     | —        |
| 17. Wizard Model List Update | TBD   | —     | —        |
| 18. GPU Management CLI       | TBD   | —     | —        |

Updated after each plan completion.
| Phase 16-critical-bugfixes P01 | 15 | 2 tasks | 2 files |
| Phase 17-wizard-model-list-update P01 | 2 | 2 tasks | 2 files |

## Accumulated Context

### Decisions

- v2.0: installer never touches Dify API (three-layer boundary)
- v2.0: credentials only in credentials.txt, never stdout
- v2.3: Phase 13 added VRAM guard in `_wizard_vllm_model()` — but NON_INTERACTIVE path bypasses it (BUG-041, fixed in Phase 16)
- v2.3: Phase 14 added `_restore_secrets_from_backup()` — resume preserves DB_PASSWORD
- v2.3: Phase 15 added graceful model timeout — `phase_models_graceful()`
- v2.4: Phase 16 fixes NON_INTERACTIVE VRAM guard + resume diagnostics (2 isolated bugfixes)
- v2.4: Phase 17 updates wizard model list — Qwen3, MoE, corrected VRAM req (14B AWQ: 12→10 GB)
- v2.4: Phase 18 adds agmind gpu subcommand — status + assign + docker-compose env vars
- [Phase 16-critical-bugfixes]: BFIX-41: Unknown custom vLLM models in NON_INTERACTIVE get warning only (no exit) -- matches interactive behavior
- [Phase 16-critical-bugfixes]: BFIX-42: On resume use run_diagnostics (not phase_diagnostics) to avoid preflight_checks user prompts; || true for partial GPU detection
- [Phase 17-wizard-model-list-update]: Phase 17-01: Default Enter=6 selects Qwen/Qwen2.5-7B-Instruct in 16-model menu
- [Phase 17-wizard-model-list-update]: Phase 17-01: VRAM corrected for AWQ models (14B: 12->10 GB, 7B: 8->5 GB) per hardware measurements
- [Phase 17-wizard-model-list-update]: Phase 17-01: MoE section separate from 32B+ bf16 to clarify active vs total params

### Architecture Notes

- `wizard.sh`: `_wizard_llm_model()` returns early for NON_INTERACTIVE — VRAM guard never reached (fix: Phase 16)
- `wizard.sh`: default `VLLM_MODEL=Qwen2.5-14B-Instruct` assigned without VRAM check (fix: Phase 16)
- `install.sh`: resume with start >= 2 skips `phase_diagnostics` → DETECTED_OS/DETECTED_GPU_VRAM unset (fix: Phase 16)
- `wizard.sh`: `_wizard_vllm_model()` model list needs Qwen3-8B, Qwen3-8B-AWQ, Qwen3-14B-AWQ, Qwen3-Coder-Next MoE AWQ, Nemotron Nano MoE AWQ (Phase 17)
- `lib/models.sh`: MODEL_SIZES needs entries for all new models (Phase 17)
- `docker-compose.yml:320`: CUDA_VISIBLE_DEVICES hardcoded "0" for vLLM → `${VLLM_CUDA_DEVICE:-0}` (Phase 18)
- `docker-compose.yml:352`: CUDA_VISIBLE_DEVICES hardcoded "0" for TEI → `${TEI_CUDA_DEVICE:-0}` (Phase 18)
- `agmind.sh`: no gpu subcommand exists — `cmd_gpu` + `_gpu_status` + `_gpu_assign` + `_gpu_auto_assign` needed (Phase 18)

### Key Files Per Phase

**Phase 16 (BFIX-41, BFIX-42):**

- `lib/wizard.sh` — `_wizard_llm_model` NON_INTERACTIVE path + default VRAM check
- `install.sh` — resume logic before phase table (always call run_diagnostics)

**Phase 17 (WMOD-01, WMOD-02):**

- `lib/wizard.sh` — `_wizard_vllm_model` model list + vram_req array
- `lib/models.sh` — MODEL_SIZES associative array

**Phase 18 (GPUM-01, GPUM-02, GPUM-03):**

- `scripts/agmind.sh` — new `cmd_gpu` + `_gpu_status` + `_gpu_assign` + `_gpu_auto_assign`
- `templates/docker-compose.yml` — CUDA_VISIBLE_DEVICES lines → env var substitution

### Pending Todos

- [ ] Plan Phase 16: Critical Bugfixes
- [ ] Execute Phase 16
- [ ] Plan Phase 17: Wizard Model List Update
- [ ] Execute Phase 17
- [ ] Plan Phase 18: GPU Management CLI
- [ ] Execute Phase 18
- [ ] Tag GitHub Release v2.4.0

### Blockers/Concerns

None.

## Session Continuity

Last session: 2026-03-22T23:57:28.116Z
Stopped at: Completed 17-wizard-model-list-update-01-PLAN.md
Resume file: None
