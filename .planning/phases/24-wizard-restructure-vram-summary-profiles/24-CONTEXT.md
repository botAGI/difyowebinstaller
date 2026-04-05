# Phase 24: Wizard Restructure + VRAM Summary + Profiles - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning
**Source:** Auto-mode (recommended defaults)

<domain>
## Phase Boundary

Перестроить порядок шагов визарда согласно WIZS-01, добавить VRAM план в сводку (WIZS-02), убедиться что COMPOSE_PROFILES корректно формируется со всеми новыми профилями (PROF-01).

</domain>

<decisions>
## Implementation Decisions

### Новый порядок шагов (WIZS-01)
- Целевой порядок из REQUIREMENTS: Профиль → LLM → Модель LLM → Embeddings → Reranker → VectorDB → Docling → Мониторинг → TLS → Алерты → UFW → Tunnel → Бэкапы → Сводка
- Маппинг текущих функций на целевой порядок:
  1. _wizard_profile (Профиль)
  2. _wizard_security_defaults (автоматический, привязан к профилю — оставить сразу после)
  3. _wizard_admin_ui (привязан к domain — группировать вместе)
  4. _wizard_domain (домен — нужен рано для TLS)
  5. _wizard_llm_provider (LLM)
  6. _wizard_llm_model (Модель LLM — вызывает ollama/vllm sub-wizard)
  7. _wizard_embed_provider (Embeddings provider)
  8. _wizard_embedding_model (Embeddings model)
  9. _wizard_reranker_model (Reranker)
  10. _wizard_vector_store (VectorDB — перемещён после reranker)
  11. _wizard_etl (Docling — перемещён после VectorDB)
  12. _wizard_hf_token (HF token — нужен после выбора всех моделей)
  13. _wizard_offline_warning (предупреждение для offline)
  14. _wizard_tls (TLS)
  15. _wizard_monitoring (Мониторинг)
  16. _wizard_alerts (Алерты)
  17. _wizard_security (UFW/Fail2ban/Authelia)
  18. _wizard_tunnel (Tunnel)
  19. _wizard_backups (Бэкапы)
  20. _wizard_summary (Сводка с VRAM планом)
  21. _wizard_confirm (Подтверждение)
- Главные перестановки: VectorDB и Docling (ETL) перемещаются с позиции 5-6 на позицию 10-11

### VRAM план в сводке (WIZS-02)
- Добавить блок VRAM в _wizard_summary() после основных строк
- Формат:
  ```
  --- VRAM план ---
  vLLM:       X GB   (model-name)
  TEI-embed:  2 GB   (BAAI/bge-m3)
  TEI-rerank: 1 GB   (BAAI/bge-reranker-v2-m3)
  ─────────────────
  Итого:      Y GB / Z GB доступно
  ```
- Показывать только если LLM_PROVIDER=vllm (Ollama управляет VRAM сам)
- TEI-embed: показывать только если EMBED_PROVIDER=tei
- TEI-rerank: показывать только если ENABLE_RERANKER=true
- Если total > available: жёлтое предупреждение "⚠ VRAM бюджет превышен! Возможен OOM."
- Если GPU не определён: "GPU VRAM не определён — проверьте вручную"
- Для получения vram_req vLLM модели: использовать _get_vllm_vram_req()

### COMPOSE_PROFILES (PROF-01)
- build_compose_profiles() УЖЕ корректно обрабатывает tei, reranker, docling (Phases 20-22)
- Задача: верифицировать что NON_INTERACTIVE path формирует правильные профили
- Если обнаружатся проблемы — исправить, если нет — зафиксировать как "verified"

### Claude's Discretion
- Точное форматирование VRAM блока (цвета, отступы)
- Обработка edge case когда GPU не определён
- Размещение admin_ui/domain в потоке (до или после LLM)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Wizard flow
- `lib/wizard.sh` §1003-1040 — run_wizard() текущий порядок вызовов и exports
- `lib/wizard.sh` §967-997 — _wizard_summary() текущая сводка (добавить VRAM блок)

### VRAM
- `lib/wizard.sh` §350-361 — _get_vram_offset() динамический offset
- `lib/wizard.sh` §358-378 — _get_vllm_vram_req() per-model VRAM lookup
- `lib/detect.sh` — DETECTED_GPU_VRAM (сырое значение в МБ)

### Profiles
- `lib/compose.sh` §17-41 — build_compose_profiles() все профили
- `lib/config.sh` — записывает переменные в .env

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `_get_vram_offset()` — возвращает суммарный offset (TEI + reranker), использовать для VRAM summary
- `_get_vllm_vram_req()` — возвращает VRAM requirement для vLLM модели
- `DETECTED_GPU_VRAM` — raw GPU VRAM в МБ из detect.sh
- `build_compose_profiles()` — уже обрабатывает tei, reranker, docling

### Established Patterns
- Wizard summary: echo с цветами (CYAN, YELLOW, NC)
- VRAM guard: effective_vram = raw - offset, warn if exceeded
- NON_INTERACTIVE: проверяет env vars, не показывает меню

### Integration Points
- run_wizard(): порядок вызовов — единственное место для перестановки
- _wizard_summary(): добавить VRAM план перед _wizard_confirm()
- build_compose_profiles(): может потребоваться проверка для NON_INTERACTIVE

</code_context>

<specifics>
## Specific Ideas

- Перестановка шагов: только изменение порядка вызовов в run_wizard(), функции не зависят друг от друга (кроме security_defaults ← profile)
- VRAM summary: аналогично формату VRAM guard warning, но в виде таблицы
- Минимальные изменения: порядок в run_wizard() + VRAM блок в summary

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 24-wizard-restructure-vram-summary-profiles*
*Context gathered: 2026-03-23 via auto-mode*
