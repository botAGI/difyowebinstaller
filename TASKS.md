# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.

---

## Текущий статус: ⚠️ Плагины и модели OK, но import.py крашится на KB create

**Последний тест:** 2026-03-17 04:42 PDT (деплой #10)  
**Коммит:** 999dc94  
**Exit code:** 0 (graceful fallback)

---

## 🔴 TASK-013: BUG-017 не починен — ollama pull падает на IPv6

**Приоритет:** 🔴 Критический — блокирует скачивание моделей на любом хосте без IPv6 маршрута

### Проблема

`lib/models.sh:43` в `pull_model()` перезаписывает `/etc/resolv.conf` внутри контейнера Ollama на `8.8.8.8`. Google DNS возвращает AAAA-записи для `registry.ollama.ai`. Go runtime в Ollama использует свой DNS resolver и **игнорирует** `sysctl net.ipv6.conf.all.disable_ipv6=1` — пытается коннект на IPv6 адрес → `connect: cannot assign requested address`.

Текущий "фикс" BUG-017 (sysctls в docker-compose) **не работает** — Go не использует ядерный сетевой стек для DNS resolution, у него свой userspace resolver.

### Воспроизведение

Любой хост без IPv6 маршрута (большинство домашних/офисных сетей):
```
docker exec agmind-ollama ollama pull qwen2.5:7b
→ dial tcp [2606:4700:3034::ac43:b6e5]:443: connect: cannot assign requested address
```

### Требуемый фикс

Убрать хак с перезаписью resolv.conf. Вместо этого — **одно из двух** (оба надёжные, можно комбинировать):

**Вариант A (рекомендуемый): переменная окружения Go**

Добавить в docker-compose секцию ollama:
```yaml
environment:
  GODEBUG: "netdns=cgo"
```
Это заставляет Go использовать системный (cgo) DNS resolver, который **уважает** sysctl `disable_ipv6`. В связке с уже стоящим `sysctls: net.ipv6.conf.all.disable_ipv6=1` — решает проблему полностью.

**Вариант B (belt-and-suspenders): force IPv4 в pull_model()**

В `lib/models.sh` функция `pull_model()` — вместо перезаписи resolv.conf, резолвить адрес на хосте и прокидывать через `extra_hosts`:
```bash
# В pull_model() — заменить текущий docker exec с перезаписью resolv.conf на:
docker exec agmind-ollama ollama pull "$1"
```
А в шаблоне docker-compose для ollama добавить:
```yaml
extra_hosts:
  - "registry.ollama.ai:$(dig +short A registry.ollama.ai | head -1)"
```
Или статически (Cloudflare стабилен):
```yaml
extra_hosts:
  - "registry.ollama.ai:104.21.75.227"
```

### Что убрать

1. `lib/models.sh:43` — удалить `echo "nameserver ..." > /etc/resolv.conf` из `pull_model()`. Просто `docker exec agmind-ollama ollama pull "$1"`.
2. `lib/docker.sh:205` — DOCKER_DNS хак для resolv.conf больше не нужен (если выбран вариант A).

### Как проверить

```bash
# На хосте без IPv6:
docker exec agmind-ollama ollama pull qwen2.5:7b
# Должно скачать без ошибок
```

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

## 🟡 TASK-014: Post-install summary — показывать ВСЕ credentials и ссылки

**Приоритет:** 🟡 Важный — UX, безопасность

### Проблема

После установки `phase_complete()` показывает баннер, но:
1. **Пароль скрыт** — написано `(см. /opt/agmind/.admin_password)`, а файл root-only. Пользователь уже root в момент установки — нет причин скрывать.
2. **Grafana пароль скрыт** — написано `(см. GRAFANA_ADMIN_PASSWORD в .env)`. Опять grep.
3. **DIFY_API_KEY не показан** — и вообще не записан в .env (отдельный баг, см. ниже).
4. **Нет сводки по безопасности** — какие порты открыты, что доступно извне, UFW статус.
5. **Нет сводки по контейнерам** — сколько up, сколько failed.

### Что нужно

`phase_complete()` должна после баннера выводить **полный блок credentials и ссылок** — всё в одном месте, copy-paste ready:

```
╔══════════════════════════════════════════════════════╗
║                 CREDENTIALS & URLS                   ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  Open WebUI:    http://192.168.50.26                 ║
║  Dify Console:  http://192.168.50.26:3000            ║
║  Grafana:       http://192.168.50.26:3001            ║
║  Portainer:     https://192.168.50.26:9443           ║
║                                                      ║
║  Admin email:   admin@admin.com                      ║
║  Admin pass:    dQgucxIDBbDr0Ilz                     ║
║  Grafana pass:  HPhvCxTMbSXPwK2x                    ║
║  Dify API key:  app-xxxxxxxxxxxxxxxx                 ║
║                                                      ║
║  LLM:           qwen2.5:7b (Ollama)                  ║
║  Embedding:     bge-m3 (Ollama)                      ║
║  Reranker:      bce-reranker-base_v1 (Xinference)    ║
║  Vector DB:     Weaviate                             ║
║                                                      ║
║  Containers:    23/23 healthy                        ║
║  Plugins:       ollama ✅ xinference ✅ docling ✅      ║
║                                                      ║
╚══════════════════════════════════════════════════════╝
```

Дополнительно — **записать эту же сводку в файл** `${INSTALL_DIR}/credentials.txt` (chmod 600) для будущего доступа.

### Связанный баг: DIFY_API_KEY не записывается в .env

`import.py` создаёт API key для приложения, но **не пишет его** в `/opt/agmind/docker/.env` (поле `DIFY_API_KEY=` остаётся пустым). Из-за этого:
- Pipeline контейнер не может подключиться к Dify
- Open WebUI не видит RAG-ассистента как модель
- Вся цепочка Open WebUI → Pipeline → Dify сломана

**Фикс:** `import.py` после создания API key должен:
1. Записать ключ в `.env`: `sed -i "s/^DIFY_API_KEY=.*/DIFY_API_KEY=${api_key}/" /opt/agmind/docker/.env`
2. Перезапустить pipeline + openwebui: `docker compose restart pipeline openwebui`
3. Вернуть ключ в stdout для `phase_complete()`

### Как проверить

После установки:
1. В терминале видны ВСЕ credentials и ссылки
2. `cat /opt/agmind/credentials.txt` содержит то же самое
3. `grep DIFY_API_KEY /opt/agmind/docker/.env` → непустое значение
4. `curl http://localhost:9099/v1/models` → список содержит RAG-ассистента

---

## 🟡 TASK-015: import.py — рестарт pipeline + openwebui после записи DIFY_API_KEY

**Приоритет:** 🟡 Важный — без этого Open WebUI не видит RAG-ассистента

### Проблема

`save_api_key()` (строка 853) правильно записывает ключ в `.dify_service_api_key` и патчит `DIFY_API_KEY=` в `.env`. Но **pipeline и openwebui** уже запущены с пустым `DIFY_API_KEY` — они не перечитывают `.env` автоматически.

Результат: Open WebUI → Pipeline → Dify цепочка сломана. RAG-ассистент не появляется в списке моделей Open WebUI. Пользователь думает что установка сломана.

### Требуемый фикс

После `save_api_key()` в `main()` (после строки 1114) добавить рестарт двух контейнеров:

```python
# --- Step 20: Restart pipeline + openwebui to pick up DIFY_API_KEY ---
print("  Restarting pipeline + openwebui...")
compose_dir = os.path.join(args.install_dir, "docker")
subprocess.run(
    ["docker", "compose", "-f", f"{compose_dir}/docker-compose.yml",
     "restart", "pipeline", "openwebui"],
    capture_output=True, timeout=120
)
print("  Pipeline + OpenWebUI restarted with DIFY_API_KEY")
```

### Как проверить

После установки:
```bash
grep DIFY_API_KEY /opt/agmind/docker/.env
# → DIFY_API_KEY=app-xxxxxxxxxxxxxxxx

curl -s http://localhost:9099/v1/models | python3 -m json.tool
# → должен содержать модель "Ассистент AGMind" (или как назван app)
```

### Заметка

Код `save_api_key()` и `create_service_api_key()` уже реализован и выглядит корректно. В последнем деплое файл `.dify_service_api_key` НЕ создался — вероятно import.py упал раньше (до TASK-012 фикса). После деплоя с новым кодом (TASK-012 + TASK-013) нужно проверить, доходит ли до шага 18.

---

_Обновлено: 2026-03-17 09:55 PDT — Gbot (TASK-015 добавлен)_
