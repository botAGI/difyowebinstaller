# Requirements: AGmind Installer

**Defined:** 2026-03-29
**Core Value:** One command installs, secures, and monitors a production-ready AI stack

## v2.7 Requirements

Requirements for milestone v2.7 Release Workflow + Platform Expansion.

### Release & Update (RELU)

- [x] **RELU-01**: Installer клонирует ветку `release` по умолчанию (README, документация обновлены)
- [x] **RELU-02**: `agmind update` тянет скрипты/конфиги из ветки `release` через git pull
- [x] **RELU-03**: `agmind update --main` переключает на ветку `main` (скрыт из --help, dev only, только конфиги без перекачки образов)
- [x] **RELU-04**: Pre-pull валидация образов через HTTP HEAD к registry API перед docker pull/update
- [x] **RELU-05**: Полные release notes в `agmind update --check` (полный текст + ссылка на GitHub)
- [x] **RELU-06**: Telegram HTML escape спецсимволов (`<`, `>`, `&`) в уведомлениях
- [x] **RELU-07**: Model API endpoints (Ollama/vLLM URL, TEI URL) записываются в credentials.txt
- [x] **RELU-08**: Dify FILES_URL auto-populate из домена/IP при установке

### Docling (DOCL)

- [x] **DOCL-01**: Wizard выбор Docling образа: GPU (quay.io cu128) или CPU (ghcr.io стандартный)
- [x] **DOCL-02**: Persistent volumes для HuggingFace cache и моделей Docling (переживают recreate)
- [x] **DOCL-03**: Русский OCR по умолчанию (OCR_LANG=rus,eng)
- [x] **DOCL-04**: Предзагрузка OCR/layout моделей при установке (до старта контейнера)

### Reliability (RLBL)

- [x] **RLBL-01**: Dify init fallback — увеличенный retry + автоматический повтор при неудаче
- [x] **RLBL-02**: Offline bundle e2e тест — build → airgap simulate → install → verify
- [x] **RLBL-03**: install.sh --dry-run — preflight checks (prereqs, ports, disk, DNS) без запуска контейнеров

## v2.8 Requirements

Requirements for milestone v2.8 New Services + Wizard Simplification.

### Wizard Simplification (WZRD)

- [x] **WZRD-01**: Wizard deploy profile сокращён до 2 пунктов: LAN (по умолчанию) и VDS/VPS (переключение на ветку agmind-caddy)
- [x] **WZRD-02**: Offline профиль полностью удалён из wizard, install.sh и всех связанных скриптов
- [x] **WZRD-03**: `scripts/build-offline-bundle.sh` удалён
- [x] **WZRD-04**: Ветка `agmind-caddy` создана от main; VDS/VPS в wizard делает `git fetch origin agmind-caddy && git checkout agmind-caddy && exec bash install.sh --vds`
- [x] **WZRD-05**: `lib/health.sh` и `lib/detect.sh` затрекены в git (не только копируются инсталлером)

### Core Services (CSVC)

- [x] **CSVC-01**: LiteLLM контейнер `agmind-litellm`, порт 4000, `litellm-config.yaml` генерируется wizard'ом на основе выбранных LLM провайдеров
- [x] **CSVC-02**: LiteLLM переиспользует PostgreSQL; Dify/Open WebUI получают `LLM_BASE_URL=http://agmind-litellm:4000/v1` в `.env`

### Optional Services (OSVC)

- [x] **OSVC-01**: Open Notebook — wizard `y/N`, compose profile=notebook, SurrealDB + LiteLLM, ~512 MB RAM
- [x] **OSVC-02**: DB-GPT — wizard `y/N`, compose profile=dbgpt, через LiteLLM, ~1 GB RAM
- [x] **OSVC-03**: Crawl4AI — wizard `y/N`, compose profile=crawl4ai, REST API, ~2 GB RAM (Chromium)
- [x] **OSVC-04**: SearXNG — wizard `y/N`, compose profile=searxng, порт 8888, JSON API, ~256 MB RAM

## Future (v3.0)

### Infrastructure

- **UXPL-02**: install.sh full dry-run mode (полная симуляция всех фаз, ~40-60 call sites)

## Out of Scope

| Feature | Reason |
| ------- | ------ |
| Real-time Dify API automation | Removed in Phase 1, user does this in Dify UI |
| GUI/web installer | CLI sufficient for target audience |
| Multi-node / cluster | Single-node focus |
| Auto-update | Only manual `agmind update` |
| CDN for update distribution | GitHub Releases sufficient |

## Priority Hints

Phase 31 (Wizard Simplify) first — убирает offline, расчищает для новых сервисов. LiteLLM (32) до Optional Services (33) — Open Notebook/DB-GPT через него работают.

## Traceability

| Requirement | Phase | Status |
| ----------- | ----- | ------ |
| RELU-01 | Phase 28 | Complete |
| RELU-02 | Phase 28 | Complete |
| RELU-03 | Phase 28 | Complete |
| RELU-05 | Phase 28 | Complete |
| RELU-06 | Phase 28 | Complete |
| RELU-07 | Phase 28 | Complete |
| RELU-08 | Phase 28 | Complete |
| DOCL-01 | Phase 29 | Complete |
| DOCL-02 | Phase 29 | Complete |
| DOCL-03 | Phase 29 | Complete |
| DOCL-04 | Phase 29 | Complete |
| RLBL-01 | Phase 30 | Complete |
| RLBL-03 | Phase 30 | Complete |
| RELU-04 | Phase 30 | Complete |
| RLBL-02 | Phase 30 | Complete |
| WZRD-01 | Phase 31 | Planned |
| WZRD-02 | Phase 31 | Planned |
| WZRD-03 | Phase 31 | Planned |
| WZRD-04 | Phase 31 | Planned |
| WZRD-05 | Phase 31 | Planned |
| CSVC-01 | Phase 32 | Planned |
| CSVC-02 | Phase 32 | Planned |
| OSVC-01 | Phase 33 | Planned |
| OSVC-02 | Phase 33 | Planned |
| OSVC-03 | Phase 33 | Planned |
| OSVC-04 | Phase 33 | Planned |

**Coverage:**

- v2.7 requirements: 15 total (all complete)
- v2.8 requirements: 11 total
- Mapped to phases: 11
- Unmapped: 0

---
*Requirements defined: 2026-03-29*
*Last updated: 2026-03-30 — v2.8 requirements added, 12 reqs mapped to phases 31-36*
