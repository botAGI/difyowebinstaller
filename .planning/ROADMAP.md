# Roadmap: AGmind Installer

## Milestones

- ✅ **v2.0 MVP** — Phases 1-5 (shipped 2026-03-18)
- ✅ **v2.1 Bugfixes + Improvements** — Phases 6-9 (shipped 2026-03-21)
- ✅ **v2.2 Release Bundle Update System** — Phases 10-11 (shipped 2026-03-22)
- 🚧 **v2.3 Stability & Reliability Bugfixes** — Phases 12-15 (in progress)

---

<details>
<summary>✅ v2.0 MVP (Phases 1-5) — SHIPPED 2026-03-18</summary>

## Phase 1: Surgery — Remove Dify API Automation

**Goal:** Delete import.py and all code that touches Dify API. Reduce attack surface, eliminate 50% of bugs, enforce three-layer boundary.

**Requirements:** SURG-01, SURG-02, SURG-03, SURG-04, SURG-05

**Plans:** 2 plans

Plans:
- [x] 01-01-PLAN.md — Delete files, restructure install.sh to 9 phases, remove wizard fields, clean downstream configs
- [x] 01-02-PLAN.md — Create workflows/README.md with import instructions, final stale-reference sweep

**Success criteria:**
- `install.sh` runs clean without import.py
- No HTTP calls to Dify API in codebase
- No GitHub downloads of plugin source code
- Stack comes up healthy (23+ containers minus import-dependent ones)

**Depends on:** nothing

---

## Phase 2: Security Hardening v2

**Goal:** Close all known security gaps. Fail2ban and backup must actually work. Credentials never leak to stdout.

**Requirements:** SECV-01, SECV-02, SECV-03, SECV-04, SECV-05, SECV-06, SECV-07

**Plans:** 4/4 plans complete

Plans:
- [x] 02-01-PLAN.md — Nginx rate limiting extension + fail2ban nginx jail removal (SECV-05, SECV-07)
- [x] 02-02-PLAN.md — Wizard admin-UI opt-in, credential suppression, Squid ACL, Authelia policy (SECV-01, SECV-02, SECV-03, SECV-04)
- [x] 02-03-PLAN.md — Backup/restore fixes + BATS test (SECV-06)
- [x] 02-04-PLAN.md — Gap closure: SECV-02 documentation drift fix (SECV-02)

**Success criteria:**
- `ss -tlnp | grep 9443` shows 127.0.0.1 (not 0.0.0.0)
- `grep -r "password\|DIFY_API" install.log` returns nothing
- `backup.sh && destroy && restore.sh && verify` passes
- Fail2ban active and banning (or nginx rate limiting configured)
- `curl 169.254.169.254` from sandbox container blocked

**Depends on:** Phase 1

---

## Phase 3: Provider Architecture

**Goal:** User chooses LLM and embedding provider in wizard. Compose profiles start only what's needed.

**Requirements:** PROV-01, PROV-02, PROV-03, PROV-04

**Plans:** 3/3 plans complete

Plans:
- [x] 03-01-PLAN.md — Compose profiles: Ollama to profile, add vLLM + TEI services, versions.env, env templates (PROV-03)
- [x] 03-02-PLAN.md — Wizard provider selection, config.sh, models.sh dispatcher, BATS tests (PROV-01, PROV-02, PROV-03)
- [x] 03-03-PLAN.md — Provider-aware phase_complete() hints + workflows/README.md docs (PROV-04)

**Success criteria:**
- Each provider choice results in correct containers running (and nothing extra)
- `docker compose --profile vllm up` starts vLLM, not Ollama
- `docker compose --profile ollama up` starts Ollama, not vLLM
- External provider: no LLM container started
- README documents which plugins to install per provider

**Depends on:** Phase 1

---

## Phase 4: Installer Redesign

**Goal:** 9-phase installation with resume, logging, timeouts. Professional installer that never leaves user blind.

**Requirements:** INST-01, INST-02, INST-03, INST-04

**Plans:** 2/2 plans complete

Plans:
- [x] 04-01-PLAN.md — run_phase() wrapper, checkpoint/resume, tee logging, --force-restart flag (INST-01, INST-02, INST-03)
- [x] 04-02-PLAN.md — Timeout/retry for phases 5/6/7, named volumes agmind_ prefix, v1 migration (INST-04, INST-01)

**Success criteria:**
- Kill install at phase 5, restart -> resumes from phase 5
- install.log contains every phase with timestamps
- Stuck model pull times out after configured duration with helpful message
- `docker volume ls | grep agmind_` shows all volumes with prefix

**Depends on:** Phase 3

