# AGMind Installer v3 — SPEC

Цель: Полная переписка инсталлера с нуля по модульному spec-first подходу.
Статус: APPROVED
Дата: 2026-03-19

---

## §1. Общее описание

AGMind Installer — bash-инсталлер production-ready AI-стека:
Dify + Open WebUI + Ollama/vLLM + Weaviate/Qdrant + PostgreSQL + Redis + nginx.

Одна команда: `sudo bash install.sh` → полнофункциональный RAG-стек
с мониторингом, бэкапами и security hardening.

### 1.1 Принципы переписки

| Принцип | Описание |
|---------|----------|
| Модульность | Каждый `lib/*.sh` — самостоятельный модуль с чётким контрактом (входы/выходы/side effects). Тестируемый отдельно. |
| Fail-fast | `set -euo pipefail` везде. Все переменные проверяются. Нет молчаливых падений. |
| Идемпотентность | Повторный запуск любой фазы безопасен. Checkpoint resume работает. |
| Разделение ответственности | `install.sh` = оркестратор фаз. Вся логика — в `lib/*.sh`. |
| Тестируемость | Каждый модуль имеет BATS-тест. CI (GitHub Actions) прогоняет shellcheck + bats + bash -n. |
| Dify из коробки | Никаких патчей кода Dify. Никакой API-автоматизации (import.py удалён). |

---

## §2. Архитектура

### 2.1 Структура файлов

```
agmind-installer/
├── install.sh                  # Оркестратор (только фазы, без логики)
├── lib/
│   ├── common.sh               # Цвета, логгинг, валидация, утилиты, init defaults
│   ├── detect.sh               # Диагностика: OS, GPU, RAM, диск, порты, Docker
│   ├── wizard.sh               # Интерактивный визард (все вопросы)
│   ├── docker.sh               # Установка Docker + nvidia-toolkit + DNS fix
│   ├── config.sh               # Генерация .env, nginx.conf, docker-compose.yml
│   ├── compose.sh              # Docker compose up/down, sync_db, create_plugin_db
│   ├── health.sh               # Healthcheck всех контейнеров
│   ├── models.sh               # Скачивание моделей (Ollama pull, vLLM/TEI)
│   ├── security.sh             # UFW, fail2ban, SOPS, docker hardening, squid
│   ├── authelia.sh             # Authelia 2FA конфигурация
│   ├── backup.sh               # Настройка cron бэкапов
│   ├── tunnel.sh               # Reverse SSH tunnel (autossh) для LAN/VPN
│   └── openwebui.sh            # Создание admin Open WebUI, lockdown signup
├── scripts/
│   ├── agmind.sh               # Day-2 CLI: status, doctor, logs, backup, restore
│   ├── backup.sh               # Standalone бэкап скрипт
│   ├── restore.sh              # Восстановление из бэкапа
│   ├── update.sh               # Обновление стека
│   ├── uninstall.sh            # Удаление
│   ├── health-gen.sh           # Генерация health.json для nginx
│   ├── rotate_secrets.sh       # Ротация секретов
│   ├── build-offline-bundle.sh # Сборка offline-пакета (образы + модели)
│   ├── generate-manifest.sh    # Генерация release-manifest.json
│   └── dr-drill.sh             # DR drill скрипт
├── templates/
│   ├── docker-compose.yml      # Compose шаблон с профилями
│   ├── env.{lan,vps,vpn,offline}.template
│   ├── nginx.conf.template
│   ├── authelia/               # Шаблоны Authelia
│   ├── versions.env            # Pinned версии образов (source of truth)
│   └── release-manifest.json
├── monitoring/
│   ├── prometheus.yml           # Prometheus config
│   ├── alertmanager.yml         # Alertmanager config
│   ├── alert_rules.yml          # Alert rules
│   ├── loki-config.yml          # Loki config
│   ├── promtail-config.yml      # Promtail config
│   └── grafana/
│       ├── dashboards/          # overview, containers, alerts, logs
│       └── provisioning/        # datasources, dashboards, alerting, plugins
├── tests/
│   ├── test_common.bats        # Тесты common.sh
│   ├── test_detect.bats        # Тесты detect.sh
│   ├── test_wizard.bats        # Тесты wizard.sh (non-interactive)
│   ├── test_config.bats        # Тесты config.sh
│   ├── test_compose.bats       # Тесты compose.sh
│   ├── test_security.bats      # Тесты security.sh
│   ├── test_health.bats        # Тесты health.sh
│   ├── test_openwebui.bats     # Тесты openwebui.sh
│   ├── test_models.bats        # Тесты models.sh
│   ├── test_backup.bats        # Тесты backup.sh
│   └── test_lifecycle.bats     # E2E тесты
├── workflows/
│   ├── rag-assistant.json      # Шаблон для ручного импорта
│   └── README.md               # Инструкция по импорту
├── branding/
│   ├── logo.svg
│   └── theme.json
├── docs/                       # Docusaurus документация
├── .github/workflows/          # CI: lint, test, lifecycle
├── CLAUDE.md                   # Контекст для GSD кодера
├── SPEC.md                     # Этот файл
├── CHANGELOG.md
├── README.md
└── .gitignore
```

