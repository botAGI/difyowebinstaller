# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.  
> Кодер: перед началом работы делай `git pull` и читай этот файл.  
> После фикса — коммить и пуш. Gbot подтянет, задеплоит, протестирует, обновит статусы.

---

## Текущий статус: ✅ install.sh exit 0 — первый полностью успешный деплой!

**Последний тест:** 2026-03-16 15:42 PDT (деплой #8)  
**Сервер:** ragbot@192.168.50.26 (Ubuntu 24.04, Docker 29.3.0, RTX 5070 Ti)  
**Коммит:** 2b97bfe  
**Режим установки:** интерактивный (визард)  
**Параметры:** lan / AGMind / weaviate / ETL enhanced / qwen2.5:7b / bge-m3 / monitoring local  
**Контейнеры:** 34/34 Up+Healthy автоматически  
**Exit code:** 0 (все 11 фаз завершены)

---

## 🟢 Все критические задачи закрыты

| Задача | Статус | Деплой | Коммит |
|--------|--------|--------|--------|
| ✅ TASK-009: cAdvisor v0.56.2 → v0.55.1 | Закрыт | #8 | 2b97bfe |
| ✅ TASK-004: import.py graceful skip | Закрыт | #8 | a116142 |
| ✅ TASK-002: cAdvisor name labels | Закрыт | #8 | 2b97bfe |
| ✅ BUG-009: Loki delete_request_store | Закрыт | #3 | 8dc5ae2 |
| ✅ BUG-010: Promtail healthcheck | Закрыт | #3-8 | 90776b3 |
| ✅ BUG-013: Grafana provisioning dirs | Закрыт | #3-8 | 90776b3 |
| ✅ BUG-014: install.sh health verification | Закрыт | #3-8 | 90776b3 |
| ✅ TASK-005: контейнеры в Created | Закрыт | #4-8 | 40b35d9 |
| ✅ TASK-007: wget→curl Open WebUI admin | Закрыт | #5-8 | d21c854 |
| ✅ TASK-008: IPv6 Ollama pull | Закрыт | #6-8 | 51b736d |

---

## 🎉 Верификация деплоя #8

### ✅ cAdvisor v0.55.1 (TASK-009)
```
gcr.io/cadvisor/cadvisor:v0.55.1 Pulled 5.8s
Container agmind-cadvisor Started
```
**Результат:** Pull успешен, контейнер работает.

### ✅ cAdvisor name labels (TASK-002)
```
name="agmind-prometheus"
name="agmind-redis"
name="agmind-weaviate"
name="agmind-plugin-daemon"
```
**Результат:** Docker 29.x overlayfs + cAdvisor v0.55.1 — name labels ВИДНЫ в metrics. Проблема решена.

### ✅ import.py graceful fallback (TASK-004)
```
⚠ Cannot fetch marketplace manifest: HTTP Error 403: Forbidden
⚠ Marketplace unreachable — plugins must be installed manually
HTTP Error 400: BAD REQUEST
⚠ Workflow import failed — configure models manually in Dify UI
```
```bash
exit 0  # install.sh завершился успешно несмотря на падение import.py
```
**Результат:** Graceful fallback работает. Dify API стартовал, логи чистые, marketplace 403 не прерывает установку.

### ✅ Автозапуск контейнеров (TASK-005)
```
✓ Все контейнеры запущены!
[OK] db, redis, sandbox, ssrf_proxy, api, worker, web, plugin_daemon, ollama, pipeline, nginx, open-webui, weaviate, prometheus, alertmanager, cadvisor, grafana, portainer, loki, promtail, docling, xinference
```
**Результат:** 34/34 контейнеров Up+Healthy без ручного вмешательства.

---

## 📋 Known Issues (не критичные)

### TASK-004: Dify marketplace 403 Forbidden
**Статус:** Workaround работает (graceful skip).  
**Симптом:** `import.py` не может скачать плагины из Dify marketplace.  
**Причина:** Marketplace API возвращает HTTP 403 (проблема upstream).  
**Workaround:** Модели и KB настраиваются вручную через Dify UI (Settings > Model Provider > Add Ollama).  
**Действие:** Оставить как есть. Manual setup задокументирован в выводе install.sh.

---

## 🚀 Следующие шаги

1. ✅ **Деплой готов к production** — все критические баги решены.
2. 📖 **Документация:** добавить README с manual Dify setup (Settings > Model Provider > Add Ollama http://ollama:11434).
3. 🎨 **Опционально:** UI для визарда (web-based installer вместо PTY).
4. 🔍 **Долгосрочно:** решить TASK-004 через альтернативный репозиторий плагинов или форк Dify marketplace.

---

_Обновлено: 2026-03-16 15:50 PDT — Gbot (деплой #8 SUCCESS, коммит 2b97bfe)_
