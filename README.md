<p align="center">
  <img src="branding/logo.svg" alt="AGMind" width="200">
</p>

<h1 align="center">AGMind</h1>

<p align="center">
  <strong>Private AI Stack — one command, production-ready platform</strong>
</p>

<p align="center">
  <a href="#-обзор">Русский</a> · <a href="#-overview">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="License">
  <img src="https://img.shields.io/badge/bash-5%2B-green" alt="Bash 5+">
  <img src="https://img.shields.io/badge/containers-20--37-orange" alt="Containers">
  <img src="https://img.shields.io/badge/GPU-NVIDIA%20%7C%20AMD-76b900" alt="GPU Support">
</p>

---

# RU

## Обзор

AGMind — установщик RAG-платформы, который разворачивает полный AI-стек одной командой:
**Dify + Ollama/vLLM + Weaviate/Qdrant + мониторинг** — от 20 до 37 контейнеров
в Docker Compose с интерактивным визардом и автодетектом оборудования.

```bash
sudo bash install.sh
```

**Для кого:** DevOps-инженеры, ML-команды и IT-отделы, которым нужна приватная AI-инфраструктура
без vendor lock-in и облачных подписок.

**Ключевые ценности:**

- **5 минут до рабочей платформы** — визард задаёт вопросы, генерирует конфиги, качает образы, поднимает стек. Никаких ручных YAML-правок.
- **Локальные модели, полный контроль данных** — LLM, эмбеддинги и вектора работают на вашем железе. Данные не покидают периметр.
- **Продакшн из коробки** — TLS, файрвол, мониторинг, бэкапы, ротация секретов. Не proof-of-concept, а рабочая инфраструктура.
- **GPU-утилизация без боли** — автодетект NVIDIA/AMD, автоматическое распределение VRAM между vLLM и TEI, CPU-фолбэк для эмбеддингов.
- **Day-2 CLI** — `agmind status`, `agmind backup`, `agmind update` — эксплуатация без знания Docker.

---

## Ключевые возможности

### RAG-платформа полного цикла
Dify (workflow-оркестратор, основной фронтенд) + выбор LLM-провайдера (Ollama, vLLM, внешний API).
Векторные БД Weaviate или Qdrant, ETL через Docling с OCR, поиск через SearXNG — всё в одном деплое.
Open WebUI доступен как опциональный чат-интерфейс (`ENABLE_OPENWEBUI=true`).

### Автоматический GPU-менеджмент
Детект GPU при установке. Автоматический расчёт VRAM-сплита между vLLM (inference) и TEI (embeddings).
Поддержка multi-GPU: `agmind gpu assign --auto` распределяет сервисы по видеокартам.

### Профили деплоя
**LAN** — внутренняя сеть, без публичного домена, Portainer/Grafana только через SSH-туннель.
**VPS** — публичный домен, автоматический Let's Encrypt, Authelia 2FA.

### Поддержка ARM64 / DGX Spark
Нативная поддержка `aarch64`: автодетект unified memory GPU (NVIDIA GB10),
автоматический fallback на vLLM-based embeddings/reranking (TEI не имеет arm64-образов).

### Безопасность на уровне продакшна
30+ Linux capabilities отброшены. UFW + fail2ban + Authelia 2FA. Секреты генерируются через
`/dev/urandom`, хранятся в chmod 600. Rate limiting на nginx. SSRF-прокси для песочницы кода.
Ротация секретов: `agmind rotate-secrets`.

### Мониторинг и алертинг
Prometheus + Grafana (5 дашбордов: overview, containers, GPU, logs, alerts) + Loki (логи) + Alertmanager (Telegram/webhook).
Node Exporter + cAdvisor для метрик хоста и контейнеров. Portainer для визуального управления.

### Опциональные сервисы

Каждый включается одним `y` в визарде:

