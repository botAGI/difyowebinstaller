# AGMind Installer

Production-ready AI-стек: **Dify + Open WebUI + Ollama/vLLM** — автоматическая установка за 9 шагов.

[![Lint](https://github.com/botAGI/difyowebinstaller/actions/workflows/lint.yml/badge.svg)](https://github.com/botAGI/difyowebinstaller/actions/workflows/lint.yml)
[![Tests](https://github.com/botAGI/difyowebinstaller/actions/workflows/test.yml/badge.svg)](https://github.com/botAGI/difyowebinstaller/actions/workflows/test.yml)

## Быстрый старт

```bash
git clone https://github.com/botAGI/difyowebinstaller.git
cd difyowebinstaller
sudo bash install.sh
```

Неинтерактивная установка:
```bash
sudo DEPLOY_PROFILE=lan LLM_PROVIDER=ollama LLM_MODEL=qwen2.5:14b \
     EMBED_PROVIDER=ollama bash install.sh --non-interactive
```

После установки:

| Сервис | URL | Примечание |
|--------|-----|------------|
| Open WebUI (чат) | `http://server/` | Основной интерфейс |
| Dify Console | `http://server:3000/` | Управление workflow |
| Health endpoint | `http://server/health` | JSON-статус всех сервисов |
| Grafana | `http://127.0.0.1:3001/` | Только при `MONITORING_MODE=local` |
| Portainer | `https://127.0.0.1:9443/` | Только при `MONITORING_MODE=local` |

Пароль администратора: `/opt/agmind/credentials.txt` (chmod 600)

Управление стеком:
```bash
agmind status          # Статус всех сервисов, GPU, моделей
agmind doctor          # Диагностика проблем
agmind backup          # Ручной бэкап
agmind help            # Все команды
```

---

## Требования

| Параметр | Минимум | Рекомендация |
|----------|---------|--------------|
| ОС | Ubuntu 20.04, Debian 11, CentOS Stream 9 | Ubuntu 22.04+ |
| RAM | 4 GB | 16 GB+ (32 GB для GPU-инференса) |
| CPU | 2 ядра | 4+ ядер |
| Диск | 20 GB | 100 GB+ (SSD) |
| Docker | 24.0+ | 27.0+ (ставится автоматически) |
| Compose | 2.20+ | 2.29+ (ставится автоматически) |
| GPU (опционально) | NVIDIA Pascal+ | Ampere+ (CUDA 12.0+) |

Pre-flight проверки выполняются автоматически (пропуск: `SKIP_PREFLIGHT=true`).

---

## Архитектура

### Три уровня

```
┌─────────────────────────────────────────────────────────────────┐
│  Infra Layer (installer)    │  install.sh, lib/*.sh             │
│  → Разворачивает и защищает инфраструктуру                     │
├─────────────────────────────────────────────────────────────────┤
│  AI Config Layer (user)     │  Dify UI, Open WebUI              │
│  → Пользователь настраивает workflow, KB, модели               │
├─────────────────────────────────────────────────────────────────┤
│  Operations Layer (CLI)     │  agmind status/doctor/backup/...  │
│  → Day-2 операции и мониторинг                                 │
└─────────────────────────────────────────────────────────────────┘
```

Инсталлер **не трогает Dify API**: не создаёт аккаунты, не импортирует workflow, не ставит плагины. Всё, что касается AI-конфигурации — задача пользователя через Dify UI.

### Сервисы (23-34 контейнера)

```
┌─────────────────────────────── agmind-frontend ───────────────────────────────┐
│                              nginx :80/:443                                   │
│                          ┌───────┴───────┐                                    │
│                     Open WebUI :8080   Dify Web :3000                          │
│  Grafana :3001    Portainer :9443                                              │
└───────────────────────────────────────────────────────────────────────────────┘
┌─────────────────────────────── agmind-backend ────────────────────────────────┐
│  Dify API :5001    Dify Worker    Plugin Daemon :5002                          │
│  PostgreSQL :5432  Redis :6379                                                │
│  Ollama :11434 / vLLM :8000 / TEI :8080                                       │
│  Weaviate :8080 / Qdrant :6333    Sandbox :8194                               │
│  Docling :8765     Xinference :9997                                            │
│  Prometheus  Alertmanager  cAdvisor  Loki  Promtail  Authelia                  │
└───────────────────────────────────────────────────────────────────────────────┘
┌───────────── ssrf-network ─────────────┐
│  sandbox  ssrf_proxy :3128  api worker │
└────────────────────────────────────────┘
```

**Сети:**
- `agmind-frontend` — bridge: nginx, grafana, portainer
- `agmind-backend` — bridge, **internal**: все core-сервисы (порты наружу не выставлены)
- `ssrf-network` — bridge, **internal**: sandbox + ssrf_proxy + api + worker (SSRF-изоляция)

---

## Этапы установки (9 фаз)

Установка поддерживает **checkpoint/resume** — при сбое повторный `sudo bash install.sh` продолжает с последней фазы. Полный лог записывается в `/opt/agmind/install.log` с таймстемпами.

| Фаза | Что происходит | Таймаут |
|------|----------------|---------|
| 1/9 | Диагностика системы + pre-flight checks (ОС, GPU, RAM, диск, порты) | — |
| 2/9 | Интерактивный визард (профиль, провайдер LLM/embedding, модель, TLS, мониторинг) | — |
| 3/9 | Установка Docker + Compose + NVIDIA toolkit (если отсутствуют) | — |
| 4/9 | Генерация .env, nginx.conf, redis.conf, credentials.txt, cron | — |
| 5/9 | Запуск контейнеров (`docker compose up --profile ...`) | 300с + retry |
| 6/9 | Ожидание healthcheck всех сервисов | 300с + retry |
| 7/9 | Загрузка LLM + embedding моделей (Ollama/vLLM) | 1200с + retry |
| 8/9 | Настройка cron-бэкапов | — |
| 9/9 | Итоговая информация с URL-ами и путём к credentials.txt | — |

При превышении таймаута фаза автоматически повторяется с удвоенным лимитом. Если повтор не помогает — выводится сообщение с инструкцией для ручного продолжения.

---

## Выбор LLM-провайдера

Визард спрашивает провайдера LLM и embedding отдельно. В зависимости от выбора активируются соответствующие compose profiles.

### LLM-провайдеры

| Провайдер | Compose profile | Описание |
|-----------|-----------------|----------|
| Ollama | `--profile ollama` | Локальный инференс, авто-загрузка моделей |
| vLLM | `--profile vllm` | Production-grade, OpenAI-совместимый API, tensor parallel |
| External | — | Внешний API (OpenAI, Anthropic и др.), контейнер LLM не запускается |
| Skip | — | Без LLM, только Dify + Open WebUI |

### Embedding-провайдеры

| Провайдер | Compose profile | Описание |
|-----------|-----------------|----------|
| Ollama | `--profile ollama` | Embedding через Ollama (bge-m3 и др.) |
| TEI | `--profile tei` | HuggingFace Text Embeddings Inference |
| External | — | Внешний embedding API |
| Same | — | Тот же провайдер, что и для LLM |

### Выбор модели (Ollama)

Инсталлер определяет GPU/RAM и рекомендует оптимальную модель (`lib/detect.sh` → `recommend_model()`).

| # | Модель | Размер | RAM | VRAM |
|---|--------|--------|-----|------|
| 1 | `gemma3:4b` | 4B | 8GB+ | 6GB+ |
| 2 | `qwen2.5:7b` | 7B | 8GB+ | 6GB+ |
| 3 | `qwen3:8b` | 8B | 8GB+ | 6GB+ |
| 4 | `llama3.1:8b` | 8B | 8GB+ | 6GB+ |
| 5 | `mistral:7b` | 7B | 8GB+ | 6GB+ |
| 6 | `qwen2.5:14b` ★ | 14B | 16GB+ | 10GB+ |
| 7 | `phi-4:14b` | 14B | 16GB+ | 10GB+ |
| 8 | `mistral-nemo:12b` | 12B | 16GB+ | 10GB+ |
| 9 | `gemma3:12b` | 12B | 16GB+ | 10GB+ |
| 10 | `qwen2.5:32b` | 32B | 32GB+ | 16GB+ |
| 11 | `gemma3:27b` | 27B | 32GB+ | 16GB+ |
| 12 | `command-r:35b` | 35B | 32GB+ | 16GB+ |
| 13 | `qwen2.5:72b-instruct-q4_K_M` | 72B | 64GB+ | 24GB+ |
| 14 | `llama3.1:70b-instruct-q4_K_M` | 70B | 64GB+ | 24GB+ |
| 15 | `qwen3:32b` | 32B | 32GB+ | 16GB+ |
| 16 | Своя модель | — | — | — |

★ — дефолт.

---

## Профили деплоя

| Профиль  | Интернет | TLS           | UFW | Fail2ban | SOPS | Описание |
|----------|----------|---------------|-----|----------|------|----------|
| `vps`    | ✅       | Let's Encrypt | да  | да       | да   | Публичный доступ через домен |
| `lan`    | ✅       | Опционально   | нет | да       | нет  | Локальная сеть офиса |
| `vpn`    | ✅       | Опционально   | нет | да       | нет  | Корпоративный VPN |
| `offline`| ❌       | нет           | нет | нет      | нет  | Изолированная сеть (air-gapped) |

Security-дефолты по профилю переопределяются через `DISABLE_SECURITY_DEFAULTS=true`.

---

## Compose profiles

| Profile | Сервисы | Активация |
|---------|---------|-----------|
| *(default)* | db, redis, api, worker, web, open-webui, nginx, sandbox, ssrf_proxy, plugin_daemon | Всегда |
| `ollama` | ollama | `LLM_PROVIDER=ollama` или `EMBED_PROVIDER=ollama` |
| `vllm` | vllm | `LLM_PROVIDER=vllm` |
| `tei` | tei | `EMBED_PROVIDER=tei` |
| `weaviate` | weaviate | `VECTOR_STORE=weaviate` |
| `qdrant` | qdrant | `VECTOR_STORE=qdrant` |
| `etl` | docling, xinference | `ETL_ENHANCED=yes` |
| `monitoring` | prometheus, alertmanager, grafana, cadvisor, loki, promtail, portainer, node-exporter | `MONITORING_MODE=local` |
| `vps` | certbot | `DEPLOY_PROFILE=vps` |
| `authelia` | authelia | `ENABLE_AUTHELIA=true` |

---

## agmind CLI

Устанавливается как `/usr/local/bin/agmind` (symlink). Управление стеком без необходимости запоминать пути и compose-команды.

| Команда | Описание | Root |
|---------|----------|------|
| `agmind status` | Контейнеры, GPU, модели, эндпоинты, путь к credentials | нет |
| `agmind status --json` | То же в JSON (совместим со схемой `/health`) | нет |
| `agmind doctor` | Диагностика: DNS, GPU, Docker, порты, диск, сеть | нет |
| `agmind doctor --json` | Диагностика в JSON | нет |
| `agmind backup` | Ручной бэкап | да |
| `agmind restore <path>` | Восстановление из бэкапа | да |
| `agmind update` | Rolling update с rollback | да |
| `agmind uninstall` | Удаление стека | да |
| `agmind rotate-secrets` | Ротация секретов | да |
| `agmind logs [service]` | Логи (проксирует docker compose logs) | нет |
| `agmind help` | Справка по всем командам | нет |

```bash
# Примеры
agmind status                  # Обзор стека
agmind doctor --json | jq .    # Машинночитаемая диагностика
sudo agmind backup             # Бэкап в /var/backups/agmind/
curl localhost/health | jq .   # Health endpoint (cron-обновляется каждую минуту)
```

---

## Компоненты и версии

Все образы запинены в `templates/versions.env` — единый source of truth. Ни один сервис не использует `:latest`.

| Компонент | Версия | Image |
|-----------|--------|-------|
| Dify API/Worker/Web | 1.13.0 | `langgenius/dify-api`, `langgenius/dify-web` |
| Open WebUI | v0.5.20 | `ghcr.io/open-webui/open-webui` |
| Ollama | 0.6.2 | `ollama/ollama` |
| vLLM | v0.8.4 | `vllm/vllm-openai` |
| TEI | cuda-1.9.2 | `ghcr.io/huggingface/text-embeddings-inference` |
| PostgreSQL | 15.10-alpine | `postgres` |
| Redis | 7.4.1-alpine | `redis` |
| Weaviate | 1.27.6 | `semitechnologies/weaviate` |
| Qdrant | v1.12.1 | `qdrant/qdrant` |
| Nginx | 1.27.3-alpine | `nginx` |
| Sandbox | 0.2.12 | `langgenius/dify-sandbox` |
| Squid (SSRF) | 6.6-24.04_edge | `ubuntu/squid` |
| Plugin Daemon | 0.5.3-local | `langgenius/dify-plugin-daemon` |
| Certbot | v3.1.0 | `certbot/certbot` |
| Docling Serve | v1.14.3 | `ghcr.io/docling-project/docling-serve` |
| Xinference | v0.16.3 | `xprobe/xinference` |
| Authelia | 4.38 | `authelia/authelia` |
| Grafana | 11.4.0 | `grafana/grafana` |
| Portainer | 2.21.4 | `portainer/portainer-ce` |
| cAdvisor | v0.55.1 | `gcr.io/cadvisor/cadvisor` |
| Node Exporter | v1.8.2 | `prom/node-exporter` |
| Prometheus | v2.54.1 | `prom/prometheus` |
| Alertmanager | v0.27.0 | `prom/alertmanager` |
| Loki | 3.3.2 | `grafana/loki` |
| Promtail | 3.3.2 | `grafana/promtail` |

Open WebUI запинен на v0.5.20 для совместимости с white-label брендингом.

---

## GPU поддержка

Автоматическое определение в `lib/detect.sh` → `detect_gpu()`:

| GPU | Обнаружение | Метод в docker-compose |
|-----|-------------|----------------------|
| NVIDIA | `nvidia-smi` | deploy.resources.reservations (CUDA) |
| AMD ROCm | `/dev/kfd`, `rocminfo` | device passthrough + `OLLAMA_ROCM=1` |
| Intel Arc | `/dev/dri` + `lspci` | device passthrough |
| Apple M | arm64 + Darwin | Metal нативно (GPU блок удаляется) |
| CPU | fallback | GPU блоки удаляются, `OLLAMA_NUM_PARALLEL=2` |

Переопределение:
```bash
FORCE_GPU_TYPE=amd bash install.sh --non-interactive    # Принудительно AMD
SKIP_GPU_DETECT=true bash install.sh --non-interactive  # Без GPU
```

---

## Безопасность

### Контейнерный уровень

```yaml
x-security-defaults: &security-defaults
  sysctls:
    - net.ipv6.conf.all.disable_ipv6=1
  cap_drop: [ALL]                          # Все capabilities сброшены
  security_opt:
    - no-new-privileges:true               # Запрет эскалации привилегий
  logging:
    driver: json-file
    options: { max-size: 10m, max-file: "5" }
```

Все сервисы наследуют `*security-defaults`. Per-service `cap_add` добавляется точечно.

### Host-уровень

| Механизм | Профиль | Описание |
|----------|---------|----------|
| UFW | VPS | Deny incoming, allow 22/80/443 |
| Fail2ban | VPS/LAN/VPN | SSH jail (3 retries → 10d ban) |
| SOPS + Age | VPS | Шифрование .env → .env.enc, keypair в `.age/agmind.key` |
| Secret Rotation | Opt-in | `agmind rotate-secrets` — ротация SECRET_KEY, паролей БД/Redis |

### Защита данных

- **Credentials**: хранятся только в `credentials.txt` (chmod 600), терминал показывает только путь к файлу — пароли никогда не выводятся в stdout
- **Nginx**: rate limiting (10r/s API, 1r/10s login burst=3), security headers (X-Frame-Options DENY, X-Content-Type-Options, XSS-Protection, Referrer-Policy, Permissions-Policy), `server_tokens off`
- **Admin UI**: Grafana/Portainer привязаны к `127.0.0.1` по умолчанию — opt-in открытие через визард
- **SSRF Proxy**: изолированная сеть, ACL блокирует RFC1918, link-local и `169.254.169.254` (metadata)
- **Authelia**: 2FA на `/console/*` (Dify UI); API-маршруты `/api`, `/v1`, `/files` обходят Authelia (используют собственную API key авторизацию + rate limiting)
- **PostgreSQL**: `password_encryption=scram-sha-256`
- **Redis**: `requirepass`, опасные команды отключены (FLUSHALL, CONFIG, DEBUG, SHUTDOWN)
- **Секреты**: авто-генерация (64 символа SECRET_KEY, 32 символа пароли), блокировка `changeme`/`password`/`difyai123456`
- **.env**: `chmod 600`, `chown root:root`
- **Lock file**: symlink protection (`/var/lock/agmind-install.lock`)

### Security-дефолты по профилям

| Переменная | vps | lan | vpn | offline |
|------------|-----|-----|-----|---------|
| `ENABLE_UFW` | true | false | false | false |
| `ENABLE_FAIL2BAN` | true | true | true | false |
| `ENABLE_SOPS` | true | false | false | false |
| `ENABLE_SECRET_ROTATION` | false | false | false | false |
| `ENABLE_AUTHELIA` | false | false | false | false |

---

## Мониторинг

Активируется при `MONITORING_MODE=local` (compose profile: `monitoring`).

### Стек

| Компонент | Роль | Порт |
|-----------|------|------|
| Prometheus | Сбор метрик (scrape 15s) | 9090 (internal) |
| Alertmanager | Маршрутизация алертов | 9093 (internal) |
| Grafana | Дашборды + визуализация | 3001 (127.0.0.1) |
| cAdvisor | Метрики контейнеров | 8081 (internal) |
| Node Exporter | Метрики хоста | 9100 (internal) |
| Loki | Агрегация логов (retention 30d) | 3100 (internal) |
| Promtail | Сбор Docker-логов | 9080 (internal) |
| Portainer | Управление контейнерами | 9443 (127.0.0.1) |

### Dashboards (auto-provisioned)

- `overview.json` — системный обзор
- `containers.json` — метрики Docker-контейнеров
- `logs.json` — Loki log viewer
- `alerts.json` — статус алертов

### Alert rules

| Алерт | Условие | Severity |
|-------|---------|----------|
| ContainerDown | Контейнер не виден >2 мин | critical |
| ContainerRestartLoop | >3 рестартов за 15 мин | critical |
| HighCpuUsage | >90% CPU >5 мин | warning |
| HighMemoryUsage | >90% RAM (при наличии лимита) | warning |
| DiskSpaceLow | <15% свободного места | warning |
| DiskSpaceCritical | <5% свободного места | critical |

### Каналы уведомлений

```bash
ALERT_MODE=telegram
ALERT_TELEGRAM_TOKEN=...
ALERT_TELEGRAM_CHAT_ID=...

ALERT_MODE=webhook
ALERT_WEBHOOK_URL=https://...
```

---

## Nginx routing

Nginx обслуживает два сервера: порт 80 (Open WebUI) и порт 3000 (Dify Console).

**Порт 80 — Open WebUI:**

| Путь | Upstream | Примечание |
|------|----------|------------|
| `/` | `open-webui:8080` | Основной чат-интерфейс (WebSocket) |
| `/health` | static JSON | Health endpoint (cron-обновляется каждую минуту) |
| `/.well-known/acme-challenge/` | файловая система | Certbot ACME |
| `~ ^/[a-f0-9]{24,}/` | — | Блокируется (return 404) |

**Порт 3000 — Dify Console:**

| Путь | Upstream | Примечание |
|------|----------|------------|
| `/` | `dify_web:3000` | Dify Console UI (Next.js) |
| `/console/api` | `dify_api:5001` | Console API (rate limit: 10r/s) |
| `/api` | `dify_api:5001` | Dify API (rate limit: 10r/s) |
| `/v1` | `dify_api:5001` | Dify Service API |
| `/files` | `dify_api:5001` | Dify файлы |
| `/e/` | `plugin_daemon:5002` | Plugin Daemon |

TLS-блок (порт 443) дублирует маршруты порта 80. Управляется маркерами `#__TLS__` и `#__TLS_REDIRECT__`.
Authelia 2FA: маркеры `#__AUTHELIA__` активируются при `ENABLE_AUTHELIA=true`.

---

## Скрипты и операции

### agmind CLI

Основная точка входа для всех day-2 операций. Устанавливается как symlink `/usr/local/bin/agmind`.

```bash
agmind status              # Контейнеры + GPU + модели + эндпоинты
agmind status --json       # Машинночитаемый JSON
agmind doctor              # DNS, GPU, Docker, порты, диск
agmind doctor --json       # Диагностика в JSON
sudo agmind backup         # Ручной бэкап
sudo agmind restore <path> # Восстановление
sudo agmind update         # Rolling update
sudo agmind uninstall      # Удаление стека
sudo agmind rotate-secrets # Ротация секретов
agmind logs [service]      # Docker-логи
```

### Standalone-скрипты

Копируются в `/opt/agmind/scripts/` при установке.

| Скрипт | Назначение | Ключевые флаги |
|--------|-----------|----------------|
| `backup.sh` | Бэкап PostgreSQL + volumes + конфиг + checksums | `ENABLE_S3_BACKUP`, `ENABLE_BACKUP_ENCRYPTION`, `BACKUP_RETENTION_COUNT` |
| `restore.sh` | Восстановление из бэкапа (интерактивный) | `AUTO_CONFIRM=true`, `<backup_path>` |
| `restore-runbook.sh` | 7-step verified restore с валидацией | `<backup_path>` |
| `update.sh` | Rolling update с rollback | `--auto`, `--check-only` |
| `health-gen.sh` | Генерация health.json для nginx `/health` endpoint | cron каждую минуту |
| `rotate_secrets.sh` | Ротация секретов в .env | — |
| `uninstall.sh` | Удаление контейнеров + volumes + конфигурации | `--force`, `--dry-run` |
| `multi-instance.sh` | Создание изолированных инстансов (multi-tenant) | `create\|list\|delete --name NAME --port-offset N` |
| `build-offline-bundle.sh` | Сборка offline-архива с Docker-образами + моделями | `--include-models M1,M2`, `--platform`, `--skip-images` |
| `dr-drill.sh` | Ежемесячный DR тест (бэкап → проверка) | `--dry-run`, `--skip-restore`, `--report-only` |

### Бэкап и восстановление

```bash
# Ручной бэкап
sudo agmind backup

# Восстановление (интерактивное)
sudo agmind restore /var/backups/agmind/2026-03-15_0300

# 7-step verified restore
sudo /opt/agmind/scripts/restore-runbook.sh /var/backups/agmind/2026-03-15_0300
```

Состав бэкапа: `dify_db.sql.gz`, `dify_plugin_db.sql.gz`, `volumes.tar.gz`, `config.tar.gz`, `sha256sums.txt`

Cron: `0 3 * * *` (фаза 8/9). Хранилище: `/var/backups/agmind/`

```bash
BACKUP_RETENTION_COUNT=10       # Хранить N последних
ENABLE_S3_BACKUP=true           # Загрузка через rclone
ENABLE_BACKUP_ENCRYPTION=true   # Шифрование (age)
ENABLE_DR_DRILL=true            # Ежемесячный DR drill cron
```

### Обновление

```bash
sudo agmind update                                        # Интерактивное
sudo /opt/agmind/scripts/update.sh --auto                 # Автоматическое
sudo /opt/agmind/scripts/update.sh --check-only           # Только проверка версий
```

Порядок: pre-flight → бэкап → сравнение с `versions.env` → rolling restart по одному сервису → healthcheck → rollback при ошибке → уведомление.

---

## Переменные окружения

### Основные

| Переменная | Описание | По умолчанию |
|------------|-------|--------------|
| `DEPLOY_PROFILE` | Профиль: vps/lan/vpn/offline | lan |
| `DOMAIN` | Домен (обязателен для VPS) | — |
| `CERTBOT_EMAIL` | Email для Let's Encrypt | — |
| `LLM_PROVIDER` | Провайдер LLM: ollama/vllm/external/skip | ollama |
| `EMBED_PROVIDER` | Провайдер embedding: ollama/tei/external/same | same |
| `LLM_MODEL` | Модель LLM (для Ollama/vLLM) | qwen2.5:14b |
| `EMBEDDING_MODEL` | Embedding модель | bge-m3 |
| `VECTOR_STORE` | weaviate / qdrant | weaviate |
| `ETL_ENHANCED` | Docling + Xinference (yes/no) | no |
| `TLS_MODE` | none / self-signed / custom / letsencrypt | none (vps: letsencrypt) |
| `MONITORING_MODE` | none / local / external | none |
| `ALERT_MODE` | none / webhook / telegram | none |
| `BACKUP_TARGET` | local / remote / both | local |
| `BACKUP_SCHEDULE` | Cron расписание | 0 3 * * * |
| `NON_INTERACTIVE` | Без интерактивного визарда | false |
| `FORCE_REINSTALL` | Разрешить переустановку | false |

### Безопасность

| Переменная | Описание | По умолчанию |
|------------|-------|--------------|
| `ENABLE_UFW` | UFW файрвол | по профилю |
| `ENABLE_FAIL2BAN` | Fail2ban IDS | по профилю |
| `ENABLE_SOPS` | SOPS + age шифрование .env | по профилю |
| `ENABLE_AUTHELIA` | Authelia 2FA proxy | false |
| `ENABLE_SECRET_ROTATION` | Авто-ротация секретов (cron) | false |
| `ADMIN_UI_OPEN` | Открыть Grafana/Portainer на 0.0.0.0 | false |
| `FORCE_GPU_TYPE` | Принудительный тип GPU (nvidia/amd/intel/apple) | авто |
| `SKIP_GPU_DETECT` | Пропустить GPU детекцию | false |
| `SKIP_PREFLIGHT` | Пропустить pre-flight проверки | false |
| `SKIP_DOCKER_HARDENING` | Пропустить hardening compose | false |
| `DISABLE_SECURITY_DEFAULTS` | Не применять security defaults | false |

### Таймауты и бэкапы

| Переменная | Описание | По умолчанию |
|------------|-------|--------------|
| `TIMEOUT_START` | Таймаут фазы 5 (запуск контейнеров) | 300с |
| `TIMEOUT_HEALTH` | Таймаут фазы 6 (healthcheck) | 300с |
| `TIMEOUT_MODELS` | Таймаут фазы 7 (загрузка моделей) | 1200с |
| `BACKUP_RETENTION_COUNT` | Макс. количество бэкапов | 10 |
| `ENABLE_S3_BACKUP` | Загрузка в S3 (rclone) | false |
| `ENABLE_BACKUP_ENCRYPTION` | Шифрование бэкапов (age) | false |
| `ENABLE_DR_DRILL` | Ежемесячный DR drill | true |
| `ENABLE_LOKI` | Loki log aggregation | true |
| `HEALTHCHECK_INTERVAL` | Интервал healthcheck | 30s |
| `HEALTHCHECK_RETRIES` | Количество попыток | 5 |

---

## Структура установки

```
/opt/agmind/
├── docker/
│   ├── .env                       # Конфигурация (chmod 600, root:root)
│   ├── docker-compose.yml         # 23+ сервисов, 3 сети, compose profiles
│   ├── nginx/nginx.conf           # Reverse proxy + /health endpoint
│   ├── authelia/                  # Если ENABLE_AUTHELIA=true
│   │   ├── configuration.yml
│   │   └── users_database.yml
│   ├── monitoring/                # Если MONITORING_MODE=local
│   │   ├── prometheus.yml
│   │   ├── alertmanager.yml
│   │   ├── alert_rules.yml
│   │   ├── loki-config.yml
│   │   ├── promtail-config.yml
│   │   └── grafana/
│   │       ├── provisioning/datasources/
│   │       ├── provisioning/dashboards/
│   │       └── dashboards/*.json
│   └── volumes/
│       ├── app/storage/           # Dify uploads
│       ├── db/data/               # PostgreSQL
│       ├── redis/                 # Redis data + redis.conf
│       ├── weaviate/ или qdrant/  # Vector store
│       ├── sandbox/conf/          # Sandbox config
│       ├── ssrf_proxy/squid.conf  # SSRF proxy ACL
│       ├── plugin_daemon/storage/ # Plugin storage
│       └── certbot/               # TLS certificates
├── scripts/                       # Операционные скрипты + agmind CLI
├── workflows/
│   ├── rag-assistant.json         # RAG workflow шаблон для Dify
│   └── README.md                  # Инструкции по ручной настройке Dify
├── branding/
│   ├── logo.svg
│   └── theme.json                 # Open WebUI white-label
├── credentials.txt                # Пароли (chmod 600) — единый источник
├── versions.env                   # Пиннинг версий (единый source of truth)
├── install.log                    # Лог установки с таймстемпами (chmod 600)
├── .install_phase                 # Checkpoint для resume
└── .agmind_installed              # Маркер завершённой установки
```

---

## Миграция с v1

При запуске `install.sh` на существующей v1-инсталляции:
- Автоматически добавляются `LLM_PROVIDER=ollama` и `EMBED_PROVIDER=ollama` в `.env`
- Существующие Docker volumes сохраняются (без переименования в `agmind_` prefix)
- Новые инсталляции используют named volumes с `agmind_` prefix

---

## Multi-Instance (Multi-Tenant)

```bash
# Создать изолированный инстанс
/opt/agmind/scripts/multi-instance.sh create --name client-a --port-offset 100 --domain client-a.example.com

# Список инстансов
/opt/agmind/scripts/multi-instance.sh list

# Удалить инстанс
/opt/agmind/scripts/multi-instance.sh delete --name client-a
```

Каждый инстанс получает: отдельный `INSTALL_DIR`, `COMPOSE_PROJECT_NAME`, Docker-сети, смещение портов.

---

## Offline-установка

```bash
# 1. На машине с интернетом: собрать bundle
./scripts/build-offline-bundle.sh --include-models qwen2.5:14b,bge-m3 --platform linux/amd64

# 2. Перенести архив на air-gapped сервер

# 3. Установить
sudo DEPLOY_PROFILE=offline bash install.sh
```

В offline-профиле: marketplace отключён, sandbox network disabled, CHECK_UPDATE_URL пуст, plugins не устанавливаются.

---

## CI/CD

| Workflow | Что проверяет | Блокирует? |
|----------|---------------|------------|
| **Lint** | ShellCheck (все .sh), yamllint (docker-compose.yml), JSON validate, `bash -n` syntax | Да |
| **Tests** | BATS unit tests, Trivy security scan (CRITICAL/HIGH) | Да |

---

## Устранение неполадок

```bash
# Обзор стека
agmind status

# Диагностика проблем
agmind doctor

# Health endpoint
curl localhost/health | jq .

# Логи конкретного сервиса
agmind logs api

# Статус всех контейнеров
cd /opt/agmind/docker && docker compose ps

# Перезапуск сервиса
cd /opt/agmind/docker && docker compose restart <service>

# Ollama не отвечает
cd /opt/agmind/docker && docker compose exec ollama ollama list
cd /opt/agmind/docker && docker compose restart ollama

# Сертификат не получен (VPS)
dig +short your-domain.com
cd /opt/agmind/docker && docker compose exec certbot certbot certonly \
    --webroot -w /var/www/certbot -d your-domain.com
cd /opt/agmind/docker && docker compose restart nginx

# Параллельные операции заблокированы
rm -f /var/lock/agmind-install.lock
rm -f /var/lock/agmind-operation.lock

# Установка упала на фазе N — resume
sudo bash install.sh    # Продолжит с последнего checkpoint

# Полный install.log
cat /opt/agmind/install.log

# Полное восстановление
ls -lt /var/backups/agmind/
sudo agmind restore /var/backups/agmind/<backup>
agmind doctor
```

---

## Документация

Полная документация: `docs/` (Docusaurus)

```bash
cd docs && npm install && npm start
```

Инструкция по настройке Dify (workflow, Knowledge Base, плагины): `workflows/README.md`

---

## Совместимость

[COMPATIBILITY.md](COMPATIBILITY.md) — матрица версий, ОС, минимальные требования.

---

## Лицензия

Open Source. См. [LICENSE](LICENSE).
