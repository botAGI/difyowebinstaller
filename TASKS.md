# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.  
> Кодер: перед началом работы делай `git pull` и читай этот файл.  
> После фикса — коммить и пуш. Gbot подтянет, задеплоит, протестирует, обновит статусы.

---

## Текущий статус: 23/23 healthy (после ручного docker start)

**Последний тест:** 2026-03-16 13:42 PDT  
**Сервер:** ragbot@192.168.50.26 (Ubuntu 24.04, Docker 29.3.0, RTX 5070 Ti)  
**Коммит:** c893f62  
**Режим установки:** интерактивный (визард)  
**Параметры:** lan / AGMind / weaviate / ETL enhanced / qwen2.5:7b / bge-m3 / monitoring local

---

## Открытые задачи

### 🔴 TASK-005: 9 контейнеров застревают в "Created" после docker compose up
**Баг:** BUG-015 (новый)  
**Симптом:** После завершения install.sh следующие контейнеры НЕ стартуют (статус "Created"):
- agmind-sandbox, agmind-plugin-daemon, agmind-api, agmind-worker
- agmind-promtail, agmind-grafana, agmind-pipeline, agmind-openwebui, agmind-nginx

**Контейнеры которые стартуют нормально (14):**
- db, redis, web, docling, loki, portainer, prometheus, weaviate, ollama, alertmanager, cadvisor, node-exporter, ssrf-proxy, xinference

**Ручной workaround:** `docker start agmind-sandbox agmind-plugin-daemon agmind-api agmind-worker agmind-promtail agmind-grafana agmind-pipeline agmind-openwebui agmind-nginx` — после этого все 23 healthy.

**Вероятная причина:** depends_on с condition: service_healthy — docker compose up завершается до того как все зависимости станут healthy. Или install.sh убивает docker compose процесс до завершения каскада.

**Приоритет:** 🔴 Критический — без ручного вмешательства система не работает

### 🟡 TASK-002: cAdvisor не видит имена контейнеров
**Баг:** BUG-011  
**Коммит:** 90776b3 (попытка фикса: docker.sock + --docker_only + --store_container_labels)  
**Статус:** ❌ НЕ РЕШЕНО  
**Тест:** `curl -sf http://localhost:8080/metrics | grep 'container_last_seen.*name='` → пусто  
**Влияние:** Grafana container dashboards показывают "No data"  
**Примечание:** Docker 29.3.0 + overlayfs (containerd snapshotter). cAdvisor v0.52.1 всё ещё не может прочитать container metadata. Возможно нужен альтернативный подход: Docker API exporter вместо cAdvisor, или cAdvisor с `--containerd=/run/containerd/containerd.sock`.

### 🔴 TASK-004: import.py — провижонинг моделей и плагинов
**Баги:** BUG-007, BUG-008  
**Статус:** Отложено (API-level changes)  
**Описание:** import.py не работает без ручной настройки моделей в Dify UI

### 🟡 TASK-006: non-interactive режим не принимает CLI параметры
**Баг:** Обнаружен при деплое  
**Описание:** `install.sh --non-interactive` парсит только `--non-interactive` флаг. Параметры типа `--profile lan --llm qwen2.5:7b --monitoring local` игнорируются.  
**Текущий обход:** env переменные (DEPLOY_PROFILE, LLM_MODEL и т.д.) ИЛИ интерактивный режим.  
**Рекомендация:** Добавить парсинг CLI аргументов: `--profile`, `--llm`, `--embedding`, `--monitoring`, `--etl`, `--company`, `--admin`

---

## Завершённые задачи

- ✅ BUG-009: Loki delete_request_store (коммит 8dc5ae2)
- ✅ BUG-010: Promtail healthcheck wget → promtail -check-syntax (коммит 90776b3) — **ПРОВЕРЕНО НА СЕРВЕРЕ, РАБОТАЕТ**
- ✅ BUG-013: Grafana provisioning dirs (коммит 90776b3) — **ПРОВЕРЕНО**
- ✅ BUG-014: install.sh health verification (коммит 90776b3)
- ✅ TASK-003: cAdvisor wget проверен — есть в образе

---

_Обновлено: 2026-03-16 13:47 PDT — Gbot (автоматический деплой-тест)_
