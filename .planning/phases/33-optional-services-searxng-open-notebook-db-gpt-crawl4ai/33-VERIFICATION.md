---
phase: 33-optional-services-searxng-open-notebook-db-gpt-crawl4ai
verified: 2026-03-30T06:15:00Z
status: passed
score: 6/6 must-haves verified
---

# Phase 33: Optional Services Verification Report

**Phase Goal:** Четыре опциональных сервиса через wizard `y/N` + compose profiles. Каждый: docker-compose service, versions.env, wizard step, credentials.txt, agmind doctor.
**Verified:** 2026-03-30T06:15:00Z
**Status:** passed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | SearXNG: wizard y/N, profile=searxng, agmind-searxng port 8888, JSON API, 4 engines, ~256 MB | VERIFIED | wizard.sh:945 `_wizard_searxng()`, docker-compose.yml:998-1019 with profile `searxng`, port 8888:8080, mem_limit 256m; searxng-settings.yml has `formats: [html, json]` and 4 engines (google, bing, duckduckgo, wikipedia) |
| 2 | Open Notebook: wizard y/N, profile=notebook, agmind-notebook uses SurrealDB + LiteLLM, ~512 MB | VERIFIED | wizard.sh:958 `_wizard_notebook()`, docker-compose.yml:1042-1068 with profile `notebook`, mem_limit 512m, `SURREAL_URL=ws://surrealdb:8000/rpc`, depends_on surrealdb service_healthy |
| 3 | DB-GPT: wizard y/N, profile=dbgpt, agmind-dbgpt through LiteLLM, ~1 GB | VERIFIED | wizard.sh:971 `_wizard_dbgpt()`, docker-compose.yml:1070-1095 with profile `dbgpt`, mem_limit 1g, `OPENAI_API_BASE=http://litellm:4000/v1`, depends_on litellm service_healthy |
| 4 | Crawl4AI: wizard y/N, profile=crawl4ai, agmind-crawl4ai REST API, ~2 GB (Chromium) | VERIFIED | wizard.sh:984 `_wizard_crawl4ai()`, docker-compose.yml:1097-1114 with profile `crawl4ai`, mem_limit 2g, shm_size 1g, healthcheck on :11235/health |
| 5 | All 4 services: N leaves no trace in compose ps; y adds port in credentials.txt, agmind doctor checks health | VERIFIED | compose.sh:38-41 conditionally adds profiles; health.sh:64-72 adds services to doctor list; install.sh:427-449 credentials blocks with ENABLE_* guards |
| 6 | SearXNG JSON API responds at localhost:8888/search?q=test&format=json | VERIFIED (config) | searxng-settings.yml:13-15 has `formats: [html, json]`; docker-compose.yml:1007 maps 8888:8080. Runtime test needs human. |

