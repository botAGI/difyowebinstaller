# Phase 3: Provider Architecture — Research

**Researched:** 2026-03-18
**Domain:** Docker Compose profiles, Bash wizard patterns, vLLM/TEI container configuration
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Wizard: provider selection flow**
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

**Wizard: non-interactive mode**
- `LLM_PROVIDER=ollama|vllm|external|skip` env variable (default: ollama)
- `EMBED_PROVIDER=ollama|tei|external|skip` env variable (default: same logic as interactive)
- Consistent with existing `NON_INTERACTIVE` guard pattern
- CLI flags NOT added (env-only for providers)

**Wizard: offline profile**
- Provider selection works normally for offline profile
- Offline only affects `--pull never` and skipping model download
- User must pre-load chosen provider's container image and models

**Compose profiles: Ollama**
- Ollama moves to `profiles: ["ollama"]` (currently always-on, no profile)
- install.sh adds "ollama" to COMPOSE_PROFILES when LLM_PROVIDER=ollama or EMBED_PROVIDER=ollama
- Breaking change from v1: existing installs that don't set provider will need `LLM_PROVIDER=ollama`

**Compose profiles: vLLM**
- New service `vllm` in docker-compose.yml with `profiles: ["vllm"]`
- Image: `vllm/vllm-openai:${VLLM_VERSION}` (pinned in versions.env)
- Model passed via env: `VLLM_MODEL` in .env → `command: --model ${VLLM_MODEL}`
- Named volume: `vllm_cache:/root/.cache/huggingface` (persist between restarts)
- GPU passthrough: `#__GPU__` comment pattern used for deploy section (same as Ollama)
  - phase_config() uncomments GPU deploy block when nvidia-smi detected
- Healthcheck: `curl -sf http://localhost:8000/health` with start_period 10-15min

**Compose profiles: TEI**
- New service `tei` in docker-compose.yml with `profiles: ["tei"]`
- Image: `ghcr.io/huggingface/text-embeddings-inference:${TEI_VERSION}` (pinned in versions.env)
- Model: BAAI/bge-m3 hardcoded in command or env
- Named volume: `tei_cache:/data` (persist between restarts)
- Healthcheck with extended start_period for model download

**Compose: dependency changes**
- Remove `depends_on: ollama` from ALL services (openwebui, dify-api, dify-worker)
- Ollama becomes fully optional service
- Open WebUI: OLLAMA_BASE_URL set dynamically based on provider
  - Ollama → `OLLAMA_BASE_URL=http://ollama:11434`
  - vLLM → `OPENAI_API_BASE_URL=http://vllm:8000/v1`
  - External/Skip → no URL set (user configures in WebUI settings)

**Compose: Dify connection**
- Dify configures model providers through UI (plugins), NOT through env vars
- OLLAMA_API_BASE stays as hint for Ollama plugin auto-detection
- For vLLM/External: user installs openai_api_compatible plugin and configures endpoint in Dify UI

**Compose: sandbox network**
- vLLM/TEI accessible through Docker network (agmind-backend)
- Sandbox (SSRF proxy) access through Squid only — no direct LLM access from sandbox

**Model download logic**
- phase_models() becomes dispatcher based on LLM_PROVIDER and EMBED_PROVIDER:
  - Ollama (LLM or Embed) → `docker exec ollama pull` (existing logic)
  - vLLM → skip (model downloads at container start)
  - TEI → skip (model downloads at container start)
  - External/Skip → skip entirely
- Mixed scenario: e.g., LLM=vLLM + Embed=Ollama → Ollama pull for embedding only
- Ollama models pulled sequentially (LLM first, then embedding)
- Reranker via Xinference (load_reranker) unchanged — depends only on ETL_ENHANCED=yes
- vLLM health check: extended wait in phase_health for vLLM container to become healthy

**Plugin documentation**
- Expand existing workflows/README.md with "Plugin setup by provider" section
- Per-provider instructions:
  - Ollama: install `langgenius/ollama` plugin
  - vLLM: install `langgenius/openai_api_compatible` plugin, endpoint http://vllm:8000/v1
  - TEI: install `langgenius/openai_api_compatible` plugin, endpoint http://tei:80/v1
  - External: install `langgenius/openai_api_compatible` plugin, configure external URL
  - ETL enhanced: install `s20ss/docling` plugin
- phase_complete() shows provider-specific hint + path to README

### Claude's Discretion

