# AGMind Installer

RAG-стек: **Dify + Open WebUI + Ollama** — автоматическая установка, настройка и обслуживание.

## Быстрый старт

```bash
# Интерактивная установка
sudo bash install.sh

# Неинтерактивная установка (все параметры из ENV)
sudo DEPLOY_PROFILE=lan ADMIN_EMAIL=admin@company.com ADMIN_PASSWORD=secret \
     COMPANY_NAME="My Corp" LLM_MODEL=qwen2.5:14b \
     bash install.sh --non-interactive
```

## Профили деплоя

| Профиль  | Интернет | Домен | TLS          | Описание                        |
|----------|----------|-------|--------------|---------------------------------|
| `vps`    | ✅       | ✅    | Let's Encrypt | Публичный доступ через домен    |
| `lan`    | ✅       | ❌    | Опционально   | Локальная сеть офиса            |
| `vpn`    | ✅       | ❌    | Опционально   | Корпоративный VPN               |
| `offline`| ❌       | ❌    | ❌            | Изолированная сеть без интернета |

## GPU поддержка

Инсталлер автоматически определяет GPU и настраивает docker-compose:

| GPU       | Обнаружение           | Метод                          |
|-----------|-----------------------|--------------------------------|
| NVIDIA    | `nvidia-smi`          | deploy.resources (CUDA)        |
| AMD ROCm  | `/dev/kfd`, `rocminfo`| device passthrough             |
| Intel Arc | `/dev/dri` + `lspci`  | device passthrough             |
| Apple M   | arm64 + Darwin        | Metal нативно (без Docker GPU) |
| CPU       | fallback              | OLLAMA_NUM_PARALLEL=2          |

```bash
# Принудительно указать тип GPU
FORCE_GPU_TYPE=amd bash install.sh --non-interactive

# Пропустить детекцию GPU
SKIP_GPU_DETECT=true bash install.sh --non-interactive
```

## Безопасность

### UFW файрвол
Автоматически включается для VPS профиля. Для LAN/VPN — опционально.
```bash
ENABLE_UFW=true  # Открывает 22, 80, 443 + LAN subnet / VPN interface
```

### Fail2ban
Защита от bruteforce на SSH и nginx (401/403/429 ответы).
```bash
ENABLE_FAIL2BAN=true
```

### Authelia 2FA
Двухфакторная аутентификация перед доступом к приложению.
```bash
ENABLE_AUTHELIA=true  # Добавляет Authelia proxy перед nginx
```

### Шифрование секретов (SOPS + age)
```bash
ENABLE_SOPS=true  # Шифрует .env → .env.enc с помощью age ключей
```

### Ротация секретов
```bash
/opt/agmind/scripts/rotate_secrets.sh  # Ручная ротация 6 секретов
ENABLE_SECRET_ROTATION=true            # Авто-ротация 1-го числа каждого месяца
```

Ротируются: SECRET_KEY, REDIS_PASSWORD, GRAFANA_ADMIN_PASSWORD, SANDBOX_API_KEY, PLUGIN_DAEMON_KEY, PLUGIN_INNER_API_KEY.

## Неинтерактивный режим (ENV переменные)

### Основные

| Переменная             | Описание                              | По умолчанию      |
|------------------------|---------------------------------------|--------------------|
| `DEPLOY_PROFILE`       | Профиль: vps/lan/vpn/offline          | lan                |
| `DOMAIN`               | Домен (только VPS)                    | —                  |
| `CERTBOT_EMAIL`        | Email для Let's Encrypt (только VPS)  | —                  |
| `COMPANY_NAME`         | Название компании                     | AGMind             |
| `ADMIN_EMAIL`          | Email администратора                  | admin@admin.com    |
| `ADMIN_PASSWORD`       | Пароль (или авто-генерация)           | авто               |
| `LLM_MODEL`            | Модель LLM                            | qwen2.5:14b        |
| `EMBEDDING_MODEL`      | Модель эмбеддингов                    | bge-m3             |
| `VECTOR_STORE`         | Векторное хранилище: weaviate/qdrant  | weaviate           |
| `ETL_ENHANCED`         | Docling+Xinference: yes/no            | no                 |
| `TLS_MODE`             | TLS: none/self-signed/custom          | none               |
| `MONITORING_MODE`      | none/local/external                   | none               |
| `ALERT_MODE`           | none/webhook/telegram                 | none               |
| `BACKUP_TARGET`        | local/remote/both                     | local              |
| `BACKUP_SCHEDULE`      | Cron expression                       | 0 3 * * *          |