---

## Phase 5: DevOps & UX

**Goal:** CLI tools for day-2 operations. User never needs to guess stack status.

**Requirements:** DEVX-01, DEVX-02, DEVX-03, DEVX-04

**Plans:** 2/2 plans complete

Plans:
- [x] 05-01-PLAN.md — agmind CLI entry point with status dashboard, --json output, doctor diagnostics (DEVX-01, DEVX-02, DEVX-04)
- [x] 05-02-PLAN.md — health-gen.sh + nginx /health endpoint + install.sh integration + BATS tests (DEVX-03)

**Success criteria:**
- `agmind status` shows all containers, GPU util, loaded models, HTTP status of each endpoint
- `agmind status --json` outputs valid JSON with services/gpu/endpoints/backup fields
- `agmind doctor` catches: wrong Docker version, port conflict, DNS failure, low disk
- `curl localhost/health` returns JSON with per-service status
- Non-zero exit code from doctor when issues found

**Depends on:** Phase 4

</details>

---

<details>
<summary>✅ v2.1 Bugfixes + Improvements (Phases 6-9) — SHIPPED 2026-03-21</summary>

**Milestone Goal:** Fix critical runtime bugs that affect production reliability, add component-level update workflow, and improve post-install feedback and operator guidance.

### Phase 6: Runtime Stability

**Goal:** The stack survives real-world conditions — plugin-daemon starts reliably after PostgreSQL is ready, Redis stale locks never block a second startup, and GPU containers come back automatically after a host reboot.

**Depends on:** Phase 5
**Requirements:** STAB-01, STAB-02, STAB-03

**Success Criteria** (what must be TRUE):

1. `docker compose up` after a fresh boot never fails with "plugin-daemon DB not ready" — plugin-daemon waits for `dify_plugin` database to exist
2. Running `docker compose up` a second time after a crash clears any stale Redis lock (older than 15 min) automatically, without manual `redis-cli DEL`
3. After `sudo reboot`, all GPU containers (vLLM / Ollama) are running within 2 minutes without any manual intervention
4. `agmind status` confirms healthy GPU containers post-reboot

**Plans:** 3/3 plans complete

Plans:
- [x] 06-01-PLAN.md — PostgreSQL init SQL + enhanced healthcheck, Redis lock-cleaner init-container, plugin_daemon dependency chain (STAB-01, STAB-02)
- [x] 06-02-PLAN.md — systemd auto-start service + GPU container restart policy change to unless-stopped (STAB-03)
- [x] 06-03-PLAN.md — Gap closure: copy redis-lock-cleanup.sh in installer + persist COMPOSE_PROFILES for systemd reboot (STAB-02, STAB-03)

### Phase 7: Update System

**Goal:** Operators can check for available version updates and update any single component without touching the rest of the stack, with automatic rollback if the updated container fails its healthcheck.

**Depends on:** Phase 6
**Requirements:** UPDT-01, UPDT-02, UPDT-03

**Success Criteria** (what must be TRUE):

1. `agmind update --check` prints a table of current vs. available image tags for all managed components
2. `agmind update --component dify-api --version 1.4.0` pulls the new image, restarts only that container, and runs its healthcheck
3. If the healthcheck fails after update, the previous image tag is restored and the container is restarted — no manual steps needed
4. `agmind update` records what was updated and the outcome in install.log with a timestamp

**Plans:** 2/2 plans complete

Plans:
- [x] 07-01-PLAN.md — Remote version fetching from GitHub + component targeting with short-name mapping (UPDT-01, UPDT-02)
- [x] 07-02-PLAN.md — Per-component rollback hardening + manual rollback command + BATS tests (UPDT-03)

### Phase 8: Health Verification & UX Polish

**Goal:** Post-install summary confirms real service reachability (not just container health), `agmind doctor` becomes a comprehensive diagnostics tool, operator pain points (SSH lockout, Portainer tunnel) are resolved, and the repo has a license for public release.

**Depends on:** Phase 6
**Requirements:** HLTH-01, HLTH-02, UXPL-01, UXPL-02, UXPL-03

**Success Criteria** (what must be TRUE):

1. After `install.sh` completes, the summary block shows a per-service HTTP status (OK / FAIL) based on real `curl` calls to vLLM `/v1/models`, TEI `/info`, and Dify `/console/api/setup`
2. When the installer disables SSH `PasswordAuthentication`, the terminal outputs a warning and SSH public key setup instructions before making the change
3. `credentials.txt` and the post-install summary both include the Portainer SSH tunnel command (`ssh -L 9443:127.0.0.1:9443 user@host`)
4. An operator on a fresh server can access Portainer on the first attempt by following only the on-screen instructions
5. `agmind doctor` checks disk/RAM usage, Docker daemon, unhealthy/exited/high-restart containers, GPU availability, key service HTTP endpoints, and .env completeness — outputs colored summary with exit code 0/1
6. `LICENSE` file (Apache 2.0) exists in repo root