- **Docling** — расширенный ETL: OCR для PDF/изображений, поддержка таблиц, формул. CPU или GPU (CUDA). ~2 GB RAM / ~4 GB VRAM.
- **Open WebUI** — альтернативный чат-интерфейс (доступен на `/chat`). Простой UI для работы с моделями. ~300 MB RAM.
- **LiteLLM** — AI Gateway: единый OpenAI-совместимый API поверх всех провайдеров. Логирование запросов, rate-limit, fallback между моделями. ~1 GB RAM.
- **SearXNG** — приватный метапоисковик (Google, Bing, DuckDuckGo, Wikipedia). JSON API для интеграции с Dify-агентами. ~256 MB RAM.
- **Open Notebook** — альтернатива Google NotebookLM. Загрузка PDF, видео, аудио, веб-страниц — AI-суммаризация и Q&A. Хранение в SurrealDB. ~768 MB RAM.
- **DB-GPT** — AI-агент для анализа данных: генерация SQL, визуализация, чат с базами данных. ~1 GB RAM.
- **Crawl4AI** — REST API для извлечения данных из веб-страниц. Chromium-рендеринг, AI-парсинг, playground. ~2 GB RAM.

---

## Архитектура

### Высокоуровневая схема

```mermaid
graph TB
    subgraph NGINX["🌐 nginx :80 / :443 / :3000"]
        direction LR
        DIFY_APP["Dify App<br/><b>/ (default)</b>"]
        DIFY_API["Dify API<br/>/api /v1 /console"]
        DIFY_CONSOLE["Dify Console<br/>:3000"]
        OWUI["Open WebUI<br/>/chat (optional)"]
    end

    subgraph GPU["⚡ GPU Services"]
        direction LR
        OLLAMA["Ollama<br/>:11434"]
        VLLM["vLLM<br/>:8000"]
        TEI["TEI / vLLM-embed<br/>Embeddings"]
        RERANK["TEI / vLLM-rerank<br/>Reranking"]
    end

    subgraph DATA["💾 Data Layer"]
        direction LR
        PG["PostgreSQL<br/>:5432"]
        REDIS["Redis<br/>:6379"]
        WEAVIATE["Weaviate / Qdrant<br/>Vectors"]
    end

    subgraph OPTIONAL["📦 Optional Services"]
        direction LR
        LITELLM["LiteLLM<br/>AI Gateway"]
        SEARXNG["SearXNG<br/>Search"]
        NOTEBOOK["Open Notebook"]
        CRAWL4AI["Crawl4AI"]
        DBGPT["DB-GPT"]
        DOCLING["Docling<br/>ETL/OCR"]
    end

    subgraph MONITORING["📊 Monitoring"]
        direction LR
        PROM["Prometheus"]
        GRAFANA["Grafana<br/>:3001"]
        LOKI["Loki + Promtail"]
        ALERT["Alertmanager"]
        PORTAINER["Portainer<br/>:9443"]
    end

    NGINX --> GPU
    NGINX --> DATA
    DIFY_API --> PG
    DIFY_API --> REDIS
    DIFY_API --> WEAVIATE
    DIFY_API --> GPU
    PROM --> GRAFANA
    LOKI --> GRAFANA
    ALERT --> PROM

    style NGINX fill:#1a1a2e,stroke:#e94560,color:#fff
    style GPU fill:#1a1a2e,stroke:#0f3460,color:#fff
    style DATA fill:#1a1a2e,stroke:#16213e,color:#fff
    style OPTIONAL fill:#1a1a2e,stroke:#533483,color:#fff
    style MONITORING fill:#1a1a2e,stroke:#0f3460,color:#fff
```

### Структура репозитория

```
agmind/
├── install.sh                 # Главный оркестратор (9 фаз)
├── lib/                       # 15 модулей (wizard, config, compose, health, security, ...)
├── scripts/                   # Day-2: agmind CLI, update, backup, restore, rotate, DR-drill, uninstall
├── templates/                 # docker-compose.yml, nginx, env-шаблоны, versions.env
├── monitoring/                # Prometheus, Grafana (5 дашбордов), Loki, Alertmanager
├── workflows/                 # Dify workflow-шаблоны (RAG-ассистент и др.)
├── docs/                      # Документация (installation, ops, security)
└── branding/                  # Логотип, тема
```

### Сети Docker

| Сеть | Назначение |
|------|-----------|
| `agmind-frontend` | Nginx ↔ Web UI, Grafana, Portainer |
| `agmind-backend` | Все сервисы, внутренняя связь |
| `ssrf-network` | Изолированная: Sandbox ↔ Squid (SSRF-защита) |

### Фазы установки

