# Requirements: AGmind Installer

**Defined:** 2026-03-25
**Core Value:** One command installs, secures, and monitors a production-ready AI stack

## v2.6 Requirements

Requirements for Install Stability + Update Robustness milestone.

### Install Stability

- [x] **ISTB-01**: Health wait парсит Docker logs GPU-контейнеров и показывает реальный статус (Downloading 45%, Loading model); таймаут по отсутствию прогресса (60s без новых строк), не по абсолютному времени
- [x] **ISTB-02**: При TLS=letsencrypt nginx стартует с self-signed placeholder cert; certbot получает настоящий cert; nginx reload — без race condition
- [x] **ISTB-03**: В LAN профиле Squid не блокирует RFC1918 адреса для webhook-вызовов из Dify sandbox
- [x] **ISTB-04**: Telegram notifications экранируют HTML-спецсимволы (`<`, `>`, `&`) перед отправкой
- [x] **ISTB-05**: credentials.txt содержит disclaimer: пароли могут устареть при смене через UI

### Update Robustness

- [ ] **UPDT-01**: update.sh при изменении major версии PostgreSQL (16→17) останавливает обновление с warning и предлагает pg_dump
- [ ] **UPDT-02**: update --check показывает полные release notes (до 10 строк + ссылка на GitHub)
- [ ] **UPDT-03**: После rollback автоматически запускается agmind doctor --json для верификации health
- [ ] **UPDT-04**: CI action автоматически синхронизирует release-manifest.json при создании GitHub Release

### UX Polish

- [ ] **UXPL-01**: Скачивание моделей стримит docker logs -f с progress bar; при таймауте — warning + инструкция `agmind model pull`
- [ ] **UXPL-02**: install.sh поддерживает `--dry-run` режим: валидирует конфиг, проверяет доступность образов, показывает план без запуска контейнеров

## Future Requirements (v3.0+)

### New Services

- **NSVC-01**: DB-GPT как опциональный сервис (Text-to-SQL, Multi-agent)
- **NSVC-02**: Open Notebook как опциональный сервис (NotebookLM альтернатива)

### Testing

- **TEST-01**: Offline bundle end-to-end lifecycle test (build → airgap → install → verify)

## Out of Scope

| Feature | Reason |
|---------|--------|
| DB-GPT (WISH-025) | Новый сервис, требует отдельный milestone с research |
| Open Notebook (WISH-026) | Новый сервис, требует отдельный milestone с research |
| Offline bundle e2e test (WISH-023) | Требует физический airgap-стенд, нельзя автоматизировать в CI |
| Auto-update | Только ручной `agmind update` — осознанное решение |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| ISTB-01 | Phase 25 | Complete |
| ISTB-02 | Phase 25 | Complete |
| ISTB-03 | Phase 25 | Complete |
| ISTB-04 | Phase 25 | Complete |
| ISTB-05 | Phase 25 | Complete |
| UPDT-01 | Phase 26 | Pending |
| UPDT-02 | Phase 26 | Pending |
| UPDT-03 | Phase 26 | Pending |
| UPDT-04 | Phase 26 | Pending |
| UXPL-01 | Phase 27 | Pending |
| UXPL-02 | Phase 27 | Pending |

**Coverage:**
- v2.6 requirements: 11 total
- Mapped to phases: 11
- Unmapped: 0

---
*Requirements defined: 2026-03-25*
*Last updated: 2026-03-25 after initial definition*
