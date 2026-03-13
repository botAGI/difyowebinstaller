# AGMind Installer — Спецификация v1

## Концепция

Один bash-скрипт (`install.sh`) разворачивает полный RAG-стек (Dify + Open WebUI + Ollama) на любом железе клиента. Четыре профиля деплоя, автоматическая настройка бэкапов, подключение к центральному Dokploy для мониторинга.

## Архитектура

```
[Центральный VPS — Dokploy Dashboard]
        ↑ Dokploy agent / reverse SSH
    ┌───┴──────────────────────────┐
[Клиент A: VPS]          [Клиент B: офис LAN]
├── Open WebUI (фронт)    ├── Open WebUI
├── Dify (бэкенд)         ├── Dify
├── Ollama (LLM+embed)    ├── Ollama
├── PostgreSQL             ├── PostgreSQL
├── Weaviate (vector)      ├── Weaviate
├── Redis                  ├── Redis
├── Nginx                  ├── Nginx
├── Sandbox (code exec)    ├── Sandbox
├── Dokploy agent          └── данные клиента
└── certbot (TLS)

[Клиент C: VPN]           [Клиент D: offline]
├── тот же стек            ├── тот же стек
├── доступ через VPN       ├── без интернета
└── Dokploy через VPN      └── без Dokploy
```

Каждый клиент = отдельная нода на своём железе. Данные никогда не покидают ноду клиента.

## Профили деплоя

| Профиль | Интернет | Домен | Ваш доступ | Доступ сотрудников | Dokploy | Бэкап |
|---------|----------|-------|------------|-------------------|---------|-------|
| **vps** | да | да (certbot TLS) | SSH прямой | https://domain.com | agent | локал + удалённо |
| **lan** | да | нет | reverse SSH через VPS | http://192.168.x.x | agent через tunnel | локал + SCP |
| **vpn** | через VPN | внутренний (опц.) | VPN credentials | VPN + IP/домен | agent через VPN | локал + SCP |
| **offline** | нет | нет | физический | http://LAN_IP | нет | только локал |

## Структура проекта

```
agmind-installer/
├── install.sh                  # Точка входа: curl -sSL https://install.aillmsystems.com | bash
├── lib/
│   ├── detect.sh               # Определение ОС, GPU, RAM, диск, порты
│   ├── docker.sh               # Установка Docker + Docker Compose
│   ├── config.sh               # Генерация .env из шаблона по профилю
│   ├── models.sh               # Скачивание Ollama моделей (после старта контейнеров)
│   ├── workflow.sh             # Импорт workflow через Dify Console API
│   ├── tunnel.sh               # Настройка reverse SSH + autossh + systemd (LAN)
│   ├── backup.sh               # Настройка cron бэкапов
│   ├── dokploy.sh              # Установка Dokploy agent + подключение к центральному
│   └── health.sh               # Проверка здоровья всех контейнеров
├── templates/
│   ├── docker-compose.yml      # Единый compose: Dify + OpenWebUI + Ollama + Weaviate + PostgreSQL + Redis + Nginx + Sandbox
│   ├── env.vps.template        # .env: домен, certbot, публичные порты
│   ├── env.lan.template        # .env: только LAN, без TLS
│   ├── env.vpn.template        # .env: VPN subnet, внутренний домен
│   ├── env.offline.template    # .env: без внешних зависимостей, marketplace отключен
│   ├── nginx.conf.template     # Nginx: reverse proxy Dify + OpenWebUI
│   ├── backup-cron.template    # Crontab entry для бэкапов
│   └── autossh.service.template # systemd unit для reverse SSH tunnel
├── workflows/
│   ├── rag-assistant.json      # MVP workflow (15 нод: upload/list/delete/RAG query)
│   └── import.py               # Скрипт: login → create KB → create app → push workflow → publish → create API key
├── branding/
│   ├── logo.svg                # Дефолтный лого (заменяется при установке)
│   └── theme.json              # Цвета/стили Open WebUI
└── scripts/
    ├── backup.sh               # Бэкап: pg_dump + tar volumes → /var/backups/agmind/YYYY-MM-DD/
    ├── restore.sh              # Восстановление из бэкапа
    └── uninstall.sh            # Остановка + удаление контейнеров + volumes (с подтверждением)
```

