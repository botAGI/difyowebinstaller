# Requirements: AGmind Installer

**Defined:** 2026-03-29
**Core Value:** One command installs, secures, and monitors a production-ready AI stack

## v2.7 Requirements

Requirements for milestone v2.7 Release Workflow + Platform Expansion.

### Release & Update (RELU)

- [x] **RELU-01**: Installer клонирует ветку `release` по умолчанию (README, документация обновлены)
- [x] **RELU-02**: `agmind update` тянет скрипты/конфиги из ветки `release` через git pull
- [x] **RELU-03**: `agmind update --main` переключает на ветку `main` (скрыт из --help, dev only, только конфиги без перекачки образов)
- [ ] **RELU-04**: Pre-pull валидация образов через HTTP HEAD к registry API перед docker pull/update
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

- [ ] **RLBL-01**: Dify init fallback — увеличенный retry + автоматический повтор при неудаче
- [ ] **RLBL-02**: Offline bundle e2e тест — build → airgap simulate → install → verify
- [ ] **RLBL-03**: install.sh --dry-run — preflight checks (prereqs, ports, disk, DNS) без запуска контейнеров

## Future (v3.0)

### New Services

- **NSVC-01**: DB-GPT как опциональный сервис (COMPOSE_PROFILE=dbgpt, SQLite, подключается к Ollama)
- **NSVC-02**: Open Notebook как опциональный сервис (COMPOSE_PROFILE=notebook, SurrealDB sidecar)

### Infrastructure

- **UXPL-02**: install.sh full dry-run mode (полная симуляция всех фаз, ~40-60 call sites)
- **CADDY-01**: Caddy reverse proxy + subdomains вместо nginx

## Out of Scope

| Feature | Reason |
| ------- | ------ |
| Real-time Dify API automation | Removed in Phase 1, user does this in Dify UI |
| GUI/web installer | CLI sufficient for target audience |
| Multi-node / cluster | Single-node focus |
| Auto-update | Only manual `agmind update` |
| CDN for update distribution | GitHub Releases sufficient |
| Caddy migration (v2.7) | Deferred to v3.0 — large scope, nginx works |

## Priority Hints

Within Release & Update: RELU-01/02/03 (branching) and RELU-06/07 (quick fixes) first. RELU-04 (pre-pull) last — depends on update infrastructure.

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
| RLBL-01 | Phase 30 | Pending |
| RLBL-03 | Phase 30 | Pending |
| RELU-04 | Phase 31 | Pending |
| RLBL-02 | Phase 32 | Pending |

**Coverage:**

- v2.7 requirements: 15 total
- Mapped to phases: 15
- Unmapped: 0

---
*Requirements defined: 2026-03-29*
*Last updated: 2026-03-29 — traceability mapped to phases 28-32*
