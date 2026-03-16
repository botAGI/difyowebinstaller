# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.  
> Кодер: перед началом работы делай `git pull` и читай этот файл.  
> После фикса — коммить и пуш. Gbot подтянет, задеплоит, протестирует, обновит статусы.

---

## Текущий статус: ✅ Первая успешная установка до конца (exit 0)

**Последний тест:** 2026-03-16 15:00 PDT (деплой #6)  
**Сервер:** ragbot@192.168.50.26 (Ubuntu 24.04, Docker 29.3.0, RTX 5070 Ti)  
**Коммит:** 51b736d  
**Режим установки:** интерактивный (визард)  
**Параметры:** lan / AGMind / weaviate / ETL enhanced / qwen2.5:7b / bge-m3 / monitoring local

---

## ✅ Что работает (подтверждено деплоем #6)

- **34/34 контейнеров** Up+Healthy автоматически
- **Модели скачаны:** qwen2.5:7b (4.7 GB), bge-m3 (1.2 GB)
- **Xinference reranker:** зарегистрирован
- **Open WebUI admin:** `admin@admin.com`, пароль в `/opt/agmind/.admin_password`
- **install.sh exit 0:** фазы 1-11 завершены, система полностью развёрнута
- **Graceful fallback:** import.py упал на KB create, но установка не прервалась — пользователь получил инструкцию

---

## 🟡 Частично решённые задачи

### TASK-004: import.py — плагины Dify и provisioning моделей
**Статус:** 🟡 Graceful fallback работает (коммит d21c854 + 51b736d)  
**Симптом:** Marketplace возвращает 403 Forbidden → плагины `langgenius/ollama` и `langgenius/xinference` не установлены. import.py не может создать provider/model/KB/workflow. Крашится на `create_dataset()`:
```
HTTP 400: Default model not found for text-embedding
urllib.error.HTTPError: HTTP Error 400: BAD REQUEST
```

**Что работает:**
- install.sh **НЕ прерывается** (фазы 9-11 выполняются)
- Пользователь видит предупреждение:
  ```
  ⚠ Workflow import failed — configure models manually in Dify UI
    Settings > Model Provider > Add Ollama (http://ollama:11434)
  ```
- Все контейнеры Up, Ollama с моделями работает

**Что нужно сделать вручную:**
1. Открыть Dify UI (http://192.168.50.26:3000)
2. Settings > Model Provider > Add Ollama: `http://ollama:11434`
3. Settings > Model Provider > Add Xinference: `http://xinference:9997` (если нужен reranker)
4. Создать KB вручную в Knowledge Base UI
5. Импортировать workflow из `/opt/agmind/workflows/*.yml`

**Долгосрочное решение:**
- Либо marketplace починят (вне нашего контроля)
- Либо добавить manual plugin install в install.sh (установка .zip из локальных файлов)
- Либо оставить как есть (graceful degradation — приемлемо для enterprise)

**Приоритет:** 🟡 Средний — система работает, но требует manual setup после установки.

---

### TASK-002: cAdvisor не видит имена контейнеров
**Баг:** BUG-011  
**Статус:** ❌ НЕ РЕШЕНО  
**Симптом:** `curl http://localhost:8080/metrics | grep 'container_last_seen.*name='` → пусто  
**Причина:** Docker 29.x + overlayfs snapshotter несовместим с cAdvisor v0.52.1 — нет `name` лейблов в метриках  
**Влияние:** Grafana container dashboards → "No data"; ContainerDown alert всегда firing  
**Вариант фикса:** обновить cAdvisor до v0.53.0+, или добавить `--containerd` socket  
**Приоритет:** 🟡 Средний — система работает, мониторинг контейнеров частично слепой.

---

## ✅ Закрытые задачи (полностью рабочие)

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

## 📊 История деплоев

- **Деплой #1-3:** Диагностика, ранние фиксы
- **Деплой #4 (40b35d9):** TASK-005 починен, BUG-016 (wget) найден
- **Деплой #5 (d21c854):** BUG-016 закрыт, BUG-017 (IPv6) найден
- **Деплой #6 (51b736d):** ✅ **Первый успешный** (exit 0, все 11 фаз)

---

_Обновлено: 2026-03-16 15:05 PDT — Gbot (деплой #6, коммит 51b736d) — SUCCESSFUL_
