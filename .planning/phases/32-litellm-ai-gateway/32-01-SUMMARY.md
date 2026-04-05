---
phase: 32-litellm-ai-gateway
plan: "01"
subsystem: ai-gateway
tags: [litellm, docker-compose, config-generation, secrets, openai-proxy]
dependency_graph:
  requires: [templates/docker-compose.yml, templates/versions.env, lib/config.sh, lib/common.sh]
  provides: [agmind-litellm service, litellm-config.yaml generator, LITELLM_MASTER_KEY secret]
  affects: [Open WebUI OPENAI_API_BASE_URL, db service init scripts, preflight bind mount check]
tech_stack:
  added: [LiteLLM v1.82.3-stable.patch.2 (ghcr.io/berriai/litellm)]
  patterns: [OpenAI-compatible proxy, PostgreSQL reuse for state, sk- prefix for API keys]
key_files:
  created:
    - templates/init-litellm-db.sql
  modified:
    - templates/docker-compose.yml
    - templates/versions.env
    - templates/env.lan.template
    - templates/env.vps.template
    - lib/config.sh
    - lib/common.sh
decisions:
  - "LiteLLM is a core service (no profiles tag) — always starts alongside Dify, Open WebUI, PostgreSQL"
  - "LITELLM_MASTER_KEY uses sk- prefix convention required by LiteLLM key validation"
  - "Open WebUI retains OLLAMA_BASE_URL for model management (pull/list/delete) when provider=ollama"
  - "litellm-config.yaml uses os.environ/ resolution — secrets never hardcoded in config file"
  - "_restore_secrets_from_backup() intentionally excludes LITELLM_MASTER_KEY (LiteLLM recreates tables on new key)"
metrics:
  duration: ~15min
  completed: "2026-03-30"
  tasks_completed: 2
  tasks_total: 2
  files_changed: 7
---

# Phase 32 Plan 01: LiteLLM AI Gateway — Core Service Integration Summary

**One-liner:** LiteLLM v1.82.3 added as always-on OpenAI-compatible proxy with PostgreSQL reuse, sk-prefixed secret generation, and per-provider litellm-config.yaml generation from wizard choices.

## What Was Built

LiteLLM AI Gateway integrated as a core Docker Compose service. All LLM traffic from Open WebUI now routes through `agmind-litellm:4000/v1` regardless of the underlying provider (Ollama, vLLM, external). The installer generates `litellm-config.yaml` automatically based on wizard LLM_PROVIDER/LLM_MODEL selections.

## Tasks Completed

| Task | Name | Commit | Files |
| --- | --- | --- | --- |
| 1 | Add LiteLLM to docker-compose, versions.env, init SQL, env templates | 94de8ce | docker-compose.yml, versions.env, init-litellm-db.sql, env templates |
| 2 | Generate litellm-config.yaml and LITELLM_MASTER_KEY in config.sh + rewire vars | bf0b04c | lib/config.sh, lib/common.sh |

## Key Changes

### templates/docker-compose.yml

- Added `agmind-litellm` service (no `profiles:` tag — core service)
- Image: `ghcr.io/berriai/litellm:${LITELLM_VERSION:-v1.82.3-stable.patch.2}`
- Healthcheck: `curl -sf --max-time 5 http://localhost:4000/health`
- Depends on: `db: condition: service_healthy`
- Bind mount: `./litellm-config.yaml:/app/config.yaml:ro`
- Added `init-litellm-db.sql` mount to db service as `02-create-litellm-db.sql`

### templates/versions.env

- Added `LITELLM_VERSION=v1.82.3-stable.patch.2` in new `# --- AI Gateway ---` section

### templates/init-litellm-db.sql (new file)

- Idempotent `CREATE DATABASE litellm` using `\gexec` pattern (same as dify_plugin)

### templates/env.lan.template + env.vps.template

- Added `# --- LiteLLM (AI Gateway) ---` section with `LITELLM_MASTER_KEY=__LITELLM_MASTER_KEY__`

### lib/config.sh

- `_LITELLM_MASTER_KEY=""` module-level variable declared
- `_generate_secrets()`: `_LITELLM_MASTER_KEY="sk-$(generate_random 32)"`
- `_generate_env_file()`: sed substitution for `__LITELLM_MASTER_KEY__`
- `_generate_litellm_config()`: new function generating `litellm-config.yaml` per provider
- `generate_config()`: `_generate_litellm_config` called after `_generate_squid_config`
- `_append_provider_vars()`: all providers now set `OPENAI_API_BASE_URL=http://agmind-litellm:4000/v1`; ollama keeps `OLLAMA_BASE_URL` for model management

### lib/common.sh

- `preflight_bind_mount_check()`: `"litellm-config.yaml"` added to `all_bind_files` array

## Deviations from Plan

None — plan executed exactly as written.

## Decisions Made

1. **LITELLM_MASTER_KEY excluded from `_restore_secrets_from_backup()`** — LiteLLM stores session state in PostgreSQL but doesn't bind auth tokens to volume data. New key = new sessions, users re-authenticate. This is acceptable; the plan explicitly noted this.

2. **`sk-` prefix mandatory** — LiteLLM validates that master keys start with `sk-`. Without it, the proxy rejects all API calls with 401.

3. **All three providers route through LiteLLM** — ollama, vllm, and external all get `OPENAI_API_BASE_URL=http://agmind-litellm:4000/v1`. This enables unified cost tracking, fallback, and centralized key management regardless of provider.

## Self-Check: PASSED

All 7 modified/created files exist. Both task commits (94de8ce, bf0b04c) verified in git log.