| Фаза | Название | Что делает |
|------|----------|-----------|
| 1 | Diagnostics | Детект ОС, CPU, GPU, проверка диска/RAM/портов |
| 2 | Wizard | Интерактивный визард (~15 вопросов) |
| 3 | Docker | Установка Docker CE + NVIDIA Runtime |
| 4 | Config | Генерация .env, nginx, Redis, секретов |
| 5 | Pull | Валидация и загрузка Docker-образов |
| 6 | Start | `docker compose up -d`, создание admin-пользователей |
| 7 | Health | Ожидание healthcheck всех сервисов |
| 8 | Models | Загрузка LLM/embedding моделей |
| 9 | Complete | Бэкапы, CLI, systemd, финальный отчёт |

---

## Быстрый старт

### Требования

| Параметр | Минимум | Рекомендуется |
|----------|---------|--------------|
| ОС | Ubuntu 22.04 / Debian 12 | Ubuntu 24.04 LTS |
| CPU | 4 ядра | 8+ ядер |
| RAM | 8 GB | 32 GB |
| Диск | 20 GB | 100 GB SSD |
| GPU | — (CPU-режим) | NVIDIA 12+ GB VRAM |
| Docker | Устанавливается автоматически | — |

### Установка

```bash
git clone https://github.com/botAGI/AGmind.git
cd AGmind
sudo bash install.sh
```

Визард задаст ~15 вопросов (профиль, LLM-провайдер, модели, безопасность, мониторинг).
Через 5-10 минут после запуска:

- **Dify App** — `http://<IP>` (основной фронтенд, workflow-оркестратор)
- **Dify Console** — `http://<IP>:3000` (консоль администратора)
- **Open WebUI** — `http://<IP>/chat` (опционально, если `ENABLE_OPENWEBUI=true`)
- **Credentials** — `nano /opt/agmind/credentials.txt`

### Неинтерактивная установка

```bash
sudo DEPLOY_PROFILE=lan LLM_PROVIDER=ollama LLM_MODEL=qwen2.5:14b \
  EMBED_PROVIDER=ollama EMBEDDING_MODEL=bge-m3 \
  NON_INTERACTIVE=true bash install.sh
```

---

## Сценарии использования

### CLI — agmind

```bash
agmind status              # Дашборд: сервисы, GPU, эндпоинты
agmind doctor              # Диагностика: диск, RAM, Docker, DNS, порты
agmind logs -f api         # Логи сервиса в реальном времени
agmind gpu status          # Загрузка GPU, VRAM, температура
agmind gpu assign --auto   # Авто-распределение GPU между сервисами
agmind backup              # Создать бэкап (PostgreSQL + Redis + volumes)
agmind restore <path>      # Восстановить из бэкапа
agmind update --check      # Проверить обновления
agmind rotate-secrets      # Ротация паролей и ключей
```

### Типичные use-cases

| Роль | Сценарий |
|------|----------|
| **ML-инженер** | RAG-пайплайн: документы → Docling OCR → TEI эмбеддинги → Weaviate → vLLM генерация |
| **Аналитик** | Чат с корпоративными данными через Dify, SQL-аналитика через DB-GPT |
| **DevOps** | Мониторинг AI-стека: Grafana дашборды, алерты в Telegram, автобэкапы |
| **Руководитель** | Приватная ChatGPT-альтернатива для команды без облачных подписок |

---

## Конфигурация

### Профили деплоя

| Параметр | LAN | VPS |
|----------|-----|-----|
| Публичный домен | Нет | Да |
| TLS | Опционально (self-signed) | Let's Encrypt (авто) |
| Portainer/Grafana | localhost (SSH tunnel) | LAN-доступ |
| LiteLLM | Выключен по умолчанию | Включён по умолчанию |
| Authelia 2FA | Опционально | Опционально |

### LLM-провайдеры

| Провайдер | Когда использовать | RAM/VRAM |
|-----------|-------------------|----------|
| **Ollama** | Быстрый старт, CPU или GPU | 4-16 GB RAM / 4-48 GB VRAM |
| **vLLM** | Максимальная производительность GPU | 8-128 GB VRAM |
| **Внешний API** | Облачные модели (OpenAI, Anthropic) | Минимальные |

### Ключевые переменные

Все параметры конфигурации хранятся в `/opt/agmind/docker/.env`.
Ключевые переменные задаются визардом, версии образов привязаны через `versions.env`.
Секреты (пароли, API-ключи) генерируются автоматически и никогда не хардкодятся.