### 2.2 Контейнеры (стек)

| Контейнер | Образ | Роль | Профиль |
|-----------|-------|------|---------|
| api | langgenius/dify-api | Dify API сервер | core |
| worker | langgenius/dify-api | Celery воркер | core |
| web | langgenius/dify-web | Dify фронтенд | core |
| plugin_daemon | langgenius/dify-plugin-daemon | Плагины Dify | core |
| db | postgres:16-alpine | PostgreSQL | core |
| redis | redis:7-alpine | Redis (кэш + Celery broker) | core |
| sandbox | langgenius/dify-sandbox | Песочница для кода | core |
| ssrf_proxy | ubuntu/squid | SSRF прокси | core |
| nginx | nginx:stable-alpine | Reverse proxy + rate limiting | core |
| pipeline | valiantlynx/open-webui-pipelines | Pipelines Open WebUI | core |
| open-webui | ghcr.io/open-webui/open-webui | Чат-интерфейс | core |
| ollama | ollama/ollama | LLM/Embedding сервер | ollama |
| vllm | vllm/vllm-openai | LLM сервер (prod) | vllm |
| tei | ghcr.io/huggingface/tei | Embedding сервер | tei |
| weaviate | semitechnologies/weaviate | Векторное хранилище | weaviate |
| qdrant | qdrant/qdrant | Векторное хранилище | qdrant |
| docling | ds4sd/docling-serve | OCR/парсинг документов | etl |
| xinference | xprobe/xinference | Reranker | etl |
| prometheus | prom/prometheus | Метрики | monitoring |
| grafana | grafana/grafana | Дашборды | monitoring |
| portainer | portainer/portainer-ce | Управление контейнерами | monitoring |
| alertmanager | prom/alertmanager | Алерты | monitoring |
| loki | grafana/loki | Логи | monitoring |
| promtail | grafana/promtail | Сбор логов | monitoring |
| node-exporter | prom/node-exporter | Системные метрики | monitoring |
| cadvisor | gcr.io/cadvisor | Container metrics | monitoring |
| certbot | certbot/certbot | Let's Encrypt TLS | vps |
| authelia | authelia/authelia | 2FA | authelia |

### 2.3 Профили деплоя

| Профиль | Интернет | TLS | UFW | Fail2ban | Authelia |
|---------|----------|-----|-----|----------|----------|
| vps | да | Let's Encrypt | auto | auto (SSH jail) | опция |
| lan | да | self-signed/custom/none | опция | опция (SSH jail) | нет |
| vpn | да | self-signed/custom/none | опция | опция (SSH jail) | нет |
| offline | нет | none | опция | опция (SSH jail) | нет |

> **Примечание:** Fail2ban используется только для SSH jail. Защита API — через nginx rate limiting.

---

## §3. Функциональные требования (F-*)

### F-01: Диагностика системы

**Модуль:** `lib/detect.sh`
**Описание:** Определение OS, GPU, RAM, диска, портов, Docker, сети.

**AC:**
- [ ] Определяет OS: Ubuntu/Debian/CentOS/RHEL/Rocky/Fedora/macOS
- [ ] Определяет GPU: NVIDIA (nvidia-smi), AMD (ROCm), Intel (DRI), Apple Silicon, none
- [ ] VRAM определяется корректно для NVIDIA/AMD
- [ ] RAM: total и available (MB/GB)
- [ ] Диск: свободное место (GB)
- [ ] Порты: проверка 80, 443, 3000, 5001, 8080, 11434
- [ ] Docker: версия, compose plugin, daemon running
- [ ] Сеть: доступность hub.docker.com
- [ ] Рекомендация модели по RAM/VRAM
- [ ] `FORCE_GPU_TYPE` и `SKIP_GPU_DETECT` env overrides работают
- [ ] Preflight checks: OS version, Docker >= 24, Compose >= 2.20, disk >= 30GB, RAM >= 4GB, CPU >= 2

### F-02: Интерактивный визард

**Модуль:** `lib/wizard.sh`
**Описание:** Все вопросы пользователю в одном модуле.

