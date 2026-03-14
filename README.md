# AGMind Installer

Production-ready RAG-стек: **Dify + Open WebUI + Ollama** — автоматическая установка за 11 шагов.

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
sudo DEPLOY_PROFILE=lan ADMIN_EMAIL=admin@company.com \
     COMPANY_NAME="My Corp" LLM_MODEL=qwen2.5:14b \
     bash install.sh --non-interactive
```

После установки:

| Сервис | URL | Примечание |
|--------|-----|------------|
| Open WebUI (чат) | `http://server/` | Основной интерфейс |
| Dify Console | `http://server/dify/` | Управление workflow |
| Grafana | `http://server:3001/` | Только при `MONITORING_MODE=local` |
| Portainer | `https://server:9443/` | Только при `MONITORING_MODE=local` |

Пароль администратора: `/opt/agmind/.admin_password`

---

## Этапы установки (11 фаз)

| Фаза | Что происходит |
|------|----------------|
| 1/11 | Диагностика системы + pre-flight checks |
| 2/11 | Интерактивный визард (профиль, модель, TLS, мониторинг, бэкапы) |
| 3/11 | Установка Docker (если отсутствует) |
| 4/11 | Генерация .env, nginx.conf, копирование скриптов |
| 5/11 | Запуск контейнеров (docker compose up) |
| 6/11 | Ожидание healthcheck всех сервисов (300 сек таймаут) |
| 7/11 | Загрузка LLM + embedding моделей в Ollama |
| 8/11 | Импорт RAG workflow в Dify |
| 9/11 | Настройка cron-бэкапов |
| 10/11 | Dokploy + SSH tunnel (опционально) |
| 11/11 | Итоговая информация |

---

## Профили деплоя

| Профиль  | Интернет | TLS           | UFW | Fail2ban | SOPS | Описание |
|----------|----------|---------------|-----|----------|------|----------|
| `vps`    | ✅       | Let's Encrypt | да  | да       | да   | Публичный доступ через домен |
| `lan`    | ✅       | Опционально   | нет | да       | нет  | Локальная сеть офиса |
| `vpn`    | ✅       | Опционально   | нет | да       | нет  | Корпоративный VPN |
| `offline`| ❌       | нет           | нет | нет      | нет  | Изолированная сеть |

Security-дефолты задаются в `phase_wizard()` через `DISABLE_SECURITY_DEFAULTS=true` для переопределения.

---

## Компоненты и версии

Все образы запинены в `templates/versions.env`. Ни один сервис не использует `:latest`.

| Компонент | Версия | Image |
|-----------|--------|-------|
| Dify API/Worker/Web | 1.13.0 | `langgenius/dify-api`, `langgenius/dify-web` |
| Open WebUI | v0.5.20 | `ghcr.io/open-webui/open-webui` |
| Ollama | 0.6.2 | `ollama/ollama` |
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
| cAdvisor | v0.49.1 | `gcr.io/cadvisor/cadvisor` |
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
| CPU | fallback | GPU блоки удаляются из compose |

Переопределение:
```bash
FORCE_GPU_TYPE=amd bash install.sh --non-interactive    # Принудительно AMD
SKIP_GPU_DETECT=true bash install.sh --non-interactive  # Без GPU
```

---

## Nginx routing

Определено в `templates/nginx.conf.template`, генерируется `lib/config.sh` → `generate_nginx_config()`.

| Путь | Upstream | Примечание |
|------|----------|------------|
| `/` | `open-webui:8080` | Основной фронтенд |
| `/dify/` | `dify_web:3000` | Dify Console (sub_filter для path rewrite) |
| `/dify/console/api` | `dify_api:5001` | Dify Console API (rate limit: 10r/s) |
| `/dify/api` | `dify_api:5001` | Dify API |
| `/dify/v1` | `dify_api:5001` | Dify Service API |
| `/dify/files` | `dify_api:5001` | Dify файлы |
| `/dify/e/` | `plugin_daemon:5002` | Plugin Daemon |
| `/dify/_next` | `dify_web:3000` | Static assets |
| `~ ^/[a-f0-9]{24,}/` | — | Блокируется (return 404) |

