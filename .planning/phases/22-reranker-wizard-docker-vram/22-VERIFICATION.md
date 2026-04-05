---
phase: 22-reranker-wizard-docker-vram
verified: 2026-03-23T09:37:46Z
status: passed
score: 8/8 must-haves verified
re_verification: false
---

# Phase 22: Reranker Wizard + Docker + VRAM Verification Report

**Phase Goal:** Пользователь опционально включает reranker в визарде, выбирает модель, TEI-rerank контейнер поднимается в отдельном profile, VRAM реранкера учитывается в бюджете.
**Verified:** 2026-03-23T09:37:46Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Wizard shows reranker step with yes/no question followed by model menu | VERIFIED | `_wizard_reranker_model()` at wizard.sh:652 — `_ask "Включить реранкер? [y/N]:"` + 3-model menu |
| 2 | Default is 'no' (ENABLE_RERANKER=false) in both interactive and NON_INTERACTIVE | VERIFIED | `_init_wizard_defaults` line 35: `ENABLE_RERANKER="${ENABLE_RERANKER:-false}"`, NON_INTERACTIVE path at 655: only activates on `== "true"` |
| 3 | VRAM guard subtracts RERANKER_VRAM_OFFSET when ENABLE_RERANKER=true | VERIFIED | 3 locations updated: interactive effective_vram (393-395), interactive check+warn (481-488), NON_INTERACTIVE check+error (547-553) |
| 4 | Wizard summary shows reranker line when enabled | VERIFIED | wizard.sh:971: `[[ "${ENABLE_RERANKER:-}" == "true" ]] && echo "  Реранкер:     ${RERANK_MODEL} (~1 GB)"` |
| 5 | tei-rerank service exists in docker-compose.yml in profile reranker | VERIFIED | docker-compose.yml:373-395 — `container_name: agmind-tei-rerank`, `profiles: [reranker]`, `agmind_tei_rerank_cache` volume |
| 6 | build_compose_profiles includes reranker profile when ENABLE_RERANKER=true | VERIFIED | compose.sh:37: `[[ "${ENABLE_RERANKER:-false}" == "true" ]] && profiles="${profiles:+$profiles,}reranker"` |
| 7 | config.sh substitutes ENABLE_RERANKER and RERANK_MODEL placeholders | VERIFIED | config.sh:236-237 (safe_ vars), 279-280 (sed substitutions) |
| 8 | All 4 env templates contain ENABLE_RERANKER and RERANK_MODEL placeholders | VERIFIED | env.lan.template:83-84, env.vps.template:83-84, env.vpn.template:83-84, env.offline.template:84-85 |

**Score:** 8/8 truths verified

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/wizard.sh` | `_wizard_reranker_model` function, `RERANKER_VRAM_OFFSET` constant, updated VRAM guard, updated summary | VERIFIED | Syntax OK; function at line 652; readonly constant at line 353; 3x VRAM guard locations updated; summary line at 971 |
| `templates/docker-compose.yml` | tei-rerank service definition | VERIFIED | Service at line 373; profile `reranker`; volume `agmind_tei_rerank_cache` at line 386 (mount) and 1051 (declaration) |
| `lib/compose.sh` | reranker profile in build_compose_profiles | VERIFIED | Line 37 adds `reranker`; also present in compose_down (204) and _cleanup_stale_containers (220) profiles |
| `lib/config.sh` | sed substitutions for ENABLE_RERANKER and RERANK_MODEL | VERIFIED | Lines 236-237 (safe_ declarations), 279-280 (sed blocks); syntax OK |
| `templates/env.lan.template` | ENABLE_RERANKER and RERANK_MODEL placeholders | VERIFIED | Lines 83-84 |
| `templates/env.vps.template` | ENABLE_RERANKER and RERANK_MODEL placeholders | VERIFIED | Lines 83-84 |
| `templates/env.vpn.template` | ENABLE_RERANKER and RERANK_MODEL placeholders | VERIFIED | Lines 83-84 |
| `templates/env.offline.template` | ENABLE_RERANKER and RERANK_MODEL placeholders | VERIFIED | Lines 84-85 |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/wizard.sh::_wizard_reranker_model` | `lib/wizard.sh::run_wizard` | function call after `_wizard_embedding_model` | WIRED | wizard.sh:1011-1013 — `_wizard_embedding_model`, `_wizard_reranker_model`, `_wizard_hf_token` in order |
| `lib/wizard.sh::RERANKER_VRAM_OFFSET` | `lib/wizard.sh::_wizard_vllm_model` VRAM guards | effective_vram calculation in 3 locations | WIRED | Lines 393-395, 481-488, 547-553 all subtract `reranker_offset`/`reranker_off`/`ni_reranker_off` |
| `lib/compose.sh::build_compose_profiles` | `templates/docker-compose.yml::tei-rerank` | reranker profile activation | WIRED | compose.sh:37 adds `reranker` profile; docker-compose.yml:380 `- reranker` in tei-rerank profiles |
| `lib/config.sh` | `templates/env.*.template` | sed `__ENABLE_RERANKER__` and `__RERANK_MODEL__` substitution | WIRED | config.sh:279-280 sed patterns match placeholder names in all 4 templates |
| `run_wizard` exports | downstream env consumers | `export ENABLE_RERANKER RERANK_MODEL` | WIRED | wizard.sh:1027 |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| RNKR-01 | 22-01-PLAN.md | Новый шаг визарда `_wizard_reranker_model()` с выбором реранкера | SATISFIED | `_wizard_reranker_model()` at wizard.sh:652; 3-model menu + custom input + NON_INTERACTIVE handling |
| RNKR-02 | 22-02-PLAN.md | При ENABLE_RERANKER=true поднимается отдельный TEI-rerank контейнер (profile `reranker`) | SATISFIED | docker-compose.yml:373 tei-rerank service; compose.sh:37 profile wiring; all env templates have placeholder |
| RNKR-03 | 22-01-PLAN.md | VRAM реранкера учитывается в VRAM бюджете и сводке | SATISFIED | `RERANKER_VRAM_OFFSET=1` at wizard.sh:353; subtracted in 3 VRAM guard locations; summary line at 971 |

