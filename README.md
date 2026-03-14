# AGMind Installer

Production-ready RAG-стек: **Dify + Open WebUI + Ollama** — автоматическая установка, безопасность, мониторинг и DR.

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

| Сервис | URL |
|--------|-----|
| Open WebUI (чат) | `http://server/` |
| Dify Console | `http://server/dify/` |
| Grafana (мониторинг) | `http://server:3001/` |

Пароль администратора сохранён в `/opt/agmind/docker/.admin_password`.

---

## Профили деплоя

| Профиль  | Интернет | TLS           | UFW | Fail2ban | Описание                       |
|----------|----------|---------------|-----|----------|--------------------------------|
| `vps`    | ✅       | Let's Encrypt | ✅  | ✅       | Публичный доступ через домен   |
| `lan`    | ✅       | Опционально   | ❌  | ✅       | Локальная сеть офиса           |
| `vpn`    | ✅       | Опционально   | ❌  | ✅       | Корпоративный VPN              |
| `offline`| ❌       | ❌            | ❌  | ❌       | Изолированная сеть             |

## GPU поддержка

Автоматическое определение GPU:

| GPU       | Обнаружение           | Метод                          |
|-----------|-----------------------|--------------------------------|
| NVIDIA    | `nvidia-smi`          | deploy.resources (CUDA)        |
| AMD ROCm  | `/dev/kfd`, `rocminfo`| device passthrough             |
| Intel Arc | `/dev/dri` + `lspci`  | device passthrough             |
| Apple M   | arm64 + Darwin        | Metal нативно (без Docker GPU) |
| CPU       | fallback              | OLLAMA_NUM_PARALLEL=2          |

```bash
FORCE_GPU_TYPE=amd bash install.sh --non-interactive    # Принудительно AMD
SKIP_GPU_DETECT=true bash install.sh --non-interactive  # Без GPU
```

---

## Безопасность

AGMind реализует defense-in-depth по CIS Docker Benchmark:

| Уровень | Что | По умолчанию |
|---------|-----|-------------|
| **Хост** | UFW файрвол | VPS: вкл |
| **Хост** | Fail2ban IDS | VPS/LAN: вкл |
| **Сеть** | Frontend/backend изоляция | Всегда вкл |
| **Сеть** | Backend internal (нет внешнего доступа) | Всегда вкл |
| **Контейнеры** | `no-new-privileges`, `cap_drop: ALL` | Всегда вкл |
| **Контейнеры** | Read-only filesystems (nginx, redis) | Всегда вкл |
| **Контейнеры** | Resource limits | Всегда вкл |
| **Приложение** | Rate limiting (Nginx) | Всегда вкл |
| **Приложение** | Security headers (XFO, CSP, HSTS) | Всегда вкл |
| **Данные** | scram-sha-256 (PostgreSQL) | Всегда вкл |
| **Данные** | Redis requirepass + отключение опасных команд | Всегда вкл |
| **Секреты** | Авто-генерация через `openssl rand` | Всегда вкл |
| **Секреты** | SOPS шифрование .env | VPS: вкл |

Нет дефолтных паролей — инсталлер валидирует отсутствие `changeme`, `password`, `difyai123456` и т.д.

### Опциональные модули

```bash
ENABLE_AUTHELIA=true        # Authelia 2FA proxy
ENABLE_SOPS=true            # SOPS + age шифрование .env
ENABLE_SECRET_ROTATION=true # Авто-ротация секретов (ежемесячно)
```

### Сетевая изоляция

```
Internet → [UFW/Fail2ban] → [Nginx: rate limit + headers]
                                    │
                    ┌───── agmind-frontend (bridge) ─────┐
                    │  nginx, grafana, portainer          │
                    └───────────────┬─────────────────────┘
                                    │
                    ┌───── agmind-backend (internal) ─────┐
                    │  api, worker, db, redis, ollama,    │
                    │  weaviate — НЕТ портов наружу       │
                    └─────────────────────────────────────┘
```

