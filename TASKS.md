# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.

---

## Текущий статус: ⚠️ Плагины работают, модели timeout — один фикс

**Последний тест:** 2026-03-16 17:00 PDT (деплой #9)  
**Коммит:** a500d07  
**Exit code:** 0

---

## 🔴 TASK-011: import.py — sleep после плагинов + передача модели

**Приоритет:** 🔴 Критический — единственный оставшийся блокер

### Что произошло в деплое #9

Плагины установились **отлично** (все 3 с GitHub). Но шаг "Модели" упал с таймаутом:
```
--- Плагины ---
  ✓ langgenius/ollama installed
  ✓ langgenius/xinference installed
  ✓ s20ss/docling installed

--- Модели ---
  ⚠ Plugin/model setup failed: timed out
```

### Причина: гонка (race condition)

`install_plugins_from_github()` возвращает `True` когда task status = `success`. Но plugin_daemon ещё компилирует Python runtime (docling ~2 мин). API endpoint `/model-providers/langgenius/ollama/ollama/models/credentials` отвечает ошибкой пока runtime не "осядет".

### Фикс 1: sleep после плагинов

**Файл:** `workflows/import.py`, после вызова `install_plugins_from_github()` (строка ~970)

```python
if plugin_specs:
    plugins_ok = install_plugins_from_github(client, plugin_specs)
else:
    print("  No plugins to install")

# === ДОБАВИТЬ ===
if plugins_ok:
    print("  Waiting for plugin runtimes to initialize...")
    time.sleep(30)  # plugin_daemon needs time to compile/start runtimes
```

### Фикс 2: retry в add_model / set_default

Лучше: обернуть `add_model()` в retry loop (3 попытки, 15с пауза). Это надёжнее чем фиксированный sleep.

```python
def _retry(fn, retries=3, delay=15, label=""):
    for attempt in range(retries):
        try:
            return fn()
        except Exception as e:
            if attempt < retries - 1:
                print(f"  Retry {attempt+1}/{retries} for {label}: {e}")
                time.sleep(delay)
            else:
                raise
```

### Фикс 3: workflow.sh уже передаёт правильную модель

Проверил: `lib/workflow.sh` передаёт `--model "$llm_model"` где `llm_model="${LLM_MODEL:-qwen2.5:14b}"`.

**Проблема:** Fallback `qwen2.5:14b` в workflow.sh. Если `LLM_MODEL` не экспортирована как env var — возьмёт 14b.

**Проверить:** что install.sh экспортирует `LLM_MODEL` перед вызовом `import_workflow`. Grep показал: `LLM_MODEL=qwen2.5:7b` есть в .env, но import_workflow может не видеть его.

**Фикс:** В `import_workflow()` (lib/workflow.sh строка 53):
```bash
# Явно прочитать из .env если переменная не установлена
if [[ -z "${LLM_MODEL:-}" && -f "${INSTALL_DIR}/docker/.env" ]]; then
    LLM_MODEL=$(grep '^LLM_MODEL=' "${INSTALL_DIR}/docker/.env" | cut -d= -f2-)
fi
```

### Фикс 4: rag-assistant.json — reranking

В workflow JSON: `"reranking_enable": false`. Если пользователь выбрал ETL enhanced с Xinference, `patch_workflow()` должен включить reranking.

Проверить: есть ли в `patch_workflow()` логика для reranking_enable.

---

## ✅ TASK-010: Плагины с GitHub — ЗАКРЫТ ✅

Деплой #9 подтвердил:
- `dify-official-plugins` клонируется
- ollama + xinference собираются в .difypkg
- docling скачивается готовым
- Upload + install через API работает
- `FORCE_VERIFYING_SIGNATURE=false` в шаблонах env ✅

---

## ✅ Все остальные задачи закрыты

TASK-009, TASK-002, BUG-009–BUG-018, TASK-003/005/007/008 — закрыты в деплоях #3-9.

---

_Обновлено: 2026-03-16 17:15 PDT — Gbot (деплой #9, коммит a500d07)_