**AC:**
- [ ] Профиль деплоя: VPS/LAN/VPN/Offline
- [ ] Admin UI (Portainer/Grafana): open/locked (LAN/VPN only)
- [ ] Домен + email (VPS only)
- [ ] Векторное хранилище: Weaviate/Qdrant
- [ ] ETL: стандартный/расширенный (Docling + Xinference)
- [ ] LLM провайдер: Ollama/vLLM/External/Skip
- [ ] LLM модель: меню моделей + custom (список определяется в wizard.sh)
- [ ] Embedding провайдер: Same as LLM/TEI/External/Skip
- [ ] Embedding модель: bge-m3 default (Ollama only)
- [ ] HuggingFace token (vLLM/TEI)
- [ ] TLS: none/self-signed/custom (LAN/VPN), Let's Encrypt (VPS auto)
- [ ] Мониторинг: none/local/external
- [ ] Алерты: none/webhook/Telegram
- [ ] Security: UFW (опция), Fail2ban SSH (опция), Authelia 2FA (VPS)
- [ ] Tunnel: reverse SSH tunnel (LAN/VPN, опция)
- [ ] Бэкапы: local/remote/both + расписание (daily/12h/custom cron)
- [ ] Non-interactive режим через env vars + `--non-interactive` flag
- [ ] Summary перед подтверждением
- [ ] Валидация всех вводов (model name, domain, email, URL, port, cron, path)

### F-03: Установка Docker

**Модуль:** `lib/docker.sh`
**Описание:** Автоустановка Docker CE + Compose + nvidia-toolkit + DNS fix.

**AC:**
- [ ] Установка Docker CE: Debian/Ubuntu (apt), RHEL/CentOS/Fedora (yum/dnf), macOS (проверка Docker Desktop)
- [ ] Docker Compose plugin устанавливается вместе с Docker
- [ ] NVIDIA Container Toolkit: auto-detect + установка (Debian, RHEL)
- [ ] DNS fix: systemd-resolved stub → upstream DNS, atomic symlink
- [ ] Пропуск DNS fix: `SKIP_DNS_FIX=true`, offline профиль
- [ ] Пропуск Docker если уже установлен
- [ ] Пользователь `$SUDO_USER` добавляется в группу docker

### F-04: Генерация конфигурации

**Модуль:** `lib/config.sh`
**Описание:** Генерация .env, nginx.conf, redis.conf, sandbox config, squid config, compose profiles.

**AC:**
- [ ] .env генерируется из шаблона `env.{profile}.template`
- [ ] Все секреты генерируются через `/dev/urandom` (fatal если пусто)
- [ ] Пароль admin: auto-generated, Base64 для INIT_PASSWORD
- [ ] Валидация: нет дефолтных паролей и неразрешённых плейсхолдеров `__*__`
- [ ] nginx.conf: TLS маркеры, rate limiting, Authelia маркеры
- [ ] Redis: requirepass, ACL rules (не rename-command), maxmemory 512mb
- [ ] Sandbox: config.yaml с ключом из .env
- [ ] Squid: SSRF protection (block metadata 169.254.*, block 192.168.0.0/16, allow Docker networks)
- [ ] GPU compose: NVIDIA deploy.resources / AMD ROCm / Intel DRI / Apple none
- [ ] Bind mount safety: `safe_write_file()` удаляет directory artifacts
- [ ] `ensure_bind_mount_files()` — перед compose up
- [ ] `preflight_bind_mount_check()` — abort если .yml/.conf = directory
- [ ] Atomic sed: `_atomic_sed()` через temp file + mv
- [ ] Permissions: .env chmod 600, .admin_password chmod 600
- [ ] Provider-specific Open WebUI env vars
- [ ] `versions.env` → pinned versions в .env (source of truth: `templates/versions.env`)

### F-05: Запуск контейнеров

**Модуль:** `lib/compose.sh`
**Описание:** Docker compose up с правильными профилями, sync DB, создание plugin DB.

**AC:**
- [ ] Compose profiles собираются динамически из wizard choices
- [ ] Перед up: `COMPOSE_PROFILES=all docker compose down --remove-orphans`
- [ ] Перед up: force-remove `agmind-*` containers
- [ ] Перед up: nuclear cleanup (find *.yml *.conf directories → rm)
- [ ] `preflight_bind_mount_check()` перед compose up
- [ ] Offline: `--pull never`, online: `--pull missing`
- [ ] `sync_db_password()`: ALTER USER если volume от прошлого деплоя
- [ ] `create_plugin_db()`: CREATE DATABASE dify_plugin если нет
- [ ] Retry loop (3 попытки) для контейнеров в `Created` state
- [ ] Fix storage permissions: `chown dify:dify /app/api/storage`
- [ ] `post_launch_status()`: ждёт 120s, показывает unhealthy/restarting + logs

### F-06: Health check

**Модуль:** `lib/health.sh`
**Описание:** Ожидание готовности контейнеров, проверка статусов.