Переключатели опциональных сервисов:
`ENABLE_OPENWEBUI`, `ENABLE_LITELLM`, `ENABLE_DOCLING`, `ENABLE_SEARXNG`, `ENABLE_NOTEBOOK`, `ENABLE_DBGPT`, `ENABLE_CRAWL4AI`, `ENABLE_DIFY_PREMIUM`

---

## Разработка и вклад

### Проверки

```bash
shellcheck lib/*.sh scripts/*.sh install.sh
```

### Git-flow

- `release` — стабильная ветка (LAN-профиль)
- `agmind-caddy` — VPS-профиль с Caddy
- PR → code review → merge
- Все Docker-образы привязаны к версиям через `versions.env`. Тег `:latest` запрещён.

### Стандарты кода

- `set -euo pipefail` во всех скриптах
- Функции короткие, делают одну вещь
- Явные имена переменных, минимум магических констант
- Скрипты проходят `shellcheck`

### Вклад

Проект с открытым исходным кодом (Apache 2.0). Принимаем PR и issue.
Перед крупными изменениями — откройте issue с описанием.

---

## Деплой и эксплуатация

### Структура на сервере

```
/opt/agmind/
├── docker/
│   ├── .env                    # Секреты и конфигурация (chmod 600)
│   ├── docker-compose.yml      # Развёрнутые сервисы
│   ├── nginx/nginx.conf        # Reverse proxy
│   ├── litellm-config.yaml     # LLM-роутинг (если включён)
│   └── volumes/                # Данные: PostgreSQL, Redis, векторы, модели
├── credentials.txt             # Пароли (chmod 600)
├── scripts/                    # CLI и утилиты
└── install.log                 # Лог установки
```

### CI/CD

| Workflow | Триггер | Действие |
|----------|---------|----------|
| `test.yml` | Push/PR | shellcheck + build + smoke test |
| `check-upstream.yml` | Cron (weekly) | Проверка новых версий upstream-образов |
| `sync-release.yml` | Manual | Синхронизация release-ветки |

### Runbook типичных инцидентов

1. **Сервис не стартует** → `agmind logs <service>` → проверить последние строки лога
2. **Модель не загружается** → `agmind gpu status` → проверить VRAM → `docker logs agmind-vllm`
3. **502 Bad Gateway** → `agmind doctor` → проверить health: `docker compose ps`
4. **Полный диск** → `docker system prune -a` → `agmind backup` → удалить старые бэкапы
5. **Восстановление после сбоя** → `agmind restore /var/backups/agmind/latest/`

---

## Бенчмарки

Результаты на NVIDIA DGX Spark (GB10, 128 GB unified memory):

| Метрика | gemma-4-26B-A4B-it (MoE) |
|---------|--------------------------|
| TTFT (streaming) | 183 ms |
| TPS (1 запрос) | 23-24 tokens/sec |
| TPS (3 параллельных) | 50 tokens/sec aggregate |
| Длинная генерация (500 tok) | 20.6s @ 24.3 TPS |
| Контекст | 65K tokens (fp8 KV cache) |
| Max concurrency @ 65K | 45 параллельных запросов |
| Память: веса модели | 48.5 GiB (bfloat16) |
| Память: KV cache | 41.7 GiB (fp8) |
| Общий footprint | ~95 GiB |

---

## Лицензия

[Apache License 2.0](LICENSE)

Copyright 2024-2026 AGMind Contributors.

---

---

# EN

## Overview

AGMind is a RAG platform installer that deploys a production-ready AI stack
with a single command: **Dify + Ollama/vLLM + Weaviate/Qdrant + monitoring** —
20 to 37 containers via Docker Compose, with an interactive wizard and automatic hardware detection.

```bash
sudo bash install.sh
```

**Target audience:** DevOps engineers, ML teams, and IT departments that need private
AI infrastructure without vendor lock-in or cloud subscriptions.

**Key value propositions:**

- **5 minutes to a working platform** — the wizard asks questions, generates configs, pulls images, starts the stack. No manual YAML editing.
- **Local models, full data sovereignty** — LLMs, embeddings, and vector stores run on your hardware. Data never leaves your perimeter.
- **Production-ready out of the box** — TLS, firewall, monitoring, backups, secret rotation. Not a proof-of-concept, but real infrastructure.
- **GPU utilization without pain** — auto-detects NVIDIA/AMD, automatically splits VRAM between vLLM and TEI, CPU fallback for embeddings.
- **Day-2 CLI** — `agmind status`, `agmind backup`, `agmind update` — operations without Docker knowledge.

