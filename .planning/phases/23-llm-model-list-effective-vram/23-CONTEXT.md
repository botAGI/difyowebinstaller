# Phase 23: LLM Model List + Effective VRAM - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning
**Source:** Auto-mode (recommended defaults)

<domain>
## Phase Boundary

Рефакторинг VRAM offset из hardcoded констант в динамическую функцию, которая учитывает текущую конфигурацию (EMBED_PROVIDER, ENABLE_RERANKER). Аудит и при необходимости обновление списка vLLM моделей и их VRAM requirements.

</domain>

<decisions>
## Implementation Decisions

### Dynamic VRAM offset (LLMM-02)
- Заменить `readonly TEI_VRAM_OFFSET=2` и `readonly RERANKER_VRAM_OFFSET=1` на функцию `_get_vram_offset()`
- Функция возвращает суммарный offset в GB на основе активных сервисов:
  - EMBED_PROVIDER=tei → +2 GB
  - EMBED_PROVIDER=ollama/external/skip → +0 GB (Ollama embedding на CPU или внешний, не ест VRAM GPU)
  - ENABLE_RERANKER=true → +1 GB
  - ENABLE_RERANKER=false → +0 GB
- Все 3 места использования offset (recommended tag, VRAM guard, NON_INTERACTIVE check) вызывают `_get_vram_offset()` вместо прямых ссылок на константы
- _get_vllm_vram_req() — оставить как есть (per-model lookup)

### Список моделей vLLM (LLMM-01)
- Текущий список: 16 моделей + custom = 17 вариантов — это соответствует ROADMAP
- Секции: AWQ (5), bf16 7-8B (4), bf16 14B (3), bf16 32B+ (2), MoE (2) — всё корректно
- Аудит VRAM values: проверить что текущие значения в vram_req[] и _get_vllm_vram_req() совпадают и корректны
- Если обнаружатся расхождения — исправить. Если нет — список остаётся как есть
- Рекомендуемая модель: алгоритм уже работает (largest fitting → [рекомендуется]) — не менять

### Claude's Discretion
- Точная реализация _get_vram_offset() (local function vs top-level)
- Форматирование VRAM warning messages при изменении offset logic

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### VRAM offset
- `lib/wizard.sh` §350-353 — TEI_VRAM_OFFSET и RERANKER_VRAM_OFFSET (заменить на функцию)
- `lib/wizard.sh` §390-397 — effective_vram calculation для [рекомендуется] tag
- `lib/wizard.sh` §480-498 — VRAM guard check при интерактивном выборе
- `lib/wizard.sh` §547-560 — NON_INTERACTIVE VRAM check

### Model list
- `lib/wizard.sh` §358-378 — _get_vllm_vram_req() case statement
- `lib/wizard.sh` §381-500 — _wizard_vllm_model() полная функция
- `lib/wizard.sh` §383 — vram_req array (должна совпадать с _get_vllm_vram_req)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `_get_vllm_vram_req()` — уже существует per-model lookup, не трогать
- `_vllm_line()` — helper для форматирования строк меню, не трогать
- `EMBED_PROVIDER` и `ENABLE_RERANKER` — переменные доступны к моменту вызова _wizard_vllm_model()

### Established Patterns
- readonly constants для offsets (текущий паттерн → заменяем на функцию)
- VRAM guard: effective_vram = raw - offset → compare → warn/block
- 3 места используют offset: recommended tag (§390), guard (§480), NON_INTERACTIVE (§547)

### Integration Points
- _wizard_vllm_model() вызывается после _wizard_llm_provider() в run_wizard()
- К этому моменту EMBED_PROVIDER и ENABLE_RERANKER уже установлены (wizard flow: profile→llm→embed→reranker→vllm)
- Порядок: _wizard_embed_provider → _wizard_embedding_model → _wizard_reranker_model → _wizard_llm_provider → _wizard_llm_model/_wizard_vllm_model

</code_context>

<specifics>
## Specific Ideas

- Минимальные изменения: заменить 2 readonly на 1 функцию, обновить 3 callsite
- Если EMBED_PROVIDER ещё не установлен к моменту вызова — fallback на +2 GB (безопасный default)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 23-llm-model-list-effective-vram*
*Context gathered: 2026-03-23 via auto-mode*