No orphaned requirements — all 3 IDs claimed by plans, all verified in codebase.

---

## Anti-Patterns Found

No anti-patterns found in phase-modified files. Spot checks on key files:

- `lib/wizard.sh` — no TODO/FIXME/placeholder comments in new code; `_wizard_reranker_model` is a complete implementation
- `templates/docker-compose.yml` — tei-rerank block is fully defined (image, profiles, healthcheck, volumes, GPU stubs consistent with sibling services)
- `lib/compose.sh` — no empty implementations; reranker added to all 3 relevant profile locations (build, down, cleanup)

---

## Human Verification Required

### 1. Interactive wizard flow end-to-end

**Test:** Run `sudo bash install.sh` interactively, reach the reranker step, select "y", choose a model, complete install
**Expected:** ENABLE_RERANKER=true and selected RERANK_MODEL written to .env; tei-rerank container starts in docker compose up
**Why human:** Interactive terminal flow with `_ask` prompts cannot be verified programmatically

### 2. VRAM guard warning message with reranker enabled

**Test:** Set ENABLE_RERANKER=true in env, run wizard with a GPU that has insufficient VRAM for chosen model
**Expected:** Warning message shows `"X GB - N GB TEI + 1 GB reranker"` breakdown
**Why human:** Requires a GPU environment and specific VRAM value to trigger the warning branch

### 3. tei-rerank container GPU activation

**Test:** Deploy with ENABLE_RERANKER=true on a GPU server; run `docker compose up` with COMPOSE_PROFILES including reranker
**Expected:** agmind-tei-rerank container starts, pulls RERANK_MODEL, responds to `/health` on port 80
**Why human:** Requires live Docker + GPU environment; real model download cannot be simulated

---

## Commits Verified

All 4 commits documented in SUMMARY files confirmed to exist in git history:

| Commit | Description |
|--------|-------------|
| `49197f7` | feat(22-01): add _wizard_reranker_model() function and RERANKER_VRAM_OFFSET constant |
| `df23944` | feat(22-01): wire reranker into run_wizard, VRAM guards, and summary |
| `b9dc63d` | feat(22-02): add tei-rerank service and reranker compose profile |
| `56ebcc6` | feat(22-02): add ENABLE_RERANKER/RERANK_MODEL to config.sh and env templates |

---

## Summary

Phase 22 goal fully achieved. All 3 requirements (RNKR-01, RNKR-02, RNKR-03) are satisfied by concrete, non-stub implementations:

- **RNKR-01:** `_wizard_reranker_model()` is a complete wizard step with yes/no gate, 3-model menu, custom input, and NON_INTERACTIVE handling. Wired into `run_wizard()` in correct position and exports are in place.
- **RNKR-02:** `tei-rerank` service is fully defined in docker-compose.yml under the `reranker` profile. `build_compose_profiles()` activates it on `ENABLE_RERANKER=true`. Config substitution pipeline (config.sh sed + env templates) is complete for all 4 deployment profiles.
- **RNKR-03:** `RERANKER_VRAM_OFFSET=1` is a readonly constant used in all 3 VRAM guard locations (interactive effective_vram, interactive check+warn, NON_INTERACTIVE guard). Wizard summary also shows the reranker line when enabled.

Three human verification items remain for runtime/GPU behavior that cannot be verified programmatically.

---

_Verified: 2026-03-23T09:37:46Z_
_Verifier: Claude (gsd-verifier)_