**AC:**
- [ ] `wait_healthy(timeout)`: ждёт все контейнеры Up/Healthy
- [ ] `check_all()`: статус каждого контейнера (OK/starting/failed)
- [ ] Список сервисов динамический: core + optional по .env (vector store, monitoring, ETL)
- [ ] Критические сервисы (db, redis, api, worker, web, nginx): halt если unhealthy
- [ ] `report_health()`: extended report (GPU, models, vector, disk, backup)
- [ ] `send_alert()`: webhook/Telegram при сбоях

### F-07: Создание admin Open WebUI

**Модуль:** `lib/openwebui.sh`
**Описание:** Безопасное создание admin без public exposure.

**AC:**
- [ ] Stop nginx → enable signup → create admin via container-internal API → disable signup → start nginx
- [ ] Wait up to 120s для Open WebUI health
- [ ] JSON payload: name, email, password (escaped)
- [ ] Обработка "already exists"
- [ ] `ENABLE_SIGNUP=false` в .env постоянно, shell override только на время создания

### F-08: Скачивание моделей

**Модуль:** `lib/models.sh`
**Описание:** Ollama pull, vLLM/TEI auto-download, Xinference reranker.

**AC:**
- [ ] `wait_for_ollama()`: 5 минут timeout
- [ ] `pull_model()`: валидация имени, pull через docker exec
- [ ] LLM + Embedding модели: pull по выбору визарда
- [ ] Offline: `check_ollama_models()` — только проверка, без pull
- [ ] vLLM/TEI: сообщение что модель загружается при старте контейнера
- [ ] `load_reranker()`: Xinference bce-reranker-base_v1 (только ETL enhanced)

### F-09: Security hardening

**Модуль:** `lib/security.sh`
**Описание:** UFW, fail2ban (SSH jail), SOPS encryption, Docker hardening.

**AC:**
- [ ] UFW: deny incoming, allow SSH/80/443, LAN subnet, VPN interface, monitoring ports
- [ ] Fail2ban: **SSH jail only** (опция для всех профилей), maxretry=3, bantime=10d
- [ ] SOPS/age: генерация keypair, шифрование .env → .env.enc
- [ ] Docker hardening: `no-new-privileges` на все контейнеры кроме cadvisor/sandbox
- [ ] Security defaults по профилю: VPS = UFW+fail2ban+SOPS auto, LAN/VPN/Offline = опционально

> **Примечание:** Nginx rate limiting (10r/s general, 1r/10s login) — основная защита API.
> Fail2ban используется исключительно для SSH jail, не для HTTP.

### F-10: Authelia 2FA