- Exact vLLM model list for wizard (popular HuggingFace models)
- vLLM/TEI version pinning values
- Exact healthcheck intervals and timeouts for vLLM/TEI
- GPU detection logic details (nvidia-smi vs nvidia-container-toolkit check)
- Docker network configuration for vLLM/TEI services
- Exact format of provider-specific hints in phase_complete()

### Deferred Ideas (OUT OF SCOPE)

- GPU memory isolation (vLLM 80% VRAM, embedding 20%) — v2.2+ (ADVX-02)
- Multi-model support in wizard (fast + powerful) — v2.2+ (ADVX-03)
- Model validation in wizard (check HuggingFace registry before pull) — v2.1 (INSE-04)
- vLLM quantization options (AWQ, GPTQ) in wizard — future
- TEI model selection (let user choose embedding model) — future
- Automatic Dify plugin installation via API — removed in Phase 1, stays out of scope
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PROV-01 | LLM provider wizard (Ollama / vLLM / External API / Skip) | Wizard pattern from existing code at lines 268–393; NON_INTERACTIVE guard pattern confirmed throughout install.sh; GPU detection via DETECTED_GPU exported from detect.sh |
| PROV-02 | Embedding provider wizard (Ollama / TEI / External / Same as LLM) | Same wizard scaffolding; TEI image confirmed: ghcr.io/huggingface/text-embeddings-inference:1.9.2; BAAI/bge-m3 supported in TEI v1.9+ |
| PROV-03 | Compose profiles per provider choice (ollama, vllm, external) | Profile pattern confirmed in existing services (weaviate, qdrant, etl, monitoring); COMPOSE_PROFILES builder at lines 776–783; #__GPU__ pattern at lines 269–275 |
| PROV-04 | Plugin documentation per provider (README with install commands) | workflows/README.md already started (line 27–33 shows partial provider docs); needs expansion with full per-provider plugin setup section |
</phase_requirements>

---

## Summary

Phase 3 adds provider selection to the installation wizard and restructures docker-compose.yml so that only the chosen LLM/embedding containers start. The core pattern — Docker Compose `profiles:` + dynamic COMPOSE_PROFILES string — already exists in the project for weaviate, qdrant, etl, monitoring, and authelia services. The change for Ollama is structural: it moves from always-on to `profiles: ["ollama"]`, which is a breaking change handled in Phase 4 migration. Two new services are added: vLLM (OpenAI-compatible, GPU-accelerated) and TEI (production embedding server from HuggingFace).

The wizard integration follows the established pattern precisely: `NON_INTERACTIVE` guard, `read -rp` with default value, `case` dispatch, global variable assignment. GPU detection (`DETECTED_GPU`) is already exported by `phase_diagnostics` via `detect.sh`, so the wizard can read it directly without additional detection code. The existing `#__GPU__` comment-toggle pattern in docker-compose.yml applies identically to vLLM as it does to Ollama and Xinference.

Model download logic in `lib/models.sh` is currently Ollama-only. Phase 3 extends `download_models()` into a provider dispatcher: Ollama → existing pull logic, vLLM/TEI/External/Skip → skip (models download at container start for vLLM/TEI). The critical new complexity is the extended `start_period` in vLLM's healthcheck — model download can take 10-25 minutes for large models, and `phase_health()` must wait accordingly without timing out.

**Primary recommendation:** Follow the existing patterns exactly. Don't introduce new abstraction layers — extend existing functions (`phase_wizard`, `phase_start`, `phase_models`, `phase_complete`, `generate_config`, `download_models`) with provider-aware `case` blocks using the same style already present for `VECTOR_STORE`, `ETL_ENHANCED`, and `MONITORING_MODE`.

---

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| vllm/vllm-openai | v0.8.4 | LLM inference with OpenAI API compat | Official Docker image; only image with CUDA preinstalled; OpenAI API at :8000/v1 |
| ghcr.io/huggingface/text-embeddings-inference | cuda-1.9.2 | High-throughput embedding server | Official HF image; supports BAAI/bge-m3; REST API at :80 |
| Docker Compose profiles | v2 native | Conditional service activation | Already used in project; zero dependencies |

### Supporting
| Tool | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| nvidia-smi | system | GPU detection | Used in detect.sh already; check DETECTED_GPU == "nvidia" |
| HUGGING_FACE_HUB_TOKEN env | — | Gated model access | Required for Llama3, Gemma, Phi-4 families |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| vllm/vllm-openai | ghcr.io/vllm-project/vllm-openai | Same image, different registry; Docker Hub is the canonical reference |
| TEI cuda tag | TEI cpu tag | CPU tag exists but 10-50x slower; target audience has GPU |
| TEI for embeddings | Ollama bge-m3 | TEI is faster in production; Ollama embedding is acceptable for dev/small installs |

