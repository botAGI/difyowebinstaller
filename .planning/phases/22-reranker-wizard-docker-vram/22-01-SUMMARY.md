---
phase: 22-reranker-wizard-docker-vram
plan: "01"
subsystem: wizard
tags: [reranker, wizard, vram-guard, tei, ux]
dependency_graph:
  requires: [21-01]
  provides: [_wizard_reranker_model, RERANKER_VRAM_OFFSET, ENABLE_RERANKER export]
  affects: [lib/wizard.sh]
tech_stack:
  added: []
  patterns: [yes/no gate before model menu, VRAM offset chaining, NON_INTERACTIVE env passthrough]
key_files:
  created: []
  modified:
    - lib/wizard.sh
decisions:
  - "_ask_yn helper does not exist; used _ask with default 'n' for yes/no gate — consistent with _wizard_confirm pattern"
  - "RERANKER_VRAM_OFFSET=1 placed immediately after TEI_VRAM_OFFSET=2 as readonly constant"
  - "All 3 VRAM guard locations updated: interactive effective_vram, interactive VRAM check+warn, NON_INTERACTIVE VRAM check+error"
metrics:
  duration_minutes: ~10
  completed_date: "2026-03-23"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 1
---

# Phase 22 Plan 01: Reranker Wizard Step + VRAM Budget Summary

**One-liner:** Added optional TEI reranker wizard step with yes/no gate, 3-model menu, and VRAM budget integration that subtracts 1 GB from effective VRAM when reranker is enabled.

## What Was Built

### _wizard_reranker_model() function
New wizard step in `lib/wizard.sh` that:
- Asks yes/no "Включить реранкер?" with default "n" (NON_INTERACTIVE default: false)
- If enabled: shows 3-model TEI reranker menu + custom HuggingFace ID option
- NON_INTERACTIVE: respects `ENABLE_RERANKER` env var; defaults `RERANK_MODEL` to `BAAI/bge-reranker-v2-m3` when enabled
- Inserted in `run_wizard()` between `_wizard_embedding_model` and `_wizard_hf_token`

### RERANKER_VRAM_OFFSET=1 constant
`readonly RERANKER_VRAM_OFFSET=1` placed next to `TEI_VRAM_OFFSET=2`. Used in 3 VRAM guard locations.

### VRAM guard updates (3 locations)
- Interactive `effective_vram` calculation for [recommended] model tag
- Interactive VRAM check guard with updated warning message showing `TEI + reranker` offset when both enabled
- NON_INTERACTIVE VRAM check with updated error message showing offset breakdown

### Wizard summary line
`_wizard_summary()` shows `Реранкер: {model} (~1 GB)` line when `ENABLE_RERANKER=true`.

### Exports
`run_wizard()` now exports `ENABLE_RERANKER` and `RERANK_MODEL`.

## Tasks Completed

| Task | Name | Commit | Key Changes |
|------|------|--------|-------------|
| 1 | Add _wizard_reranker_model() and RERANKER_VRAM_OFFSET | 49197f7 | _init_wizard_defaults defaults, readonly constant, new function |
| 2 | Wire reranker into run_wizard, VRAM guards, summary | df23944 | run_wizard call, exports, 3x VRAM guard updates, summary line |

## Verification Results

```
bash -n lib/wizard.sh  →  SYNTAX_OK
grep -c "_wizard_reranker_model"  →  2 (definition + run_wizard call)
grep "readonly RERANKER_VRAM_OFFSET=1"  →  1 match
grep -c "ENABLE_RERANKER"  →  9 matches
grep -c "BAAI/bge-reranker-v2-m3"  →  7 matches (menu x2, NON_INTERACTIVE, case x3, summary)
grep "Реранкер:" → 1 match in _wizard_summary
All 3 VRAM guard locations include reranker offset subtraction
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] _ask_yn helper does not exist**
- **Found during:** Task 1
- **Issue:** Plan specified `_ask_yn "Включить реранкер?" "n"` but this helper function does not exist in wizard.sh
- **Fix:** Used `_ask "Включить реранкер? [y/N]:" "n"` which is the existing pattern (matches `_wizard_confirm` and other yes/no prompts in the file)
- **Files modified:** lib/wizard.sh
- **Commit:** 49197f7

## Self-Check

- [x] lib/wizard.sh exists and modified
- [x] Commit 49197f7 exists (Task 1)
- [x] Commit df23944 exists (Task 2)
- [x] bash -n passes
- [x] All acceptance criteria verified

## Self-Check: PASSED
