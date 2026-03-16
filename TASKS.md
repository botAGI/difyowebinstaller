# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.  
> Кодер: перед началом работы делай `git pull` и читай этот файл.  
> После фикса — коммить и пуш. Gbot подтянет, задеплоит, протестирует, обновит статусы.

---

## Текущий статус: ❌ install.sh crashed на шаге 5/11 (docker compose up)

**Последний тест:** 2026-03-16 15:30 PDT (деплой #7)  
**Сервер:** ragbot@192.168.50.26 (Ubuntu 24.04, Docker 29.3.0, RTX 5070 Ti)  
**Коммит:** a116142  
**Режим установки:** интерактивный (визард)  
**Параметры:** lan / AGMind / weaviate / ETL enhanced / qwen2.5:7b / bge-m3 / monitoring local

---

## 🔴 Открытые задачи

### TASK-009 🔴 cAdvisor v0.56.2 не существует в gcr.io registry
**Баг:** BUG-018 (новый, критический — блокирует установку)  
**Коммит:** a116142 (попытка обновления cAdvisor)  
**Симптом:**
```
Error response from daemon: failed to resolve reference "gcr.io/cadvisor/cadvisor:v0.56.2": not found
```
**Причина:** Версия v0.56.2 не существует. Доступные версии в gcr.io:
```
v0.55.1, v0.54.1, v0.52.1, v0.52.0, v0.51.0, v0.50.0
```
**Фикс:** Заменить `v0.56.2` → `v0.55.1` в трёх файлах:
- `templates/docker-compose.yml`
- `templates/versions.env`
- `templates/release-manifest.json`

**Приоритет:** 🔴 Критический — docker compose up падает, ничего не стартует.

---

### TASK-004 🟡 import.py — graceful skip когда модели не сконфигурированы
**Статус:** ✅ Код добавлен (коммит a116142), но не верифицирован из-за BUG-018  
**Ожидание:** Верификация в деплое #8 после фикса cAdvisor.

---

### TASK-002 🟡 cAdvisor не видит имена контейнеров
**Статус:** Обновление до v0.55.1 должно помочь (Docker 29.x совместимость), но нужно тестировать.

---

## ✅ Закрытые задачи

| Задача | Баг | Проверено | Коммит |
|--------|-----|-----------|--------|
| BUG-009: Loki delete_request_store | BUG-009 | ✅ | 8dc5ae2 |
| BUG-010: Promtail healthcheck | BUG-010 | ✅ Деплой #3-6 | 90776b3 |
| BUG-013: Grafana provisioning dirs | BUG-013 | ✅ Деплой #3-6 | 90776b3 |
| BUG-014: install.sh health verification | BUG-014 | ✅ | 90776b3 |
| TASK-003: wget в cAdvisor | BUG-012 | ✅ | — |
| TASK-005: контейнеры в Created | BUG-015 | ✅ Деплой #4-6 | 40b35d9 |
| TASK-007: wget→curl в Open WebUI admin | BUG-016 | ✅ Деплой #5-6 | d21c854 |
| TASK-008: IPv6 в Ollama pull | BUG-017 | ✅ Деплой #6 | 51b736d |

---

_Обновлено: 2026-03-16 15:35 PDT — Gbot (деплой #7 FAILED, коммит a116142)_
