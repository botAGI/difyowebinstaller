---
phase: 03-provider-architecture
plan: 01
subsystem: infra
tags: [docker-compose, profiles, vllm, tei, ollama, open-webui, provider-architecture]

# Dependency graph
requires:
  - phase: 02-security-hardening-v2
    provides: hardened docker-compose.yml with security-defaults and logging-defaults anchors used by new services
provides:
  - vLLM service definition (profiles: vllm, ipc: host, GPU block, start_period 900s)
  - TEI service definition (profiles: tei, BAAI/bge-m3 hardcoded, GPU block, start_period 600s)
  - Ollama behind profiles: [ollama] (no longer always-on)
  - Open WebUI provider-agnostic (OLLAMA_BASE_URL, ENABLE_OLLAMA_API, ENABLE_OPENAI_API as variables)
  - Named volumes vllm_cache and tei_cache
  - VLLM_VERSION=v0.8.4, TEI_VERSION=cuda-1.9.2 in versions.env
  - LLM_PROVIDER, EMBED_PROVIDER, VLLM_MODEL, HF_TOKEN placeholders in all 4 env templates
affects:
  - 03-02 (install.sh wizard needs profiles and env vars established here)
  - 03-03 (config.sh generates LLM_PROVIDER/EMBED_PROVIDER/VLLM_MODEL/HF_TOKEN from this structure)

# Tech tracking
tech-stack:
  added:
    - vllm/vllm-openai:v0.8.4 (GPU-accelerated LLM inference with OpenAI-compatible API)
    - ghcr.io/huggingface/text-embeddings-inference:cuda-1.9.2 (production embedding server)
  patterns:
    - Docker Compose profiles: [provider] pattern for conditional service activation (same as qdrant/weaviate/etl)
    - "#__GPU__ comment-toggle pattern extended to vLLM and TEI services"
    - Variable substitution for provider-dependent env vars in Open WebUI (${OLLAMA_BASE_URL:-})

key-files:
  created: []
  modified:
    - templates/docker-compose.yml
    - templates/versions.env
    - templates/env.lan.template
    - templates/env.vpn.template
    - templates/env.vps.template
    - templates/env.offline.template

key-decisions:
  - "Open WebUI ENABLE_OLLAMA_API defaults to false in compose (not true) — config.sh sets true only for Ollama provider. Prevents connection error logs when Ollama profile not active."
  - "ENABLE_OPENAI_API defaults to false in compose — config.sh sets true only for vLLM/External. Matches same pattern."
  - "vLLM ipc: host required for PyTorch tensor parallel — without it inference fails silently on multi-GPU."
  - "start_period: 900s for vLLM — 14B model download on 1Gbps can take 8-20 min; Docker must not mark unhealthy during this window."
  - "TEI model hardcoded as BAAI/bge-m3 — no user question asked, per locked decisions in CONTEXT.md."

patterns-established:
  - "Provider profile pattern: services behind profiles: [provider-name]; COMPOSE_PROFILES builder in phase_start() adds profile when provider selected"
  - "Env var default empty pattern: ${OLLAMA_BASE_URL:-} and ${OPENAI_API_BASE_URL:-} — empty by default, set by config.sh based on provider"
  - "GPU block pattern: #__GPU__deploy: prefix lines in vLLM/TEI same as existing Ollama/Xinference pattern"

requirements-completed: [PROV-03]

# Metrics
duration: 15min
completed: 2026-03-18
---

# Phase 3 Plan 01: Provider Architecture Compose Foundation Summary

**Docker Compose restructured for provider architecture: Ollama moved to profile, vLLM (v0.8.4) and TEI (cuda-1.9.2) services added with profiles and GPU blocks, Open WebUI decoupled from Ollama via variable substitution.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-18T00:00:00Z
- **Completed:** 2026-03-18T00:15:00Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- Ollama service now behind `profiles: [ollama]` — not started unless COMPOSE_PROFILES includes "ollama"
- vLLM service fully defined: `ipc: host`, `start_period: 900s` healthcheck, `#__GPU__` toggle block, named volume `vllm_cache`
- TEI service fully defined: BAAI/bge-m3 hardcoded, `start_period: 600s` healthcheck, `#__GPU__` toggle block, named volume `tei_cache`
- Open WebUI decoupled: removed `depends_on: ollama`, all provider URLs via variable substitution
- All 4 env templates (lan/vpn/vps/offline) carry `LLM_PROVIDER`, `EMBED_PROVIDER`, `VLLM_MODEL`, `HF_TOKEN` placeholders
- `versions.env` has pinned `VLLM_VERSION=v0.8.4` and `TEI_VERSION=cuda-1.9.2`

## Task Commits

Each task was committed atomically:

1. **Task 1: Restructure docker-compose.yml** - `c10966c` (feat)
2. **Task 2: Add version pins and env template placeholders** - `aee2a66` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `templates/docker-compose.yml` - Ollama to profile, vLLM + TEI services added, Open WebUI env vars updated, volumes added
- `templates/versions.env` - VLLM_VERSION and TEI_VERSION added
- `templates/env.lan.template` - Provider Architecture section + Open WebUI provider vars added
- `templates/env.vpn.template` - Provider Architecture section + Open WebUI provider vars added
- `templates/env.vps.template` - Provider Architecture section + Open WebUI provider vars added
- `templates/env.offline.template` - Provider Architecture section + Open WebUI provider vars added

## Decisions Made
- `ENABLE_OLLAMA_API` defaults to `false` in docker-compose.yml (was `true`). Rationale: prevents Open WebUI from polling `ollama:11434` when Ollama is not in COMPOSE_PROFILES, which floods logs with connection errors. config.sh will set `true` when `LLM_PROVIDER=ollama`.
- `ENABLE_OPENAI_API` added as variable `${ENABLE_OPENAI_API:-false}` (was hardcoded `false`). Rationale: config.sh needs to set `true` for vLLM/External providers.
- `OPENAI_API_BASE_URL=${OPENAI_API_BASE_URL:-}` added as new env var in Open WebUI. Rationale: vLLM provider needs `http://vllm:8000/v1` set here; empty default is safe.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- Compose profiles foundation is in place: `ollama`, `vllm`, `tei` profiles declared and tested
- Plan 02 (install.sh wizard) can now reference these profiles in COMPOSE_PROFILES builder
- Plan 03 (config.sh) can generate `LLM_PROVIDER`, `EMBED_PROVIDER`, `VLLM_MODEL`, `HF_TOKEN` into `.env`
- No blockers for Plans 02 and 03

## Self-Check: PASSED

- FOUND: templates/docker-compose.yml (agmind-vllm, agmind-tei, ipc: host, profiles, volumes)
- FOUND: templates/versions.env (VLLM_VERSION=v0.8.4, TEI_VERSION=cuda-1.9.2)
- FOUND: .planning/phases/03-provider-architecture/03-01-SUMMARY.md
- FOUND commit: c10966c (Task 1)
- FOUND commit: aee2a66 (Task 2)

---
*Phase: 03-provider-architecture*
*Completed: 2026-03-18*
