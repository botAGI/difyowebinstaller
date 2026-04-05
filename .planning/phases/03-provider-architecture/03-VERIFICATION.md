---
phase: 03-provider-architecture
verified: 2026-03-18T02:10:00Z
status: passed
score: 19/19 must-haves verified
re_verification: false
---

# Phase 3: Provider Architecture Verification Report

**Phase Goal:** User chooses LLM and embedding provider in wizard. Compose profiles start only what's needed.
**Verified:** 2026-03-18T02:10:00Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                     | Status     | Evidence                                                                                    |
|----|-------------------------------------------------------------------------------------------|------------|---------------------------------------------------------------------------------------------|
| 1  | Ollama behind `profiles: [ollama]`, not started unless COMPOSE_PROFILES includes ollama   | VERIFIED   | `templates/docker-compose.yml` line 252: `profiles: - ollama`                              |
| 2  | vLLM service exists with `profiles: [vllm]`, `ipc: host`, GPU block, `start_period: 900s`| VERIFIED   | lines 283-302: container `agmind-vllm`, `ipc: host` at 292, `start_period: 900s` at 298    |
| 3  | TEI service exists with `profiles: [tei]`, BAAI/bge-m3 hardcoded, `start_period: 600s`   | VERIFIED   | lines 313-332: container `agmind-tei`, `--model-id BAAI/bge-m3`, `start_period: 600s`      |
| 4  | Open WebUI has no `depends_on: ollama`                                                    | VERIFIED   | open-webui block (lines 219-244) contains zero `depends_on` references to ollama           |
| 5  | Open WebUI uses variable substitution for provider env vars                               | VERIFIED   | lines 231-234: `${OLLAMA_BASE_URL:-}`, `${ENABLE_OLLAMA_API:-false}`, `${OPENAI_API_BASE_URL:-}` |
| 6  | Named volumes `vllm_cache` and `tei_cache` declared                                       | VERIFIED   | `templates/docker-compose.yml` lines 967-968                                               |
| 7  | `versions.env` has `VLLM_VERSION=v0.8.4` and `TEI_VERSION=cuda-1.9.2`                    | VERIFIED   | lines 31-32 of `templates/versions.env`                                                    |
| 8  | All four env templates contain LLM_PROVIDER, EMBED_PROVIDER, VLLM_MODEL, HF_TOKEN        | VERIFIED   | confirmed in lan/vpn/vps/offline templates — 4 matches each                                |
| 9  | Wizard asks LLM provider (1-4) with GPU-aware default before model selection              | VERIFIED   | `install.sh` lines 304-337: `DETECTED_GPU` check, `Выберите LLM провайдер:` prompt         |
| 10 | Wizard asks embedding provider (1-4) with "Same as LLM" mapping correctly                | VERIFIED   | `install.sh` lines 454-485: `Выберите Embedding провайдер:`, LLM-to-embed case dispatch    |
| 11 | HF_TOKEN prompt appears only when vLLM or TEI is selected                                 | VERIFIED   | `install.sh` lines 498-505: gated on `LLM_PROVIDER == vllm || EMBED_PROVIDER == tei`       |
| 12 | NON_INTERACTIVE mode respects LLM_PROVIDER and EMBED_PROVIDER env vars                   | VERIFIED   | `install.sh` lines 322-328 and 462-470: case dispatch on env var string                    |
| 13 | COMPOSE_PROFILES builder adds ollama/vllm/tei conditionally                               | VERIFIED   | `install.sh` lines 911-914: three conditional profile additions                            |
| 14 | Nuclear cleanup includes `ollama,vllm,tei` in COMPOSE_PROFILES                           | VERIFIED   | `install.sh` line 920: `COMPOSE_PROFILES=vps,monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei` |
| 15 | config.sh generates LLM_PROVIDER, EMBED_PROVIDER, VLLM_MODEL, HF_TOKEN, provider WebUI vars | VERIFIED | `lib/config.sh` lines 271-275 (safe_ vars), 306-309 (sed), 324-340 (provider WebUI append) |
| 16 | models.sh dispatches by provider: Ollama pull only when needed, skip for vLLM/TEI/External | VERIFIED | `lib/models.sh` lines 128-163: `need_ollama` flag logic, skip messages for vLLM/TEI       |
| 17 | phase_complete() shows provider name in LLM and Embedding display                        | VERIFIED   | `install.sh` lines 1246-1259: `llm_display`/`embed_display` case dispatch; used at 1341-1342, 1405-1406 |
| 18 | Provider-specific plugin hint shown after install summary                                  | VERIFIED   | `install.sh` lines 1369-1390: 4-case plugin_hint block with vLLM endpoint URL             |
| 19 | workflows/README.md has per-provider plugin setup with endpoints                          | VERIFIED   | `workflows/README.md` lines 22-68: Ollama, vLLM, TEI, External API, ETL sections with URLs |