**Installation (versions.env additions):**
```bash
VLLM_VERSION=v0.8.4
TEI_VERSION=cuda-1.9.2
```

**Version verification (confirmed 2026-03-18):**
- vLLM latest stable: v0.8.4 (Docker Hub tag confirmed: `vllm/vllm-openai:v0.8.4`)
- TEI latest stable: v1.9.2 (GitHub release 2025-02-25, tag `cuda-1.9.2`)

---

## Architecture Patterns

### Recommended Project Structure

No new directories. All changes go into existing files:

```
install.sh              — phase_wizard(), phase_start(), phase_models(), phase_complete()
lib/models.sh           — download_models() extended with provider dispatch
lib/config.sh           — generate_config() adds HF_TOKEN, LLM_PROVIDER, EMBED_PROVIDER, VLLM_MODEL
templates/
  docker-compose.yml    — add vllm/tei services; move ollama to profile
  versions.env          — add VLLM_VERSION, TEI_VERSION
  env.*.template        — add LLM_PROVIDER, EMBED_PROVIDER, VLLM_MODEL, HF_TOKEN placeholders
workflows/
  README.md             — expand with per-provider plugin setup section
```

### Pattern 1: Existing Compose Profile Pattern (reference for vLLM/TEI)

**What:** Services with `profiles: [name]` only start when COMPOSE_PROFILES contains that name.
**When to use:** Any optional/selectable service.

```yaml
# Source: templates/docker-compose.yml (qdrant service — existing pattern)
qdrant:
  <<: *security-defaults
  image: qdrant/qdrant:${QDRANT_VERSION:-v1.12.1}
  container_name: agmind-qdrant
  restart: always
  profiles:
    - qdrant
  ...
```

Apply the same pattern for vLLM:
```yaml
vllm:
  <<: *logging-defaults          # NOT security-defaults — GPU needs more caps
  image: vllm/vllm-openai:${VLLM_VERSION:-v0.8.4}
  container_name: agmind-vllm
  restart: always
  profiles:
    - vllm
  environment:
    - HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}
  command: --model ${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct}
  volumes:
    - vllm_cache:/root/.cache/huggingface
  ipc: host                      # Required for PyTorch tensor parallel
  healthcheck:
    test: ["CMD-SHELL", "curl -sf http://localhost:8000/health || exit 1"]
    interval: 30s
    timeout: 10s
    retries: 5
    start_period: 900s           # 15 minutes: model download + GPU load
  #__GPU__deploy:
  #__GPU__  resources:
  #__GPU__    reservations:
  #__GPU__      devices:
  #__GPU__        - driver: nvidia
  #__GPU__          count: all
  #__GPU__          capabilities: [gpu]
  networks:
    - agmind-backend
```

### Pattern 2: Existing GPU Comment Toggle Pattern

**What:** Lines prefixed with `#__GPU__` are uncommented by install.sh when GPU is detected.
**When to use:** GPU deploy blocks for vLLM (identical to Ollama and Xinference).

```yaml
# Source: templates/docker-compose.yml lines 269-275 (Ollama — existing pattern)
#__GPU__deploy:
#__GPU__  resources:
#__GPU__    reservations:
#__GPU__      devices:
#__GPU__        - driver: nvidia
#__GPU__          count: all
#__GPU__          capabilities: [gpu]
```

The existing `phase_config()` function already uncomments these lines when DETECTED_GPU == "nvidia". vLLM and TEI blocks use the exact same comment prefix.

### Pattern 3: Existing NON_INTERACTIVE Wizard Guard

**What:** Every wizard question checks `$NON_INTERACTIVE` and falls back to env var.
**When to use:** All new wizard questions.

```bash
# Source: install.sh lines 273-278 (vector store — existing pattern)
if [[ "$NON_INTERACTIVE" != "true" ]]; then
    read -rp "Выбор [1-2, Enter=1]: " choice
    choice="${choice:-1}"
else
    choice="${VECTOR_STORE_CHOICE:-1}"
fi
```