TLS-блок дублирует все маршруты. Управляется маркерами `#__TLS__` и `#__TLS_REDIRECT__`.
Authelia 2FA: маркеры `#__AUTHELIA__` активируются при `ENABLE_AUTHELIA=true`.

---

## Docker networks

| Сеть | Тип | Сервисы |
|------|-----|---------|
| `agmind-frontend` | bridge | nginx, grafana, portainer |
| `agmind-backend` | bridge, internal | api, worker, web, db, redis, ollama, weaviate/qdrant, plugin_daemon, sandbox, pipeline, open-webui, все мониторинговые |
| `ssrf-network` | bridge, internal | sandbox, ssrf_proxy, api, worker |

Backend — `internal: true`, порты наружу не выставлены.

---

## Безопасность

Реализовано в docker-compose.yml, lib/config.sh, lib/security.sh:

| Уровень | Механизм | Где реализовано |
|---------|----------|----------------|
| Контейнеры | `security_opt: [no-new-privileges:true]`, `cap_drop: [ALL]` | x-security-defaults anchor |
| Контейнеры | Read-only fs (nginx, redis) | `read_only: true` + tmpfs |
| Nginx | Rate limiting (10r/s API, 3r/s login) | nginx.conf.template |
| Nginx | Security headers (X-Frame-Options, X-Content-Type-Options, XSS, Referrer-Policy, Permissions-Policy) | nginx.conf.template |
| Nginx | `server_tokens off` | nginx.conf.template |
| PostgreSQL | `password_encryption=scram-sha-256` | docker-compose.yml |
| Redis | `requirepass`, опасные команды отключены (FLUSHALL, CONFIG, DEBUG) | lib/config.sh → `generate_redis_config()` |
| Секреты | Авто-генерация (64 символа SECRET_KEY, 32 символа пароли) | lib/config.sh → `generate_config()` |
| Секреты | Валидация: блокировка `changeme`, `password`, `difyai123456` и нерезольвленных `__PLACEHOLDER__` | lib/config.sh → `validate_no_default_secrets()` |
| .env | `chmod 600`, `chown root:root` | lib/config.sh |
| Healthcheck | 24 из 25 сервисов (все кроме certbot) | docker-compose.yml |
| Restart | `restart: always` на всех сервисах (certbot: `unless-stopped`) | docker-compose.yml |

### Security-дефолты по профилям (из env templates)

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

Сервисы: Prometheus, Alertmanager, Grafana, cAdvisor, Loki, Promtail, Portainer.

Порты (из env templates):
- Grafana: `${GRAFANA_PORT:-3001}`, bind: `127.0.0.1` (vps) / `0.0.0.0` (lan/vpn)
- Portainer: `${PORTAINER_PORT:-9443}`, bind: `127.0.0.1` (vps) / `0.0.0.0` (lan/vpn)

### Алерты

Каналы (`ALERT_MODE`):
```bash
ALERT_MODE=telegram
ALERT_TELEGRAM_TOKEN=...
ALERT_TELEGRAM_CHAT_ID=...

ALERT_MODE=webhook
ALERT_WEBHOOK_URL=https://...
```

---

## Скрипты

Копируются в `/opt/agmind/scripts/` на фазе 4/11.

| Скрипт | Назначение | Ключевые флаги |
|--------|-----------|----------------|
| `backup.sh` | Бэкап PostgreSQL (pg_dump), volumes, конфиг, checksums | `ENABLE_S3_BACKUP`, `ENABLE_BACKUP_ENCRYPTION`, `BACKUP_RETENTION_COUNT` |
| `restore.sh` | Восстановление из бэкапа | `AUTO_CONFIRM=true` |
| `restore-runbook.sh` | 7-step verified restore | `<backup_path>` |
| `update.sh` | Rolling update с rollback | `--auto`, `--check-only` |
| `health.sh` | Проверка здоровья всех сервисов | `--send-test` |
| `rotate_secrets.sh` | Ротация секретов в .env | — |
| `uninstall.sh` | Удаление контейнеров, volumes, конфигурации | `--force`, `--dry-run` |
| `multi-instance.sh` | Создание изолированных инстансов | `create\|list\|delete --name NAME --port-offset N` |
| `build-offline-bundle.sh` | Сборка offline-архива с образами | `--include-models M1,M2`, `--platform`, `--skip-images` |
| `dr-drill.sh` | Ежемесячный DR тест | `--dry-run`, `--skip-restore`, `--report-only` |

