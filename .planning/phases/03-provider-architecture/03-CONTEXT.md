# Phase 3: Provider Architecture - Context

**Gathered:** 2026-03-18
**Status:** Ready for planning

<domain>
## Phase Boundary

User chooses LLM and embedding provider in wizard. Compose profiles start only what's needed. vLLM and TEI containers added to docker-compose.yml. Plugin documentation per provider. The installer handles infrastructure choice — AI model configuration (API keys, endpoints) is the user's job in Dify UI.

</domain>

<decisions>
## Implementation Decisions

### Wizard: provider selection flow
- Two-step selection: first provider, then model (not a single merged list)
- LLM provider question: `1) Ollama 2) vLLM 3) External API 4) Skip` — names only, no descriptions
- Default LLM provider: **vLLM** (target audience has GPU)
- GPU detection fallback: if `nvidia-smi` not found in phase_diagnostics, show warning and change default to Ollama. vLLM still selectable explicitly.
- After LLM provider: model selection depends on provider:
  - Ollama → existing 16-model list (unchanged)
  - vLLM → curated list of popular HuggingFace models + manual input option
  - External → skip model selection (user configures in Dify UI)
  - Skip → skip everything (no LLM container started, phase_models skipped)
- Embedding provider question: `1) Same as LLM 2) TEI 3) External 4) Skip`
  - Default: "Same as LLM" (Ollama→Ollama bge-m3, vLLM→TEI, External→External, Skip→Skip)
  - If LLM=External or Skip: option "Same as LLM" maps to External/Skip respectively
- TEI model: hardcoded BAAI/bge-m3 (no question asked)
- HuggingFace token: optional prompt when vLLM or TEI selected: "HuggingFace token (Enter для пропуска):"
  - Saved to .env as HF_TOKEN, passed to vLLM/TEI containers
  - Needed for gated models (Llama, Gemma, etc.)
- Provider shown in wizard summary: "LLM: qwen2.5:14b (vLLM)" instead of "(Ollama)"

### Wizard: non-interactive mode
- `LLM_PROVIDER=ollama|vllm|external|skip` env variable (default: ollama)
- `EMBED_PROVIDER=ollama|tei|external|skip` env variable (default: same logic as interactive)
- Consistent with existing `NON_INTERACTIVE` guard pattern
- CLI flags NOT added (env-only for providers)

### Wizard: offline profile
- Provider selection works normally for offline profile
- Offline only affects `--pull never` and skipping model download
- User must pre-load chosen provider's container image and models

### Compose profiles: Ollama
- Ollama moves to `profiles: ["ollama"]` (currently always-on, no profile)
- install.sh adds "ollama" to COMPOSE_PROFILES when LLM_PROVIDER=ollama or EMBED_PROVIDER=ollama
- Breaking change from v1: existing installs that don't set provider will need `LLM_PROVIDER=ollama` — handled by Phase 4 installer redesign (migration)

### Compose profiles: vLLM
- New service `vllm` in docker-compose.yml with `profiles: ["vllm"]`
- Image: `vllm/vllm-openai:${VLLM_VERSION}` (pinned in versions.env)
- Model passed via env: `VLLM_MODEL` in .env → `command: --model ${VLLM_MODEL}`
- Named volume: `vllm_cache:/root/.cache/huggingface` (persist between restarts)
- GPU passthrough: `#__GPU__` comment pattern used for deploy section (same as Ollama)
  - phase_config() uncomments GPU deploy block when nvidia-smi detected
- Healthcheck: `curl -sf http://localhost:8000/health` with start_period 10-15min (download + load)

### Compose profiles: TEI
- New service `tei` in docker-compose.yml with `profiles: ["tei"]`
- Image: `ghcr.io/huggingface/text-embeddings-inference:${TEI_VERSION}` (pinned in versions.env)
- Model: BAAI/bge-m3 hardcoded in command or env
- Named volume: `tei_cache:/data` (persist between restarts)
- Healthcheck with extended start_period for model download

### Compose: dependency changes
- Remove `depends_on: ollama` from ALL services (openwebui, dify-api, dify-worker)
- Ollama becomes fully optional service
- Open WebUI: OLLAMA_BASE_URL set dynamically based on provider
  - Ollama → `OLLAMA_BASE_URL=http://ollama:11434`
  - vLLM → `OPENAI_API_BASE_URL=http://vllm:8000/v1`
  - External/Skip → no URL set (user configures in WebUI settings)

### Compose: Dify connection
- Dify configures model providers through UI (plugins), NOT through env vars
- OLLAMA_API_BASE stays as hint for Ollama plugin auto-detection
- For vLLM/External: user installs openai_api_compatible plugin and configures endpoint in Dify UI
- Consistent with three-layer principle: installer = infra, AI config = user

### Compose: sandbox network
- vLLM/TEI accessible through Docker network (agmind-backend)
- Sandbox (SSRF proxy) access through Squid only — no direct LLM access from sandbox

### Model download logic
- phase_models() becomes dispatcher based on LLM_PROVIDER and EMBED_PROVIDER:
  - Ollama (LLM or Embed) → `docker exec ollama pull` (existing logic)
  - vLLM → skip (model downloads at container start)
  - TEI → skip (model downloads at container start)
  - External/Skip → skip entirely
