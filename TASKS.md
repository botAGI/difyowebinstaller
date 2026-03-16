# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.  
> Кодер: перед началом работы делай `git pull` и читай этот файл.  
> После фикса — коммить и пуш. Gbot подтянет, задеплоит, протестирует, обновит статусы.

---

## Текущий статус: ⚠️ 33/33 up, но install.sh crashed на шаге 8/11

**Последний тест:** 2026-03-16 14:05 PDT (деплой #4)  
**Сервер:** ragbot@192.168.50.26 (Ubuntu 24.04, Docker 29.3.0, RTX 5070 Ti)  
**Коммит:** 40b35d9  
**Режим установки:** интерактивный (визард)  
**Параметры:** lan / AGMind / weaviate / ETL enhanced / qwen2.5:7b / bge-m3 / monitoring local

---

## Открытые задачи

### 🟢 TASK-005: 9 контейнеров застревают в "Created" после docker compose up
**Баг:** BUG-015  
**Статус:** ✅ **ИСПРАВЛЕНО** — коммит 40b35d9  
**Результат деплоя:** Все 33 контейнера поднялись автоматически. Retry loop из фикса сработал, ручной `docker start` больше не требуется.

---

### 🔴 TASK-007: Open WebUI admin provision использует wget вместо curl
**Баг:** BUG-016 (новый)  
**Файл:** `scripts/deploy/create_openwebui_admin.sh`  
**Симптом:** Скрипт вызывает `wget --spider http://localhost:8080/health` внутри контейнера Open WebUI. Контейнер содержит только `curl`, `wget` отсутствует. Результат: 15 попыток healthcheck → все fail → админ пользователь не создаётся.

**Лог:**
```
/opt/agmind/scripts/deploy/create_openwebui_admin.sh: line 32: wget: command not found
```

**Фикс:** Заменить `wget --spider` на `curl -sf` в `create_openwebui_admin.sh`.

**Приоритет:** 🔴 Критический — без админа Open WebUI нельзя использовать (нет логина).

---

### 🔴 TASK-004: import.py — провижонинг моделей и плагинов
**Баги:** BUG-007, BUG-008  
**Статус:** ❌ **БЛОКИРУЕТ УСТАНОВКУ** — install.sh падает на шаге 8/11 (Import workflow)  
**Новый симптом:** Dify marketplace вернул 403 Forbidden → плагины `langgenius/ollama` и `langgenius/xinference` не загружены → provider не существует → модели не регистрируются → import.py крашится при попытке установить дефолтные модели.

**Лог (деплой #4):**
```
⚠ Cannot fetch marketplace manifest: HTTP Error 403: Forbidden
⚠ Marketplace unreachable — plugins must be installed manually
HTTP 400: Provider langgenius/ollama/ollama does not exist.
HTTP 400: Provider langgenius/xinference/xinference does not exist.
urllib.error.HTTPError: HTTP Error 400: BAD REQUEST
```

**Результат:** install.sh прервался (код 1). Контейнеры работают, но workflow не импортирован, Dify не настроена.

**Рекомендация:** import.py должен устанавливать плагины вручную (не полагаться на marketplace API), либо делать graceful fallback когда модели уже сконфигурированы вручную. Или: перенести model provisioning в post-install manual шаг.

**Приоритет:** 🔴 Критический — install.sh не завершается до конца из-за этого бага.

---

### 🟡 TASK-002: cAdvisor не видит имена контейнеров
**Баг:** BUG-011  
**Коммит:** 90776b3 (попытка фикса: docker.sock + --docker_only + --store_container_labels)  
**Статус:** ❌ НЕ РЕШЕНО  
**Тест:** `curl -sf http://localhost:8080/metrics | grep 'container_last_seen.*name='` → пусто  
**Влияние:** Grafana container dashboards показывают "No data"  
**Примечание:** Docker 29.3.0 + overlayfs (containerd snapshotter). cAdvisor v0.52.1 всё ещё не может прочитать container metadata. Возможно нужен альтернативный подход: Docker API exporter вместо cAdvisor, или cAdvisor с `--containerd=/run/containerd/containerd.sock`.

---

### 🟡 TASK-006: non-interactive режим не принимает CLI параметры
**Баг:** Обнаружен при деплое  
**Статус:** ✅ **ЧАСТИЧНО ИСПРАВЛЕНО** — коммит 40b35d9 (CLI args работают в интерактивном режиме)  
**Описание:** `install.sh --non-interactive` парсит только `--non-interactive` флаг. Параметры типа `--profile lan --llm qwen2.5:7b --monitoring local` игнорируются.  
**Текущий обход:** env переменные (DEPLOY_PROFILE, LLM_MODEL и т.д.) ИЛИ интерактивный режим (рекомендуется).  
**Рекомендация:** Добавить парсинг CLI аргументов в non-interactive path, если требуется полная автоматизация.

---

## Завершённые задачи

- ✅ BUG-009: Loki delete_request_store (коммит 8dc5ae2)
- ✅ BUG-010: Promtail healthcheck wget → promtail -check-syntax (коммит 90776b3) — **ПРОВЕРЕНО НА СЕРВЕРЕ, РАБОТАЕТ**
- ✅ BUG-013: Grafana provisioning dirs (коммит 90776b3) — **ПРОВЕРЕНО**
- ✅ BUG-014: install.sh health verification (коммит 90776b3)
- ✅ TASK-003: cAdvisor wget проверен — есть в образе
- ✅ TASK-005: 9 контейнеров в Created (коммит 40b35d9) — **retry loop работает, все 33 up автоматически**

---

_Обновлено: 2026-03-16 14:08 PDT — Gbot (деплой #4, коммит 40b35d9)_
