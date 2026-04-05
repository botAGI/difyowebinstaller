---
phase: 23-llm-model-list-effective-vram
verified: 2026-03-23T10:30:00Z
status: passed
score: 4/4 must-haves verified
re_verification: false
---

# Phase 23: LLM Model List + Effective VRAM Verification Report

**Phase Goal:** Список моделей vLLM обновлён до 17 моделей с корректными AWQ/bf16/MoE секциями, VRAM рекомендации учитывают TEI offset для более точных рекомендаций.
**Verified:** 2026-03-23T10:30:00Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                                          | Status     | Evidence                                                                                    |
|----|----------------------------------------------------------------------------------------------------------------|------------|---------------------------------------------------------------------------------------------|
| 1  | VRAM offset динамически вычислен на основе EMBED_PROVIDER и ENABLE_RERANKER, не hardcoded константы           | VERIFIED | `_get_vram_offset()` существует на line 352; `TEI_VRAM_OFFSET` и `RERANKER_VRAM_OFFSET` — 0 вхождений |
| 2  | Все 3 callsite используют `_get_vram_offset()` вместо старых констант                                        | VERIFIED | Lines 402, 490, 554 — все три места вызывают `$(_get_vram_offset)`                          |
| 3  | Индексы vram_req[1-16] точно совпадают с case-значениями `_get_vllm_vram_req()`                              | VERIFIED | Массив `(0 5 6 10 10 20 16 16 16 16 28 28 28 48 140 12 4)` совпадает со всеми 16 case-ветками |
| 4  | MODEL_SIZES в models.sh покрывает все 16 моделей vLLM                                                        | VERIFIED | Все 16 моделей найдены с count=1 в `lib/models.sh` (lines 28-43)                           |

**Score:** 4/4 truths verified

---

### Required Artifacts

| Artifact       | Ожидаемое содержимое                            | Status     | Детали                                                                          |
|----------------|-------------------------------------------------|------------|---------------------------------------------------------------------------------|
| `lib/wizard.sh` | `_get_vram_offset()` function + updated callsites | VERIFIED | Функция на line 352-361; callsites на lines 402, 490, 554; `bash -n` проходит  |
| `lib/models.sh` | MODEL_SIZES для всех vLLM моделей               | VERIFIED | Все 16 вLLM-моделей присутствуют; `bash -n` проходит                           |

---

### Key Link Verification

| From                              | To                          | Via                                 | Status   | Детали                                               |
|-----------------------------------|-----------------------------|-------------------------------------|----------|------------------------------------------------------|
| `wizard.sh:_wizard_vllm_model`    | `wizard.sh:_get_vram_offset` | `vram_offset=$(_get_vram_offset)` callsite | WIRED | Line 402 — recommended-tag callsite; line 490 — interactive guard callsite |
| `wizard.sh:_wizard_llm_model`     | `wizard.sh:_get_vram_offset` | NON_INTERACTIVE VRAM guard          | WIRED    | Line 554 — `ni_vram_offset=$(_get_vram_offset)`     |

---

### Requirements Coverage

| Requirement | Source Plan   | Description                                                                                               | Status    | Evidence                                                                                          |
|-------------|---------------|-----------------------------------------------------------------------------------------------------------|-----------|---------------------------------------------------------------------------------------------------|
| LLMM-01     | 23-01-PLAN.md | Список моделей vLLM обновлён до 17 моделей (AWQ/bf16/MoE) с корректными VRAM requirements и TEI offset | SATISFIED | 16 numbered models + option 17 (custom) в меню wizard; все секции AWQ/bf16/MoE присутствуют; MODEL_SIZES полна |
| LLMM-02     | 23-01-PLAN.md | VRAM guard учитывает TEI offset (~2 GB) при расчёте effective_vram для рекомендации                     | SATISFIED | `_get_vram_offset()` добавляет +2 GB при `EMBED_PROVIDER=tei`; вызывается во всех 3 местах расчёта |

Оба требования помечены как Complete в REQUIREMENTS.md Traceability (`Phase 23`).

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | Не найдено |

Проверки `TODO/FIXME/placeholder/return null` и пустые реализации не обнаружены в изменённых секциях. Commit `2602e7a` задокументирован в SUMMARY.

---

### Human Verification Required

Нет. Логика полностью верифицируема статически: функция, массив VRAM и MODEL_SIZES доступны для grep/чтения. Визуальный вывод меню (цвет `[рекомендуется]`) не влияет на корректность цели фазы.