### Безопасность и GPU

| Переменная               | Описание                            | По умолчанию |
|--------------------------|-------------------------------------|--------------|
| `ENABLE_UFW`             | Настройка UFW файрвола              | false        |
| `ENABLE_FAIL2BAN`        | Установка и настройка Fail2ban      | false        |
| `ENABLE_SOPS`            | Шифрование .env (SOPS + age)        | false        |
| `ENABLE_SECRET_ROTATION` | Авто-ротация секретов (cron)        | false        |
| `ENABLE_AUTHELIA`        | Authelia 2FA proxy                  | false        |
| `FORCE_GPU_TYPE`         | Принудительный тип GPU              | —            |
| `SKIP_GPU_DETECT`        | Пропустить GPU детекцию             | false        |
| `SKIP_PREFLIGHT`         | Пропустить pre-flight проверки      | false        |
| `FORCE_REINSTALL`        | Переустановка поверх существующей   | false        |

### Бэкапы

| Переменная                 | Описание                          | По умолчанию |
|----------------------------|-----------------------------------|--------------|
| `BACKUP_RETENTION_COUNT`   | Макс. количество бэкапов          | 10           |
| `ENABLE_S3_BACKUP`         | Загрузка бэкапов в S3 (rclone)    | false        |
| `ENABLE_BACKUP_ENCRYPTION` | Шифрование бэкапов (age)          | false        |
| `S3_REMOTE_NAME`           | Имя rclone remote                 | s3           |
| `S3_BUCKET`                | S3 bucket                         | agmind-backups |
| `S3_PATH`                  | Путь внутри bucket                | hostname     |

### Мониторинг

| Переменная             | Описание                          | По умолчанию |
|------------------------|-----------------------------------|--------------|
| `ENABLE_LOKI`          | Loki + Promtail для логов         | true         |
| `GRAFANA_BIND_ADDR`    | Bind address Grafana              | 127.0.0.1 (vps), 0.0.0.0 (lan) |
| `PORTAINER_BIND_ADDR`  | Bind address Portainer            | 127.0.0.1 (vps), 0.0.0.0 (lan) |
| `HEALTHCHECK_INTERVAL` | Интервал Docker healthcheck       | 30s          |
| `HEALTHCHECK_RETRIES`  | Количество ретраев healthcheck    | 5            |

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
| 16| Своя модель                        | —      | —       | —      | —            |

★ — рекомендуется по умолчанию

> **Совет:** Инсталлер автоматически определяет GPU/RAM и предлагает оптимальную модель.

## TLS режимы

| Режим         | Профили    | Описание                                    |
|---------------|------------|---------------------------------------------|
| `none`        | lan, vpn   | HTTP без шифрования (по умолчанию)          |
| `self-signed` | lan, vpn   | Автоматически сгенерированный сертификат    |
| `custom`      | lan, vpn   | Свой сертификат (указать путь к .pem)       |
| `letsencrypt` | vps        | Автоматический через certbot (по умолчанию) |

## Мониторинг

### Локальный (Grafana + Portainer + Loki)
- **Grafana**: `http://server:3001` — дашборды метрик и логов
- **Portainer**: `https://server:9443` — UI для управления Docker
- **Loki + Promtail** — агрегация логов всех контейнеров (вкл. по умолчанию)
- Prometheus + cAdvisor собирают метрики автоматически

> **VPS профиль:** Grafana и Portainer привязаны к `127.0.0.1` (не доступны снаружи). Для доступа используйте SSH tunnel.

### Внешний
Укажите endpoint и token для отправки метрик на внешний сервер мониторинга.

## Обслуживание

### Обновление
```bash
/opt/agmind/scripts/update.sh              # Интерактивное обновление
/opt/agmind/scripts/update.sh --auto       # Автоматическое (без подтверждения)
/opt/agmind/scripts/update.sh --check-only # Только проверить наличие обновлений
```

Rolling update: обновляет сервисы по одному, проверяет healthcheck после каждого, откатывает при ошибке.

### Бэкап и восстановление
```bash
/opt/agmind/scripts/backup.sh                          # Ручной бэкап
/opt/agmind/scripts/restore.sh                         # Интерактивное восстановление
/opt/agmind/scripts/restore.sh /var/backups/agmind/... # Указать конкретный бэкап
AUTO_CONFIRM=true /opt/agmind/scripts/restore.sh ...   # Без подтверждений
```