**Plans:** 3/3 plans complete

Plans:
- [x] 08-01-PLAN.md — verify_services() HTTP liveness checks + Portainer SSH tunnel in credentials/summary (HLTH-01, UXPL-02)
- [x] 08-02-PLAN.md — Doctor enhancement: container health, HTTP endpoints, disk/RAM %, .env completeness (HLTH-02)
- [x] 08-03-PLAN.md — SSH lockout prevention with warning + Apache 2.0 LICENSE (UXPL-01, UXPL-03)

### ~~Phase 9: Operator Makefile~~ — SKIPPED

**Reason:** agmind CLI already covers all operator commands (status, logs, doctor, update, restart). Makefile would be redundant.

</details>

---

<details>
<summary>✅ v2.2 Release Bundle Update System (Phases 10-11) — SHIPPED 2026-03-22</summary>

**Milestone Goal:** Перейти с покомпонентных обновлений на bundle-based через GitHub Releases API. Каждый Release — проверенный набор версий всех 27 компонентов. Оператор получает только то, что протестировано вместе.

### Phase 10: Release Foundation

**Goal:** Зафиксировать текущее состояние как первый официальный release v2.1.0 с versions.env как asset, исправить locale-баг в update.sh, и задокументировать dependency groups для мейнтейнеров.

**Depends on:** Phase 8
**Requirements:** BFIX-01, RELS-01, RELS-02

**Success Criteria** (what must be TRUE):

1. GitHub Release `v2.1.0` создан с tag на main, содержит release notes и `versions.env` как downloadable asset — curl к GitHub API возвращает release с asset `versions.env`
2. Все `grep`/`sed` вызовы в `update.sh` используют `LC_ALL=C` — проверяется запуском update.sh на сервере с `LANG=ru_RU.UTF-8` без регрессий
3. Файл `COMPONENTS.md` в корне репозитория описывает все dependency groups (dify-core, gpu-inference, monitoring, standalone, infra) с перечнем компонентов в каждой группе
4. Мейнтейнер, открыв `COMPONENTS.md`, понимает какие компоненты нужно тестировать вместе перед выпуском нового release

**Plans:** 2/2 plans complete

Plans:
- [x] 10-01-PLAN.md — Verify BFIX-01 locale fix + create COMPONENTS.md dependency groups (BFIX-01, RELS-02)
- [x] 10-02-PLAN.md — Create GitHub Release v2.1.0 with versions.env asset (RELS-01)

---

### Phase 11: Bundle Update Rewrite

**Goal:** Переписать `agmind update` с per-component логики на bundle workflow через GitHub Releases API. Оператор получает diff версий, подтверждает, получает rolling restart с автооткатом при неудаче. Emergency-режим `--component` сохранён с предупреждением.

**Depends on:** Phase 10
**Requirements:** BUPD-01, BUPD-02, BUPD-03, BUPD-04, EMRG-01, EMRG-02, RBCK-01

**Success Criteria** (what must be TRUE):

1. `agmind update --check` обращается к GitHub Releases API, выводит current release vs latest release, построчный diff изменённых версий компонентов, и release notes — при current == latest выводит `"You are up to date (vX.Y.Z)"`
2. `agmind update` скачивает `versions.env` из latest release, показывает diff, запрашивает подтверждение `[y/N]`, делает backup в `.rollback/`, обновляет `.env` и `versions.env`, делает `docker pull` только для изменившихся образов, выполняет rolling restart контейнеров
3. После rolling restart выполняется healthcheck — при неудаче автоматически применяется rollback из `.rollback/` и оператор видит сообщение об ошибке с инструкцией
4. `agmind update --component X --version Y` показывает предупреждение о bypass release compatibility с запросом подтверждения `[y/N]` — флаг `--force` пропускает запрос
5. `agmind update --rollback` восстанавливает предыдущий bundle из `.rollback/` — команда работает как после ручного запуска, так и после auto-rollback

**Plans:** 2/2 plans complete

Plans:
- [x] 11-01-PLAN.md — Core rewrite: GitHub Releases API + bundle diff + bundle update flow + auto-rollback (BUPD-01, BUPD-02, BUPD-03, BUPD-04)
- [x] 11-02-PLAN.md — Emergency mode warning + --force bypass + bundle rollback + CLI help update (EMRG-01, EMRG-02, RBCK-01)