---

## Детали проверки

### Функция `_get_vram_offset()` (lib/wizard.sh lines 350-361)

```bash
_get_vram_offset() {
    local offset=0
    case "${EMBED_PROVIDER:-tei}" in
        tei) offset=$(( offset + 2 )) ;;
    esac
    [[ "${ENABLE_RERANKER:-}" == "true" ]] && offset=$(( offset + 1 ))
    echo "$offset"
}
```

- Default fallback `${EMBED_PROVIDER:-tei}` реализует "безопасный overestimate" согласно решению в CONTEXT.md.
- Старые константы `readonly TEI_VRAM_OFFSET=2` и `readonly RERANKER_VRAM_OFFSET=1` — **0 вхождений** в wizard.sh.

### Callsites

| Callsite              | Строка | Код                                      |
|-----------------------|--------|------------------------------------------|
| Recommended tag       | 402    | `vram_offset=$(_get_vram_offset)`        |
| Interactive VRAM guard | 490   | `vram_offset_guard=$(_get_vram_offset)`  |
| NON_INTERACTIVE guard | 554    | `ni_vram_offset=$(_get_vram_offset)`     |

Итого: 1 определение + 3 вызова = **4 вхождения** `_get_vram_offset` (соответствует acceptance criteria >= 4).

### vram_req vs _get_vllm_vram_req cross-check

| Idx | Модель                                   | vram_req | case value | Совпадение |
|-----|------------------------------------------|----------|------------|------------|
| 1   | Qwen2.5-7B-Instruct-AWQ                  | 5        | 5          | OK         |
| 2   | Qwen3-8B-AWQ                             | 6        | 6          | OK         |
| 3   | Qwen2.5-14B-Instruct-AWQ                 | 10       | 10         | OK         |
| 4   | Qwen3-14B-AWQ                            | 10       | 10         | OK         |
| 5   | Qwen2.5-32B-Instruct-AWQ                 | 20       | 20         | OK         |
| 6   | Qwen2.5-7B-Instruct                      | 16       | 16         | OK         |
| 7   | Qwen3-8B                                 | 16       | 16         | OK         |
| 8   | Mistral-7B-Instruct-v0.3                 | 16       | 16         | OK         |
| 9   | Llama-3.1-8B-Instruct                    | 16       | 16         | OK         |
| 10  | Qwen2.5-14B-Instruct                     | 28       | 28         | OK         |
| 11  | Qwen3-14B                                | 28       | 28         | OK         |
| 12  | microsoft/phi-4                          | 28       | 28         | OK         |
| 13  | Qwen2.5-32B-Instruct                     | 48       | 48         | OK         |
| 14  | Llama-3.3-70B-Instruct                   | 140      | 140        | OK         |
| 15  | Qwen3-Coder-Next-AWQ-4bit                | 12       | 12         | OK         |
| 16  | NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ       | 4        | 4          | OK         |

Все 16 значений совпадают.

### MODEL_SIZES coverage (lib/models.sh)

Все 16 vLLM-моделей присутствуют с разумными размерами (AWQ ~4-18 GB, bf16 ~14-131 GB). Четыре модели, требовавшие отдельной проверки согласно PLAN Task 2:
- `microsoft/phi-4` — 28 GB (найдено)
- `meta-llama/Llama-3.3-70B-Instruct` — 131 GB (найдено)
- `bullpoint/Qwen3-Coder-Next-AWQ-4bit` — 8 GB (найдено)
- `stelterlab/NVIDIA-Nemotron-3-Nano-30B-A3B-AWQ` — 2 GB (найдено)

### Синтаксическая проверка

- `bash -n lib/wizard.sh` — EXIT 0 (PASS)
- `bash -n lib/models.sh` — EXIT 0 (PASS)

---

## Итог

Цель фазы 23 **достигнута в полном объёме**:

1. `_get_vram_offset()` заменяет два hardcoded readonly-константы — динамический расчёт offset на основе конфигурации.
2. Все три callsite обновлены и подтверждены.
3. 16 vLLM-моделей консистентны во всех трёх источниках данных.
4. Оба требования LLMM-01 и LLMM-02 выполнены и подтверждены в REQUIREMENTS.md.

---

_Verified: 2026-03-23T10:30:00Z_
_Verifier: Claude (gsd-verifier)_