**Score:** 19/19 truths verified

---

### Required Artifacts

| Artifact                             | Expected                                                   | Status      | Details                                                              |
|--------------------------------------|------------------------------------------------------------|-------------|----------------------------------------------------------------------|
| `templates/docker-compose.yml`       | vLLM/TEI/Ollama with profiles; Open WebUI independent     | VERIFIED    | All three services with profiles; no `depends_on: ollama` in webui  |
| `templates/versions.env`             | Pinned VLLM_VERSION and TEI_VERSION                       | VERIFIED    | `VLLM_VERSION=v0.8.4`, `TEI_VERSION=cuda-1.9.2` at lines 31-32      |
| `templates/env.lan.template`         | LLM_PROVIDER, EMBED_PROVIDER, VLLM_MODEL, HF_TOKEN        | VERIFIED    | All four `__PLACEHOLDER__` values present                           |
| `templates/env.vpn.template`         | Same 4 provider placeholders                              | VERIFIED    | 4 matches confirmed                                                  |
| `templates/env.vps.template`         | Same 4 provider placeholders                              | VERIFIED    | 4 matches confirmed                                                  |
| `templates/env.offline.template`     | Same 4 provider placeholders                              | VERIFIED    | 4 matches confirmed                                                  |
| `install.sh`                         | Wizard provider questions, COMPOSE_PROFILES builder       | VERIFIED    | `bash -n` passes; LLM_PROVIDER, EMBED_PROVIDER, VLLM_MODEL all present |
| `lib/config.sh`                      | Provider env vars generated in .env                       | VERIFIED    | `bash -n` passes; all 4 placeholder sed replacements + provider WebUI append |
| `lib/models.sh`                      | Provider-aware download dispatcher                        | VERIFIED    | `bash -n` passes; `need_ollama` logic, vLLM/TEI skip paths          |
| `tests/test_wizard_provider.bats`    | BATS tests for wizard provider selection                  | VERIFIED    | 31 `@test` blocks; valid BATS syntax                                 |
| `tests/test_compose_profiles.bats`   | BATS tests for COMPOSE_PROFILES builder                   | VERIFIED    | 24 `@test` blocks; valid BATS syntax                                 |
| `workflows/README.md`                | Per-provider plugin installation docs                     | VERIFIED    | "Plugin Setup by Provider" section with all 4 providers + endpoints  |

---

### Key Link Verification

| From                                    | To                                 | Via                                          | Status  | Details                                                        |
|-----------------------------------------|------------------------------------|----------------------------------------------|---------|----------------------------------------------------------------|
| `templates/docker-compose.yml`          | `templates/versions.env`           | `${VLLM_VERSION}` and `${TEI_VERSION}` refs  | WIRED   | Both variable references confirmed in vllm/tei image tags      |
| `templates/docker-compose.yml`          | `.env`                             | `${HF_TOKEN:-}`, `${VLLM_MODEL:-}` etc.      | WIRED   | All 4 variables used in service definitions                    |
| `install.sh phase_wizard()`             | `install.sh phase_start() COMPOSE_PROFILES` | LLM_PROVIDER/EMBED_PROVIDER globals | WIRED   | Variables set in wizard (lines 304-485), consumed in COMPOSE_PROFILES builder (lines 911-914) |
| `lib/config.sh generate_config()`      | `templates/env.*.template`         | sed replacement of `__LLM_PROVIDER__` etc.   | WIRED   | Lines 306-309: all 4 placeholders replaced                     |
| `install.sh phase_models()`             | `lib/models.sh download_models()`  | `export LLM_PROVIDER EMBED_PROVIDER`         | WIRED   | Line 1212: explicit export of LLM_PROVIDER EMBED_PROVIDER      |

---

### Requirements Coverage

