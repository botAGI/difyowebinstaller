<p align="center">
  <img src="branding/logo.svg" width="200" alt="AGMind Logo">
</p>

<h1 align="center">AGMind Installer</h1>

<p align="center">Production-ready AI-стек одной командой</p>

<p align="center">
  <a href="https://github.com/botAGI/AGmind/actions/workflows/test.yml"><img src="https://github.com/botAGI/AGmind/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License"></a>
  <img src="https://img.shields.io/badge/docker-ready-blue?logo=docker" alt="Docker Ready">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu 24.04 LTS">
</p>

<p align="center">
  <a href="README.md">English version</a>
</p>

---

## Зачем AGMind

| Возможность | Руками | AGMind |
|-------------|--------|--------|
| Развернуть Dify + Open WebUI + Ollama | 2-3 дня, 5+ docker-compose файлов | 1 команда, 5 минут |
| Работа без API-ключей внешних сервисов | Ручная настройка Ollama/vLLM | Из коробки: Ollama или vLLM локально |
| Поддержка Qwen (русский язык) | Ручной подбор модели и параметров | Qwen2.5/Qwen3 в меню, авто-рекомендация по GPU/RAM |
| Offline-установка (закрытый контур) | Собирать образы и модели вручную | `build-offline-bundle.sh` — один архив |
| GPU auto-detect (NVIDIA/AMD/Intel) | Ручная настройка runtime + deploy блоков | Автоматически: nvidia-smi, rocm-smi, /dev/dri |
| Мониторинг (Grafana + Prometheus + Loki) | Отдельный стек, ручная настройка дашбордов | Включается одной переменной, 4 дашборда из коробки |
| Бэкап с ротацией и шифрованием | Скрипты с нуля, cron руками | `agmind backup`, автоматический cron 3:00 |
| Откат при сбое обновления | Надежда на удачу | Автоматический rollback по healthcheck |
| Диагностика проблем | `docker ps`, `docker logs`, гадание | `agmind doctor` — 15+ проверок с рекомендациями |
| Переживает перезагрузку сервера | systemd unit руками | systemd-сервис создаётся автоматически |

---

## Быстрый старт

```bash
git clone https://github.com/botAGI/AGmind.git
cd AGmind
sudo bash install.sh
```

Интерактивный мастер проведёт через выбор профиля, LLM-провайдера, модели, TLS и мониторинга. Через ~5 минут — работающая AI-платформа из 23-34 контейнеров.

**Non-interactive с Qwen (рекомендуется для русскоязычных задач):**

```bash
sudo DEPLOY_PROFILE=lan LLM_PROVIDER=ollama LLM_MODEL=qwen2.5:14b \
     EMBED_PROVIDER=ollama bash install.sh --non-interactive
```

---

## После установки

| Сервис | URL | Примечание |
|--------|-----|------------|
| Open WebUI (чат) | `http://server/` | Основной интерфейс |
| Dify Console | `http://server:3000/` | Управление workflow |
| Health endpoint | `http://server/health` | JSON-статус всех сервисов |
| Grafana | `http://127.0.0.1:3001/` | При `MONITORING_MODE=local` |
| Portainer | `https://127.0.0.1:9443/` | При `MONITORING_MODE=local` |

Пароль администратора: `/opt/agmind/credentials.txt` (chmod 600, доступ только root).

---

## CLI

Устанавливается как `/usr/local/bin/agmind`. Управление стеком без запоминания Docker-команд.

| Команда | Описание | Root | Пример |
|---------|----------|------|--------|
| `agmind status` | Обзор стека: контейнеры, GPU, модели, эндпоинты | нет | `agmind status` |
| `agmind status --json` | То же в формате JSON | нет | `agmind status --json \| jq .services` |
| `agmind doctor` | Диагностика: DNS, GPU, Docker, порты, диск, RAM, .env | нет | `agmind doctor` |
| `agmind doctor --json` | Диагностика в JSON | нет | `agmind doctor --json` |
| `agmind logs [сервис]` | Логи контейнеров | нет | `agmind logs api` |
| `agmind logs -f [сервис]` | Логи в реальном времени | нет | `agmind logs -f ollama` |
| `agmind stop` | Остановить все контейнеры | да | `sudo agmind stop` |
| `agmind start` | Запустить контейнеры | да | `sudo agmind start` |
| `agmind restart` | Перезапустить стек | да | `sudo agmind restart` |
| `agmind backup` | Ручной бэкап | да | `sudo agmind backup` |
| `agmind restore <путь>` | Восстановление из бэкапа | да | `sudo agmind restore /var/backups/agmind/2026-03-15_0300` |
| `agmind update` | Обновление с откатом при сбое | да | `sudo agmind update` |
| `agmind update --check` | Проверить доступные обновления (без изменений) | да | `sudo agmind update --check` |
| `agmind update --component <имя> --version <тег>` | Обновить один компонент | да | `sudo agmind update --component dify-api --version 1.14.0` |
| `agmind update --rollback <имя>` | Откатить компонент | да | `sudo agmind update --rollback ollama` |
| `agmind uninstall` | Удалить стек | да | `sudo agmind uninstall` |
| `agmind rotate-secrets` | Ротация паролей и ключей | да | `sudo agmind rotate-secrets` |
| `agmind help` | Справка по командам | нет | `agmind help` |