---

## Мониторинг и алертинг

При `MONITORING_MODE=local` разворачивается полный стек:

- **Prometheus** — сбор метрик (15s scrape interval)
- **Grafana** — 2 преднастроенных дашборда (Overview, Alerts)
- **Alertmanager** — 9 правил алертов (контейнеры, хост, сервисы)
- **cAdvisor** — метрики контейнеров
- **Loki + Promtail** — агрегация логов

### Алерты

| Алерт | Условие | Уровень |
|-------|---------|---------|
| ContainerDown | Сервис не работает > 1 мин | critical |
| ContainerRestarting | > 3 рестартов за 15 мин | warning |
| HighCPU/HighMemory | > 80-90% за 5 мин | warning/critical |
| DiskSpaceLow | > 85% занято | critical |
| PostgresDown / RedisDown | Недоступен > 1 мин | critical |

Каналы доставки:
```bash
ALERT_MODE=telegram               # Telegram бот
ALERT_TELEGRAM_TOKEN=...
ALERT_TELEGRAM_CHAT_ID=...

ALERT_MODE=webhook                # Slack, Discord и т.д.
ALERT_WEBHOOK_URL=https://...
```

### Health check (26 проверок)
```bash
/opt/agmind/scripts/health.sh              # Полный отчёт
/opt/agmind/scripts/health.sh --send-test  # Тест отправки алертов
```

---

## Обслуживание

### Обновление (rolling update с rollback)
```bash
/opt/agmind/scripts/update.sh              # Интерактивное
/opt/agmind/scripts/update.sh --auto       # Автоматическое
/opt/agmind/scripts/update.sh --check-only # Только проверить
```

Обновление: создаёт бэкап → сохраняет rollback state → обновляет по одному сервису → healthcheck → откат при ошибке.

### Бэкап и восстановление
```bash
/opt/agmind/scripts/backup.sh                          # Ручной бэкап
/opt/agmind/scripts/restore.sh /var/backups/agmind/...  # Восстановление
/opt/agmind/scripts/restore-runbook.sh /var/backups/... # 7-step verified restore
```

Бэкап включает: PostgreSQL, векторное хранилище (Weaviate/Qdrant snapshots), Dify storage, Open WebUI, Ollama модели, конфигурацию, SHA256 checksums.

Опции:
```bash
BACKUP_SCHEDULE="0 3 * * *"     # Cron (по умолчанию ежедневно 03:00)
BACKUP_RETENTION_COUNT=10       # Хранить N последних бэкапов
ENABLE_S3_BACKUP=true           # Загрузка в S3 (rclone)
ENABLE_BACKUP_ENCRYPTION=true   # Шифрование бэкапов (age)
```

### DR drill (ежемесячный тест)
```bash
/opt/agmind/scripts/dr-drill.sh                # Полный тест (с downtime)
/opt/agmind/scripts/dr-drill.sh --skip-restore  # Только бэкап + проверка
/opt/agmind/scripts/dr-drill.sh --dry-run       # Без изменений
```

### Offline bundle
```bash
./scripts/build-offline-bundle.sh                              # Базовый
./scripts/build-offline-bundle.sh --include-models llama3.2    # С моделями
./scripts/build-offline-bundle.sh --platform linux/arm64       # Для ARM64
```

### Multi-instance
```bash
/opt/agmind/scripts/multi-instance.sh create --name client1 --port-offset 100
/opt/agmind/scripts/multi-instance.sh list
/opt/agmind/scripts/multi-instance.sh delete --name client1
```

### Удаление
```bash
/opt/agmind/scripts/uninstall.sh           # Интерактивное
/opt/agmind/scripts/uninstall.sh --force   # Без подтверждений
```

---

## Версии и совместимость

Все образы запинены в `versions.env` — ни один сервис не использует `:latest`.