---

## Key Features

### Full-Cycle RAG Platform
Dify (workflow orchestrator, default frontend) + choice of LLM provider (Ollama, vLLM, external API).
Vector databases Weaviate or Qdrant, ETL via Docling with OCR, search via SearXNG — all in one deployment.
Open WebUI is available as an optional chat interface (`ENABLE_OPENWEBUI=true`).

### Automatic GPU Management
GPU detection at install time. Automatic VRAM split calculation between vLLM (inference) and TEI (embeddings).
Multi-GPU support: `agmind gpu assign --auto` distributes services across GPUs.

### Deployment Profiles
**LAN** — internal network, no public domain, Portainer/Grafana only via SSH tunnel.
**VPS** — public domain, automatic Let's Encrypt, Authelia 2FA.

### ARM64 / DGX Spark Support
Native `aarch64` support: auto-detects unified memory GPUs (NVIDIA GB10),
automatic fallback to vLLM-based embeddings/reranking (TEI has no arm64 images).

### Production-Grade Security
30+ Linux capabilities dropped. UFW + fail2ban + Authelia 2FA. Secrets generated via
`/dev/urandom`, stored with chmod 600. Rate limiting on nginx. SSRF proxy for code sandbox.
Secret rotation: `agmind rotate-secrets`.

### Monitoring & Alerting
Prometheus + Grafana (5 dashboards: overview, containers, GPU, logs, alerts) + Loki (logs) + Alertmanager (Telegram/webhook).
Node Exporter + cAdvisor for host and container metrics. Portainer for visual management.

### Optional Services

Each toggled with a single `y` in the wizard:

- **Docling** — enhanced ETL: OCR for PDFs/images, table and formula support. CPU or GPU (CUDA). ~2 GB RAM / ~4 GB VRAM.
- **Open WebUI** — alternative chat interface (available at `/chat`). Simple UI for model interaction. ~300 MB RAM.
- **LiteLLM** — AI Gateway: unified OpenAI-compatible API over all providers. Request logging, rate limiting, model fallback. ~1 GB RAM.
- **SearXNG** — private metasearch engine (Google, Bing, DuckDuckGo, Wikipedia). JSON API for Dify agent integration. ~256 MB RAM.
- **Open Notebook** — Google NotebookLM alternative. Upload PDFs, videos, audio, web pages — AI summarization and Q&A. SurrealDB storage. ~768 MB RAM.
- **DB-GPT** — AI agent for data analysis: SQL generation, visualization, chat with databases. ~1 GB RAM.
- **Crawl4AI** — REST API for web page data extraction. Chromium rendering, AI parsing, playground UI. ~2 GB RAM.

---

## Architecture

### High-Level Diagram

```mermaid
graph TB
    subgraph NGINX["🌐 nginx :80 / :443 / :3000"]
        direction LR
        DIFY_APP["Dify App<br/><b>/ (default)</b>"]
        DIFY_API["Dify API<br/>/api /v1 /console"]
        DIFY_CONSOLE["Dify Console<br/>:3000"]
        OWUI["Open WebUI<br/>/chat (optional)"]
    end

    subgraph GPU["⚡ GPU Services"]
        direction LR
        OLLAMA["Ollama<br/>:11434"]
        VLLM["vLLM<br/>:8000"]
        TEI["TEI / vLLM-embed<br/>Embeddings"]
        RERANK["TEI / vLLM-rerank<br/>Reranking"]
    end

    subgraph DATA["💾 Data Layer"]
        direction LR
        PG["PostgreSQL<br/>:5432"]
        REDIS["Redis<br/>:6379"]
        WEAVIATE["Weaviate / Qdrant<br/>Vectors"]
    end

    subgraph OPTIONAL["📦 Optional Services"]
        direction LR
        LITELLM["LiteLLM<br/>AI Gateway"]
        SEARXNG["SearXNG<br/>Search"]
        NOTEBOOK["Open Notebook"]
        CRAWL4AI["Crawl4AI"]
        DBGPT["DB-GPT"]
        DOCLING["Docling<br/>ETL/OCR"]
    end

    subgraph MONITORING["📊 Monitoring"]
        direction LR
        PROM["Prometheus"]
        GRAFANA["Grafana<br/>:3001"]
        LOKI["Loki + Promtail"]
        ALERT["Alertmanager"]
        PORTAINER["Portainer<br/>:9443"]
    end

    NGINX --> GPU
    NGINX --> DATA
    DIFY_API --> PG
    DIFY_API --> REDIS
    DIFY_API --> WEAVIATE
    DIFY_API --> GPU
    PROM --> GRAFANA
    LOKI --> GRAFANA
    ALERT --> PROM

    style NGINX fill:#1a1a2e,stroke:#e94560,color:#fff
    style GPU fill:#1a1a2e,stroke:#0f3460,color:#fff
    style DATA fill:#1a1a2e,stroke:#16213e,color:#fff
    style OPTIONAL fill:#1a1a2e,stroke:#533483,color:#fff
    style MONITORING fill:#1a1a2e,stroke:#0f3460,color:#fff
```

