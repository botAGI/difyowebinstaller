# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.  
> Кодер: перед началом работы делай `git pull` и читай этот файл.  
> После фикса — коммить и пуш. Gbot подтянет, задеплоит, протестирует, обновит статусы.

---

## Текущий статус: ⚠️ 23/23 контейнеров OK, но install.sh crashed на шаге 7/11

**Последний тест:** 2026-03-16 14:35 PDT (деплой #5)  
**Сервер:** ragbot@192.168.50.26 (Ubuntu 24.04, Docker 29.3.0, RTX 5070 Ti)  
**Коммит:** d21c854  
**Режим установки:** интерактивный (визард)  
**Параметры:** lan / AGMind / weaviate / ETL enhanced / qwen2.5:7b / bge-m3 / monitoring local

---

## ✅ Что работает (подтверждено деплоем #5)

- **TASK-005 / BUG-015: ЗАКРЫТ** — 34/34 контейнеров поднялись автоматически, ручной `docker start` не нужен
- **TASK-007 / BUG-016: ЗАКРЫТ** — Open WebUI админ создан (`admin@admin.com`), wget→curl фикс работает
- Каскад depends_on отрабатывает полностью
- Dify, Open WebUI, Nginx, API, Worker, Pipeline — все Up + Healthy

---

## 🔴 Открытые задачи (приоритет: сверху вниз)

---

### TASK-008 🔴 Ollama pull использует IPv6, сеть недоступна
**Баг:** BUG-017 (новый, критический)  
**Шаг установки:** 7/11 — Загрузка моделей  
**Симптом:** `ollama pull qwen2.5:7b` внутри контейнера пытается подключиться по IPv6:
```
dial tcp [2606:4700:3034::ac43:b6e5]:443: connect: cannot assign requested address
```
**Причина:** DNS возвращает AAAA-записи для `registry.ollama.ai`. На хосте IPv6 маршрута нет (`ip -6 route get ... → Network is unreachable`), но интерфейс существует. Go-runtime (Ollama написан на Go) выбирает IPv6 по приоритету.

**Фикс-опции (любой из них достаточно):**
1. Добавить в `docker-compose.yml` для сервиса `ollama`: `sysctls: net.ipv6.conf.all.disable_ipv6: 1`
2. **ИЛИ** в `lib/models.sh` при `ollama pull` передавать `OLLAMA_HOST` с `--no-ipv6` (если поддерживается)
3. **ИЛИ** форсировать IPv4 DNS: добавить `dns: ["1.1.1.1"]` в сервис ollama docker-compose
4. **ИЛИ** запускать pull через `docker exec agmind-ollama sh -c 'GODEBUG=netdns=go+4 ollama pull qwen2.5:7b'`

**Рекомендация:** вариант 1 (sysctl) — самый надёжный.

**Приоритет:** 🔴 Критический — без моделей Dify и Open WebUI не работают.

---

### TASK-004 🔴 import.py — плагины Dify и provisioning моделей
**Баги:** BUG-007, BUG-008  
**Шаг установки:** 8/11 — Импорт workflow (ещё не дошли из-за TASK-008)  
**Симптом (из деплоя #4):** Dify marketplace вернул 403 Forbidden → плагины `langgenius/ollama` и `langgenius/xinference` не установлены → provider не существует → `import.py` крашится:
```
HTTP 400: Provider langgenius/ollama/ollama does not exist.
urllib.error.HTTPError: HTTP Error 400: BAD REQUEST
```
**Статус:** В деплое #5 до этого шага не дошли (упали раньше на TASK-008)  
**Коммит d21c854** добавил graceful fallback — нужно верифицировать что он работает  
**Приоритет:** 🔴 Критический — блокирует завершение установки.

---

### TASK-002 🟡 cAdvisor не видит имена контейнеров
**Баг:** BUG-011  
**Статус:** ❌ НЕ РЕШЕНО  
**Симптом:** `curl http://localhost:8080/metrics | grep 'container_last_seen.*name='` → пусто  
**Причина:** Docker 29.x + overlayfs snapshotter несовместим с cAdvisor v0.52.1 — нет `name` лейблов в метриках  
**Влияние:** Grafana container dashboards → "No data"; ContainerDown alert всегда firing  
**Вариант фикса:** обновить cAdvisor до v0.53.0+, или добавить `--containerd` socket  
**Приоритет:** 🟡 Средний — система работает, мониторинг контейнеров частично слепой.

---

## ✅ Завершённые задачи

| Задача | Баг | Статус | Коммит |
|--------|-----|--------|--------|
| BUG-009: Loki delete_request_store | BUG-009 | ✅ | 8dc5ae2 |
| BUG-010: Promtail healthcheck | BUG-010 | ✅ Проверено | 90776b3 |
| BUG-013: Grafana provisioning dirs | BUG-013 | ✅ Проверено | 90776b3 |
| BUG-014: install.sh health verification | BUG-014 | ✅ | 90776b3 |
| TASK-003: wget в cAdvisor | BUG-012 | ✅ Проверено | — |
| TASK-005: контейнеры в Created | BUG-015 | ✅ Проверено #4 и #5 | 40b35d9 |
| TASK-007: wget→curl в Open WebUI admin | BUG-016 | ✅ Проверено #5 | d21c854 |

---

_Обновлено: 2026-03-16 14:40 PDT — Gbot (деплой #5, коммит d21c854)_