</details>

---

## v2.3 Stability & Reliability Bugfixes (In Progress)

**Milestone Goal:** Исправить критичные баги, обнаруженные при тестировании v2.2. Повысить надёжность установки на edge-кейсах (медленное железо, resume, low VRAM) и улучшить UX оператора (doctor, прогресс, ошибки).

## Phase Details

### Phase 12: Isolated Bugfixes

**Goal:** Операторский инструментарий и runtime-конфиг работают корректно без ложных ошибок — doctor не показывает FAIL без прав, Redis ACL не блокирует нужные команды, upstream-отчёт показывает правильные теги, Dify admin init не прерывается на медленном железе.

**Depends on:** Phase 11
**Requirements:** IREL-01, IREL-04, OPUX-01, OPUX-02

**Success Criteria** (what must be TRUE):

1. `agmind doctor`, запущенный без sudo, показывает `SKIP` для проверок .env с сообщением "Запустите: sudo agmind doctor" — ни одна проверка .env не показывает FAIL при отсутствии прав чтения
2. Redis ACL в сгенерированном конфиге содержит точечный blocklist (`-FLUSHALL -FLUSHDB -SHUTDOWN` и т.д.), а команды `CONFIG`, `INFO`, `KEYS` остаются доступными — проверяется `redis-cli CONFIG GET maxmemory` без ошибки
3. `check-upstream.sh` для Weaviate, Postgres, Redis, Grafana выводит версию без v-prefix в отчёт — тег `v1.36.6` записывается как `1.36.6`
4. Dify admin init ждёт до 5 минут (60 попыток x 5 сек) — на медленном сервере установка завершается без ошибки таймаута; если всё же не удалось — `credentials.txt` содержит fallback инструкцию с `INIT_PASSWORD`

**Plans:** 2/2 plans complete

Plans:
- [ ] 12-01-PLAN.md — Doctor .env SKIP guard without root + Redis ACL explicit blocklist (OPUX-01, OPUX-02)
- [ ] 12-02-PLAN.md — check-upstream.sh v-prefix strip + Dify init timeout 5 min + fallback credentials (IREL-01, IREL-04)

---

### Phase 13: VRAM Guard in Wizard

**Goal:** Wizard не позволяет молча выбрать модель vLLM, которая не помещается в VRAM — пользователь видит требования к памяти рядом с каждой моделью и получает предупреждение при попытке выбрать слишком большую.

**Depends on:** Phase 12
**Requirements:** IREL-02

**Success Criteria** (what must be TRUE):

1. В меню выбора модели vLLM каждая строка показывает требуемый VRAM (например, `mistral-7b [~14 GB VRAM]`) — метка `[рекомендуется]` ставится только для моделей с VRAM <= обнаруженного GPU
2. При выборе модели с VRAM > обнаруженного GPU wizard выводит явное предупреждение с цифрами (требуется X GB, доступно Y GB) и запрашивает подтверждение `[y/N]` перед продолжением
3. При DETECTED_GPU_VRAM=0 (GPU не обнаружен) — все модели показываются без метки `[рекомендуется]`, предупреждение о неизвестном VRAM выводится один раз в начале списка

**Plans:** 1/1 plans complete

Plans:
- [ ] 13-01-PLAN.md — VRAM-aware vLLM model selection with dynamic [recommended] tag and oversized warning (IREL-02)

---

### Phase 14: DB Password Resume Safety

**Goal:** Resume установки на сервере с существующими PG volumes не затирает пароль БД — `.env` сохраняет тот же `DB_PASSWORD`, что был при первоначальной установке, stack поднимается без ошибок аутентификации.

**Depends on:** Phase 12
**Requirements:** IREL-03

**Success Criteria** (what must be TRUE):

1. При resume установки (checkpoint существует, PG volume существует) `DB_PASSWORD` в `.env` совпадает с паролем из backup `.env` предыдущего запуска — новый пароль не генерируется
2. После resume `docker compose up` стартует без ошибок аутентификации PostgreSQL (`FATAL: password authentication failed` отсутствует в логах)
3. При отсутствии PG volume (чистая установка) поведение не изменилось — `DB_PASSWORD` генерируется как раньше

**Plans:** 1/1 plans complete

Plans:
- [ ] 14-01-PLAN.md — Preserve secrets from .env backup on resume + harden sync_db_password timeout/errors (IREL-03)

---

### Phase 15: Pull & Download UX

**Goal:** Оператор видит прогресс скачивания образов и моделей, а не чёрный экран. Отсутствующий образ даёт понятное сообщение с именем и тегом. Зависший pull моделей не обрывает установку.