## Логика install.sh

### Фаза 1: Диагностика (detect.sh)

```bash
# Определяем:
- ОС и версия (Ubuntu 20+/22+/24+, Debian 11+, CentOS 8+/9+, macOS)
- Архитектура (x86_64, arm64)
- GPU: nvidia-smi → NVIDIA (драйвер, VRAM), нет → CPU only
- RAM: total, available (минимум 4GB, рекомендация 16GB+)
- Диск: свободное место (минимум 30GB, рекомендация 50GB+)
- Порты: 80, 443, 3000, 5001, 8080 свободны?
- Docker: установлен? версия? compose plugin?
- Сеть: есть ли интернет (curl -s https://hub.docker.com > /dev/null)

# Вывод:
"Система: Ubuntu 24.04, x86_64"
"GPU: NVIDIA RTX 3060 (12GB VRAM)"
"RAM: 32GB (28GB доступно)"
"Диск: 120GB свободно"
"Docker: не установлен"
"Сеть: доступна"
```

### Фаза 2: Интерактивный мастер

```bash
echo "=== AGMind Installer ==="

# 1. Профиль
"Выберите режим деплоя:"
  1) VPS — публичный доступ через домен (есть интернет, есть домен)
  2) LAN — локальная сеть офиса (есть интернет, нет домена)
  3) VPN — корпоративный VPN (доступ только через VPN)
  4) Offline — замкнутая сеть (без интернета)

# 2. Домен (только VPS)
"Домен для доступа:" → client.aillmsystems.com
"Email для сертификата:" → admin@client.com

# 3. Брендинг
"Название компании:" → "ООО Ромашка"
"Путь к логотипу (опционально):" → /path/to/logo.svg или Enter для дефолтного

# 4. Модель (рекомендация на основе RAM/GPU)
"Выберите LLM модель:"
  1) qwen2.5:7b   — быстрая, 8GB+ RAM          [рекомендуется для вашей системы]
  2) qwen2.5:14b  — сбалансированная, 16GB+ RAM
  3) qwen2.5:32b  — максимальное качество, 32GB+ RAM, GPU рекомендуется
  4) Своя модель  — укажите название из Ollama registry

"Embedding модель:" → bge-m3 (по умолчанию, Enter для подтверждения)

# 5. Админ
"Email администратора:" → admin@company.com
"Пароль (Enter для авто-генерации):" → ********

# 6. Бэкапы
"Настройка бэкапов:"
"Куда сохранять?"
  1) Локально (/var/backups/agmind/)
  2) Удалённо (SCP на сервер обслуживания)
  3) Оба варианта
  
"Расписание:"
  1) Ежедневно в 03:00
  2) Каждые 12 часов (03:00 и 15:00)
  3) Своё (cron expression)

# Для удалённого бэкапа:
"SSH хост:" → backups.aillmsystems.com
"SSH порт:" → 22
"SSH пользователь:" → backup-clientA
"SSH ключ (путь):" → ~/.ssh/id_ed25519 или сгенерировать

# 7. Dokploy (все профили кроме offline)
"Подключить к центральному мониторингу?"
  1) Да (укажите токен Dokploy)
  2) Нет (настрою позже)

# 8. Reverse SSH (только LAN)
"Настроить удалённый доступ для обслуживания?"
  1) Да (SSH tunnel к вашему VPS)
  2) Нет

"VPS хост:" → maintain.aillmsystems.com
"VPS порт SSH:" → 2222
"Локальный порт для проброса:" → 8080
```

### Фаза 3: Установка Docker (docker.sh)