**Модуль:** `lib/authelia.sh`
**Описание:** Двухфакторная аутентификация на /console/*.

**AC:**
- [ ] 2FA только на `/console/*` (Dify Console login)
- [ ] API routes bypass: `/api/`, `/v1/`, `/files/` — Dify API key auth + rate limiting
- [ ] nginx маркеры `#__AUTHELIA__` → активация
- [ ] users_database.yml + configuration.yml из шаблонов

### F-11: Бэкапы

**Модуль:** `lib/backup.sh`
**Описание:** Настройка автоматических бэкапов через cron.

**AC:**
- [ ] Cron entry для backup.sh с настраиваемым расписанием
- [ ] backup.conf: INSTALL_DIR, BACKUP_DIR, retention, remote settings
- [ ] Local: /var/backups/agmind/
- [ ] Remote: SCP/rsync (host, port, user, key, path)
- [ ] DR drill: ежемесячно 1-го числа (опционально)

### F-12: Reverse SSH Tunnel

**Модуль:** `lib/tunnel.sh`
**Описание:** Autossh reverse tunnel для доступа к LAN/VPN нодам через VPS.

**AC:**
- [ ] Установка autossh (apt/yum)
- [ ] Генерация SSH keypair (`ed25519`) в `$INSTALL_DIR/.ssh/`
- [ ] Systemd service `agmind-tunnel` с auto-restart
- [ ] Два туннеля: web (HTTP) + SSH
- [ ] Bind на `127.0.0.1` (не `0.0.0.0`)
- [ ] Вывод инструкции по добавлению ключа на VPS
- [ ] Профили: LAN/VPN only, опционально

### F-13: Day-2 CLI

**Модуль:** `scripts/agmind.sh`
**Описание:** Команда `agmind` для повседневных операций.

**AC:**
- [ ] `agmind status` — контейнеры, GPU, модели, endpoints, credentials path
- [ ] `agmind status --json` — machine-parseable JSON
- [ ] `agmind doctor` — DNS, GPU driver, Docker version, port conflicts, disk, network
- [ ] `agmind doctor --json` — machine-parseable diagnostics
- [ ] `agmind logs [-f] [service]` — просмотр логов
- [ ] `agmind backup` — ручной бэкап
- [ ] `agmind restore <path>` — восстановление
- [ ] `agmind update` — обновление стека
- [ ] `agmind stop/start/restart` — управление стеком
- [ ] `agmind rotate-secrets` — ротация секретов
- [ ] `agmind uninstall` — удаление
- [ ] Symlink `/usr/local/bin/agmind`

### F-14: Update / Rollback

**Модуль:** `scripts/update.sh`
**Описание:** Обновление стека с возможностью отката.

**AC:**
- [ ] Auto-backup перед обновлением
- [ ] Обновление versions.env → docker compose pull → up
- [ ] Rollback: откат к предыдущему release-manifest.json
- [ ] Changelog / breaking changes warning

### F-15: Offline Bundle

**Модуль:** `scripts/build-offline-bundle.sh`
**Описание:** Сборка пакета для air-gapped деплоя.

**AC:**
- [ ] Экспорт всех Docker-образов в `.tar.gz`
- [ ] Включение моделей Ollama (опционально)
- [ ] Включение versions.env, compose, templates
- [ ] Инструкция по загрузке на offline-ноду
- [ ] Валидация целостности (checksums)

---

## §4. Нефункциональные требования (NF-*)

### NF-01: Совместимость

- [ ] Ubuntu 20.04+, Debian 11+, CentOS/RHEL 8+, Fedora 38+
- [ ] macOS: только для разработки (Docker Desktop)
- [ ] x86_64, ARM64 (aarch64)
- [ ] Docker >= 24.0, Docker Compose >= 2.20

### NF-02: Минимальные ресурсы

- [ ] RAM: 4GB min, 16GB рекомендуется
- [ ] Disk: 30GB min, 50GB рекомендуется
- [ ] CPU: 2 ядра min, 4 рекомендуется

### NF-03: Безопасность

- [ ] Все секреты через `/dev/urandom`, не hardcoded
- [ ] .env chmod 600, root:root
- [ ] Credentials не в stdout, только в credentials.txt
- [ ] SSRF sandbox: block RFC1918 + metadata + link-local
- [ ] Redis: requirepass + ACL (не rename-command, deprecated в Redis 7+)
- [ ] Portainer/Grafana: 127.0.0.1 по умолчанию
- [ ] Docker: no-new-privileges, cap_drop, IPv6 disabled
- [ ] Rate limiting: 10r/s burst=20 general, 1r/10s burst=3 login

### NF-04: Надёжность

- [ ] Checkpoint resume: `.install_phase` файл
- [ ] Timeout + retry на фазах 5, 6, 7 (doubled timeout on retry)
- [ ] Atomic file writes: temp + mv
- [ ] Exclusive lock: flock/mkdir
- [ ] `set -euo pipefail` во всех скриптах
- [ ] Cleanup on failure: trap с информацией о фазе

### NF-05: Логирование

- [ ] install.log с timestamps (`touch` + `chmod 600` перед tee — фикс BUG-002)
- [ ] health.json генерируется каждую минуту (cron)
- [ ] logrotate для AGMind логов

### NF-06: Качество кода

- [ ] shellcheck clean (все .sh файлы)
- [ ] BATS тесты для каждого `lib/*.sh` модуля
- [ ] `bash -n` проверка синтаксиса
- [ ] CI: GitHub Actions (Ubuntu) — shellcheck + bats + bash -n
- [ ] Все переменные: `${VAR:-default}` при `set -u`
- [ ] Функции документированы: назначение, входы, выходы, side effects

---

## §5. Фазы установки

```
Phase 1: Diagnostics       → lib/detect.sh      → run_phase
Phase 2: Wizard             → lib/wizard.sh      → run_phase
Phase 3: Docker             → lib/docker.sh      → run_phase
Phase 4: Configuration      → lib/config.sh      → run_phase
Phase 5: Start Containers   → lib/compose.sh     → run_phase_with_timeout (300s)
Phase 6: Health Check       → lib/health.sh      → run_phase_with_timeout (300s)
Phase 7: Download Models    → lib/models.sh      → run_phase_with_timeout (1200s)
Phase 8: Setup Backups      → lib/backup.sh      → run_phase
Phase 9: Complete           → install.sh          → run_phase
```

### 5.1 install.sh (оркестратор)

```bash
# install.sh — ТОЛЬКО оркестрация
main() {
    parse_args "$@"
    check_root
    setup_logging      # touch + chmod 600 ПЕРЕД tee (BUG-002 fix)
    show_banner
    handle_checkpoint_resume

    run_phase 1 9 "Diagnostics"    phase_diagnostics
    run_phase 2 9 "Wizard"         phase_wizard
    run_phase 3 9 "Docker"         phase_docker
    run_phase 4 9 "Configuration"  phase_config
    run_phase_with_timeout 5 9 "Start" phase_start "$TIMEOUT_START"
    run_phase_with_timeout 6 9 "Health" phase_health "$TIMEOUT_HEALTH"
    run_phase_with_timeout 7 9 "Models" phase_models "$TIMEOUT_MODELS"
    run_phase 8 9 "Backups"        phase_backups
    run_phase 9 9 "Complete"       phase_complete
}
```

Максимальная длина install.sh: **≤ 200 строк**. Вся логика в `lib/*.sh`.

---

## §6. RAM Budget

| Компонент | Лимит | Примечание |
|-----------|-------|------------|
| api | 2g | Dify API |
| worker | 2g | Celery worker |
| web | 512m | Dify frontend |
| plugin_daemon | 512m | |
| db | 1g | PostgreSQL |
| redis | 512m | maxmemory 512mb в redis.conf |
| sandbox | 256m | |
| ssrf_proxy | 128m | Squid |
| nginx | 256m | |
| pipeline | 512m | Open WebUI pipelines |
| open-webui | 1g | |
| **Core total** | **~9.5g** | **Без LLM/embedding** |
| ollama | mem_limit из .env | По умолчанию нет лимита (зависит от модели) |
| vllm | mem_limit из .env | GPU-bound |
| weaviate/qdrant | 2g | |
| monitoring (full) | ~2g | prometheus+grafana+portainer+alertmanager+loki+promtail+node-exporter+cadvisor |
| etl (docling+xinference) | ~3g | Xinference с reranker |

- **Минимум** (core + ollama 7b): ~16GB RAM
- **Рекомендуется** (core + ollama 14b + monitoring): ~24GB RAM

---

## §7. Контракты модулей

### 7.1 common.sh

```bash
# Экспортирует:
# - Цвета: RED, GREEN, YELLOW, CYAN, BOLD, NC
# - log_info(), log_warn(), log_error(), log_success()
# - validate_model_name(), validate_domain(), validate_email()
# - validate_url(), validate_port(), validate_cron(), validate_path()
# - generate_random(length)
# - _atomic_sed(file, sed_args...)
# - escape_sed(string)
# - safe_write_file(filepath)
# - init_detected_defaults()  ← инициализация всех DETECTED_* с defaults (BUG-001 fix)
# Зависимости: нет
```

### 7.2 detect.sh

```bash
# Вход: ENV overrides (FORCE_GPU_TYPE, SKIP_GPU_DETECT, SKIP_PREFLIGHT)
# Экспортирует:
# - DETECTED_OS, DETECTED_OS_VERSION, DETECTED_OS_NAME, DETECTED_ARCH
# - DETECTED_GPU, DETECTED_GPU_NAME, DETECTED_GPU_VRAM
# - DETECTED_RAM_TOTAL_MB, DETECTED_RAM_AVAILABLE_MB, DETECTED_RAM_TOTAL_GB
# - DETECTED_DISK_FREE_GB
# - DETECTED_DOCKER_INSTALLED, DETECTED_DOCKER_VERSION, DETECTED_DOCKER_COMPOSE
# - DETECTED_NETWORK
# - RECOMMENDED_MODEL, RECOMMENDED_REASON
# - DOCKER_PLATFORM, PORTS_IN_USE
# Функции: run_diagnostics(), preflight_checks()
# Зависимости: common.sh (init_detected_defaults)
```

### 7.3 wizard.sh

```bash
# Вход: NON_INTERACTIVE, env var overrides (DEPLOY_PROFILE, LLM_PROVIDER, etc.)
# Экспортирует все wizard choices как глобальные переменные:
# - DEPLOY_PROFILE, DOMAIN, CERTBOT_EMAIL, VECTOR_STORE, ETL_ENHANCED
# - LLM_PROVIDER, LLM_MODEL, VLLM_MODEL, EMBED_PROVIDER, EMBEDDING_MODEL
# - HF_TOKEN, TLS_MODE, TLS_CERT_PATH, TLS_KEY_PATH
# - MONITORING_MODE, MONITORING_ENDPOINT, MONITORING_TOKEN
# - ALERT_MODE, ALERT_WEBHOOK_URL, ALERT_TELEGRAM_TOKEN, ALERT_TELEGRAM_CHAT_ID
# - ENABLE_UFW, ENABLE_FAIL2BAN, ENABLE_AUTHELIA
# - ENABLE_TUNNEL, TUNNEL_VPS_HOST, TUNNEL_VPS_PORT, TUNNEL_REMOTE_PORT
# - BACKUP_TARGET, BACKUP_SCHEDULE, REMOTE_BACKUP_*
# - ADMIN_UI_OPEN
# Функции: run_wizard()
# Зависимости: common.sh, detect.sh (RECOMMENDED_MODEL, DETECTED_GPU)
# Defaults: все переменные имеют defaults для --non-interactive
```

### 7.4 compose.sh

```bash
# Вход: INSTALL_DIR, DEPLOY_PROFILE, все provider/wizard vars, compose profiles
# Функции:
# - compose_up() — build profiles, cleanup, preflight, up, sync_db, create_plugin_db, retry loop
# - compose_down()
# - sync_db_password()
# - create_plugin_db()
# - post_launch_status()
# Зависимости: common.sh, config.sh (ensure_bind_mount_files, preflight_bind_mount_check)
```

### 7.5 openwebui.sh

```bash
# Вход: INSTALL_DIR
# Функции: create_openwebui_admin()
# Зависимости: common.sh
```

### 7.6 tunnel.sh

```bash
# Вход: INSTALL_DIR, TUNNEL_VPS_HOST, TUNNEL_VPS_PORT, TUNNEL_REMOTE_PORT, TUNNEL_LOCAL_PORT
# Функции: setup_tunnel()
# Side effects: autossh install, SSH key generation, systemd service creation
# Зависимости: common.sh
```

---

## §8. Non-interactive режим

```bash
sudo DEPLOY_PROFILE=lan \
     LLM_PROVIDER=ollama \
     LLM_MODEL=qwen2.5:14b \
     EMBEDDING_MODEL=bge-m3 \
     VECTOR_STORE=weaviate \
     MONITORING_MODE=none \
     BACKUP_TARGET=local \
     BACKUP_SCHEDULE="0 3 * * *" \
     bash install.sh --non-interactive
```

Все env vars имеют defaults. Минимальная конфигурация: только `DEPLOY_PROFILE`.

### 8.1 Defaults для non-interactive

| Переменная | Default | Описание |
|------------|---------|----------|
| DEPLOY_PROFILE | (обязательный) | Профиль деплоя |
| LLM_PROVIDER | ollama | LLM провайдер |
| LLM_MODEL | (по RECOMMENDED_MODEL) | LLM модель |
| EMBED_PROVIDER | same | Embedding = LLM provider |
| EMBEDDING_MODEL | bge-m3 | Embedding модель |
| VECTOR_STORE | weaviate | Векторное хранилище |
| ETL_ENHANCED | false | Расширенный ETL |
| TLS_MODE | (по профилю) | VPS=letsencrypt, иначе none |
| MONITORING_MODE | none | Мониторинг |
| ALERT_MODE | none | Алерты |
| ENABLE_UFW | (по профилю) | VPS=true, иначе false |
| ENABLE_FAIL2BAN | (по профилю) | VPS=true, иначе false |
| ENABLE_AUTHELIA | false | 2FA |
| ENABLE_TUNNEL | false | SSH tunnel |
| BACKUP_TARGET | local | Бэкапы |
| BACKUP_SCHEDULE | 0 3 * * * | Ежедневно в 3:00 |
| ADMIN_UI_OPEN | false | Portainer/Grafana locked |

---

## §9. Rollback

| Фаза | Side effect | Rollback |
|------|-------------|----------|
| 3: Docker | Установка Docker | Нет (Docker остаётся) |
| 4: Config | Файлы в /opt/agmind/ | `rm -rf /opt/agmind` |
| 5: Start | Docker containers + volumes | `docker compose down -v` |
| 7: Models | Модели в Docker volumes | `docker exec ollama rm <model>` |
| 8: Backups | Cron entries | `crontab -l \| grep -v agmind \| crontab -` |

Full uninstall: `agmind uninstall` или `scripts/uninstall.sh`

---

## §10. Известные баги v2 (исправляются в v3)

| ID | Описание | Причина | Фикс в v3 |
|----|----------|---------|-----------|
| BUG-001 | `lib/docker.sh` DETECTED_* без `${:-default}` при `set -u` | Переменные не инициализированы до source | `common.sh` → `init_detected_defaults()` |
| BUG-002 | install.log chmod race condition с tee | chmod до создания файла | `touch` + `chmod 600` перед tee |
| BUG-003 | SSD I/O errors при нагрузке 24 контейнеров | Hardware (USB-C SSD) | Не баг инсталлера, документировать требования к хранилищу |
| BUG-004 | Portainer порт 9443 конфликт | docker-proxy от прошлого деплоя | Динамический порт или cleanup перед стартом |
| BUG-005 | install.sh = 1763 строки | Вся логика в одном файле | Разделение на `lib/` модули (≤200 строк для install.sh) |
| BUG-006 | Wizard и compose логика смешаны в install.sh | Нет чёткого разделения | `wizard.sh`, `compose.sh`, `openwebui.sh` — отдельные модули |
| BUG-007 | Фазы на кириллице в логах | Смешение языков | Английские имена фаз |

---

## §11. Блоки для GSD кодера

Переписка разбита на независимые блоки. Каждый блок = один GSD task с чётким Definition of Done.

| # | Блок | Файлы | DoD |
|---|------|-------|-----|
| 1 | common.sh | lib/common.sh, tests/test_common.bats | Все утилиты + init_detected_defaults, shellcheck clean, BATS coverage |
| 2 | detect.sh | lib/detect.sh, tests/test_detect.bats | Все detect_*, preflight, shellcheck, BATS |
| 3 | wizard.sh | lib/wizard.sh, tests/test_wizard.bats | Весь визард, non-interactive defaults, shellcheck, BATS |
| 4 | docker.sh | lib/docker.sh, tests/test_docker.bats | Установка Docker + DNS + nvidia, shellcheck, BATS |
| 5 | config.sh | lib/config.sh, tests/test_config.bats | Генерация всех конфигов, Redis ACL, shellcheck, BATS |
| 6 | compose.sh | lib/compose.sh, tests/test_compose.bats | compose up/down, sync, retries, shellcheck, BATS |
| 7 | health.sh | lib/health.sh, tests/test_health.bats | Healthcheck, report, alerts, shellcheck, BATS |
| 8 | openwebui.sh | lib/openwebui.sh, tests/test_openwebui.bats | Admin creation, lockdown, shellcheck, BATS |
| 9 | models.sh | lib/models.sh, tests/test_models.bats | Ollama pull, vLLM, TEI, reranker, shellcheck, BATS |
| 10 | security.sh | lib/security.sh + lib/authelia.sh, tests/test_security.bats | UFW, fail2ban SSH, SOPS, hardening, shellcheck, BATS |
| 11 | tunnel.sh | lib/tunnel.sh | Autossh setup, systemd service, shellcheck |
| 12 | backup.sh | lib/backup.sh, tests/test_backup.bats | Cron setup, config, shellcheck, BATS |
| 13 | install.sh | install.sh (оркестратор ≤200 строк) | Фазы, checkpoint, logging, ≤200 строк, shellcheck |
| 14 | agmind CLI | scripts/agmind.sh | status, doctor, logs, backup, restore, --json, shellcheck |
| 15 | scripts | scripts/update.sh, restore.sh, uninstall.sh, build-offline-bundle.sh, generate-manifest.sh, dr-drill.sh, rotate_secrets.sh, health-gen.sh | Day-2 операции, shellcheck |
| 16 | CI | .github/workflows/*.yml | shellcheck + bats + bash -n |
| 17 | Templates | templates/docker-compose.yml, env.*.template, nginx.conf.template, monitoring/* | Все профили, все переменные, pinned versions |

**Порядок:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 → 16 → 17

---

## §12. Версии (source of truth: `templates/versions.env`)

| Компонент | Версия |
|-----------|--------|
| Dify | 1.13.0 |
| Open WebUI | v0.5.20 |
| Ollama | 0.6.2 |
| PostgreSQL | **16-alpine** (upgrade с 15) |
| Redis | 7.4.1-alpine |
| Weaviate | 1.27.6 |
| Qdrant | v1.12.1 |
| Nginx | 1.27.3-alpine |
| Sandbox | 0.2.12 |
| Squid | 6.6-24.04_edge |
| Certbot | v3.1.0 |
| Plugin Daemon | 0.5.3-local |
| Docling | v1.14.3 |
| Xinference | v0.16.3 |
| vLLM | v0.8.4 |
| TEI | cuda-1.9.2 |
| Authelia | 4.38 |
| Grafana | 11.4.0 |
| Portainer | 2.21.4 |
| Prometheus | v2.54.1 |
| Alertmanager | v0.27.0 |
| Loki | 3.3.2 |
| Promtail | 3.3.2 |
| Node Exporter | v1.8.2 |
| cAdvisor | v0.55.1 |

> При переписке обновить `templates/versions.env` с новой версией PostgreSQL.

---

## §13. Out of Scope

| Что | Почему |
|-----|--------|
| Dify API automation (import workflows, create KB) | Удалено в v2. Dify из коробки. |
| Патчи кода Dify/Open WebUI | Нарушает модель обновлений. |
| GUI/web installer | CLI для сисадминов. |
| Multi-node / cluster | Single-node. Kubernetes = другой продукт. |
| Multi-instance (multi-instance.sh) | Отдельный продукт, не часть core installer. |
| OAuth/SSO beyond Authelia | Есть в Dify enterprise. |
| Mobile app / dashboard | Инсталлер, не приложение. |
| Dokploy интеграция | Убрана из scope v3. |

---

## §14. Удалённые файлы (cleanup при переписке)

| Файл | Причина удаления |
|------|-----------------|
| lib/dokploy.sh | Out of Scope |
| scripts/multi-instance.sh | Out of Scope |
| scripts/test-upgrade-rollback.sh | Заменяется BATS тестами |
| scripts/restore-runbook.sh | Интегрируется в docs/ |