Бэкап включает: PostgreSQL (Dify + Plugin DB), векторное хранилище (Weaviate/Qdrant snapshots), Dify storage, Open WebUI, Ollama модели, конфигурацию, age ключи, Authelia конфиг, SHA256 контрольные суммы.

### Проверка здоровья
```bash
/opt/agmind/scripts/health.sh              # Полный отчёт
/opt/agmind/scripts/health.sh --send-test  # Тест отправки алертов
```

Проверяет: контейнеры, GPU, модели Ollama, векторные хранилища, диск, статус бэкапов.

### Multi-instance
```bash
/opt/agmind/scripts/multi-instance.sh create --name client1 --port-offset 100
/opt/agmind/scripts/multi-instance.sh list
/opt/agmind/scripts/multi-instance.sh delete --name client1
```

### Удаление
```bash
/opt/agmind/scripts/uninstall.sh           # Интерактивное удаление
/opt/agmind/scripts/uninstall.sh --dry-run # Показать что будет удалено
/opt/agmind/scripts/uninstall.sh --force   # Без подтверждений
```

## Полезные команды

```bash
# Статус сервисов
/opt/agmind/scripts/health.sh

# Логи
cd /opt/agmind/docker && docker compose logs -f

# Логи конкретного сервиса
docker compose logs -f api

# Ручной бэкап
/opt/agmind/scripts/backup.sh

# Перезапуск
cd /opt/agmind/docker && docker compose restart

# Ротация секретов
/opt/agmind/scripts/rotate_secrets.sh
```

## Структура установки

```
/opt/agmind/
├── docker/
│   ├── .env                    # Конфигурация (chmod 600)
│   ├── docker-compose.yml      # Стек сервисов
│   ├── nginx/nginx.conf        # Nginx конфигурация
│   ├── pipeline/               # OpenAI-совместимый прокси
│   ├── authelia/               # Authelia конфиг (если включена)
│   ├── monitoring/             # Prometheus + Grafana + Loki
│   └── volumes/                # Данные сервисов
│       ├── redis/redis.conf    # Redis конфиг (пароль в файле, не в CLI)
│       └── ...
├── scripts/
│   ├── backup.sh               # Бэкап (flock, pg_isready, S3, encryption)
│   ├── restore.sh              # Восстановление (AUTO_CONFIRM, decrypt)
│   ├── health.sh               # Проверка здоровья (GPU, Ollama, vectors)
│   ├── update.sh               # Rolling update с rollback
│   ├── uninstall.sh            # Удаление (--force, --dry-run)
│   ├── rotate_secrets.sh       # Ротация 6 секретов
│   └── multi-instance.sh       # Управление multi-instance
├── versions.env                # Пиннинг версий образов
├── workflows/                  # Dify workflow шаблоны
├── branding/                   # Логотип и тема
├── .age/                       # age ключи шифрования (chmod 700)
├── .admin_password             # Пароль администратора (chmod 600)
└── .agmind_installed           # Маркер завершённой установки
```

## Устранение неполадок

### Контейнер не запускается
```bash
docker compose -f /opt/agmind/docker/docker-compose.yml logs <service>
```

### Ollama не отвечает
```bash
docker compose exec ollama ollama list    # Проверить модели
docker compose restart ollama             # Перезапустить
```

### Модели не загружены (offline)
```bash
# Скачать модели на машине с интернетом
ollama pull qwen2.5:14b
ollama pull bge-m3

# Скопировать ~/.ollama на целевой сервер в volume ollama_data
```

### Dify Console недоступен
Консоль доступна по секретному URL: `http://server/<admin_token>/`
Admin token указан в `/opt/agmind/docker/.env` (переменная `ADMIN_TOKEN`).

### Сертификат не получен (VPS)
```bash
# Проверить DNS
dig +short your-domain.com

# Принудительно получить сертификат
docker compose exec certbot certbot certonly --webroot -w /var/www/certbot -d your-domain.com
docker compose restart nginx
```

### Параллельные операции заблокированы
Скрипты backup/update/restore используют flock (`/var/lock/agmind-operation.lock`). Если предыдущая операция зависла:
```bash
rm -f /var/lock/agmind-operation.lock
```