- Mixed scenario supported: e.g., LLM=vLLM + Embed=Ollama → Ollama pull for embedding only
- Ollama models pulled sequentially (LLM first, then embedding) — same as current
- Reranker via Xinference (load_reranker) unchanged — depends only on ETL_ENHANCED=yes
- vLLM health check: extended wait in phase_health for vLLM container to become healthy (model download + load)

### Plugin documentation
- Expand existing workflows/README.md with "Plugin setup by provider" section
- Per-provider instructions:
  - Ollama: install `langgenius/ollama` plugin
  - vLLM: install `langgenius/openai_api_compatible` plugin, endpoint http://vllm:8000/v1
  - TEI: install `langgenius/openai_api_compatible` plugin, endpoint http://tei:80/v1
  - External: install `langgenius/openai_api_compatible` plugin, configure external URL
  - ETL enhanced: install `s20ss/docling` plugin
- phase_complete() shows provider-specific hint: "Установите плагин langgenius/ollama в Dify → Plugins" + path to README

### Claude's Discretion
- Exact vLLM model list for wizard (popular HuggingFace models)
- vLLM/TEI version pinning values
- Exact healthcheck intervals and timeouts for vLLM/TEI
- GPU detection logic details (nvidia-smi vs nvidia-container-toolkit check)
- Docker network configuration for vLLM/TEI services
- Exact format of provider-specific hints in phase_complete()

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope
- `.planning/REQUIREMENTS.md` §Provider Architecture — PROV-01 through PROV-04: requirement definitions
- `.planning/ROADMAP.md` §Phase 3 — Key deliverables and success criteria

### Prior decisions
- `.planning/phases/01-surgery-remove-dify-api-automation/01-CONTEXT.md` §Wizard simplification — wizard field changes from Phase 1
- `.planning/phases/02-security-hardening-v2/02-CONTEXT.md` §Wizard opt-in — wizard pattern established in Phase 2

### Files to modify
- `install.sh` — wizard provider questions, phase_models() dispatcher, phase_complete() hints, COMPOSE_PROFILES builder in phase_start(), GPU detection
- `templates/docker-compose.yml` — add vLLM/TEI services, move Ollama to profile, remove depends_on ollama, add volumes
- `lib/models.sh` — provider-aware download logic, skip for vLLM/TEI/External
- `lib/config.sh` — generate LLM_PROVIDER, EMBED_PROVIDER, VLLM_MODEL, HF_TOKEN in .env
- `workflows/README.md` — expand with per-provider plugin instructions

### New files
- No new scripts expected — changes go into existing files

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `install.sh` wizard pattern (lines 295-393): `read -rp` with `NON_INTERACTIVE` guard and case-based model selection — extend with provider selection before model selection
- `COMPOSE_PROFILES` builder (lines 777-783): dynamic profile string concatenation — add ollama/vllm/tei profiles here
- `lib/models.sh:download_models()`: dispatch already checks offline profile — extend with provider check
- `#__GPU__` comment pattern (docker-compose.yml lines 269-275): GPU deploy block toggling — reuse for vLLM

### Established Patterns
- Phase functions: `phase_NAME()` with `[N/9]` display label
- Variables collected in wizard, exported for downstream phases
- Docker images pinned via `${SERVICE_VERSION}` in versions.env
- Profiles: services use `profiles: ["name"]`, install.sh builds COMPOSE_PROFILES string
- Health checks: `test: ["CMD", ...]` with configurable interval/timeout/retries/start_period

### Integration Points
- `phase_start()` line 774: COMPOSE_PROFILES builder — add ollama/vllm/tei conditions
- `phase_models()` line 1079: calls download_models — needs provider dispatch
- `phase_complete()` line ~1190: summary display — add provider label, plugin hint
- `phase_wizard()`: insert provider selection before model selection (~line 295)
- `lib/config.sh:generate_config()`: export new env vars to .env

</code_context>

<specifics>
## Specific Ideas

- vLLM default provider reflects that target audience (corporate AI teams) has GPU hardware
- GPU fallback: automatic switch to Ollama default keeps wizard usable on dev machines without GPU
- Mixed provider scenario (e.g., vLLM for LLM + Ollama for embeddings) explicitly supported — real use case where vLLM is better for generation but Ollama embedding is sufficient
- HF_TOKEN prompt only when vLLM/TEI selected — don't ask Ollama-only users
- TEI embedding model (BAAI/bge-m3) is the same model currently used via Ollama — user gets same quality, different runtime
- Plugin hints in phase_complete are provider-specific — user sees exactly what they need, not generic instructions

</specifics>

<deferred>
## Deferred Ideas

- GPU memory isolation (vLLM 80% VRAM, embedding 20%) — v2.2+ (ADVX-02)
- Multi-model support in wizard (fast + powerful) — v2.2+ (ADVX-03)
- Model validation in wizard (check HuggingFace registry before pull) — v2.1 (INSE-04)
- vLLM quantization options (AWQ, GPTQ) in wizard — future
- TEI model selection (let user choose embedding model) — future
- Automatic Dify plugin installation via API — removed in Phase 1, stays out of scope

</deferred>

---

*Phase: 03-provider-architecture*
*Context gathered: 2026-03-18*