**Score:** 6/6 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `templates/docker-compose.yml` | 5 service definitions (searxng, surrealdb, open-notebook, dbgpt, crawl4ai) | VERIFIED | Lines 997-1114: all 5 services with profiles, healthchecks, mem_limits, named volumes |
| `templates/versions.env` | Version pins for 5 new images | VERIFIED | Lines 34-38: SEARXNG_VERSION, SURREALDB_VERSION, OPEN_NOTEBOOK_VERSION, DBGPT_VERSION, CRAWL4AI_VERSION |
| `templates/searxng-settings.yml` | SearXNG config with JSON API | VERIFIED | 40 lines, `formats: [html, json]`, `__SEARXNG_SECRET_KEY__` placeholder, 4 search engines |
| `lib/wizard.sh` | 4 wizard steps with NON_INTERACTIVE support | VERIFIED | Functions at lines 945-995, run_wizard calls at 1102-1105, exports at 1122, summary at 1012-1015 |
| `lib/compose.sh` | Profile building for 4 services | VERIFIED | Lines 38-41 conditional profile appends; stop/cleanup at 429,445 include all 4 profiles |
| `lib/health.sh` | Health detection for 4 services | VERIFIED | Lines 64-72 grep ENABLE_* from .env, add services including surrealdb+open-notebook for notebook |
| `lib/config.sh` | Secret generation + sed substitution + searxng config generation | VERIFIED | Declarations at 118-120, generation at 183-185, sed at 309-315, `_generate_searxng_config()` at 668 |
| `install.sh` | Credentials blocks for 4 services | VERIFIED | Lines 427-449 conditional blocks with URLs for SearXNG, Open Notebook, DB-GPT, Crawl4AI |
| `templates/env.lan.template` | ENABLE_* and secret placeholders | VERIFIED | Lines 94-100: 4 ENABLE_ vars + 3 secret placeholders |
| `templates/env.vps.template` | ENABLE_* and secret placeholders | VERIFIED | Lines 94-100: identical to lan template |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| wizard.sh | compose.sh | ENABLE_SEARXNG/NOTEBOOK/DBGPT/CRAWL4AI env vars | WIRED | wizard exports at line 1122; compose.sh reads at lines 38-41 |
| compose.sh | docker-compose.yml | profile string (searxng, notebook, dbgpt, crawl4ai) | WIRED | compose.sh appends profiles; docker-compose.yml services have matching `profiles:` blocks |
| health.sh | docker .env | grep ENABLE_* from env_file | WIRED | health.sh:65-68 reads ENABLE_ vars; env templates provide them at lines 94-97 |
| docker-compose.yml (open-notebook) | docker-compose.yml (surrealdb) | depends_on | WIRED | Line 1058-1060: `depends_on: surrealdb: condition: service_healthy` |
| docker-compose.yml (dbgpt) | litellm | depends_on + OPENAI_API_BASE | WIRED | Line 1081: `OPENAI_API_BASE=http://litellm:4000/v1`; line 1085-1087: depends_on litellm |
| docker-compose.yml (searxng) | versions.env | image version variable | WIRED | `${SEARXNG_VERSION:-2024.12.23-42c82f418}` matches versions.env line 34 |
| config.sh | searxng-settings.yml | _generate_searxng_config() | WIRED | Line 47 calls function; line 668-679 processes template, replaces secret key |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| OSVC-01 | 33-01, 33-02 | Open Notebook -- wizard y/N, profile=notebook, SurrealDB + LiteLLM, ~512 MB | SATISFIED | docker-compose service, wizard step, health, credentials all present |
| OSVC-02 | 33-01, 33-02 | DB-GPT -- wizard y/N, profile=dbgpt, through LiteLLM, ~1 GB | SATISFIED | docker-compose service, wizard step, health, credentials all present |
| OSVC-03 | 33-01, 33-02 | Crawl4AI -- wizard y/N, profile=crawl4ai, REST API, ~2 GB | SATISFIED | docker-compose service, wizard step, health, credentials all present |
| OSVC-04 | 33-01, 33-02 | SearXNG -- wizard y/N, profile=searxng, port 8888, JSON API, ~256 MB | SATISFIED | docker-compose service, wizard step, health, credentials, searxng-settings.yml all present |

No orphaned requirements found.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| None | - | - | - | No anti-patterns detected in phase 33 files |

### Human Verification Required

### 1. SearXNG JSON API Response

**Test:** Enable SearXNG (`ENABLE_SEARXNG=true`), run install, then `curl http://localhost:8888/search?q=test&format=json`
**Expected:** JSON response with search results
**Why human:** Requires running containers with network access to search engines

### 2. Wizard Interactive Flow

**Test:** Run `bash install.sh` and go through wizard, answer y/N for each of the 4 optional services
**Expected:** Each prompt displays description and RAM estimate, y adds service, N skips it
**Why human:** Interactive terminal UI behavior

### 3. Doctor Health Checks

**Test:** Enable all 4 services, run `agmind doctor`, verify each service shows in health output
**Expected:** searxng, surrealdb, open-notebook, dbgpt, crawl4ai all checked
**Why human:** Requires running containers with health endpoints

### Gaps Summary

No gaps found. All 6 observable truths verified against the actual codebase. All 10 artifacts exist, are substantive (not stubs), and are properly wired together. All 4 requirement IDs (OSVC-01 through OSVC-04) are satisfied with complete implementation evidence.

The implementation covers the full vertical slice for each service: docker-compose definition with profiles/healthchecks/mem_limits, version pins, wizard y/N with NON_INTERACTIVE support, compose profile building, health detection, secret generation, env template placeholders, and credentials output.

---

_Verified: 2026-03-30T06:15:00Z_
_Verifier: Claude (gsd-verifier)_
