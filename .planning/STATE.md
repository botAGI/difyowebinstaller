---
gsd_state_version: 1.0
milestone: v2.5
milestone_name: Modular Model Selection + Xinference Removal
status: planning
stopped_at: Completed 23-llm-model-list-effective-vram 23-01-PLAN.md
last_updated: "2026-03-23T09:46:38.958Z"
last_activity: 2026-03-23 — v2.5 roadmap created
progress:
  total_phases: 6
  completed_phases: 5
  total_plans: 8
  completed_plans: 8
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
| Phase 20-xinference-removal P01 | 209 | 2 tasks | 10 files |
| Phase 21-embeddings-wizard-docker P01 | 10 | 2 tasks | 2 files |
| Phase 22-reranker-wizard-docker-vram P02 | 8 | 2 tasks | 7 files |
| Phase 22-reranker-wizard-docker-vram P01 | 10 | 2 tasks | 1 files |
| Phase 23-llm-model-list-effective-vram P01 | 12 | 2 tasks | 1 files |

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
- [Phase 20-xinference-removal]: ETL_ENHANCED retained as fallback in backward-compat shim; ENABLE_DOCLING is now primary flag
- [Phase 20-xinference-removal]: load_reranker() fully deleted; Docling profile renamed etl→docling
- [Phase 21-embeddings-wizard-docker]: TEI embedding model selection menu in wizard with 3 HuggingFace presets + custom input, wired to parameterized docker-compose TEI service
- [Phase 21-embeddings-wizard-docker]: TEI uses full HuggingFace IDs (BAAI/bge-m3), Ollama keeps short names (bge-m3); EMBEDDING_MODEL default changed to empty string
- [Phase 22-reranker-wizard-docker-vram]: TEI reranker reuses same image/version as TEI embed; RERANK_MODEL defaults to BAAI/bge-reranker-v2-m3; activated via ENABLE_RERANKER=true in reranker compose profile
- [Phase 22-reranker-wizard-docker-vram]: Phase 22: _wizard_reranker_model() uses _ask with default n for yes/no gate; RERANKER_VRAM_OFFSET=1 readonly; all 3 VRAM guard locations subtract reranker offset when ENABLE_RERANKER=true
- [Phase 23-llm-model-list-effective-vram]: _get_vram_offset() replaces TEI/RERANKER_VRAM_OFFSET constants; defaults EMBED_PROVIDER to tei (safe conservative fallback) to avoid underestimating GPU offset

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

Last session: 2026-03-23T09:46:38.956Z
Stopped at: Completed 23-llm-model-list-effective-vram 23-01-PLAN.md
Resume file: None
