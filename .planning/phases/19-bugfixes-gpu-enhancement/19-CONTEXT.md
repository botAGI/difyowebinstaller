# Phase 19: Bugfixes + GPU Enhancement - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Четыре независимых исправления до начала крупных изменений v2.5:
1. preflight_checks() не показывает ложных WARN для портов, занятых agmind
2. VRAM guard учитывает TEI offset при расчёте доступной VRAM
3. Xinference bce-reranker помечен как broken, reranker отключён по умолчанию
4. `agmind gpu status` показывает имена контейнеров вместо сырых PID

</domain>

<decisions>
## Implementation Decisions

### Preflight port filter (BFIX-43)
- Определять «свои» контейнеры через `docker compose -f ... ps nginx` — если nginx up, порты 80/443 наши
- Если порт занят agmind-контейнером — вывод `[PASS] Port 80: in use (agmind)` вместо WARN
- Если порт занят чужим процессом — оставить существующий `[WARN] Port 80: in use`

### VRAM guard TEI offset (BFIX-45)
- TEI offset захардкожен как константа 2 GB (не конфигурируемый)
- `effective_vram = gpu_vram - 2` — применяется везде: и в NON_INTERACTIVE, и в интерактивном визарде
- В NON_INTERACTIVE при vllm — hard fail (exit 1) если модель > effective_vram
- В интерактивном визарде — предупреждение с effective_vram в тексте

### Xinference reranker (BFIX-44)
- Отключить reranker по умолчанию — bce-reranker-base_v1 broken в Xinference v2.3.0
- Визард ETL_ENHANCED: опция 2 становится «Да — Docling» без упоминания reranker
- В env templates: закомментировать RERANK_MODEL_NAME с пометкой `# BROKEN in xinference v2.3.0`
- `load_reranker()` в models.sh: добавить log_warn что reranker disabled (broken), не пытаться загружать модель
- Reranker вернётся в фазе 22 через TEI

### GPU status container map (GPUX-01)
- Маппинг PID→контейнер через `docker top` по всем agmind-контейнерам
- Рядом с контейнером показывать модель из .env (VLLM_MODEL / EMBEDDING_MODEL)
- Формат: `agmind-vllm-1 (Qwen2.5-14B)  | 8192 MiB` вместо `PID 12345 | python3 | 8192 MiB`
- Если PID не маппится на контейнер — показывать PID + process_name с пометкой `(non-agmind)`

### Claude's Discretion
- Внутренняя реализация docker top lookup (кеширование, формат вызова)
- Формат вывода warning текстов
- Порядок проверок внутри preflight_checks()

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Preflight checks
- `lib/detect.sh` §346-496 — preflight_checks() function, port check at lines 487-496

### VRAM guard
- `lib/wizard.sh` §496-542 — _wizard_llm_model() NON_INTERACTIVE VRAM guard (BFIX-41)
- `lib/wizard.sh` §462-494 — _wizard_vllm_model() interactive VRAM guard

### Xinference reranker
- `lib/models.sh` §147-183 — load_reranker() function
- `lib/wizard.sh` §196-203 — ETL_ENHANCED wizard step
- `templates/env.lan.template` §55-57 — Reranker env vars
- `templates/env.vps.template` §55-57 — Reranker env vars
- `templates/env.vpn.template` §55-57 — Reranker env vars
- `templates/env.offline.template` §55-57 — Reranker env vars

### GPU status
- `scripts/agmind.sh` §410-478 — _gpu_status() function, GPU processes at lines 463-477

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `_read_env()` in agmind.sh — reads .env values, reuse for model name lookup
- `docker compose -f "$COMPOSE_FILE" ps` — already used elsewhere in agmind.sh
- `_get_vllm_vram_req()` in wizard.sh — existing VRAM requirement lookup function

### Established Patterns
- VRAM guard pattern: `_get_vllm_vram_req()` returns int GB, compared with `DETECTED_GPU_VRAM / 1024`
- Port check: `ss -tlnp` / `lsof` dual approach in detect.sh
- Log functions: `log_warn`, `log_error`, `log_success`, `log_info` from common.sh

### Integration Points
- `preflight_checks()` called from `install.sh` phase 1
- `_wizard_llm_model()` called from `run_wizard()` in wizard.sh
- `_gpu_status()` called from `cmd_gpu()` in agmind.sh
- `load_reranker()` called from `download_models()` in models.sh

</code_context>

<specifics>
## Specific Ideas

No specific requirements — standard bugfix approaches apply.

</specifics>

<deferred>
## Deferred Ideas

- Полное удаление Xinference из docker-compose — Phase 20 (XINF-01)
- Отдельный profile для Docling — Phase 20 (XINF-03)
- Замена ETL_ENHANCED на ENABLE_DOCLING + ENABLE_RERANKER — Phase 20 (XINF-02)
- TEI-based reranker — Phase 22 (RNKR-01..03)

</deferred>

---

*Phase: 19-bugfixes-gpu-enhancement*
*Context gathered: 2026-03-23*