**Depends on:** Phase 12
**Requirements:** DLUX-01, DLUX-02

**Success Criteria** (what must be TRUE):

1. После `docker compose pull`, если образ не найден в registry, оператор видит сообщение вида `ERROR: образ 'ghcr.io/agmind/dify-api:1.99.0' не найден — проверьте тег в versions.env` — установка не падает с необъяснимым exit code
2. При скачивании модели Ollama/vLLM в TTY отображается прогресс (слои, размер, процент) — оператор видит активность, а не пустой экран
3. При превышении таймаута фазы `phase_models` установка продолжается с предупреждением `WARNING: модель не скачана, продолжаем` и инструкцией `agmind model pull <model>` — fatal error не прерывает остальные фазы

**Plans:** 1/1 plans complete

Plans:
- [ ] 15-01-PLAN.md — Post-pull image validation + model TTY progress + graceful timeout (DLUX-01, DLUX-02)

---

## Phases

- [x] **Phase 1: Surgery** — Remove Dify API automation and enforce three-layer boundary
- [x] **Phase 2: Security Hardening v2** — Close security gaps, protect credentials
- [x] **Phase 3: Provider Architecture** — Wizard + Compose profiles per LLM/embedding provider
- [x] **Phase 4: Installer Redesign** — 9-phase install with resume, logging, timeouts
- [x] **Phase 5: DevOps & UX** — agmind CLI, status, doctor, health endpoint
- [x] **Phase 6: Runtime Stability** — Fix plugin-daemon ordering, Redis stale locks, GPU reboot survival (completed 2026-03-21)
- [x] **Phase 7: Update System** — Component-level update with healthcheck + rollback (completed 2026-03-21)
- [x] **Phase 8: Health Verification & UX Polish** — Real endpoint checks, doctor enhancement, LICENSE, SSH/Portainer guidance (completed 2026-03-21)
- [~] ~~**Phase 9: Operator Makefile**~~ — SKIPPED: agmind CLI covers all operations
- [x] **Phase 10: Release Foundation** — Locale bugfix, GitHub Release v2.1.0 с versions.env asset, COMPONENTS.md (completed 2026-03-22)
- [x] **Phase 11: Bundle Update Rewrite** — Переписать update.sh на bundle workflow через GitHub Releases API + emergency mode + rollback (completed 2026-03-22)
- [x] **Phase 12: Isolated Bugfixes** — Doctor SKIP без root, Redis ACL точечный blocklist, v-prefix strip, Dify init timeout 5 мин (completed 2026-03-22)
- [x] **Phase 13: VRAM Guard in Wizard** — Показ требований VRAM в wizard vLLM + предупреждение при выборе слишком большой модели (completed 2026-03-22)
- [x] **Phase 14: DB Password Resume Safety** — Preserve DB_PASSWORD при resume если PG volume существует (completed 2026-03-22)
- [x] **Phase 15: Pull & Download UX** — Pre-pull валидация образов + прогресс скачивания моделей + graceful timeout (completed 2026-03-22)

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Surgery | v2.0 | 2/2 | Complete | 2026-03-18 |
| 2. Security Hardening v2 | v2.0 | 4/4 | Complete | 2026-03-18 |
| 3. Provider Architecture | v2.0 | 3/3 | Complete | 2026-03-18 |
| 4. Installer Redesign | v2.0 | 2/2 | Complete | 2026-03-18 |
| 5. DevOps & UX | v2.0 | 2/2 | Complete | 2026-03-18 |
| 6. Runtime Stability | v2.1 | 3/3 | Complete | 2026-03-21 |
| 7. Update System | v2.1 | 2/2 | Complete | 2026-03-21 |
| 8. Health Verification & UX Polish | v2.1 | 3/3 | Complete | 2026-03-21 |
| 9. Operator Makefile | v2.1 | — | Skipped | — |
| 10. Release Foundation | v2.2 | 2/2 | Complete | 2026-03-22 |
| 11. Bundle Update Rewrite | v2.2 | 2/2 | Complete | 2026-03-22 |
| 12. Isolated Bugfixes | v2.3 | 2/2 | Complete | 2026-03-22 |
| 13. VRAM Guard in Wizard | v2.3 | 1/1 | Complete | 2026-03-22 |
| 14. DB Password Resume Safety | v2.3 | 1/1 | Complete | 2026-03-22 |
| 15. Pull & Download UX | 1/1 | Complete   | 2026-03-22 | — |

---
*Roadmap created: 2026-03-17*
*Last updated: 2026-03-23 — Phase 15 planned (1 plan, wave 1)*
