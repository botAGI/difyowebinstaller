---
phase: 21-embeddings-wizard-docker
plan: "01"
subsystem: wizard
tags: [embeddings, tei, wizard, docker-compose]
dependency_graph:
  requires: []
  provides: [_wizard_embedding_model, tei-model-parameterization]
  affects: [lib/wizard.sh, templates/docker-compose.yml]
tech_stack:
  added: []
  patterns: [tei-model-menu, provider-aware-defaults, non-interactive-guard]
key_files:
  created: []
  modified:
    - lib/wizard.sh
    - templates/docker-compose.yml
decisions:
  - "TEI model menu has 3 presets without VRAM labels (embedding models are small)"
  - "TEI uses full HuggingFace IDs (BAAI/bge-m3), Ollama keeps short names (bge-m3)"
  - "EMBEDDING_MODEL default changed from bge-m3 to empty string — function sets provider-aware value"
  - "docker-compose uses ${EMBEDDING_MODEL:-BAAI/bge-m3} for backward compatibility"
  - "intfloat/multilingual-e5-large-instruct as model #3 per user decision in CONTEXT.md"
metrics:
  duration_minutes: 10
  completed_date: "2026-03-23"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 2
---

# Phase 21 Plan 01: Embedding Wizard TEI Model Menu Summary

**One-liner:** TEI embedding model selection menu in wizard with 3 HuggingFace presets + custom input, wired to parameterized docker-compose TEI service.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Rewrite _wizard_embed_model() with TEI model menu | 112b813 | lib/wizard.sh |
| 2 | Parameterize TEI model-id in docker-compose.yml | d0a2f45 | templates/docker-compose.yml |

## What Was Built

### Task 1 — lib/wizard.sh

Replaced the old `_wizard_embed_model()` (ollama-only, 9 lines) with a new `_wizard_embedding_model()` (56 lines) that handles three embedding providers:

- **TEI**: Shows a 4-item menu. Options 1-3 are preset HuggingFace models; option 4 asks for a manual ID and validates it with `validate_model_name`. Default is option 1 (BAAI/bge-m3).
- **Ollama**: Keeps existing simple `_ask` prompt with short name (bge-m3).
- **external/skip**: Returns immediately (no model selection needed).
- **NON_INTERACTIVE**: Uses `EMBEDDING_MODEL` env var if set and not the bare "bge-m3" value, otherwise applies a provider-aware default (BAAI/bge-m3 for TEI, bge-m3 for Ollama).

Additional changes:
- `run_wizard()` call updated: `_wizard_embed_model` → `_wizard_embedding_model`
- Default on line 34: `EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}"` → `EMBEDDING_MODEL="${EMBEDDING_MODEL:-}"` (empty; function sets value based on provider)

### Task 2 — templates/docker-compose.yml

Single-line change in the TEI service block:

```
Before: command: --model-id BAAI/bge-m3 --port 80
After:  command: --model-id ${EMBEDDING_MODEL:-BAAI/bge-m3} --port 80
```

The `${EMBEDDING_MODEL:-BAAI/bge-m3}` syntax ensures backward compatibility: existing deployments without EMBEDDING_MODEL in .env continue to use BAAI/bge-m3.

No changes needed in `lib/config.sh` (already substitutes `__EMBEDDING_MODEL__` via sed) or in the 4 env profile templates (all already have `EMBEDDING_MODEL=__EMBEDDING_MODEL__` placeholder).

## TEI Model Menu (User-Visible)

```
Выберите модель эмбеддингов TEI:

  1) BAAI/bge-m3                                — мультиязычная, стабильная  [по умолчанию]
  2) Qwen/Qwen3-Embedding-0.6B                  — лёгкая, 0.6B параметров
  3) intfloat/multilingual-e5-large-instruct     — instruct-версия, MTEB #7, понимает query:/passage: префиксы
  4) Ввод вручную                                — полный HuggingFace ID

Выбор [1-4, Enter=1]:
```

## Verification Results

All 6 plan verification checks passed:

1. `bash -n lib/wizard.sh` — SYNTAX_OK
2. `grep "_wizard_embedding_model" lib/wizard.sh` — found in definition and run_wizard() call
3. All 3 TEI model IDs present in wizard.sh
4. `grep "EMBEDDING_MODEL:-BAAI/bge-m3" templates/docker-compose.yml` — found
5. Hardcoded `model-id BAAI/bge-m3 --port` count: 0
6. All 4 env templates (lan/vps/vpn/offline) contain EMBEDDING_MODEL placeholder

## Deviations from Plan

None - plan executed exactly as written.

## Self-Check: PASSED

- `lib/wizard.sh` modified and committed: 112b813
- `templates/docker-compose.yml` modified and committed: d0a2f45
- Both commits present in git log
