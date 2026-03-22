# Requirements: AGmind Installer

**Defined:** 2026-03-20
**Core Value:** One command installs, secures, and monitors a production-ready AI stack

## v2.3 Requirements

Requirements for v2.3 Stability & Reliability Bugfixes. Each maps to roadmap phases.

### Installer Reliability

- [x] **IREL-01**: check-upstream.sh стрипает v-prefix для компонентов, чьи Docker-образы без v (Weaviate, Postgres, Redis, Grafana) перед записью в отчёт (BUG-035)
- [x] **IREL-02**: Wizard показывает требуемый VRAM рядом с каждой моделью vLLM и ставит `[рекомендуется]` только если VRAM >= требуемого; предупреждение при выборе слишком большой модели (BUG-036)
- [ ] **IREL-03**: При resume установки, если PG volume уже существует, DB_PASSWORD берётся из существующего .env backup вместо генерации нового (BUG-037)
- [x] **IREL-04**: Dify admin init ждёт до 5 минут (60 retries); если не удалось — в credentials.txt пишется fallback инструкция с INIT_PASSWORD (BUG-039)

### Operator UX

- [x] **OPUX-01**: `agmind doctor` при отсутствии прав чтения .env показывает SKIP с сообщением "Запустите: sudo agmind doctor" вместо ложных FAIL (BUG-038)
- [x] **OPUX-02**: Redis ACL использует точечный blocklist опасных команд (-FLUSHALL -FLUSHDB -SHUTDOWN ...) вместо `-@dangerous`, оставляя CONFIG/INFO/KEYS доступными (BUG-040)

### Pull & Download UX

- [ ] **DLUX-01**: После docker compose pull — проверка каких образов нет локально; для отсутствующих — понятное сообщение с именем образа и тегом (WISH-010)
- [ ] **DLUX-02**: Скачивание моделей Ollama показывает прогресс (tty passthrough); при таймауте phase_models — warning вместо fatal + инструкция `agmind model pull` (WISH-011)

## v2.2 Requirements (Validated)

### Release Infrastructure

- [x] **RELS-01**: Создан GitHub Release `v2.1.0` с tag на main, release notes, и `versions.env` как asset
- [x] **RELS-02**: Файл `COMPONENTS.md` в корне описывает dependency groups (dify-core, gpu-inference, monitoring, standalone, infra)

### Bundle Update

- [x] **BUPD-01**: `agmind update --check` использует GitHub Releases API (`/repos/.../releases/latest`), показывает current vs latest release, diff версий компонентов, и release notes
- [x] **BUPD-02**: `agmind update` скачивает `versions.env` из latest GitHub Release, показывает diff, спрашивает подтверждение, делает backup в `.rollback/`, обновляет `.env` + `versions.env`, pull только изменённых образов, rolling restart, healthcheck
- [x] **BUPD-03**: При неудачном healthcheck после bundle update — автооткат из `.rollback/` с сообщением об ошибке
- [x] **BUPD-04**: `agmind update --check` при current == latest выводит `"You are up to date (vX.Y.Z)"`

### Emergency Mode

- [x] **EMRG-01**: `agmind update --component X --version Y` показывает предупреждение о bypass release compatibility с подтверждением `[y/N]`
- [x] **EMRG-02**: Флаг `--force` пропускает предупреждение в emergency mode

### Bugfix

- [x] **BFIX-01**: Все grep/sed в update.sh используют `LC_ALL=C` для locale-safe regex (BUG-V3-041)

### Rollback

- [x] **RBCK-01**: `agmind update --rollback` откатывает к предыдущему бандлу из `.rollback/` — совместим с новым bundle flow

## v2.1 Requirements (Validated)

### Runtime Stability

- [x] **STAB-01**: plugin-daemon стартует только после PostgreSQL с готовой БД `dify_plugin` (healthcheck + depends_on) — BUG-V3-022
- [x] **STAB-02**: Stale Redis locks (`plugin_daemon:env_init_lock:*`) автоудаляются при старте, если старше 15 мин — WISH-003
- [x] **STAB-03**: GPU-контейнеры автоматически поднимаются после ребута хоста (systemd service или cron @reboot) — BUG-V3-027