---

## Архитектура

```
                         +-----------+
                         |   nginx   |  :80 / :443
                         +-----+-----+
                           /       \
                +---------+         +-----------+
                | Open    |         | Dify Web  |
                | WebUI   |         | + Console |
                +---------+         +-----+-----+
                                      /       \
                              +------+    +--------+
                              |  API |    | Worker |
                              +--+---+    +---+----+
                                 |            |
                    +------------+------------+----------+
                    |            |            |          |
               +----+---+  +----+---+  +-----+----+ +--+------+
               |Postgres|  | Redis  |  |Ollama/   | |Weaviate/|
               +--------+  +--------+  |vLLM/TEI  | |Qdrant   |
                                       +----------+ +---------+

  Мониторинг (опционально): Prometheus -> Grafana, Loki -> Promtail,
                             cAdvisor, Alertmanager, Portainer
```

Инсталлер разворачивает только инфраструктуру. Вся AI-конфигурация (workflow, базы знаний, подключение моделей) — через UI Dify и Open WebUI.

---

## Провайдеры LLM

### LLM

| Провайдер | Compose-профиль | Описание |
|-----------|----------------|----------|
| Ollama | `ollama` | Локальный инференс, авто-загрузка моделей |
| vLLM | `vllm` | Production-нагрузки, OpenAI-совместимый API, tensor parallelism |
| External | -- | Внешний API (OpenAI, Anthropic и др.) — контейнер LLM не поднимается |
| Skip | -- | Без LLM, только Dify + Open WebUI |

### Embedding

| Провайдер | Compose-профиль | Описание |
|-----------|----------------|----------|
| Ollama | `ollama` | Embedding через Ollama (bge-m3 и др.) |
| TEI | `tei` | HuggingFace Text Embeddings Inference |
| External | -- | Внешний embedding API |
| Same | -- | Тот же провайдер, что и для LLM |

### Рекомендации по моделям

Для **русскоязычных задач** рекомендуются модели Qwen — они показывают лучшее качество на русском языке по сравнению с Llama и Mistral.

| Модель | Параметры | RAM | VRAM | Примечание |
|--------|-----------|-----|------|------------|
| `qwen2.5:7b` | 7B | 8 ГБ+ | 6 ГБ+ | Быстрый старт, хорошее качество на русском |
| `qwen2.5:14b` * | 14B | 16 ГБ+ | 10 ГБ+ | **Рекомендуется** — баланс качества и скорости |
| `qwen3:8b` | 8B | 8 ГБ+ | 6 ГБ+ | Новейшая архитектура Qwen |
| `qwen3:32b` | 32B | 32 ГБ+ | 16 ГБ+ | Высокое качество, нужна мощная GPU |
| `qwen2.5:72b-instruct-q4_K_M` | 72B | 64 ГБ+ | 24 ГБ+ | Максимальное качество (квантизация Q4) |
| `gemma3:4b` | 4B | 8 ГБ+ | 6 ГБ+ | Минимальные ресурсы |
| `llama3.1:8b` | 8B | 8 ГБ+ | 6 ГБ+ | Сильная базовая модель |
| `mistral:7b` | 7B | 8 ГБ+ | 6 ГБ+ | Компактная, быстрая |

\* модель по умолчанию

Инсталлер определяет GPU и RAM, затем рекомендует оптимальную модель автоматически.

**vLLM** — для production-нагрузок с высоким QPS. Поддерживает tensor parallelism на нескольких GPU, continuous batching, PagedAttention. Рекомендуется при обслуживании 10+ пользователей одновременно.

---

## Требования

| Параметр | Минимум | Рекомендуется |
|----------|---------|---------------|
| ОС | Ubuntu 20.04, Debian 11, CentOS Stream 9 | Ubuntu 22.04+ |
| RAM | 4 ГБ | 16 ГБ+ (32 ГБ при GPU-инференсе) |
| CPU | 2 ядра | 4+ ядер |
| Диск | 20 ГБ | 100 ГБ+ (SSD) |
| Docker | 24.0+ | 27.0+ (устанавливается автоматически) |
| Compose | 2.20+ | 2.29+ (устанавливается автоматически) |
| GPU (опционально) | NVIDIA Pascal+ | Ampere+ (CUDA 12.0+) |