| Requirement | Source Plan | Description                                            | Status    | Evidence                                                                           |
|-------------|-------------|--------------------------------------------------------|-----------|------------------------------------------------------------------------------------|
| PROV-01     | 03-02-PLAN  | LLM provider wizard (Ollama/vLLM/External API/Skip)   | SATISFIED | `install.sh`: full 4-option wizard with GPU-aware default, NON_INTERACTIVE support |
| PROV-02     | 03-02-PLAN  | Embedding provider wizard (Ollama/TEI/External/Same)  | SATISFIED | `install.sh`: 4-option embed wizard with "Same as LLM" case dispatch               |
| PROV-03     | 03-01-PLAN, 03-02-PLAN | Compose profiles per provider choice (ollama, vllm, tei) | SATISFIED | docker-compose.yml has 3 profiles; COMPOSE_PROFILES builder adds them conditionally |
| PROV-04     | 03-03-PLAN  | Plugin documentation per provider (README with install commands) | SATISFIED | `workflows/README.md` has per-provider sections with exact endpoints and step-by-step config |

All 4 PROV-* requirements claimed by plans are satisfied. No orphaned requirements.

---

### Anti-Patterns Found

No blockers found.

| File             | Pattern Checked                    | Result  |
|------------------|------------------------------------|---------|
| `install.sh`     | Hardcoded `(Ollama)` in phase_complete | CLEAN — replaced by `$llm_display`/`$embed_display` |
| `install.sh`     | `bash -n` syntax                   | PASS    |
| `lib/config.sh`  | `bash -n` syntax                   | PASS    |
| `lib/models.sh`  | `bash -n` syntax                   | PASS    |
| All provider code | TODO/FIXME/PLACEHOLDER comments   | CLEAN — none found in provider-related code |
| `lib/models.sh`  | `return {}` / empty stubs          | CLEAN — full `need_ollama` dispatch logic implemented |

Note: `bash -n` on `.bats` files produces expected syntax errors because BATS uses `@test` which is not valid bash. This is normal — BATS test files require the `bats` runner. File structure and `@test` count (31 + 24) are correct.

---

### Human Verification Required

#### 1. Provider profile isolation at runtime

**Test:** Run `docker compose -f templates/docker-compose.yml --profile vllm up --dry-run` (or real up)
**Expected:** Only vLLM service planned — Ollama and TEI containers NOT included
**Why human:** Requires Docker compose environment. Profile isolation can only be fully confirmed by runtime behavior, not grep.

#### 2. GPU passthrough for vLLM/TEI

**Test:** Uncomment `#__GPU__` lines and run on a host with NVIDIA GPU
**Expected:** vLLM gets `nvidia` driver GPU access; TEI also gets GPU
**Why human:** Cannot verify GPU availability or driver behavior in static analysis.

#### 3. vLLM 14B model download during container start

**Test:** Start vLLM container with `HF_TOKEN` set and a valid model — observe `start_period: 900s` not triggering premature health failure
**Expected:** Container starts healthy after model download completes (up to 15 min)
**Why human:** Requires actual container execution and network access to HuggingFace.

#### 4. NON_INTERACTIVE install with LLM_PROVIDER=vllm

**Test:** `export LLM_PROVIDER=vllm EMBED_PROVIDER=tei NON_INTERACTIVE=true && bash install.sh`
**Expected:** Wizard skips interactive prompts, COMPOSE_PROFILES includes `vllm,tei`
**Why human:** Full end-to-end installer run requires a target host environment.

---

### Gaps Summary

No gaps. All 19 must-haves from Plans 01, 02, and 03 are verified in the actual codebase:

- Phase 3 commit history is intact (6 commits: c10966c, aee2a66, 2936b75, 902b7ee, 0a0d1ef, 0d2a690)
- All artifacts exist and are substantive (not stubs)
- All key links are wired (wizard -> profiles, config -> templates, models -> provider dispatch)
- PROV-01 through PROV-04 satisfied with direct evidence
- No hardcoded `(Ollama)` survives in phase_complete — replaced by case dispatch variables
- ROADMAP.md plan checkboxes show `[ ]` (not `[x]`) — this is a minor documentation sync issue but does not affect code correctness

The only items requiring human attention are runtime behaviors (GPU, profile isolation, container start timing) that cannot be verified statically.

---

_Verified: 2026-03-18T02:10:00Z_
_Verifier: Claude (gsd-verifier)_