### Update System

- [x] **UPDT-01**: `agmind update --component <name> --version <tag>` обновляет отдельный компонент (pull + restart + healthcheck) — BUG-V3-024 + WISH-001
- [x] **UPDT-02**: `agmind update --check` показывает текущие vs доступные версии из Docker Hub/GHCR
- [x] **UPDT-03**: Rollback при неудачном healthcheck после обновления компонента

### Health Verification

- [x] **HLTH-01**: Post-install verify проверяет реальную доступность сервисов через curl (vLLM /v1/models, TEI /info, Dify /console/api/setup), результат в summary — WISH-002
- [x] **HLTH-02**: `agmind doctor` расширен: disk/RAM usage, Docker daemon, unhealthy/exited/high-restart контейнеры, GPU (nvidia-smi), HTTP endpoints ключевых сервисов, .env completeness — цветной summary + exit code 0/1 — WISH-005

### UX Polish

- [x] **UXPL-01**: При отключении SSH PasswordAuthentication — предупреждение + инструкция по SSH-ключам — BUG-V3-025
- [x] **UXPL-02**: Portainer tunnel-доступ (`ssh -L 9443:127.0.0.1:9443`) указан в credentials summary — BUG-V3-026
- [x] **UXPL-03**: LICENSE файл (Apache 2.0) в корне репозитория — WISH-006

### Operator Makefile — SKIPPED

- [~] **MAKE-01**: ~~Makefile с командами~~ — SKIPPED: agmind CLI уже покрывает все операции, Makefile избыточен
- [~] **MAKE-02**: ~~`make help`~~ — SKIPPED: см. MAKE-01

## v2.0 Requirements (Validated)

All 24 requirements shipped and confirmed working in v2.0. See git history for details.

### Surgery

- [x] **SURG-01**: Remove import.py and all Dify API automation
- [x] **SURG-02**: Remove live plugin download from GitHub
- [x] **SURG-03**: Remove wizard fields no longer needed
- [x] **SURG-04**: Keep rag-assistant.json as template + README
- [x] **SURG-05**: Installation reduced from 11 to 9 phases

### Security

