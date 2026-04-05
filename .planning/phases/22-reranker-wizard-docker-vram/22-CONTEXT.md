# Phase 22: Reranker Wizard + Docker + VRAM - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning
**Source:** Auto-mode (recommended defaults)

<domain>
## Phase Boundary

Опциональный шаг визарда для включения reranker. Пользователь выбирает "нет" (по умолчанию) или одну из TEI reranker моделей. При включении поднимается TEI-rerank контейнер в отдельном docker-compose profile `reranker`. VRAM реранкера учитывается в VRAM бюджете и guard.

</domain>

<decisions>
## Implementation Decisions

### Меню моделей (RNKR-01)
- Формат как embedding menu: номер + имя модели + описание + VRAM
- 4 варианта + custom:
  0. Нет (по умолчанию) — реранкер не используется
  1. BAAI/bge-reranker-v2-m3 — мультиязычный, ~0.5 GB VRAM
  2. BAAI/bge-reranker-base — компактный, ~0.3 GB VRAM
  3. cross-encoder/ms-marco-MiniLM-L-6-v2 — быстрый, ~0.2 GB VRAM
  4. Ввод вручную — полный HuggingFace ID
- Дефолт: "нет" (ENABLE_RERANKER=false) — и в NON_INTERACTIVE
- В NON_INTERACTIVE: если ENABLE_RERANKER=true и RERANK_MODEL задан — использовать, если ENABLE_RERANKER=true без RERANK_MODEL — BAAI/bge-reranker-v2-m3, иначе выключен

### Docker-compose интеграция (RNKR-02)
- Новый сервис `tei-rerank` в docker-compose.yml, структура по аналогии с `tei` (embedding)
- Profile: `reranker`
- Образ: тот же `text-embeddings-inference` (TEI умеет и embed и rerank)
- Command: `--model-id ${RERANK_MODEL:-BAAI/bge-reranker-v2-m3} --port 80`
- Порт: 8090 → 80 (отличается от TEI embed 8089 → 80)
- Healthcheck: аналогичный TEI embed
- RERANK_MODEL и ENABLE_RERANKER записываются в .env через config.sh
- build_compose_profiles(): добавить `[[ "${ENABLE_RERANKER:-}" == "true" ]] && profiles="${profiles:+$profiles,}reranker"`

### VRAM бюджет (RNKR-03)
- Добавить `RERANKER_VRAM_OFFSET=1` рядом с `TEI_VRAM_OFFSET=2`
- В VRAM guard: когда ENABLE_RERANKER=true, вычитать RERANKER_VRAM_OFFSET из effective VRAM
- Формула: effective_vram = raw_vram - TEI_VRAM_OFFSET - (ENABLE_RERANKER ? RERANKER_VRAM_OFFSET : 0)
- В сводке визарда: показывать строку "Reranker: {model} (~1 GB)" если включен

### Wizard flow порядок
- _wizard_reranker_model() вызывается после _wizard_embedding_model() в run_wizard()
- Первый вопрос: "Включить реранкер? (Улучшает качество RAG, +~1 GB VRAM)" — нет/да
- При "нет" → ENABLE_RERANKER=false, return
- При "да" → ENABLE_RERANKER=true, показать меню моделей
- Export: ENABLE_RERANKER RERANK_MODEL

### Env templates
- Добавить в все 4 env templates: `ENABLE_RERANKER=__ENABLE_RERANKER__` и `RERANK_MODEL=__RERANK_MODEL__`
- config.sh: sed для __ENABLE_RERANKER__ и __RERANK_MODEL__

### Claude's Discretion
- Внутренняя реализация _wizard_reranker_model() (helper functions)
- Текст описаний моделей в меню
- Точная позиция нового сервиса в docker-compose.yml (после tei)
- Healthcheck intervals

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Wizard
- `lib/wizard.sh` §581-640 — _wizard_embedding_model() (паттерн для реплицирования reranker menu)
- `lib/wizard.sh` §939-974 — run_wizard() порядок вызовов и exports
- `lib/wizard.sh` §25-34 — _init_wizard_defaults (добавить ENABLE_RERANKER, RERANK_MODEL)

### VRAM
- `lib/wizard.sh` §348-349 — TEI_VRAM_OFFSET=2 (рядом добавить RERANKER_VRAM_OFFSET)
- `lib/wizard.sh` §386-391 — effective_vram calculation (добавить reranker offset)
- `lib/wizard.sh` §474-479 — VRAM guard check (добавить reranker offset)
- `lib/wizard.sh` §532-545 — NON_INTERACTIVE VRAM check (добавить reranker offset)

### Docker-compose
- `templates/docker-compose.yml` §341-370 — TEI embed service (паттерн для TEI-rerank)

### Compose profiles
- `lib/compose.sh` §17-38 — build_compose_profiles() (добавить profile `reranker`)

### Config / env
- `lib/config.sh` — writes .env from wizard exports (добавить ENABLE_RERANKER, RERANK_MODEL)
- `templates/env.lan.template` — env template
- `templates/env.vps.template` — env template
- `templates/env.vpn.template` — env template
- `templates/env.offline.template` — env template

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `_wizard_embedding_model()` — полный паттерн TEI menu (Phase 21), реплицировать для reranker
- `_ask_choice()` — existing choice helper, respects NON_INTERACTIVE
- `_ask_yn()` — yes/no helper для "Включить реранкер?"
- `TEI_VRAM_OFFSET` pattern — аналогичный для reranker

### Established Patterns
- TEI embedding menu: numbered list → _ask_choice → case statement → export
- VRAM guard: raw_vram - offset → compare with model requirement → warn/block
- Compose profiles: conditional append to COMPOSE_PROFILE_STRING
- Config.sh: sed __PLACEHOLDER__ → value from wizard exports

### Integration Points
- _wizard_reranker_model() → run_wizard() после _wizard_embedding_model()
- ENABLE_RERANKER → compose.sh build_compose_profiles() (profile `reranker`)
- RERANK_MODEL → config.sh → .env → docker-compose TEI-rerank command
- RERANKER_VRAM_OFFSET → VRAM guard calculation в _wizard_vllm_model()

</code_context>

<specifics>
## Specific Ideas

- Следовать паттерну Phase 21 (embedding menu) для консистентности
- Реранкер опционален в отличие от embeddings — первый вопрос yes/no с дефолтом "нет"
- VRAM offset 1 GB — консервативная оценка для большинства reranker моделей

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 22-reranker-wizard-docker-vram*
*Context gathered: 2026-03-23 via auto-mode*