Проверенные комбинации: [COMPATIBILITY.md](COMPATIBILITY.md)
Журнал изменений: [CHANGELOG.md](CHANGELOG.md)
DR политика: [DR-POLICY.md](DR-POLICY.md)

---

## CI/CD

| Workflow | Что проверяет |
|----------|--------------|
| **Lint** | ShellCheck, yamllint, JSON validate, bash -n |
| **Test** | BATS unit tests, Trivy security scan |

---

## Переменные окружения

### Основные

| Переменная             | Описание                              | По умолчанию      |
|------------------------|---------------------------------------|--------------------|
| `DEPLOY_PROFILE`       | Профиль: vps/lan/vpn/offline          | lan                |
| `DOMAIN`               | Домен (только VPS)                    | —                  |
| `COMPANY_NAME`         | Название компании                     | AGMind             |
| `ADMIN_EMAIL`          | Email администратора                  | admin@admin.com    |
| `ADMIN_PASSWORD`       | Пароль (или авто-генерация)           | авто               |
| `LLM_MODEL`            | Модель LLM                            | qwen2.5:14b        |
| `VECTOR_STORE`         | weaviate / qdrant                     | weaviate           |
| `MONITORING_MODE`      | none / local / external               | none               |
| `ALERT_MODE`           | none / webhook / telegram             | none               |

### Безопасность

| Переменная               | Описание                            | По умолчанию |
|--------------------------|-------------------------------------|--------------|
| `ENABLE_UFW`             | UFW файрвол                         | false (vps: true) |
| `ENABLE_FAIL2BAN`        | Fail2ban IDS                        | false (vps/lan: true) |
| `ENABLE_SOPS`            | SOPS + age шифрование               | false (vps: true) |
| `ENABLE_AUTHELIA`        | Authelia 2FA                        | false        |
| `ENABLE_SECRET_ROTATION` | Авто-ротация секретов               | false        |
| `FORCE_GPU_TYPE`         | Принудительный тип GPU              | —            |
| `SKIP_GPU_DETECT`        | Пропустить GPU детекцию             | false        |
| `SKIP_PREFLIGHT`         | Пропустить pre-flight проверки      | false        |

### Бэкапы

| Переменная                 | Описание                          | По умолчанию |
|----------------------------|-----------------------------------|--------------|
| `BACKUP_SCHEDULE`          | Cron расписание                   | 0 3 * * *    |
| `BACKUP_RETENTION_COUNT`   | Макс. количество бэкапов          | 10           |
| `ENABLE_S3_BACKUP`         | Загрузка в S3 (rclone)            | false        |
| `ENABLE_BACKUP_ENCRYPTION` | Шифрование бэкапов (age)          | false        |
| `ENABLE_DR_DRILL`          | Ежемесячный DR drill (cron)       | true         |

---

## Выбор LLM модели

| # | Модель                             | Размер | RAM     | VRAM   | Скорость     |
|---|------------------------------------|--------|---------|--------|--------------|
| 1 | `gemma3:4b`                        | 4B     | 8GB+    | 6GB+   | ⚡ Быстрая   |
| 2 | `qwen2.5:7b`                       | 7B     | 8GB+    | 6GB+   | ⚡ Быстрая   |
| 3 | `qwen3:8b`                         | 8B     | 8GB+    | 6GB+   | ⚡ Быстрая   |
| 4 | `llama3.1:8b`                      | 8B     | 8GB+    | 6GB+   | ⚡ Быстрая   |
| 5 | `mistral:7b`                       | 7B     | 8GB+    | 6GB+   | ⚡ Быстрая   |
| 6 | `qwen2.5:14b` ★                   | 14B    | 16GB+   | 10GB+  | ⚖️ Баланс    |
| 7 | `phi-4:14b`                        | 14B    | 16GB+   | 10GB+  | ⚖️ Баланс    |
| 8 | `mistral-nemo:12b`                 | 12B    | 16GB+   | 10GB+  | ⚖️ Баланс    |
| 9 | `gemma3:12b`                       | 12B    | 16GB+   | 10GB+  | ⚖️ Баланс    |
| 10| `qwen2.5:32b`                      | 32B    | 32GB+   | 16GB+  | 🎯 Качество  |
| 11| `gemma3:27b`                       | 27B    | 32GB+   | 16GB+  | 🎯 Качество  |
| 12| `command-r:35b`                    | 35B    | 32GB+   | 16GB+  | 🎯 Качество  |
| 13| `qwen2.5:72b-instruct-q4_K_M`     | 72B    | 64GB+   | 24GB+  | 🏆 Макс      |
| 14| `llama3.1:70b-instruct-q4_K_M`    | 70B    | 64GB+   | 24GB+  | 🏆 Макс      |
| 15| `qwen3:32b`                        | 32B    | 32GB+   | 16GB+  | 🎯 Качество  |