### Repository Structure

```
agmind/
├── install.sh                 # Main orchestrator (9 phases)
├── lib/                       # 15 modules (wizard, config, compose, health, security, ...)
├── scripts/                   # Day-2: agmind CLI, update, backup, restore, rotate, DR-drill, uninstall
├── templates/                 # docker-compose.yml, nginx, env templates, versions.env
├── monitoring/                # Prometheus, Grafana (5 dashboards), Loki, Alertmanager
├── workflows/                 # Dify workflow templates (RAG assistant, etc.)
├── docs/                      # Documentation (installation, ops, security)
└── branding/                  # Logo, theme
```

### Docker Networks

| Network | Purpose |
|---------|---------|
| `agmind-frontend` | Nginx ↔ Web UIs, Grafana, Portainer |
| `agmind-backend` | All services, internal communication |
| `ssrf-network` | Isolated: Sandbox ↔ Squid (SSRF protection) |

### Installation Phases

| Phase | Name | What it does |
|-------|------|-------------|
| 1 | Diagnostics | Detect OS, CPU, GPU; check disk/RAM/ports |
| 2 | Wizard | Interactive wizard (~15 questions) |
| 3 | Docker | Install Docker CE + NVIDIA Runtime |
| 4 | Config | Generate .env, nginx, Redis, secrets |
| 5 | Pull | Validate and pull Docker images |
| 6 | Start | `docker compose up -d`, create admin users |
| 7 | Health | Wait for all service healthchecks |
| 8 | Models | Download LLM/embedding models |
| 9 | Complete | Backups, CLI, systemd, final report |

---

## Getting Started

### Requirements

| Parameter | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu 22.04 / Debian 12 | Ubuntu 24.04 LTS |
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 32 GB |
| Disk | 20 GB | 100 GB SSD |
| GPU | — (CPU mode) | NVIDIA 12+ GB VRAM |
| Docker | Installed automatically | — |

### Installation

```bash
git clone https://github.com/botAGI/AGmind.git
cd AGmind
sudo bash install.sh
```

The wizard asks ~15 questions (profile, LLM provider, models, security, monitoring).
Within 5-10 minutes after launch:

- **Dify App** — `http://<IP>` (default frontend, workflow orchestrator)
- **Dify Console** — `http://<IP>:3000` (admin console)
- **Open WebUI** — `http://<IP>/chat` (optional, if `ENABLE_OPENWEBUI=true`)
- **Credentials** — `nano /opt/agmind/credentials.txt`

### Non-Interactive Installation

```bash
sudo DEPLOY_PROFILE=lan LLM_PROVIDER=ollama LLM_MODEL=qwen2.5:14b \
  EMBED_PROVIDER=ollama EMBEDDING_MODEL=bge-m3 \
  NON_INTERACTIVE=true bash install.sh
```

---

## Usage

### CLI — agmind

```bash
agmind status              # Dashboard: services, GPU, endpoints
agmind doctor              # Diagnostics: disk, RAM, Docker, DNS, ports
agmind logs -f api         # Real-time service logs
agmind gpu status          # GPU load, VRAM, temperature
agmind gpu assign --auto   # Auto-distribute GPU across services
agmind backup              # Create backup (PostgreSQL + Redis + volumes)
agmind restore <path>      # Restore from backup
agmind update --check      # Check for updates
agmind rotate-secrets      # Rotate passwords and keys
```

### Typical Use Cases

