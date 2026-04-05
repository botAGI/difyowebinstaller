# Phase 21: Embeddings Wizard + Docker - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Новый шаг визарда для выбора TEI embedding модели. Меню с 3 моделями + ввод вручную. Результат записывается в EMBEDDING_MODEL в .env, docker-compose TEI контейнер использует переменную вместо хардкода.

</domain>

<decisions>
## Implementation Decisions

### Меню моделей (EMBD-01)
- Формат как vLLM menu: номер + имя модели + краткое описание (без VRAM — embedding модели маленькие)
- 3 модели + custom:
  1. BAAI/bge-m3 — мультиязычная, стабильная [по умолчанию]
  2. Qwen/Qwen3-Embedding-0.6B — лёгкая, 0.6B параметров
  3. intfloat/multilingual-e5-large-instruct — instruct-версия, MTEB #7, понимает query:/passage: префиксы
  4. Ввод вручную — полный HuggingFace ID
- Дефолт: BAAI/bge-m3 (и в NON_INTERACTIVE)
- В NON_INTERACTIVE: если EMBEDDING_MODEL задан через env — использовать его, иначе BAAI/bge-m3

### Docker-compose интеграция (EMBD-02)
- Параметризовать TEI command: `--model-id ${EMBEDDING_MODEL:-BAAI/bge-m3}` вместо хардкода
- EMBEDDING_MODEL записывается в .env через config.sh
- Env templates: добавить `EMBEDDING_MODEL=BAAI/bge-m3` в секцию эмбеддингов

### Wizard flow порядок
- Объединить _wizard_embed_provider() + _wizard_embed_model() — провайдер + меню моделей в одном потоке
- При EMBED_PROVIDER=tei (прямой выбор или через «Как LLM» + vllm) — всегда показывать меню TEI моделей
- При EMBED_PROVIDER=ollama — оставить текущую логику (ввод имени модели)
- При EMBED_PROVIDER=external/skip — не показывать меню моделей

### Claude's Discretion
- Внутренняя реализация _wizard_embedding_model() (helper function для форматирования строк)
- Валидация custom model name
- Текст описаний моделей в меню

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Wizard
- `lib/wizard.sh` §551-589 — _wizard_embed_provider() + _wizard_embed_model() (текущие функции, будут объединены)
- `lib/wizard.sh` §33-34 — EMBED_PROVIDER и EMBEDDING_MODEL defaults
- `lib/wizard.sh` §900-906 — run_wizard() порядок вызовов
- `lib/wizard.sh` §918-919 — export EMBED_PROVIDER EMBEDDING_MODEL

### Docker-compose
- `templates/docker-compose.yml` §341-370 — TEI service block, line 353 `--model-id BAAI/bge-m3` (хардкод → переменная)

### Config / env
- `lib/config.sh` — writes .env from wizard exports
- `templates/env.lan.template` — env template (add EMBEDDING_MODEL)
- `templates/env.vps.template` — env template (add EMBEDDING_MODEL)
- `templates/env.vpn.template` — env template (add EMBEDDING_MODEL)
- `templates/env.offline.template` — env template (add EMBEDDING_MODEL)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `_ask_choice()` in wizard.sh — existing choice helper, respects NON_INTERACTIVE
- `_vllm_line()` pattern in _wizard_vllm_model() — menu line formatting, can replicate for embedding models
- `validate_model_name()` in common.sh — model name validation

### Established Patterns
- vLLM model menu: numbered list with descriptions, _ask_choice for selection, case statement
- NON_INTERACTIVE: if env var set → use it, otherwise default
- config.sh: wizard exports → .env file

### Integration Points
- _wizard_embed_provider() called from run_wizard() after _wizard_llm_model()
- EMBED_PROVIDER → compose.sh build_compose_profiles() (profile `tei`)
- EMBEDDING_MODEL → config.sh → .env → docker-compose TEI command

</code_context>

<specifics>
## Specific Ideas

No specific requirements — follow vLLM menu pattern for consistency.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 21-embeddings-wizard-docker*
*Context gathered: 2026-03-23*