★ — рекомендуется по умолчанию. Инсталлер автоматически определяет GPU/RAM и предлагает оптимальную модель.

---

## Структура установки

```
/opt/agmind/
├── docker/
│   ├── .env                    # Конфигурация (chmod 600)
│   ├── docker-compose.yml      # Стек сервисов
│   ├── nginx/nginx.conf        # Nginx (rate limit, security headers)
│   ├── authelia/               # Authelia конфиг (если включена)
│   ├── monitoring/             # Prometheus + Grafana + Loki
│   └── volumes/                # Данные сервисов
├── scripts/
│   ├── backup.sh               # Бэкап (flock, pg_isready, S3, encryption)
│   ├── restore.sh              # Восстановление (AUTO_CONFIRM, decrypt)
│   ├── restore-runbook.sh      # 7-step verified restore
│   ├── health.sh               # 26 проверок + auto-alert
│   ├── update.sh               # Rolling update с rollback
│   ├── dr-drill.sh             # Ежемесячный DR drill
│   ├── rotate_secrets.sh       # Ротация секретов
│   ├── build-offline-bundle.sh # Сборка offline инсталлятора
│   ├── multi-instance.sh       # Управление multi-instance
│   └── uninstall.sh            # Удаление (--force, --dry-run)
├── versions.env                # Пиннинг версий (единый источник)
├── release-manifest.json       # Манифест релиза
├── .age/                       # age ключи шифрования (chmod 700)
└── .admin_password             # Пароль администратора (chmod 600)
```

---

## Устранение неполадок

### Контейнер не запускается
```bash
docker compose -f /opt/agmind/docker/docker-compose.yml logs <service>
```

### Dify Console недоступен
Консоль доступна по адресу `http://server/dify/`. Логин через стандартную форму Dify.

### Ollama не отвечает
```bash
docker compose exec ollama ollama list    # Проверить модели
docker compose restart ollama             # Перезапустить
```

### Сертификат не получен (VPS)
```bash
dig +short your-domain.com
docker compose exec certbot certbot certonly --webroot -w /var/www/certbot -d your-domain.com
docker compose restart nginx
```

### Параллельные операции заблокированы
```bash
rm -f /var/lock/agmind-operation.lock
```

### Полное восстановление после сбоя
```bash
# 1. Найти последний бэкап
ls -lt /var/backups/agmind/

# 2. Запустить verified restore
sudo /opt/agmind/scripts/restore-runbook.sh /var/backups/agmind/<backup>

# 3. Проверить здоровье
sudo /opt/agmind/scripts/health.sh
```

---

## Документация

Полная документация: `docs/` (Docusaurus)

```bash
cd docs && npm install && npm start
```

Разделы: [Installation](docs/docs/installation/quickstart.md) · [Operations](docs/docs/operations/health-monitoring.md) · [Security](docs/docs/security/overview.md) · [Migration](docs/docs/migration/version-upgrade.md)

---

## Лицензия

Open Source. См. [LICENSE](LICENSE).