- [x] **SECV-01**: Portainer/Grafana bind 127.0.0.1 by default
- [x] **SECV-02**: Authelia 2FA on /console/*, API routes bypass with rate limiting
- [x] **SECV-03**: Credentials only in credentials.txt (chmod 600)
- [x] **SECV-04**: SSRF sandbox blocks RFC1918 + link-local + cloud metadata
- [x] **SECV-05**: Nginx rate limiting replaces fail2ban
- [x] **SECV-06**: Backup/restore fixed
- [x] **SECV-07**: Rate limiting on nginx API routes

### Provider Architecture

- [x] **PROV-01**: LLM provider wizard
- [x] **PROV-02**: Embedding provider wizard
- [x] **PROV-03**: Compose profiles per provider
- [x] **PROV-04**: Plugin documentation per provider

### Installer

- [x] **INST-01**: 9-phase installation structure
- [x] **INST-02**: Resume from checkpoint
- [x] **INST-03**: Installation log with timestamps
- [x] **INST-04**: Timeout + retry per phase

### DevOps

- [x] **DEVX-01**: agmind status
- [x] **DEVX-02**: agmind doctor
- [x] **DEVX-03**: Health endpoint /health
- [x] **DEVX-04**: Named volumes with agmind_ prefix

## Deferred

### v2.3+

- **BUG-V3-023**: Авто-настройка model providers через Dify Console API — нарушает boundary, defer
- **WISH-008**: Welcome page после установки — HTML с URL-ами сервисов и credentials
- **TLSU-01**: TLS out of box (mkcert / Let's Encrypt)
- **MONV-01..04**: Victoria Metrics, GPU monitoring, vLLM metrics, alerts
- **INSE-01..04**: Non-interactive mode, uninstall, dry-run, model validation
- **ADVX-01..06**: Graceful shutdown, GPU isolation, multi-model, billing, docs, resource limits
- `agmind test` — интеграционные тесты
- GitHub Action upstream version checker

## Out of Scope

| Feature | Reason |
|---------|--------|
| Dify API automation (import workflows, create KB) | Boundary violation; source of 50% bugs |
| GUI/web installer | CLI sufficient for target audience |
| Multi-node / cluster | Single-node focus |
| Auto model provider config (BUG-V3-023) | Violates three-layer boundary; deferred to v2.3 |
| CDN для обновлений | GitHub Releases достаточно |
| Автообновление (auto-update) | Только ручной `agmind update` |
| Автоматическая проверка совместимости версий | Ручная проверка на тестовом сервере |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| SURG-01 | Phase 1 | Complete |
| SURG-02 | Phase 1 | Complete |
| SURG-03 | Phase 1 | Complete |
| SURG-04 | Phase 1 | Complete |
| SURG-05 | Phase 1 | Complete |
| SECV-01 | Phase 2 | Complete |
| SECV-02 | Phase 2 | Complete |
| SECV-03 | Phase 2 | Complete |
| SECV-04 | Phase 2 | Complete |
| SECV-05 | Phase 2 | Complete |
| SECV-06 | Phase 2 | Complete |
| SECV-07 | Phase 2 | Complete |
| PROV-01 | Phase 3 | Complete |
| PROV-02 | Phase 3 | Complete |
| PROV-03 | Phase 3 | Complete |
| PROV-04 | Phase 3 | Complete |
| INST-01 | Phase 4 | Complete |
| INST-02 | Phase 4 | Complete |
| INST-03 | Phase 4 | Complete |
| INST-04 | Phase 4 | Complete |
| DEVX-01 | Phase 5 | Complete |
| DEVX-02 | Phase 5 | Complete |
| DEVX-03 | Phase 5 | Complete |
| DEVX-04 | Phase 5 | Complete |
| STAB-01 | Phase 6 | Complete |
| STAB-02 | Phase 6 | Complete |
| STAB-03 | Phase 6 | Complete |
| UPDT-01 | Phase 7 | Complete |
| UPDT-02 | Phase 7 | Complete |
| UPDT-03 | Phase 7 | Complete |
| HLTH-01 | Phase 8 | Complete |
| HLTH-02 | Phase 8 | Complete |
| UXPL-01 | Phase 8 | Complete |
| UXPL-02 | Phase 8 | Complete |
| UXPL-03 | Phase 8 | Complete |
| MAKE-01 | Phase 9 | Skipped |
| MAKE-02 | Phase 9 | Skipped |
| BFIX-01 | Phase 10 | Complete |
| RELS-01 | Phase 10 | Complete |
| RELS-02 | Phase 10 | Complete |
| BUPD-01 | Phase 11 | Complete |
| BUPD-02 | Phase 11 | Complete |
| BUPD-03 | Phase 11 | Complete |
| BUPD-04 | Phase 11 | Complete |
| EMRG-01 | Phase 11 | Complete |
| EMRG-02 | Phase 11 | Complete |
| RBCK-01 | Phase 11 | Complete |
| IREL-01 | Phase 12 | Complete |
| IREL-04 | Phase 12 | Complete |
| OPUX-01 | Phase 12 | Complete |
| OPUX-02 | Phase 12 | Complete |
| IREL-02 | Phase 13 | Complete |
| IREL-03 | Phase 14 | Pending |
| DLUX-01 | Phase 15 | Pending |
| DLUX-02 | Phase 15 | Pending |

**Coverage (v2.2):**

- v2.2 requirements: 11 total
- Mapped to phases: 11
- Unmapped: 0

**Coverage (v2.3):**

- v2.3 requirements: 8 total
- Mapped to phases: 8
- Unmapped: 0

---
*Requirements defined: 2026-03-20*
*Last updated: 2026-03-22 — v2.3 traceability added (IREL-01..04 → Ph12-14, OPUX-01..02 → Ph12, DLUX-01..02 → Ph15)*