```bash
# Если Docker не установлен:
- Ubuntu/Debian: apt install docker.io docker-compose-plugin
- CentOS: dnf install docker-ce docker-compose-plugin
- macOS: проверить Docker Desktop, инструкция если нет

# Если GPU NVIDIA:
- Установить nvidia-container-toolkit
- Настроить Docker runtime

# Запуск Docker daemon
- systemctl enable --now docker
- Добавить текущего пользователя в группу docker
```

### Фаза 4: Генерация конфигурации (config.sh)

```bash
# Создать рабочую директорию
mkdir -p /opt/agmind/{docker,backups,branding}

# Скопировать docker-compose.yml
# Сгенерировать .env из шаблона профиля:

# Общие параметры (все профили):
SECRET_KEY=<random 64 chars>
DB_PASSWORD=<random 32 chars>
REDIS_PASSWORD=<random 32 chars>
INIT_PASSWORD=<пароль админа, Base64>
VECTOR_STORE=weaviate
ETL_TYPE=dify
OLLAMA_HOST=http://ollama:11434

# VPS дополнительно:
NGINX_HTTPS_ENABLED=true
CERTBOT_EMAIL=admin@client.com
CERTBOT_DOMAIN=client.aillmsystems.com
EXPOSE_NGINX_PORT=80
EXPOSE_NGINX_SSL_PORT=443

# LAN дополнительно:
NGINX_HTTPS_ENABLED=false
EXPOSE_NGINX_PORT=80

# VPN дополнительно:
NGINX_HTTPS_ENABLED=false  # или true с self-signed
EXPOSE_NGINX_PORT=80

# Offline дополнительно:
MARKETPLACE_ENABLED=false
CHECK_UPDATE_URL=
FORCE_VERIFYING_SIGNATURE=false
SANDBOX_ENABLE_NETWORK=false
```

### Фаза 5: Запуск стека

```bash
cd /opt/agmind/docker
docker compose up -d

# Ожидание healthy (health.sh):
# Проверяем каждые 5 сек, таймаут 5 минут:
# - api (5001)
# - web (3000) 
# - worker
# - db (postgres)
# - redis
# - weaviate
# - sandbox
# - nginx (80/443)
# - ollama (11434)
# - open-webui (8080)
```

### Фаза 6: Скачивание моделей (models.sh)

```bash
# НЕ заранее — после старта Ollama контейнера
docker exec ollama ollama pull qwen2.5:14b
docker exec ollama ollama pull bge-m3

# Прогресс в реальном времени
# Для offline: пропуск (модели должны быть в volume заранее)
```

### Фаза 7: Настройка приложения (workflow.sh)

```bash
# Используем import.py:
# 1. Login в Dify Console API (Base64 пароль)
# 2. Создать Knowledge Base "Documents"
# 3. Создать Chatflow app "Ассистент"
# 4. Загрузить workflow из rag-assistant.json (с hash)
# 5. Обновить workflow:
#    - KB ID в knowledge-retrieval ноде
#    - API key в HTTP Request нодах
#    - Модель в LLM ноде (выбранная пользователем)
#    - Системный промпт с названием компании
# 6. Publish workflow
# 7. Создать Service API key
# 8. Настроить Open WebUI:
#    - Подключить к Dify через OpenAI-compatible endpoint
#    - Применить брендинг (лого, название)
```

### Фаза 8: Бэкапы (backup.sh)

```bash
# Создать /opt/agmind/scripts/backup.sh:
#!/bin/bash
DATE=$(date +%Y-%m-%d_%H%M)
BACKUP_DIR=/var/backups/agmind/$DATE

mkdir -p $BACKUP_DIR

# PostgreSQL dump
docker exec agmind-db pg_dump -U postgres dify | gzip > $BACKUP_DIR/dify.sql.gz

# Volumes (Weaviate + Ollama models + Dify storage)
docker run --rm -v agmind_weaviate:/data -v $BACKUP_DIR:/backup alpine tar czf /backup/weaviate.tar.gz -C /data .
docker run --rm -v agmind_dify_storage:/data -v $BACKUP_DIR:/backup alpine tar czf /backup/dify-storage.tar.gz -C /data .

# .env и docker-compose (конфигурация)
cp /opt/agmind/docker/.env $BACKUP_DIR/
cp /opt/agmind/docker/docker-compose.yml $BACKUP_DIR/

# Ротация: удалить бэкапы старше 7 дней
find /var/backups/agmind/ -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;

# Удалённый бэкап (если настроен)
if [ -n "$REMOTE_BACKUP_HOST" ]; then
    rsync -azP $BACKUP_DIR/ $REMOTE_BACKUP_USER@$REMOTE_BACKUP_HOST:$REMOTE_BACKUP_PATH/$DATE/
fi

echo "✅ Бэкап: $BACKUP_DIR ($(du -sh $BACKUP_DIR | cut -f1))"

# Crontab:
# 0 3 * * * /opt/agmind/scripts/backup.sh >> /var/log/agmind-backup.log 2>&1
# Или по выбору пользователя
```