For provider selection, the pattern becomes:
```bash
if [[ "$NON_INTERACTIVE" != "true" ]]; then
    read -rp "LLM провайдер [1-4, Enter=2]: " choice
    choice="${choice:-2}"   # default: vLLM
else
    case "${LLM_PROVIDER:-vllm}" in
        ollama) choice=1;;
        vllm)   choice=2;;
        external) choice=3;;
        skip)   choice=4;;
        *) choice=2;;
    esac
fi
```

### Pattern 4: COMPOSE_PROFILES Builder

**What:** Dynamic string concatenation adds profile names.
**When to use:** phase_start() — add ollama/vllm/tei conditions.

```bash
# Source: install.sh lines 776-783 (existing builder)
local profiles=""
[[ "$DEPLOY_PROFILE" == "vps" ]]       && profiles="vps"
[[ "$VECTOR_STORE" == "qdrant" ]]      && profiles="${profiles:+$profiles,}qdrant"
[[ "$VECTOR_STORE" == "weaviate" ]]    && profiles="${profiles:+$profiles,}weaviate"
[[ "$ETL_ENHANCED" == "yes" ]]         && profiles="${profiles:+$profiles,}etl"
[[ "$MONITORING_MODE" == "local" ]]    && profiles="${profiles:+$profiles,}monitoring"
[[ "$ENABLE_AUTHELIA" == "true" ]]     && profiles="${profiles:+$profiles,}authelia"

# Phase 3 additions (append after existing lines):
[[ "$LLM_PROVIDER" == "ollama" || "$EMBED_PROVIDER" == "ollama" ]] && \
    profiles="${profiles:+$profiles,}ollama"
[[ "$LLM_PROVIDER" == "vllm" ]]        && profiles="${profiles:+$profiles,}vllm"
[[ "$EMBED_PROVIDER" == "tei" ]]       && profiles="${profiles:+$profiles,}tei"
```

### Pattern 5: TEI Service Definition

```yaml
tei:
  <<: *logging-defaults
  image: ghcr.io/huggingface/text-embeddings-inference:${TEI_VERSION:-cuda-1.9.2}
  container_name: agmind-tei
  restart: always
  profiles:
    - tei
  environment:
    - HUGGING_FACE_HUB_TOKEN=${HF_TOKEN:-}
  command: --model-id BAAI/bge-m3 --port 80
  volumes:
    - tei_cache:/data
  healthcheck:
    test: ["CMD-SHELL", "curl -sf http://localhost:80/health || exit 1"]
    interval: 30s
    timeout: 10s
    retries: 5
    start_period: 600s           # 10 minutes: model download
  #__GPU__deploy:
  #__GPU__  resources:
  #__GPU__    reservations:
  #__GPU__      devices:
  #__GPU__        - driver: nvidia
  #__GPU__          count: all
  #__GPU__          capabilities: [gpu]
  networks:
    - agmind-backend
```

### Pattern 6: Provider-Aware models.sh Dispatcher

```bash
# Extend download_models() in lib/models.sh:
download_models() {
    local llm_model="${LLM_MODEL:-qwen2.5:14b}"
    local embedding_model="${EMBEDDING_MODEL:-bge-m3}"
    local profile="${DEPLOY_PROFILE:-lan}"
    local llm_provider="${LLM_PROVIDER:-ollama}"
    local embed_provider="${EMBED_PROVIDER:-ollama}"

    if [[ "$profile" == "offline" ]]; then
        echo -e "${YELLOW}Профиль offline: пропуск загрузки моделей${NC}"
        if [[ "$llm_provider" == "ollama" || "$embed_provider" == "ollama" ]]; then
            check_ollama_models
        fi
        load_reranker
        return 0
    fi

    local need_ollama=false
    [[ "$llm_provider" == "ollama" ]]   && need_ollama=true
    [[ "$embed_provider" == "ollama" ]] && need_ollama=true

    if [[ "$need_ollama" == "true" ]]; then
        wait_for_ollama || return 1
        echo ""
        echo -e "${YELLOW}=== Загрузка моделей ===${NC}"
        echo ""
        [[ "$llm_provider" == "ollama" ]] && pull_model "$llm_model" "LLM ($llm_model)"
        [[ "$embed_provider" == "ollama" ]] && pull_model "$embedding_model" "Embedding ($embedding_model)"
    else
        echo -e "${YELLOW}LLM/Embedding: провайдер ${llm_provider}/${embed_provider} — модели загружаются при старте контейнера${NC}"
    fi

    load_reranker
    echo ""
    echo -e "${GREEN}Фаза моделей завершена${NC}"
}
```