### Бэкап

```bash
/opt/agmind/scripts/backup.sh                          # Ручной
/opt/agmind/scripts/restore.sh /var/backups/agmind/...  # Восстановление
/opt/agmind/scripts/restore-runbook.sh /var/backups/...  # 7-step verified
```

Бэкап создаёт: `dify_db.sql.gz`, `dify_plugin_db.sql.gz`, volumes tar, SHA256 checksums.

Cron настраивается на фазе 9/11 (дефолт: `0 3 * * *`).

```bash
BACKUP_RETENTION_COUNT=10       # Хранить N последних
ENABLE_S3_BACKUP=true           # Загрузка через rclone
ENABLE_BACKUP_ENCRYPTION=true   # Шифрование (age)
ENABLE_DR_DRILL=true            # Ежемесячный DR drill cron
```

### Обновление

```bash
/opt/agmind/scripts/update.sh              # Интерактивное
/opt/agmind/scripts/update.sh --auto       # Автоматическое
/opt/agmind/scripts/update.sh --check-only # Только проверка версий
```

Порядок: pre-flight → бэкап → сравнение версий → rolling restart по одному сервису → healthcheck → rollback при ошибке.

---

## Переменные окружения

### Основные (парсятся в install.sh)

| Переменная | Описание | По умолчанию |
|------------|-------|--------------|
| `DEPLOY_PROFILE` | Профиль: vps/lan/vpn/offline | lan |
| `DOMAIN` | Домен (только VPS) | — |
| `CERTBOT_EMAIL` | Email для Let's Encrypt (VPS) | — |
| `COMPANY_NAME` | Название компании (Open WebUI branding) | AGMind |
| `ADMIN_EMAIL` | Email администратора | admin@admin.com |
| `ADMIN_PASSWORD` | Пароль (пусто = авто-генерация 16 символов) | авто |
| `LLM_MODEL` | Модель LLM для Ollama | qwen2.5:14b |
| `EMBEDDING_MODEL` | Embedding модель | bge-m3 |
| `VECTOR_STORE` | weaviate / qdrant | weaviate |
| `ETL_ENHANCED` | Docling + Xinference (yes/no) | no |
| `TLS_MODE` | none / self-signed / custom / letsencrypt | none (vps: letsencrypt) |
| `MONITORING_MODE` | none / local / external | none |
| `ALERT_MODE` | none / webhook / telegram | none |
| `BACKUP_TARGET` | local / remote / both | local |
| `BACKUP_SCHEDULE` | Cron расписание бэкапов | 0 3 * * * |
| `NON_INTERACTIVE` | Без интерактивного визарда | false |
| `FORCE_REINSTALL` | Разрешить переустановку в non-interactive | false |

### Безопасность

| Переменная | Описание | По умолчанию |
|------------|-------|--------------|
| `ENABLE_UFW` | UFW файрвол | false (vps: true) |
| `ENABLE_FAIL2BAN` | Fail2ban IDS | false (vps/lan/vpn: true) |
| `ENABLE_SOPS` | SOPS + age шифрование .env | false (vps: true) |
| `ENABLE_AUTHELIA` | Authelia 2FA proxy | false |
| `ENABLE_SECRET_ROTATION` | Авто-ротация секретов | false |
| `FORCE_GPU_TYPE` | Принудительный тип GPU (nvidia/amd/intel/apple) | — |
| `SKIP_GPU_DETECT` | Пропустить GPU детекцию | false |
| `SKIP_PREFLIGHT` | Пропустить pre-flight проверки | false |
| `DISABLE_SECURITY_DEFAULTS` | Не применять security defaults для профиля | false |

### Бэкапы и мониторинг

| Переменная | Описание | По умолчанию |
|------------|-------|--------------|
| `BACKUP_RETENTION_COUNT` | Макс. количество бэкапов | — |
| `ENABLE_S3_BACKUP` | Загрузка в S3 (rclone) | false |
| `ENABLE_BACKUP_ENCRYPTION` | Шифрование бэкапов (age) | false |
| `ENABLE_DR_DRILL` | Ежемесячный DR drill cron | true |
| `ENABLE_LOKI` | Loki log aggregation (при monitoring) | true |
| `HEALTHCHECK_INTERVAL` | Интервал healthcheck | 30s |
| `HEALTHCHECK_RETRIES` | Количество попыток healthcheck | 5 |