| Role | Scenario |
|------|----------|
| **ML Engineer** | RAG pipeline: documents → Docling OCR → TEI embeddings → Weaviate search → vLLM generation |
| **Analyst** | Chat with corporate data via Dify, SQL analytics via DB-GPT |
| **DevOps** | Monitor AI stack: Grafana dashboards, Telegram alerts, automated backups |
| **Manager** | Private ChatGPT alternative for the team, no cloud subscriptions |

---

## Configuration

### Deployment Profiles

| Parameter | LAN | VPS |
|-----------|-----|-----|
| Public domain | No | Yes |
| TLS | Optional (self-signed) | Let's Encrypt (auto) |
| Portainer/Grafana | localhost (SSH tunnel) | LAN-accessible |
| LiteLLM | Off by default | On by default |
| Authelia 2FA | Optional | Optional |

### LLM Providers

| Provider | When to use | RAM/VRAM |
|----------|-------------|----------|
| **Ollama** | Quick start, CPU or GPU | 4-16 GB RAM / 4-48 GB VRAM |
| **vLLM** | Maximum GPU performance | 8-128 GB VRAM |
| **External API** | Cloud models (OpenAI, Anthropic) | Minimal |

### Key Variables

All configuration is stored in `/opt/agmind/docker/.env`.
Key variables are set by the wizard; image versions are pinned via `versions.env`.
Secrets (passwords, API keys) are auto-generated and never hardcoded.

Optional service toggles:
`ENABLE_OPENWEBUI`, `ENABLE_LITELLM`, `ENABLE_DOCLING`, `ENABLE_SEARXNG`, `ENABLE_NOTEBOOK`, `ENABLE_DBGPT`, `ENABLE_CRAWL4AI`, `ENABLE_DIFY_PREMIUM`

---

## Development & Contributing

### Checks

```bash
shellcheck lib/*.sh scripts/*.sh install.sh
```

### Git Flow

- `release` — stable branch (LAN profile)
- `agmind-caddy` — VPS profile with Caddy
- PR → code review → merge
- All Docker images pinned to specific versions via `versions.env`. The `:latest` tag is forbidden.

### Code Standards

- `set -euo pipefail` in all scripts
- Functions are short and do one thing
- Explicit variable names, minimal magic constants
- All scripts pass `shellcheck`

### Contributing

Open-source project (Apache 2.0). PRs and issues are welcome.
For large changes, please open an issue first to discuss the approach.

---

## Deployment & Ops

### Server Layout

```
/opt/agmind/
├── docker/
│   ├── .env                    # Secrets and config (chmod 600)
│   ├── docker-compose.yml      # Deployed services
│   ├── nginx/nginx.conf        # Reverse proxy
│   ├── litellm-config.yaml     # LLM routing (if enabled)
│   └── volumes/                # Data: PostgreSQL, Redis, vectors, models
├── credentials.txt             # Passwords (chmod 600)
├── scripts/                    # CLI and utilities
└── install.log                 # Installation log
```

### CI/CD

| Workflow | Trigger | Action |
|----------|---------|--------|
| `test.yml` | Push/PR | shellcheck + build + smoke test |
| `check-upstream.yml` | Cron (weekly) | Check for upstream image updates |
| `sync-release.yml` | Manual | Sync release branch |

### Common Incidents — Runbook

1. **Service won't start** → `agmind logs <service>` → check last log lines
2. **Model not loading** → `agmind gpu status` → check VRAM → `docker logs agmind-vllm`
3. **502 Bad Gateway** → `agmind doctor` → check health: `docker compose ps`
4. **Disk full** → `docker system prune -a` → `agmind backup` → remove old backups
5. **Disaster recovery** → `agmind restore /var/backups/agmind/latest/`

---

## Benchmarks

Results on NVIDIA DGX Spark (GB10, 128 GB unified memory):

| Metric | gemma-4-26B-A4B-it (MoE) |
|--------|--------------------------|
| TTFT (streaming) | 183 ms |
| TPS (single request) | 23-24 tokens/sec |
| TPS (3 concurrent) | 50 tokens/sec aggregate |
| Long generation (500 tok) | 20.6s @ 24.3 TPS |
| Context window | 65K tokens (fp8 KV cache) |
| Max concurrency @ 65K | 45 parallel requests |
| Memory: model weights | 48.5 GiB (bfloat16) |
| Memory: KV cache | 41.7 GiB (fp8) |
| Total footprint | ~95 GiB |

---

## License

[Apache License 2.0](LICENSE)

Copyright 2024-2026 AGMind Contributors.