### Anti-Patterns to Avoid

- **Hardcoding provider-specific config in shared-env anchor:** vLLM/TEI endpoints belong in service-specific env, not x-shared-env. Dify does NOT need VLLM_API_BASE injected via env — user configures plugins in UI.
- **Adding `depends_on: vllm` to Dify services:** Dify connects to LLM via plugin layer, not at startup. Adding depends_on would break installs where vLLM profile is not selected.
- **Using `--pull always` for vLLM/TEI containers:** These images are multi-GB. Use `--pull missing` (existing default).
- **Forgetting `ipc: host` for vLLM:** Without shared memory access, tensor parallel inference fails silently.
- **Setting start_period too short for vLLM:** Model download for a 14B model takes 5-15 minutes on a typical server. Use 900s minimum. Docker will mark the container unhealthy if start_period expires before the first successful health check.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| OpenAI-compatible LLM API | Custom inference wrapper | vLLM `vllm/vllm-openai` | Handles batching, KV cache, CUDA graph, PagedAttention — 10-100x throughput vs naive impl |
| Production embedding server | Ollama embedding endpoint | TEI `ghcr.io/huggingface/text-embeddings-inference` | TEI uses Flash Attention, dynamic batching, 3-10x faster than Ollama for embeddings |
| GPU profile detection | Custom nvidia check | Existing `DETECTED_GPU` from detect.sh | Already exports the correct variable; re-detecting is redundant |
| Profile string building | New shell function | Existing `profiles` string concatenation pattern | Pattern already handles edge cases (empty profiles, comma separation) |

**Key insight:** The project already has all required infrastructure patterns. Phase 3 is extension, not invention.

---

## Common Pitfalls

### Pitfall 1: Open WebUI connects to both Ollama AND OpenAI endpoints simultaneously
**What goes wrong:** Open WebUI has `OLLAMA_BASE_URL` and `OPENAI_API_BASE_URL` independently. If both are set, users see duplicate model lists. If `ENABLE_OLLAMA_API=true` and no Ollama container runs, Open WebUI logs connection errors on every poll.
**Why it happens:** Default docker-compose.yml sets `OLLAMA_BASE_URL=http://ollama:11434` hardcoded.
**How to avoid:** Set provider-specific env in docker-compose.yml Open WebUI service:
- LLM_PROVIDER=ollama: `OLLAMA_BASE_URL=http://ollama:11434`, `ENABLE_OLLAMA_API=true`, `ENABLE_OPENAI_API=false`
- LLM_PROVIDER=vllm: `OPENAI_API_BASE_URL=http://vllm:8000/v1`, `ENABLE_OPENAI_API=true`, `ENABLE_OLLAMA_API=false`, `OLLAMA_BASE_URL=` (empty)
- LLM_PROVIDER=external/skip: both disabled, user configures in WebUI UI
**Warning signs:** WebUI health endpoint shows "Connection refused to ollama:11434" in logs when Ollama profile not active.

Implementation approach: generate_config() writes OPENWEBUI_LLM_PROVIDER_VARS to .env, docker-compose.yml reads them via `${ENABLE_OLLAMA_API:-true}` and `${OPENAI_API_BASE_URL:-}` substitutions in Open WebUI environment block.

### Pitfall 2: vLLM healthcheck false-negative during model download
**What goes wrong:** Docker marks container unhealthy before model finishes downloading. `phase_health()` in install.sh fails and aborts installation.
**Why it happens:** vLLM's `/health` endpoint returns 503 until the model is loaded. For a 14B model on a typical GPU server with 1Gbps download, expect 8-20 minutes.
**How to avoid:** Set `start_period: 900s` in vLLM healthcheck. This tells Docker not to count failures during the first 15 minutes. Separately, `phase_health()` should also have an extended wait loop for vLLM specifically (check `LLM_PROVIDER` before deciding wait duration).
**Warning signs:** `docker ps` shows `(health: starting)` for vLLM but `(unhealthy)` appears before model loads.