Предварительные проверки запускаются автоматически. Пропустить: `SKIP_PREFLIGHT=true`.

---

## Система обновлений

```bash
# Проверить доступные обновления
sudo agmind update --check

# Обновить весь стек (rolling update)
sudo agmind update

# Обновить один компонент
sudo agmind update --component dify-api --version 1.14.0

# Откатить компонент
sudo agmind update --rollback ollama

# Автоматический режим (без подтверждений)
sudo agmind update --auto
```

**Порядок обновления:** pre-flight проверки -> бэкап -> сверка с `versions.env` -> rolling restart по сервисам -> healthcheck -> откат при сбое -> уведомление.

Если healthcheck не проходит после обновления, предыдущий тег образа восстанавливается автоматически.

Все версии образов зафиксированы в `templates/versions.env` — единый источник истины. Тег `:latest` запрещён.

---

## Диагностика

```bash
agmind doctor
```

### Что проверяет

| Категория | Проверки |
|-----------|----------|
| Docker + Compose | Версии, runtime, nvidia toolkit |
| DNS + Сеть | registry.ollama.ai, Docker Hub |
| GPU | Тип, драйвер, NVIDIA Container Toolkit |
| Ресурсы | Диск (свободное место), RAM, порты 80/443 |
| Docker Disk | Использование места Docker-образами, томами, кешем |
| Контейнеры | Unhealthy, exited, restart loop (>3 перезапусков) |
| HTTP-эндпоинты | Dify API, Open WebUI, Ollama/vLLM/TEI, Weaviate/Qdrant |
| .env | Полнота обязательных переменных |

### Exit codes

| Код | Значение |
|-----|----------|
| 0 | Все проверки пройдены |
| 1 | Есть предупреждения (WARN) |
| 2 | Есть ошибки (FAIL) |

JSON-вывод для автоматизации:

```bash
agmind doctor --json | jq '.checks[] | select(.severity == "FAIL")'
```

---

## Безопасность

- **Все контейнеры**: `cap_drop: [ALL]`, `no-new-privileges:true`, IPv6 отключён, ротация логов (10 МБ x 5 файлов)
- **Credentials**: только в `credentials.txt` (chmod 600) — пароли не выводятся в stdout и логи
- **Секреты**: автогенерация (SECRET_KEY 64 символа, пароли 32 символа), блокировка `changeme`/`password`
- **Nginx**: rate limiting (10 req/s API, 1 req/10s login), security headers, `server_tokens off`
- **PostgreSQL**: `password_encryption=scram-sha-256`
- **Redis**: `requirepass`, опасные команды отключены (FLUSHALL, CONFIG, DEBUG, SHUTDOWN)
- **SSRF-изоляция**: отдельная сеть, ACL блокирует RFC1918, link-local, `169.254.169.254`
- **SSH hardening**: аутентификация только по ключам (с предупреждением о блокировке)
- **Fail2ban**: SSH jail (3 попытки -> бан 10 дней) — профили VPS/LAN/VPN
- **UFW**: deny incoming, allow 22/80/443 — профиль VPS
- **SOPS + Age**: шифрование `.env` -> `.env.enc` — профиль VPS
- **Authelia**: 2FA на `/console/*` (опционально)
- **Grafana/Portainer**: привязаны к `127.0.0.1` по умолчанию
- **Offline-профиль**: полная изоляция от интернета, никаких внешних зависимостей в runtime

---

## GPU

Автоматическое определение через `lib/detect.sh`.

| GPU | VRAM | Рекомендуемые модели |
|-----|------|---------------------|
| RTX 3060 | 12 ГБ | Ollama: qwen2.5:7b, qwen3:8b |
| RTX 3090 | 24 ГБ | Ollama: qwen2.5:14b, vLLM: qwen2.5:7b |
| RTX 4060 Ti | 16 ГБ | Ollama: qwen2.5:14b |
| RTX 4090 | 24 ГБ | vLLM: qwen2.5:14b, Ollama: qwen2.5:32b |
| A100 40/80GB | 40-80 ГБ | vLLM: qwen2.5:72b, tensor parallelism |
| AMD RX 7900 XTX | 24 ГБ | Ollama: qwen2.5:14b (ROCm) |
| CPU only | -- | Ollama: qwen2.5:7b (медленнее в 5-10x) |

**Принудительная настройка GPU:**

```bash
FORCE_GPU_TYPE=amd bash install.sh --non-interactive     # Принудительно AMD
SKIP_GPU_DETECT=true bash install.sh --non-interactive   # Без GPU
```

**Правило:**
- **Ollama** — для 1-5 пользователей, GPU от RTX 3060 12GB
- **vLLM** — для 10+ пользователей, GPU от RTX 4090 24GB или A100

