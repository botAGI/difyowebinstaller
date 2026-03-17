# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.

---

## Текущий статус: ⚠️ Плагины и модели OK, но import.py крашится на KB create

**Последний тест:** 2026-03-17 04:42 PDT (деплой #10)  
**Коммит:** 999dc94  
**Exit code:** 0 (graceful fallback)

---

## 🔴 TASK-012: import.py — add_model missing required fields

**Приоритет:** 🔴 Критический — блокирует автоматическую настройку

### Что произошло в деплое #10

Плагины установились идеально (все 3 с GitHub). Sleep 30с + retry сработали. Но:

#### Ошибка 1: add_model для embedding (bge-m3)
```
HTTP 400 POST .../langgenius/ollama/ollama/models/credentials:
{"code":"invalid_param","message":"Variable context_size is required","status":400}
```
**Причина:** API Dify 1.13 требует `context_size` в credentials для Ollama embedding. Текущий код передаёт только `{"base_url": "http://ollama:11434"}`.

**Фикс:** Добавить `context_size` в credentials для embedding:
```python
# В блоке add_model для embedding (~строка 1012)
client.add_model(
    args.embedding_provider,
    args.embedding,
    "text-embedding",
    {
        "base_url": args.ollama_url,
        "context_size": "8192",  # ← ДОБАВИТЬ
    },
)
```

#### Ошибка 2: add_model для reranker (Xinference)
```
HTTP 400 POST .../langgenius/xinference/xinference/models/credentials:
{"code":"invalid_param","message":"Variable invoke_timeout is required","status":400}
```
**Причина:** API требует `invoke_timeout` для Xinference reranker.

**Фикс:** Добавить `invoke_timeout` в credentials для reranker:
```python
# В блоке add_model для reranker (~строка 1030)
client.add_model(
    args.rerank_provider,
    args.rerank_model,
    "rerank",
    {
        "server_url": args.xinference_url,
        "model_uid": args.rerank_model,
        "invoke_timeout": "60",  # ← ДОБАВИТЬ
    },
)
```

#### Ошибка 3: LLM тоже нуждается в context_size (вторичная)
```
HTTP 400 POST .../langgenius/ollama/ollama/models/credentials:
{"code":"invalid_param","message":"Variable context_size is required","status":400}
```
Первая попытка LLM прошла (видимо первый retry удалось), но логика не стабильная.

**Фикс:** Добавить `context_size` для LLM тоже:
```python
# В блоке add_model для LLM (~строка 1000)
client.add_model(
    args.model_provider,
    args.model,
    "llm",
    {
        "base_url": args.ollama_url,
        "mode": "chat",
        "context_size": "32768",  # ← ДОБАВИТЬ
        "max_tokens": "8192",
        "vision_support": "false",
        "function_call_support": "true",
    },
)
```

#### Следствие: KB create fails
```
HTTP 400 POST /console/api/datasets:
{"code":"invalid_param","message":"Default model not found for text-embedding","status":400}
```
Embedding не зарегистрирован → set_default для text-embedding не работает → KB create падает.

### Как проверить
После фикса: деплой на ragbot@192.168.50.26:
```bash
cd ~ && rm -rf difyowebinstaller && git clone https://github.com/botAGI/difyowebinstaller.git && cd difyowebinstaller
sudo rm -rf /var/lock/agmind-install.lock /tmp/agmind-install.lock /opt/agmind
docker stop $(docker ps -aq); docker rm $(docker ps -aq); docker volume prune -af; docker network prune -f
sudo bash install.sh
```
Ожидание: import.py проходит все шаги без ошибок, KB создана, workflow импортирован.

---

## ✅ TASK-011: sleep + retry — РАБОТАЕТ ✅

Деплой #10 подтвердил:
- sleep 30с после плагинов — OK
- retry 3×15с для add_model — OK (LLM добавлен с первой попытки)
- LLM_MODEL fallback qwen2.5:7b — OK
- workflow.sh читает .env — OK

## ✅ TASK-010: Плагины с GitHub — РАБОТАЕТ ✅

Деплой #10 подтвердил повторно: 3/3 плагина установлены.

## ✅ Все остальные задачи закрыты

TASK-002/003/004/005/007/008/009, BUG-009–BUG-018 — закрыты в деплоях #3-9.

---

## Статистика деплоя #10
- Контейнеры: 23/23 Up+Healthy
- Модели Ollama: qwen2.5:7b (4.7 GB), bge-m3 (1.2 GB)
- Xinference: bce-reranker-base_v1 (загружен, working)
- Плагины Dify: ollama ✅, xinference ✅, docling ✅
- cAdvisor name labels: 23 контейнеров с name=agmind-* ✅
- Prometheus targets: ✅
- Open WebUI: ✅ (http://192.168.50.26)
- Dify Console: ✅ (http://192.168.50.26:3000)
- Grafana: ✅ (http://192.168.50.26:3001)

---

_Обновлено: 2026-03-17 04:55 PDT — Gbot (деплой #10, коммит 999dc94)_
