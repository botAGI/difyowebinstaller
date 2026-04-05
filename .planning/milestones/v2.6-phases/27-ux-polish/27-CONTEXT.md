# Phase 27: UX Polish - Context

**Gathered:** 2026-03-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Streaming progress при скачивании моделей для всех провайдеров (Ollama, vLLM, TEI). Оператор видит реальный прогресс вместо пустого экрана. При таймауте — graceful warning с инструкцией по ручному pull.

**Вырезано из скоупа:** `--dry-run` режим install.sh (UXPL-02) — перенесён в бэклог v3.0+.

</domain>

<decisions>
## Implementation Decisions

### Streaming подход по провайдерам
- **Ollama:** оставить текущий `docker exec -t ollama pull` — нативный прогресс Ollama уже работает
- **vLLM / TEI:** стримить raw `docker logs -f` контейнера — показывает HuggingFace download строки как есть
- Никакого парсинга процентов или кастомного progress bar — raw лог достаточен

### TTY / non-TTY поведение
- Streaming логов только в TTY (проверка `[ -t 1 ]`)
- В non-TTY — только статусные сообщения: "Downloading model X...", "Model ready" / "Timeout"
- Обоснование: Ollama progress использует `\r` для перезаписи строки, в non-TTY это засоряет лог

### Таймаут и recovery
- При таймауте контейнер **не останавливается** — модель продолжает скачиваться в фоне
- Инсталлятор **продолжает** дальше с следующими фазами (WARNING, не FATAL)
- Warning сообщение содержит:
  - Для Ollama: `docker exec agmind-ollama ollama pull <model>`
  - Для vLLM: `docker logs -f agmind-vllm` (чтобы следить за прогрессом)
  - Для TEI: `docker logs -f agmind-tei` (аналогично)
  - Примечание: `agmind model pull` команда не существует — показывать прямые docker команды

### Claude's Discretion
- Конкретная реализация `docker logs -f` streaming (timeout механика, signal handling)
- Формат статусных сообщений при non-TTY
- Как определять что vLLM/TEI контейнер завершил скачивание модели (по healthcheck, по строке в логах, или по timeout)

</decisions>

<canonical_refs>
## Canonical References

No external specs — requirements fully captured in decisions above.

### Existing code
- `lib/models.sh` — текущая реализация pull_model(), download_models(), MODEL_SIZES
- `install.sh:41` — TIMEOUT_MODELS=1200 (20 мин)
- `install.sh:142,551` — phase_models() и run_phase_with_timeout интеграция
- `scripts/agmind.sh` — CLI (нет команды `model pull`)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `pull_model()` в lib/models.sh — уже обрабатывает TTY fallback (`docker exec -t` → `docker exec`)
- `MODEL_SIZES` ассоциативный массив — размеры для вывода оператору
- `wait_for_ollama()` — ожидание готовности Ollama API
- `run_phase_with_timeout` в install.sh — обёртка с таймаутом для фаз

### Established Patterns
- TTY detection: `docker exec -t` уже используется в pull_model()
- Graceful timeout: Phase 15 добавляла graceful timeout для моделей
- Health wait: Phase 25 добавляла streaming docker logs для health checks

### Integration Points
- `download_models()` в lib/models.sh — основная точка модификации
- `phase_models()` / `phase_models_graceful()` в install.sh — обёртка вызова
- vLLM/TEI контейнеры: `agmind-vllm`, `agmind-tei` — имена для `docker logs -f`

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches.

</specifics>

<deferred>
## Deferred Ideas

- **UXPL-02: install.sh --dry-run** — перенесён в бэклог v3.0+. Оператор считает что dry-run не нужен на текущем этапе.
- **agmind model pull CLI команда** — сейчас нет, может быть отдельной фичей в будущем.

</deferred>

---

*Phase: 27-ux-polish*
*Context gathered: 2026-03-25*