### Wizard shortcuts (non-interactive)

| Переменная | Значения |
|------------|----------|
| `VECTOR_STORE_CHOICE` | 1 (weaviate) / 2 (qdrant) |
| `ETL_ENHANCED_CHOICE` | 1 (нет) / 2 (да) |
| `TLS_MODE_CHOICE` | 1 (none) / 2 (self-signed) / 3 (custom) |
| `MONITORING_CHOICE` | 1 (none) / 2 (local) / 3 (external) |
| `ALERT_CHOICE` | 1 (none) / 2 (webhook) / 3 (telegram) |
| `ENABLE_UFW_CHOICE` | 1 (да) / 2 (нет) |
| `ENABLE_FAIL2BAN_CHOICE` | 1 (да) / 2 (нет) |
| `ENABLE_AUTHELIA_CHOICE` | 1 (нет) / 2 (да) |
| `DOKPLOY_CHOICE` | 1 (да) / 2 (нет) |
| `TUNNEL_CHOICE` | 1 (да) / 2 (нет) |

---

## Выбор LLM модели

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

## Структура установки

```
/opt/agmind/
├── docker/
│   ├── .env                       # Конфигурация (chmod 600, root:root)
│   ├── docker-compose.yml         # 25 сервисов, 3 сети
│   ├── nginx/nginx.conf           # Из nginx.conf.template
│   ├── pipeline/                  # Dockerfile + dify_pipeline.py
│   ├── authelia/                  # Если ENABLE_AUTHELIA=true
│   ├── monitoring/                # Prometheus, Grafana, Loki конфиги
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
│       ├── db/data/               # PostgreSQL data
│       ├── redis/                 # Redis data + redis.conf
│       ├── weaviate/              # Weaviate data
│       ├── qdrant/                # Qdrant data
│       ├── sandbox/conf/          # Sandbox config.yaml
│       ├── ssrf_proxy/squid.conf  # Squid config
│       ├── plugin_daemon/storage/ # Plugin storage
│       └── certbot/               # TLS certs
├── scripts/
│   ├── backup.sh
│   ├── restore.sh
│   ├── restore-runbook.sh
│   ├── health.sh
│   ├── update.sh
│   ├── rotate_secrets.sh
│   ├── multi-instance.sh
│   └── uninstall.sh
├── workflows/
│   ├── rag-assistant.json         # RAG workflow для импорта в Dify
│   └── import.py                  # Скрипт импорта
├── branding/
│   ├── logo.svg
│   └── theme.json
├── versions.env                   # Пиннинг версий
├── release-manifest.json
├── .admin_password                # chmod 600
└── .agmind_installed              # Маркер завершённой установки
```

---

## CI/CD

| Workflow | Что проверяет | Блокирует? |
|----------|---------------|------------|
| **Lint** | ShellCheck (все .sh), yamllint (docker-compose.yml), JSON validate, bash -n | Да |
| **Tests** | BATS unit tests (11 тестов), Trivy security scan (CRITICAL/HIGH) | Да |

---

## Устранение неполадок

```bash
# Логи конкретного сервиса
cd /opt/agmind/docker && docker compose logs -f api

# Статус всех контейнеров
cd /opt/agmind/docker && docker compose ps

# Health check
/opt/agmind/scripts/health.sh

# Перезапуск сервиса
cd /opt/agmind/docker && docker compose restart <service>

# Dify Console не открывается — проверить nginx
cd /opt/agmind/docker && docker compose logs nginx

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

# Полное восстановление
ls -lt /var/backups/agmind/
sudo /opt/agmind/scripts/restore-runbook.sh /var/backups/agmind/<backup>
/opt/agmind/scripts/health.sh
```

---

## Документация

Полная документация: `docs/` (Docusaurus)

```bash
cd docs && npm install && npm start
```

---

## Совместимость

[COMPATIBILITY.md](COMPATIBILITY.md) — матрица версий, ОС, минимальные требования.

---

## Лицензия

Open Source. См. [LICENSE](LICENSE).