---

## Бэкап и DR

```bash
# Ручной бэкап
sudo agmind backup

# Восстановление
sudo agmind restore /var/backups/agmind/2026-03-15_0300
```

**Состав бэкапа:** `dify_db.sql.gz`, `dify_plugin_db.sql.gz`, `volumes.tar.gz`, `config.tar.gz`, `sha256sums.txt`.

**Автоматический cron:** ежедневно в 3:00 AM. Хранилище: `/var/backups/agmind/`.

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `BACKUP_RETENTION_COUNT` | Количество хранимых бэкапов | 10 |
| `ENABLE_S3_BACKUP` | Выгрузка в S3 через rclone | false |
| `ENABLE_BACKUP_ENCRYPTION` | Шифрование бэкапов (age) | false |
| `ENABLE_DR_DRILL` | Ежемесячная DR-проверка по cron | false |

---

## Offline-установка

Для работы в закрытых контурах (госструктуры, банки, air-gapped сети) AGMind поддерживает полностью автономную установку без доступа к интернету.

### Шаг 1. Сборка архива (на машине с интернетом)

```bash
./scripts/build-offline-bundle.sh \
    --include-models qwen2.5:14b,bge-m3 \
    --platform linux/amd64
```

Скрипт собирает в один архив:
- Все Docker-образы стека (23-34 штуки) — `docker save`
- Выбранные модели Ollama (LLM + embedding)
- Инсталлер, конфиги, шаблоны
- Контрольные суммы SHA256

Размер архива: ~15-25 ГБ (зависит от моделей).

**С Qwen 72B для максимального качества на русском:**

```bash
./scripts/build-offline-bundle.sh \
    --include-models qwen2.5:72b-instruct-q4_K_M,bge-m3 \
    --platform linux/amd64 \
    --name agmind-offline-qwen72b
```

### Шаг 2. Перенос на целевой сервер

Любым доступным способом: USB, SCP по внутренней сети, файловый сервер.

### Шаг 3. Установка

```bash
# Распаковка (если архив .tar.gz)
tar xzf agmind-offline-*.tar.gz
cd agmind-offline/

# Установка
sudo DEPLOY_PROFILE=offline bash install.sh
```

Инсталлер обнаружит локальные образы и модели, пропустит все шаги, требующие интернет. Профиль `offline` отключает UFW, Let's Encrypt, SOPS и другие компоненты, зависящие от внешних сервисов.

### Обновление в offline-контуре

1. Соберите новый бандл на машине с интернетом с обновлёнными версиями
2. Перенесите на целевой сервер
3. Запустите `sudo agmind update` — обновление подхватит локальные образы

---

## Структура проекта

```
AGmind/
+-- install.sh              # Главный инсталлер (10 фаз, checkpoint/resume)
+-- lib/                    # Модульные библиотеки
|   +-- common.sh           # Логирование, валидация, утилиты
|   +-- wizard.sh           # Интерактивный мастер настройки
|   +-- config.sh           # Генерация .env и конфигов
|   +-- compose.sh          # Docker Compose операции
|   +-- health.sh           # Health checks, верификация
|   +-- detect.sh           # Определение GPU/системы
|   +-- docker.sh           # Установка Docker
|   +-- security.sh         # SSH hardening, fail2ban, UFW
|   +-- models.sh           # Загрузка моделей
|   +-- backup.sh           # Бэкап/восстановление
+-- scripts/                # Операционные скрипты (/opt/agmind/scripts/)
|   +-- agmind.sh           # CLI
|   +-- backup.sh           # Бэкап с контрольными суммами
|   +-- restore.sh          # Восстановление
|   +-- update.sh           # Rolling update с откатом
|   +-- build-offline-bundle.sh  # Сборка offline-архива
|   +-- dr-drill.sh         # Автоматизация DR-тестов
+-- templates/              # Шаблоны конфигов
|   +-- docker-compose.yml  # 25+ сервисов, 3 сети
|   +-- versions.env        # Зафиксированные версии образов
|   +-- nginx/              # Конфиги Nginx
+-- monitoring/             # Конфиги Prometheus, Grafana, Loki
+-- branding/               # Ресурсы white-label
+-- docs/                   # Документация (Docusaurus)
+-- LICENSE                 # Apache 2.0
```

---

## Contributing

1. Fork репозитория
2. Ветка от `main`: `git checkout -b feature/my-feature`
3. Все `.sh` файлы должны проходить ShellCheck
4. Проверка: `bash -n` на изменённых скриптах
5. Pull request с описанием изменений

---

## Лицензия

[Apache License 2.0](LICENSE)

Copyright 2024-2026 AGMind Contributors