### Pitfall 3: Ollama depends_on left on downstream services
**What goes wrong:** If `depends_on: ollama` remains on open-webui, worker, or api services, those containers refuse to start when Ollama profile is not active (container doesn't exist).
**Why it happens:** Currently open-webui has `depends_on: ollama: condition: service_healthy` (docker-compose.yml line 243). Moving Ollama to a profile without removing this dependency breaks all non-Ollama installs.
**How to avoid:** Remove `depends_on: ollama` from open-webui service. Verify no other services reference it.
**Warning signs:** `docker compose up` fails with "service ollama failed to build: no such service" when ollama profile not in COMPOSE_PROFILES.

### Pitfall 4: COMPOSE_PROFILES nuclear cleanup missing new profiles
**What goes wrong:** `phase_start()` line 789 hard-codes the full profile list for cleanup: `COMPOSE_PROFILES=vps,monitoring,qdrant,weaviate,etl,authelia docker compose down`. If ollama/vllm/tei are not added, stale containers from previous failed installs won't be cleaned.
**Why it happens:** Manual list that must be kept in sync.
**How to avoid:** Add `ollama,vllm,tei` to the nuclear cleanup COMPOSE_PROFILES string at line 789.
**Warning signs:** Old agmind-ollama container from previous install blocks new install (name conflict).

### Pitfall 5: TEI API path differs from OpenAI standard
**What goes wrong:** TEI's REST API is not identical to OpenAI's. TEI exposes `/embed` endpoint (POST), not `/v1/embeddings`. The Dify openai_api_compatible plugin may not work directly with TEI.
**Why it happens:** TEI was designed before OpenAI embedding API became the standard. The `/info` and `/embed` endpoints are TEI-native.
**How to avoid:** Check TEI v1.9+ compatibility. TEI v1.2+ added an OpenAI-compatible `/v1/embeddings` endpoint. Plugin docs should specify `http://tei:80/v1` (with `/v1` prefix), not `http://tei:80`.
**Warning signs:** 404 errors when Dify plugin calls `http://tei:80/embeddings` without `/v1` prefix.

### Pitfall 6: HF_TOKEN in .env passed through to containers but not masked
**What goes wrong:** HF_TOKEN written to .env is readable via `docker exec` environment inspection or logs.
**Why it happens:** Default Docker environment variable handling.
**How to avoid:** Consistent with existing credentials pattern: write HF_TOKEN to .env with chmod 600 (already applied to .env). Do not log it in phase_complete() output or credentials.txt. The token is already protected by file permissions.
**Warning signs:** grep in logs showing token value.

---

## Code Examples

### vLLM model list for wizard (Claude's Discretion — recommended list)

Popular models confirmed to work with vLLM, sized for common GPU configurations:

```bash
# Source: Community vLLM deployment guides + HuggingFace popularity metrics (MEDIUM confidence)
echo "Выберите модель для vLLM:"
echo " ── 7-8B [14GB+ VRAM] ──"
echo "  1) Qwen/Qwen2.5-7B-Instruct"
echo "  2) mistralai/Mistral-7B-Instruct-v0.3"
echo "  3) meta-llama/Llama-3.1-8B-Instruct  (требует HF_TOKEN)"
echo ""
echo " ── 14B [24GB+ VRAM] ──"
echo "  4) Qwen/Qwen2.5-14B-Instruct           [рекомендуется]"
echo "  5) Qwen/Qwen3-14B"
echo "  6) microsoft/phi-4"
echo ""
echo " ── 32B+ [48GB+ VRAM] ──"
echo "  7) Qwen/Qwen2.5-32B-Instruct"
echo "  8) meta-llama/Llama-3.3-70B-Instruct-GPTQ-INT4 (требует HF_TOKEN)"
echo ""
echo " ── Своя модель ──"
echo "  9) Указать HuggingFace repo (org/model-name)"
```

Default: item 4 (`Qwen/Qwen2.5-14B-Instruct`) — matches existing default in Ollama wizard.

### phase_complete() provider hint block

```bash
# Extend phase_complete() provider display and plugin hint
local llm_display
case "${LLM_PROVIDER:-ollama}" in
    ollama)   llm_display="${LLM_MODEL} (Ollama)";;
    vllm)     llm_display="${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct} (vLLM)";;
    external) llm_display="External API";;
    skip)     llm_display="Не настроен";;
esac

local embed_display
case "${EMBED_PROVIDER:-ollama}" in
    ollama)   embed_display="${EMBEDDING_MODEL:-bge-m3} (Ollama)";;
    tei)      embed_display="BAAI/bge-m3 (TEI)";;
    external) embed_display="External API";;
    skip)     embed_display="Не настроен";;
esac

# Plugin hint shown after summary box
local plugin_hint
case "${LLM_PROVIDER:-ollama}" in
    ollama)   plugin_hint="Установите плагин langgenius/ollama в Dify → Plugins";;
    vllm)     plugin_hint="Установите плагин langgenius/openai_api_compatible в Dify → Plugins\n  Endpoint: http://vllm:8000/v1";;
    external) plugin_hint="Установите плагин langgenius/openai_api_compatible в Dify → Plugins\n  Endpoint: ваш внешний URL";;
    skip)     plugin_hint="Настройте модель вручную в Dify → Settings → Model Providers";;
esac
echo -e "${CYAN}Следующий шаг: ${plugin_hint}${NC}"
echo -e "${CYAN}Подробно: ${INSTALL_DIR}/workflows/README.md${NC}"
```

### config.sh: new variables to generate in .env

```bash
# Add to generate_config() after existing sed replacements:
local safe_vllm_model safe_hf_token
safe_vllm_model=$(escape_sed "${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct}")
safe_hf_token=$(escape_sed "${HF_TOKEN:-}")

# Append new provider variables to .env
cat >> "$env_file" <<EOF

# --- Provider Architecture ---
LLM_PROVIDER=${LLM_PROVIDER:-ollama}
EMBED_PROVIDER=${EMBED_PROVIDER:-ollama}
VLLM_MODEL=${VLLM_MODEL:-Qwen/Qwen2.5-14B-Instruct}
HF_TOKEN=${HF_TOKEN:-}
EOF
```

### GPU detection in wizard (using already-exported DETECTED_GPU)

```bash
# In phase_wizard(), before provider question:
# DETECTED_GPU is already exported by phase_diagnostics() → detect.sh
local default_llm_provider="vllm"
local gpu_warning=""
if [[ "${DETECTED_GPU:-none}" != "nvidia" ]]; then
    default_llm_provider="ollama"
    gpu_warning="  (GPU NVIDIA не обнаружен — умолчание изменено на Ollama)"
fi

echo "Выберите LLM провайдер:${gpu_warning}"
echo "  1) Ollama"
echo "  2) vLLM"
echo "  3) External API"
echo "  4) Skip"
echo ""
if [[ "$NON_INTERACTIVE" != "true" ]]; then
    local default_idx
    case "$default_llm_provider" in
        ollama) default_idx=1;; vllm) default_idx=2;;
    esac
    read -rp "Выбор [1-4, Enter=${default_idx}]: " choice
    choice="${choice:-${default_idx}}"
else
    case "${LLM_PROVIDER:-$default_llm_provider}" in
        ollama)   choice=1;; vllm) choice=2;; external) choice=3;; skip) choice=4;; *) choice=2;;
    esac
fi
case "$choice" in
    1) LLM_PROVIDER="ollama";;
    2) LLM_PROVIDER="vllm";;
    3) LLM_PROVIDER="external";;
    4) LLM_PROVIDER="skip";;
    *) LLM_PROVIDER="$default_llm_provider";;
esac
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Ollama always-on (no profile) | Ollama in `profiles: ["ollama"]` | Phase 3 | Breaking: existing installs need `LLM_PROVIDER=ollama` |
| Single embedding path via Ollama | TEI as dedicated embedding service | Phase 3 | TEI is 3-10x faster for high-load production use |
| Hardcoded model section in wizard | Provider-dispatched model selection | Phase 3 | vLLM models are HuggingFace repos, not Ollama tags |
| `OLLAMA_BASE_URL` always set in WebUI | Provider-conditional URL env vars | Phase 3 | Eliminates connection error logs when Ollama not active |

**Deprecated/outdated after Phase 3:**
- `EMBEDDING_MODEL` env var: still used for Ollama embed, not needed for TEI (model hardcoded)
- `depends_on: ollama` on open-webui: removed — Ollama is now optional

---

## Open Questions

1. **Open WebUI env var names for vLLM**
   - What we know: Open WebUI supports `OPENAI_API_BASE_URL` and `ENABLE_OPENAI_API` env vars
   - What's unclear: exact var name may differ between Open WebUI versions; v0.5.20 is pinned
   - Recommendation: verify against Open WebUI v0.5.20 docs before implementation. Expected var: `OPENAI_API_BASE_URL=http://vllm:8000/v1` with `ENABLE_OPENAI_API=true`

2. **TEI `/v1/embeddings` availability in v1.9.2**
   - What we know: TEI added OpenAI-compatible endpoint in v1.2+
   - What's unclear: exact path prefix and whether Dify openai_api_compatible plugin needs `/v1` suffix
   - Recommendation: set endpoint in plugin docs as `http://tei:80/v1` and verify TEI responds to `POST /v1/embeddings`

3. **vLLM `ipc: host` vs `shm-size` in docker compose**
   - What we know: Official docs recommend `--ipc=host` for tensor parallel inference
   - What's unclear: whether `ipc: host` in compose is equivalent; single-GPU installs may not need it
   - Recommendation: Use `ipc: host` in compose service definition; it's the official recommendation and harmless for single-GPU

---

## Validation Architecture

`workflow.nyquist_validation` key is absent from `.planning/config.json` — treating as enabled.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | BATS (Bash Automated Testing System) |
| Config file | tests/ directory (existing BATS tests present from Phase 2) |
| Quick run command | `bats tests/` |
| Full suite command | `bats tests/ --formatter tap` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PROV-01 | Wizard sets LLM_PROVIDER correctly for each choice (1-4) in non-interactive mode | unit | `bats tests/test_wizard_provider.bats` | ❌ Wave 0 |
| PROV-01 | GPU detection fallback: DETECTED_GPU!=nvidia sets default to ollama | unit | `bats tests/test_wizard_provider.bats` | ❌ Wave 0 |
| PROV-02 | Wizard sets EMBED_PROVIDER correctly; "Same as LLM" maps correctly | unit | `bats tests/test_wizard_provider.bats` | ❌ Wave 0 |
| PROV-03 | COMPOSE_PROFILES contains "ollama" when LLM_PROVIDER=ollama | unit | `bats tests/test_compose_profiles.bats` | ❌ Wave 0 |
| PROV-03 | COMPOSE_PROFILES contains "vllm" when LLM_PROVIDER=vllm | unit | `bats tests/test_compose_profiles.bats` | ❌ Wave 0 |
| PROV-03 | COMPOSE_PROFILES contains "tei" when EMBED_PROVIDER=tei | unit | `bats tests/test_compose_profiles.bats` | ❌ Wave 0 |
| PROV-03 | No ollama/vllm/tei in COMPOSE_PROFILES for external/skip | unit | `bats tests/test_compose_profiles.bats` | ❌ Wave 0 |
| PROV-04 | workflows/README.md contains per-provider plugin section | smoke | `grep -q "langgenius/ollama" workflows/README.md` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `bats tests/test_wizard_provider.bats tests/test_compose_profiles.bats`
- **Per wave merge:** `bats tests/`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tests/test_wizard_provider.bats` — covers PROV-01, PROV-02
- [ ] `tests/test_compose_profiles.bats` — covers PROV-03
- [ ] No additional framework install needed — BATS tests already present in project from Phase 2

---

## Sources

### Primary (HIGH confidence)
- Project codebase (install.sh, lib/models.sh, lib/config.sh, lib/detect.sh, templates/docker-compose.yml) — read directly; establishes all patterns to follow
- templates/versions.env — current version pinning format
- `.planning/phases/03-provider-architecture/03-CONTEXT.md` — all locked decisions

### Secondary (MEDIUM confidence)
- [vLLM Docker Hub](https://hub.docker.com/layers/vllm/vllm-openai/v0.8.4/images/sha256-b168cbb0101f51b2491047345d0a83f5a8ecbe56a6604f2a2edb81eca55ebc9e) — v0.8.4 tag confirmed present
- [vLLM official docs — Docker deployment](https://docs.vllm.ai/en/v0.8.4/deployment/docker.html) — GPU run command, image name, `--ipc=host` requirement, `--model` flag
- [TEI GitHub releases](https://github.com/huggingface/text-embeddings-inference/releases) — v1.9.2 release confirmed 2025-02-25

### Tertiary (LOW confidence)
- WebSearch results on vLLM healthcheck endpoint (`/health` at port 8000) — confirmed by multiple sources but not directly from official docs
- start_period recommendation of 900s for 14B model — from community deployment guides, varies by model size and bandwidth

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — versions confirmed from GitHub releases and Docker Hub
- Architecture patterns: HIGH — all patterns read directly from existing codebase
- vLLM/TEI service config: MEDIUM — based on official docs + community sources; `ipc: host` and start_period values are estimates
- Pitfalls: MEDIUM-HIGH — derived from code analysis (depends_on, COMPOSE_PROFILES cleanup) and known vLLM behaviors

**Research date:** 2026-03-18
**Valid until:** 2026-04-18 (vLLM releases frequently; TEI is stable)
