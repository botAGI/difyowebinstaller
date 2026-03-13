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

## Неинтерактивный режим (ENV переменные)

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
| `VECTOR_STORE_CHOICE`  | Номер в меню (1=weaviate, 2=qdrant)   | 1                  |
| `ETL_ENHANCED`         | Docling+Xinference: yes/no            | no                 |
| `ETL_ENHANCED_CHOICE`  | Номер в меню (1=нет, 2=да)            | 1                  |
| `TLS_MODE`             | TLS: none/self-signed/custom          | none               |
| `TLS_MODE_CHOICE`      | Номер в меню (1/2/3)                  | 1                  |
| `TLS_CERT_PATH`        | Путь к сертификату (для custom)       | —                  |
| `TLS_KEY_PATH`         | Путь к ключу (для custom)             | —                  |
| `MONITORING_MODE`      | none/local/external                   | none               |
| `MONITORING_CHOICE`    | Номер в меню (1/2/3)                  | 1                  |
| `MONITORING_ENDPOINT`  | URL (для external)                    | —                  |
| `MONITORING_TOKEN`     | Токен (для external)                  | —                  |
| `ALERT_MODE`           | none/webhook/telegram                 | none               |
| `ALERT_CHOICE`         | Номер в меню (1/2/3)                  | 1                  |
| `ALERT_WEBHOOK_URL`    | Webhook URL                           | —                  |
| `ALERT_TELEGRAM_TOKEN` | Telegram bot token                    | —                  |
| `ALERT_TELEGRAM_CHAT_ID` | Telegram chat ID                   | —                  |
| `BACKUP_TARGET`        | local/remote/both                     | local              |
| `BACKUP_SCHEDULE`      | Cron expression                       | 0 3 * * *          |
| `DOKPLOY_CHOICE`       | 1=да, 2=нет                           | 2                  |
| `TUNNEL_CHOICE`        | 1=да, 2=нет                           | 2                  |

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

### Локальный (Grafana + Portainer)
- **Grafana**: `http://server:3001` — дашборд контейнерных метрик (CPU, RAM, Network)
- **Portainer**: `https://server:9443` — UI для управления Docker
- Prometheus + cAdvisor собирают метрики автоматически

### Внешний
Укажите endpoint и token для отправки метрик на внешний сервер мониторинга.

## Алерты

| Режим      | Описание                                |
|------------|-----------------------------------------|
| `none`     | Отключены (по умолчанию)                |
| `webhook`  | HTTP POST на указанный URL при сбоях    |
| `telegram` | Сообщение через Telegram бот при сбоях  |

Алерты срабатывают автоматически при запуске `health.sh`, если один или более сервисов не работает.

## Восстановление из бэкапа

```bash
# Посмотреть доступные бэкапы
ls /var/backups/agmind/

# Восстановить конкретный бэкап
/opt/agmind/scripts/restore.sh /var/backups/agmind/2025-01-15_0300

# Или интерактивно
/opt/agmind/scripts/restore.sh
```

Бэкап включает:
- PostgreSQL дамп (Dify + Plugin DB)
- Векторное хранилище (Weaviate или Qdrant)
- Dify storage (загруженные файлы)
- Open WebUI данные
- Ollama модели
- Конфигурация (.env, nginx.conf, docker-compose.yml)
- SHA256 контрольные суммы

## Обновление Docker образов

```bash
cd /opt/agmind/docker

# Обновить конкретный сервис
docker compose pull api worker web
docker compose up -d api worker web

# Обновить все сервисы (кроме Open WebUI — пин на v0.5.20)
docker compose pull
docker compose up -d
```

> **Open WebUI v0.5.20**: версия зафиксирована для совместимости с white-label/re-branding. Не обновляйте до `:main` или `:latest` без проверки работы брендинга.

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

# Удаление
/opt/agmind/scripts/uninstall.sh
```

## Структура установки

```
/opt/agmind/
├── docker/
│   ├── .env                    # Конфигурация
│   ├── docker-compose.yml      # Стек сервисов
│   ├── nginx/nginx.conf        # Nginx конфигурация
│   ├── pipeline/               # OpenAI-совместимый прокси
│   ├── monitoring/             # Prometheus + Grafana (если включен)
│   └── volumes/                # Данные сервисов
├── scripts/
│   ├── backup.sh               # Бэкап
│   ├── restore.sh              # Восстановление
│   ├── health.sh               # Проверка здоровья
│   └── uninstall.sh            # Удаление
├── workflows/                  # Dify workflow шаблоны
├── branding/                   # Логотип и тема
└── .admin_password             # Пароль администратора
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
Admin token указан в финальном выводе инсталлера и в `/opt/agmind/docker/.env` (переменная `ADMIN_TOKEN`).

### Сертификат не получен (VPS)
```bash
# Проверить DNS
dig +short your-domain.com

# Принудительно получить сертификат
docker compose exec certbot certbot certonly --webroot -w /var/www/certbot -d your-domain.com
docker compose restart nginx
```