### Фаза 9: Dokploy agent (dokploy.sh)

```bash
# Все профили кроме offline:
curl -sSL https://dokploy.com/install.sh | sh

# Подключение к центральному Dokploy:
# Пользователь вводит токен, agent регистрируется
# Нода появляется в dashboard с именем клиента

# Для LAN: Dokploy agent подключается через reverse SSH tunnel
# Для VPN: Dokploy agent подключается через VPN
```

### Фаза 10: Reverse SSH (tunnel.sh, только LAN)

```bash
# Генерация SSH ключа для tunnel
ssh-keygen -t ed25519 -f /opt/agmind/.ssh/tunnel_key -N "" -C "agmind-tunnel-$(hostname)"

# Показать pubkey для добавления на VPS
echo "Добавьте этот ключ на VPS:"
cat /opt/agmind/.ssh/tunnel_key.pub

# Создать systemd service (autossh)
apt install -y autossh

# /etc/systemd/system/agmind-tunnel.service
[Unit]
Description=AGMind Reverse SSH Tunnel
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/autossh -M 0 -N -o "ServerAliveInterval 15" -o "ServerAliveCountMax 3" \
  -R 0.0.0.0:${REMOTE_PORT}:localhost:80 \
  -i /opt/agmind/.ssh/tunnel_key \
  -p ${VPS_SSH_PORT} tunnel@${VPS_HOST}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target

systemctl enable --now agmind-tunnel
```

### Фаза 11: Финальный вывод

```
╔══════════════════════════════════════════╗
║         ✅ AGMind установлен!            ║
╠══════════════════════════════════════════╣
║                                          ║
║  Профиль:  LAN                           ║
║  URL:      http://192.168.50.26          ║
║  Логин:    admin@company.com             ║
║  Пароль:   ********                      ║
║                                          ║
║  Модель:   qwen2.5:14b                   ║
║  Embedding: bge-m3                       ║
║  KB:       Documents (пустая)            ║
║                                          ║
║  Бэкап:    ежедневно 03:00               ║
║           /var/backups/agmind/           ║
║                                          ║
║  Dokploy:  подключён (node-id: abc123)   ║
║  Tunnel:   active (VPS:8080 → local:80)  ║
║                                          ║
║  Логи:     docker compose logs -f        ║
║  Статус:   /opt/agmind/scripts/health.sh ║
║                                          ║
╚══════════════════════════════════════════╝
```

## Docker Compose — единый файл

Один `docker-compose.yml` для всех профилей. Отличия через `.env`:

```yaml
services:
  # Dify API
  api:
    image: langgenius/dify-api:1.13.0
    environment: *shared-env
    volumes:
      - dify_storage:/app/api/storage
    depends_on: [db, redis, weaviate, sandbox]

  # Dify Worker
  worker:
    image: langgenius/dify-api:1.13.0
    environment:
      <<: *shared-env
      MODE: worker
    depends_on: [db, redis, weaviate]

  # Dify Web (Console UI — доступ только админу)
  web:
    image: langgenius/dify-web:1.13.0
    environment:
      CONSOLE_API_URL: ${CONSOLE_API_URL:-}
      APP_API_URL: ${APP_API_URL:-}

  # Open WebUI (фронтенд для клиентов)
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    ports:
      - "${OPENWEBUI_PORT:-3000}:8080"
    environment:
      - OPENAI_API_BASE_URL=http://api:5001/v1  # Dify Service API
      - OPENAI_API_KEY=${DIFY_SERVICE_API_KEY}
      - WEBUI_NAME=${COMPANY_NAME:-AGMind}
      - ENABLE_SIGNUP=false
      - DEFAULT_MODELS=rag-assistant
    volumes:
      - openwebui_data:/app/backend/data

  # Ollama
  ollama:
    image: ollama/ollama:latest
    volumes:
      - ollama_data:/root/.ollama
    # GPU override добавляется если NVIDIA detected:
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - capabilities: [gpu]

  # PostgreSQL
  db:
    image: postgres:15-alpine
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: dify
    volumes:
      - postgres_data:/var/lib/postgresql/data

  # Redis
  redis:
    image: redis:7-alpine
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data

  # Weaviate
  weaviate:
    image: semitechnologies/weaviate:1.19.0
    volumes:
      - weaviate_data:/var/lib/weaviate

  # Sandbox (code execution)
  sandbox:
    image: langgenius/dify-sandbox:0.2.12
    volumes:
      - ./volumes/sandbox/conf:/conf

  # SSRF Proxy
  ssrf_proxy:
    image: ubuntu/squid:latest

  # Nginx (reverse proxy)
  nginx:
    image: nginx:alpine
    ports:
      - "${EXPOSE_NGINX_PORT:-80}:80"
      - "${EXPOSE_NGINX_SSL_PORT:-443}:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./ssl:/etc/nginx/ssl
    depends_on: [api, web, open-webui]

  # Plugin Daemon
  plugin_daemon:
    image: langgenius/dify-plugin-daemon:0.1.0

  # Certbot (только VPS)
  certbot:
    image: certbot/certbot
    profiles: ["vps"]  # запускается только в VPS профиле
    volumes:
      - ./ssl:/etc/letsencrypt

volumes:
  dify_storage:
  postgres_data:
  redis_data:
  weaviate_data:
  ollama_data:
  openwebui_data:
```

## Workflow import (import.py)

```python
# Алгоритм:
# 1. POST /console/api/login (email + Base64 password) → access_token, csrf_token
# 2. POST /console/api/datasets → создать KB "Documents" → kb_id
# 3. POST /console/api/datasets/api-keys → service_api_key
# 4. POST /console/api/apps → создать Chatflow "Ассистент" → app_id
# 5. GET /console/api/apps/{app_id}/workflows/draft → hash
# 6. Патч rag-assistant.json:
#    - dataset_ids → [kb_id]
#    - HTTP Request URLs → http://api:5001/v1/datasets/{kb_id}/...
#    - HTTP Request authorization.config.api_key → service_api_key
#    - LLM model.name → выбранная модель
#    - Системный промпт → название компании
#    - Opening statement → брендинг
# 7. POST /console/api/apps/{app_id}/workflows/draft (с hash) → success
# 8. POST /console/api/apps/{app_id}/workflows/publish → success
```

## Важные нюансы

1. **Dify пароль = Base64**, не plaintext, не RSA
2. **CSRF токен обязателен** для всех POST (Cookie + X-CSRF-Token header)
3. **hash обязателен** при обновлении draft workflow (иначе 409)
4. **SSRF proxy блокирует localhost** — HTTP Request ноды используют `http://api:5001`
5. **Sandbox нужен config.yaml** в volumes/sandbox/conf/ (иначе crash loop)
6. **IF/ELSE comparison**: `"start with"` (не `"starts with"`)
7. **Один owner в tenant** — если два, Service API падает с "Multiple rows"
8. **Open WebUI подключается к Dify** через OpenAI-compatible API, не напрямую к Ollama
9. **Модели скачиваются ПОСЛЕ старта контейнеров** (ollama pull внутри контейнера)
10. **Offline режим**: модели должны быть в ollama_data volume заранее (физическая передача)
