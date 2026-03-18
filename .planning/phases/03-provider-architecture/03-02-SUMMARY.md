---
phase: 03-provider-architecture
plan: 02
subsystem: infra
tags: [bash, wizard, ollama, vllm, tei, compose-profiles, bats, provider-dispatch]

# Dependency graph
requires:
  - phase: 03-01
    provides: docker-compose.yml with ollama/vllm/tei services and profiles
provides:
  - Provider selection wizard in install.sh (LLM and embedding)
  - GPU-aware default provider (NVIDIA -> vLLM, else -> Ollama)
  - vLLM model list (7B-70B HuggingFace repos)
  - HF_TOKEN prompt for vLLM/TEI providers
  - Provider-aware COMPOSE_PROFILES builder
  - lib/config.sh provider env vars generation (__LLM_PROVIDER__, __EMBED_PROVIDER__, __VLLM_MODEL__, __HF_TOKEN__)
  - Open WebUI provider-specific env vars appended to .env (OLLAMA_BASE_URL, ENABLE_OPENAI_API)
  - lib/models.sh provider-aware download dispatcher (need_ollama logic)
  - BATS tests for wizard (31 tests) and COMPOSE_PROFILES (24 tests)
affects: [03-03, 04-installer-redesign, templates-env-templates, NON_INTERACTIVE-mode]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Provider-first wizard: LLM provider selection precedes model selection"
    - "GPU-aware defaults: DETECTED_GPU=nvidia -> vLLM default, else Ollama"
    - "Same-as-LLM mapping: embedding provider defaults to match LLM provider"
    - "need_ollama flag: unified condition for Ollama model pull gate"
    - "COMPOSE_PROFILES dynamic builder extended with ollama/vllm/tei conditions"

key-files:
  created:
    - tests/test_wizard_provider.bats
    - tests/test_compose_profiles.bats
  modified:
    - install.sh
    - lib/config.sh
    - lib/models.sh

key-decisions:
  - "LLM provider question precedes model selection; Ollama model list shown only when LLM_PROVIDER=ollama"
  - "vLLM model list uses HuggingFace org/repo format (not Ollama tags)"
  - "HF_TOKEN prompt gated on (LLM_PROVIDER=vllm OR EMBED_PROVIDER=tei)"
  - "Embedding model prompt gated on EMBED_PROVIDER=ollama"
  - "need_ollama=true if either LLM or embed uses ollama — single wait_for_ollama call"
  - "vLLM/TEI do not require model pull — models download at container start"
  - "config.sh appends provider WebUI vars after template sed (not in template to avoid profile conflicts)"

patterns-established:
  - "Provider dispatch pattern: local need_<provider>=false; set to true per-condition; single action block"
  - "NON_INTERACTIVE provider mapping: case statement on env var string -> numeric choice"

requirements-completed: [PROV-01, PROV-02, PROV-03]

# Metrics
duration: 4min
completed: 2026-03-18
---

# Phase 3 Plan 02: Provider Architecture Wizard Summary

**LLM/embedding provider wizard with GPU-aware defaults, vLLM model list, HF_TOKEN gating, provider-aware COMPOSE_PROFILES builder and download dispatcher, plus 55 BATS tests**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-18T01:18:35Z
- **Completed:** 2026-03-18T01:22:31Z
- **Tasks:** 2
- **Files modified:** 5 (install.sh, lib/config.sh, lib/models.sh, tests/test_wizard_provider.bats, tests/test_compose_profiles.bats)

## Accomplishments

- Wizard guides users through LLM provider (Ollama/vLLM/External/Skip) with NVIDIA-aware defaults before model selection
- vLLM model list (7B-70B) with Qwen2.5-14B-Instruct default; HF_TOKEN prompt appears only for vLLM/TEI providers
- COMPOSE_PROFILES builder adds `ollama`, `vllm`, `tei` conditionally; nuclear cleanup includes all three
- lib/config.sh replaces four new placeholders and appends provider-specific Open WebUI env vars (OLLAMA_BASE_URL, ENABLE_OPENAI_API, OPENAI_API_BASE_URL)
- lib/models.sh download_models() dispatches by provider via `need_ollama` flag, skips for vLLM/TEI/external
- 55 BATS grep-based tests validate all patterns without Docker dependency

## Task Commits

Each task was committed atomically:

1. **Task 1: Provider selection wizard, config.sh, models.sh** - `2936b75` (feat)
2. **Task 2: BATS tests for wizard and COMPOSE_PROFILES** - `902b7ee` (test)

## Files Created/Modified

- `install.sh` - Added LLM provider block, vLLM model list, embedding provider block, HF_TOKEN prompt, offline warning update, COMPOSE_PROFILES builder extension, nuclear cleanup update, phase_models export extension
- `lib/config.sh` - Added 4 provider sed replacements, appended provider-specific WebUI env vars block
- `lib/models.sh` - Rewrote download_models() with need_ollama dispatch, vLLM/TEI/external skip paths
- `tests/test_wizard_provider.bats` - 31 tests: syntax checks, LLM provider menu, GPU fallback, NON_INTERACTIVE, HF_TOKEN, vLLM model list, models.sh dispatch, config.sh replacements
- `tests/test_compose_profiles.bats` - 24 tests: COMPOSE_PROFILES builder, nuclear cleanup, docker-compose structure, versions.env, env templates, phase_models exports

## Decisions Made

- LLM provider question placed BEFORE model selection so model list can be provider-specific (Ollama list vs vLLM HuggingFace list)
- HF_TOKEN gated on `LLM_PROVIDER=vllm OR EMBED_PROVIDER=tei` — minimal prompt surface
- `need_ollama` unified flag eliminates duplicate `wait_for_ollama` calls
- Provider WebUI vars appended after sed template to avoid template duplication across profiles

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## Next Phase Readiness

- Provider wizard and COMPOSE_PROFILES are wired; Plan 03 (env templates and versions.env) will add `__LLM_PROVIDER__` placeholders to template files
- BATS tests reference templates/docker-compose.yml patterns — those tests will pass after Plan 01 artifacts are verified
- NON_INTERACTIVE mode respects `LLM_PROVIDER` and `EMBED_PROVIDER` env vars for automated installs

---
*Phase: 03-provider-architecture*
*Completed: 2026-03-18*
