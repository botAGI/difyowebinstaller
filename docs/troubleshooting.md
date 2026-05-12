# Troubleshooting Cookbook

Каждый раздел следует структуре: **Симптом → Причина → Диагностика → Фикс**.

Для общей диагностики одной командой: `agmind doctor` (сквозная проверка всего стека).
Для сбора поддержки: `agmind doctor --bundle` (sanitized-архив состояния без secrets).
Для просмотра конкретного раздела из CLI: `agmind troubleshoot <тема>`.

---

## Темы / Topics

| Alias | Раздел |
|-------|--------|
| `vllm` | [1. vLLM не загружает модель](#1-vllm-не-загружает-модель--vllm-model-not-loading) |
| `gpu`, `cuda` | [2. CUDA не виден в контейнере](#2-cuda-не-виден-в-контейнере--torchcudais_availablefalse) |
| `ragflow`, `es` | [3. RAGFlow Elasticsearch не поднимается](#3-ragflow-elasticsearch-не-поднимается--max_map_count) |
| `dify`, `worker` | [4. Dify worker завис / задачи не выполняются](#4-dify-worker-завис--задачи-не-выполняются-force-recreate-trap) |
| `ports` | [5. Конфликт портов](#5-конфликт-портов-особенно-5353--port-conflicts) |
| `mdns`, `dns` | [6. DNS / mDNS не работает](#6-dns--mdns-не-работает-agmind-local-не-резолвится) |
| `model`, `download` | [7. Не качается модель / большой файл обрывается](#7-не-качается-модель--большой-файл-обрывается--download-failed) |
| `restore` | [8. Восстановление не работает](#8-восстановление-не-работает--restore-failed) |
| `update` | [9. Обновление не работает](#9-обновление-не-работает--update-failed) |
| `memory`, `oom` | [10. Мало памяти / OOM](#10-мало-памяти--oom-unified-memory-budget) |

---

### 1. vLLM не загружает модель / vLLM model not loading

**Симптом:** первый запрос висит 5–7 минут; `Connection refused` на порту 8000;
`RayChannelTimeoutError` после 300 сек в логах.

**Причина:**
- Модель грузится лениво — первый inference блокируется на ~7 мин (нормально).
- `gpu_memory_utilization > 0.70` вызывает CUBLAS crash на GB10; на single-node — критичен лимит `<= 0.60` (docling конкурирует за unified memory).
- FlashInfer FP8 backend сломан на SM_121 — нужен `VLLM_ATTENTION_BACKEND=TRITON_ATTN`.
- CUDAGraph capture deadlock на driver 590+/595+ (три независимые регрессии на GB10).

**Диагностика:**
```bash
agmind status --service vllm
agmind logs vllm
docker inspect agmind-vllm --format '{{.RestartCount}}'
# Если RestartCount растёт — vLLM перезапускается в цикле
```

**Фикс:**
1. Подождать первую загрузку (до 7 мин) — это нормально при холодном старте.
2. Убедиться что `gpu_memory_utilization <= 0.60` на single-node (или `<= 0.70` на peer-ноде с выделенным GPU).
3. При FP8: добавить `VLLM_ATTENTION_BACKEND=TRITON_ATTN` в env.
4. Держать NVIDIA driver на 580.x — не обновлять. Проверить: `nvidia-smi --query-gpu=driver_version --format=csv,noheader`.

Подробнее: [ADR-0005: NVIDIA Driver 580 Hold](adr/0005-driver-580-hold.md), [ADR-0001: ARM64 Only](adr/0001-arm64-only.md).

---

### 2. CUDA не виден в контейнере / torch.cuda.is_available()=False

**Симптом:** ML-контейнер `healthy`, в логах `CUDA is not available. Fall back to 'CPU'`;
`nvidia-smi` внутри возвращает `Failed to initialize NVML`; производительность в 10× ниже ожидаемой.

**Причина:** GPU-сервису не задан env `NVIDIA_DRIVER_CAPABILITIES=compute,utility`.
`capabilities: [gpu]` в compose-блоке `deploy.resources.reservations.devices` — это только
запрос устройства от Docker; без env-переменной NVIDIA runtime выдаёт контейнеру только
`graphics` capability, NVML и libcuda недоступны.

**Диагностика:**
```bash
docker exec <svc> nvidia-smi
docker exec <svc> python3 -c "import torch; print(torch.cuda.is_available())"
# Проверить env:
docker inspect <svc> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep NVIDIA
```

**Фикс:**
1. Добавить в `environment` GPU-сервиса в compose:
   ```yaml
   NVIDIA_DRIVER_CAPABILITIES: ${NVIDIA_DRIVER_CAPABILITIES:-compute,utility}
   ```
2. Пересоздать контейнер без `--force-recreate` всей сети (см. раздел 4):
   ```bash
   docker stop <svc> && docker rm <svc> && docker compose up -d <svc>
   ```

`agmind doctor` автоматически проверяет NVIDIA_DRIVER_CAPABILITIES для GPU-сервисов.

---

### 3. RAGFlow Elasticsearch не поднимается / max_map_count

**Симптом:** Elasticsearch (agmind-ragflow-es) не стартует; в логах:
`max virtual memory areas vm.max_map_count [65530] is too low, increase to at least [262144]`.

**Причина:** ES 9.x требует `vm.max_map_count >= 262144` на уровне ОС хоста.
По умолчанию Ubuntu DGX OS имеет значение 65530.

**Диагностика:**
```bash
sysctl vm.max_map_count
# Должно быть >= 262144
docker logs agmind-ragflow-es 2>&1 | tail -20
```

**Фикс:**

*Автоматический (рекомендуется):*
```bash
sudo agmind doctor --fix
# Устанавливает vm.max_map_count и сохраняет в /etc/sysctl.d/99-agmind-es.conf
# Выживает после перезагрузки
```

*Ручной:*
```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-agmind-es.conf
```

---

### 4. Dify worker завис / задачи не выполняются (force-recreate trap)

**Симптом:** Новая индексация или upload документа зависает в статусе `waiting`.
Worker молчит, GPU простаивает. `celery inspect active` показывает task в active, но ничего не происходит.
Новые задачи не обрабатываются даже после рестарта Dify UI.

**Причина:** `docker compose up -d --force-recreate worker` (или `api`) посреди активной
RAG-индексации создаёт новый контейнер с новым Celery hostname. В Redis остаётся устаревшее
состояние:
- `generate_task_belong:<task_id>` (DB 0, TTL 1800s) — Dify считает, что задача ещё выполняется
- pub/sub каналы привязаны к старому hostname — новый worker их не читает
- `celery-task-meta-*` (DB 1) — zombie metadata

**Диагностика:**
```bash
agmind status --service worker
docker logs agmind-worker --tail 50
# Если worker жив, но задачи висят — проверить Redis:
docker exec agmind-redis redis-cli -a "$REDIS_PASSWORD" -n 0 --scan --pattern 'generate_task_belong:*' | wc -l
```

**Фикс:**

*Без recreate (предпочтительно):*
```bash
docker restart agmind-worker agmind-api
```

*Если recreate уже произошёл — очистить stale Redis-ключи:*
```bash
# DB 0 — task ownership
docker exec agmind-redis redis-cli -a "$REDIS_PASSWORD" -n 0 \
  --scan --pattern 'generate_task_belong:*' | \
  xargs -r docker exec agmind-redis redis-cli -a "$REDIS_PASSWORD" -n 0 DEL

# DB 1 — task metadata
docker exec agmind-redis redis-cli -a "$REDIS_PASSWORD" -n 1 \
  --scan --pattern 'celery-task-meta-*' | \
  xargs -r docker exec agmind-redis redis-cli -a "$REDIS_PASSWORD" -n 1 DEL

# Перезапустить worker
docker restart agmind-worker agmind-api
```

Подробнее: [ADR-0007: Force-Recreate Trap](adr/0007-force-recreate-trap.md).

---

### 5. Конфликт портов (особенно :5353) / Port conflicts

**Симптом:** mDNS-алиасы (`agmind-dify.local` и др.) не резолвятся; в логах avahi:
`Detected another IPv4 mDNS stack running on this host`.
Или nginx не запускается — порты :80 / :443 заняты.

**Причина:**
- Второй mDNS responder занял UDP/5353 (NoMachine с `EnableLocalNetworkBroadcast 1`, iTunes/Bonjour, другие avahi-совместимые).
- Другой HTTP-сервер держит TCP :80 или :443.

**Диагностика:**
```bash
# Проверить :5353 — должен быть только avahi
sudo ss -ulnp | grep 5353

# Проверить :80 / :443
sudo ss -tlnp | grep -E ':80\b|:443\b'
```

**Фикс:**

*Для NoMachine:*
```bash
# Редактировать /etc/NX/server/localhost/server.cfg
# Установить: EnableLocalNetworkBroadcast 0
sudo systemctl restart nxserver
```

*Для :80/:443:* определить процесс через `ss -tlnp`, остановить или поменять порт.

*Автоматическая проверка:* `agmind doctor` обнаруживает конфликт :5353.

---

### 6. DNS / mDNS не работает (agmind-*.local не резолвится)

**Симптом:** `avahi-resolve -n agmind-dify.local` зависает или возвращает ошибку.
`tcpdump -i <uplink> udp port 5353` показывает ноль пакетов от `agmind-*`.

**Причина:**
- Self-collision в avahi: alias с тем же IP что primary avahi host не отправляет probe в сеть (`Local name collision`). Попытка добавить alias через `/etc/avahi/hosts` не работает для этого случая.
- Служба `agmind-mdns.service` упала.
- Второй mDNS responder блокирует :5353 (см. раздел 5).

**Диагностика:**
```bash
systemctl status agmind-mdns
avahi-resolve -n agmind-dify.local
journalctl -u agmind-mdns --no-pager -n 30
```

**Фикс:**
```bash
sudo systemctl restart agmind-mdns
# Или:
sudo agmind doctor --fix
# Регистрация через avahi-publish-address -R, не /etc/avahi/hosts
```

Если `agmind-mdns.service` не существует — переустановить: `sudo bash install.sh --resume-from mdns`.

---

### 7. Не качается модель / большой файл обрывается / Download failed

**Симптом A:** `dpkg -i *.deb` завершается с `неожиданный конец файла или потока`.
`stat -c %s file.deb` показывает размер меньше ожидаемого.

**Симптом B:** Из контейнера `huggingface.co` резолвится, но `cas-bridge.xethub.hf.co`
или `cdn-lfs-cn-1.modelscope.cn` — нет.

**Причина A:** Промежуточный прозрачный прокси/CDN молча обрывает HTTP-ответы > 600 MB
(Connection closed до завершения Content-Length). Клиент считает это успехом (HTTP 200).

**Причина B:** Docker embedded DNS (`127.0.0.11`) иногда дропает большие DNS-ответы от CDN.

**Диагностика:**
```bash
# A: сравнить реальный размер с ожидаемым
stat -c %s file.deb
curl -sI <url> | grep -i content-length

# B: из контейнера
docker exec agmind-plugin-daemon getent hosts cas-bridge.xethub.hf.co
```

**Фикс A:** Использовать HTTPS для всех deb/iso > 100 MB:
```bash
# Вместо http://ports.ubuntu.com/...
curl -L https://ports.ubuntu.com/pool/main/.../package.deb -o package.deb
```

В air-gap-сети добавить в `/etc/apt/apt.conf.d/99agmind-https`:
```
Acquire::https::Pipeline-Depth "0";
```

**Фикс B:** Добавить `extra_hosts` в compose для `plugin_daemon` со статическими IP CDN.
Текущие IP см. в `templates/docker-compose.yml` секции `plugin_daemon.extra_hosts`.

---

### 8. Восстановление не работает / Restore failed

**Симптом:** `agmind restore` падает с ошибкой; или после restore Dify-задачи висят в `waiting`;
или `agmind backup verify latest` выдаёт FAIL.

**Причина:**
- Неполный или повреждённый backup (обрыв записи, нарушение checksums).
- Stale Redis-состояние после restore Dify DB (та же проблема, что в разделе 4).
- FLUSHDB заблокирован Redis ACL — нельзя очистить одной командой, только DEL по паттерну.

**Диагностика:**
```bash
# Проверить целостность backup перед применением
agmind backup verify latest
# Показывает: checksums / archive-integrity / sql-sanity / completeness

# Посмотреть что будет восстановлено (без изменений)
agmind restore --dry-run latest
```

**Фикс:**
1. Восстановить только нужный сервис: `agmind restore latest --service dify`
2. После restore Dify DB — очистить stale Redis (команды из раздела 4)
3. Если backup повреждён — использовать предыдущий: `agmind backup list`

Подробнее: [ADR-0007: Force-Recreate Trap](adr/0007-force-recreate-trap.md) (Redis stale state).

---

### 9. Обновление не работает / Update failed

**Симптом:** `agmind update` ломает стек; после обновления контейнеры в unhealthy;
`versions.env` и manifest рассинхронизированы; образ не находится в registry.

**Причина:**
- Невалидный `.env` (отсутствуют обязательные placeholder'ы).
- Несинхронизированные `versions.env` / `release-manifest.json` — версии расходятся.
- Выдуманный или несуществующий `image:tag` (LLM может генерировать правдоподобные, но несуществующие теги).
- Обновление NVIDIA driver на 590+ (это нельзя откатывать бесследно — см. раздел 1 и ADR-0005).

**Диагностика:**
```bash
# Проверить конфигурацию перед обновлением
agmind config validate

# Предварительный просмотр (без изменений)
agmind update --dry-run
# Показывает diff версий + список пересоздаваемых контейнеров

# Проверить консистентность версий
agmind config diff --release vX.Y.Z
```

**Фикс:**
1. Исправить проблемы по выводу `agmind config validate`.
2. Проверить существование image:tag с arm64 manifest:
   ```bash
   bash tests/compose/test_image_tags_exist.sh templates/docker-compose.yml
   # Или: make manifest-check
   ```
3. Никогда не использовать `:latest` — только конкретные версии из `templates/versions.env`.

---

### 10. Мало памяти / OOM (unified memory budget)

**Симптом:** `torch.AcceleratorError: CUDA error: out of memory`; `NVRM: Out of memory`
в dmesg; swap 100%; контейнер OOM-killed. vLLM или docling внезапно умирают.

**Причина:** DGX Spark GB10 — единый пул ~121 GiB для CPU и GPU.
vLLM при `gpu_memory_utilization=0.60` занимает ~83 GiB.
Docling в batch-режиме (layout=64, ocr=64, 2 workers) может потреблять 30–40 GiB.
Postgres `shared_buffers`, Weaviate heap, другие CPU-процессы тоже вычитаются.
Итог: `83 + 40 > 121` → CUDA OOM.

Заметка: `nvidia-smi --query-gpu=memory.used` возвращает `[N/A]` на GB10 (unified memory
не разделяется на VRAM/RAM на уровне NVML).

**Диагностика:**
```bash
agmind status
agmind estimate <profile>
free -g
cat /proc/pressure/memory
# Процессный расклад GPU:
nvidia-smi --query-compute-apps=pid,used_memory --format=csv
```

**Фикс:**
1. Убедиться в `gpu_memory_utilization <= 0.60` на single-node (shared GPU).
2. Использовать консервативные docling-параметры на shared-GPU:
   ```yaml
   UVICORN_WORKERS: "1"
   DOCLING_SERVE_NUM_WORKERS: "1"
   DOCLING_SERVE_LAYOUT_BATCH_SIZE: "32"
   DOCLING_SERVE_OCR_BATCH_SIZE: "32"
   ```
3. Вынести vLLM на выделенный peer-узел: `LLM_ON_PEER=true` в `.env`.
4. Подобрать профиль с меньшим footprint: `agmind profiles`, `agmind estimate`.

Подробнее: [ADR-0001: ARM64 Only (DGX Spark unified memory context)](adr/0001-arm64-only.md).

---

## See also

- [architecture/](architecture/) — диаграммы топологии, data flow, security zones
- [compatibility-matrix.md](compatibility-matrix.md) — протестированные версии компонентов
- [adr/](adr/) — архитектурные решения с обоснованием

Для интерактивной сквозной проверки: `agmind doctor`
Для sanitized-архива состояния: `agmind doctor --bundle`
