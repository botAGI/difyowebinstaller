# Roadmap: AGmind Installer

## Milestones

- ✅ **v2.0 MVP** — Phases 1-5 (shipped 2026-03-18)
- ✅ **v2.1 Bugfixes + Improvements** — Phases 6-9 (shipped 2026-03-21)
- ✅ **v2.2 Release Bundle Update System** — Phases 10-11 (shipped 2026-03-22)
- ✅ **v2.3 Stability & Reliability Bugfixes** — Phases 12-15 (shipped 2026-03-22)
- ✅ **v2.4 Wizard Models + GPU Management** — Phases 16-18 (shipped 2026-03-23)
- ✅ **v2.5 Modular Model Selection + Xinference Removal** — Phases 19-24 (shipped 2026-03-23)
- ✅ **v2.6 Install Stability + Update Robustness** — Phases 25-27 (shipped 2026-03-25)
- ✅ **v2.7 Release Workflow + Platform Expansion** — Phases 28-30 (shipped 2026-03-30)
- [ ] **v2.8 New Services + Wizard Simplification** — Phases 31-36 (in progress)

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

<details>
<summary>✅ v2.3 Stability & Reliability Bugfixes (Phases 12-15) — SHIPPED 2026-03-22</summary>

**Milestone Goal:** Исправить критичные баги, обнаруженные при тестировании v2.2. Повысить надёжность установки на edge-кейсах (медленное железо, resume, low VRAM) и улучшить UX оператора (doctor, прогресс, ошибки).

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
- [x] 12-01-PLAN.md — Doctor .env SKIP guard without root + Redis ACL explicit blocklist (OPUX-01, OPUX-02)
- [x] 12-02-PLAN.md — check-upstream.sh v-prefix strip + Dify init timeout 5 min + fallback credentials (IREL-01, IREL-04)

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
- [x] 13-01-PLAN.md — VRAM-aware vLLM model selection with dynamic [recommended] tag and oversized warning (IREL-02)

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
- [x] 14-01-PLAN.md — Preserve secrets from .env backup on resume + harden sync_db_password timeout/errors (IREL-03)

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
- [x] 15-01-PLAN.md — Post-pull image validation + model TTY progress + graceful timeout (DLUX-01, DLUX-02)

</details>

---

<details>
<summary>✅ v2.4 Wizard Models + GPU Management (Phases 16-18) — SHIPPED 2026-03-23</summary>

**Milestone Goal:** Обновить список моделей vLLM в визарде (Qwen3, MoE), исправить критичные баги VRAM guard в NON_INTERACTIVE режиме и resume diagnostics, добавить GPU management команды в CLI с поддержкой env-переменных в docker-compose.

### Phase 16: Critical Bugfixes

**Goal:** Два критичных бага, обнаруженных после v2.3, устранены — VRAM guard работает в NON_INTERACTIVE режиме и не позволяет запустить модель больше GPU, resume установки всегда инициализирует DETECTED_OS/DETECTED_GPU_VRAM независимо от стартовой фазы.

**Depends on:** Phase 15
**Requirements:** BFIX-41, BFIX-42

**Success Criteria** (what must be TRUE):

1. При запуске `install.sh` с `NON_INTERACTIVE=1` и `VLLM_MODEL=Qwen2.5-72B-Instruct` на сервере с 24 GB VRAM — installer завершается с `exit 1` и сообщением о превышении VRAM вместо молчаливого продолжения
2. Дефолтная модель (`VLLM_MODEL=Qwen2.5-14B-Instruct`), назначаемая в NON_INTERACTIVE при отсутствии явного выбора, проходит VRAM проверку — если VRAM < требуемого, installer завершается с `exit 1` а не запускает заведомо неработающую конфигурацию
3. При resume установки с `--start-from 3` (или любой фазы >= 2) `DETECTED_OS` и `DETECTED_GPU_VRAM` инициализированы корректно — последующие фазы используют актуальные значения без ошибок типа "unbound variable"
4. При resume с `--start-from 2` и недоступным GPU `DETECTED_GPU_VRAM=0` устанавливается явно и не остаётся unset — wizard и VRAM guard работают без падения

**Plans:** 1/1 plans complete

Plans:
- [x] 16-01-PLAN.md — VRAM guard for NON_INTERACTIVE vllm path + always run_diagnostics on resume (BFIX-41, BFIX-42)

---

### Phase 17: Wizard Model List Update

**Goal:** Список моделей vLLM в wizard отражает актуальный ландшафт (Qwen3, MoE-архитектуры), VRAM requirements для AWQ-моделей скорректированы до реальных значений, MODEL_SIZES в lib/models.sh охватывает все новые модели.

**Depends on:** Phase 16
**Requirements:** WMOD-01, WMOD-02

**Success Criteria** (what must be TRUE):

1. В меню выбора модели vLLM wizard показывает все пять новых моделей: `Qwen3-8B`, `Qwen3-8B-AWQ`, `Qwen3-14B-AWQ`, `Qwen3-Coder-Next MoE AWQ`, `Nemotron Nano MoE AWQ` — каждая с корректным VRAM requirement рядом
2. Модель `Qwen3-14B-AWQ` отображает `[~10 GB VRAM]` (не 12 GB) — метка `[рекомендуется]` появляется на GPU с >= 10 GB VRAM
3. `lib/models.sh` содержит в `MODEL_SIZES` approximate disk size для каждой из новых моделей — `agmind model pull` использует эти значения для оценки места на диске
4. При выборе MoE-модели (Qwen3-Coder-Next MoE AWQ, Nemotron Nano MoE AWQ) в NON_INTERACTIVE режиме — VRAM guard проверяет vram_req этой модели перед продолжением

**Plans:** 1/1 plans complete

Plans:
- [x] 17-01-PLAN.md — Expand vLLM model list to 16 models (Qwen3 + MoE) + fix VRAM reqs + MODEL_SIZES (WMOD-01, WMOD-02)

---

### Phase 18: GPU Management CLI

**Goal:** Оператор управляет распределением GPU между контейнерами через CLI, не редактируя docker-compose вручную — `agmind gpu status` показывает текущее состояние, `agmind gpu assign` назначает GPU сервису через .env, docker-compose использует env-переменные вместо hardcoded "0".

**Depends on:** Phase 16
**Requirements:** GPUM-01, GPUM-02, GPUM-03

**Success Criteria** (what must be TRUE):

1. `agmind gpu status` выводит таблицу: для каждого GPU — имя, общий VRAM, свободный VRAM, utilization %, и какой контейнер (vLLM / TEI) привязан к нему
2. `agmind gpu assign vllm 1` записывает `VLLM_CUDA_DEVICE=1` в `.env` и перезапускает vLLM контейнер — после рестарта `agmind gpu status` показывает контейнер привязанным к GPU 1
3. `agmind gpu assign --auto` на сервере с 2+ GPU автоматически распределяет vLLM и TEI по разным GPU с наибольшим свободным VRAM — оператор не указывает номера вручную
4. `docker-compose.yml` использует `${VLLM_CUDA_DEVICE:-0}` и `${TEI_CUDA_DEVICE:-0}` вместо hardcoded `"0"` — изменение `.env` без пересборки compose-файла меняет привязку GPU при следующем `docker compose up`
5. На сервере с одним GPU `agmind gpu assign --auto` записывает `VLLM_CUDA_DEVICE=0` и `TEI_CUDA_DEVICE=0` без ошибки — оба контейнера разделяют единственный GPU

**Plans:** 1/1 plans complete

Plans:
- [x] 18-01-PLAN.md — docker-compose env var substitution + cmd_gpu with status/assign/auto-assign (GPUM-01, GPUM-02, GPUM-03)

</details>

---

<details>
<summary>✅ v2.5 Modular Model Selection + Xinference Removal (Phases 19-24) — SHIPPED 2026-03-23</summary>

**Milestone Goal:** Переработка визарда: модульный выбор LLM, Embeddings, Reranker с VRAM-aware рекомендациями. Убрать Xinference из стека — реранк через TEI. VRAM план в сводке установки. Новые compose profiles: tei, reranker, docling.

### Phase 19: Bugfixes + GPU Enhancement

**Goal:** Мелкие независимые исправления устранены до начала крупных изменений — preflight_checks не выдаёт ложных WARN на собственных контейнерах, VRAM guard в NON_INTERACTIVE использует effective_vram с учётом TEI offset, xinference bce-reranker помечен как broken, `agmind gpu status` показывает имена контейнеров вместо сырых PID.

**Depends on:** Phase 18
**Requirements:** BFIX-43, BFIX-44, BFIX-45, GPUX-01

**Success Criteria** (what must be TRUE):

1. `preflight_checks()` при повторной установке на сервере с работающим agmind стеком не выдаёт WARN для портов 80/443, занятых собственными контейнерами nginx/docker — предупреждение показывается только для чужих процессов
2. В NON_INTERACTIVE режиме с `LLM_PROVIDER=vllm` VRAM guard вычисляет `effective_vram = gpu_vram - 2` (TEI offset) и сравнивает модель с effective_vram — модель, которая влезает в raw VRAM, но не влезает с учётом TEI, отклоняется с exit 1
3. Xinference bce-reranker-base_v1 помечен как broken в коде/документации или заменён на bge-reranker-v2-m3, если xinference остаётся как fallback profile
4. `agmind gpu status` в колонке процессов показывает имя контейнера (например, `agmind-vllm-1`) и загруженную модель вместо сырого PID числа

**Plans:** 2/2 plans complete

Plans:
- [x] 19-01-PLAN.md — Preflight port filter (BFIX-43) + GPU status container names (GPUX-01)
- [x] 19-02-PLAN.md — VRAM guard TEI offset (BFIX-45) + Xinference reranker broken (BFIX-44)

---

### Phase 20: Xinference Removal

**Goal:** Xinference убран из обязательного стека — Docling независим от Xinference, флаг ETL_ENHANCED заменён на ENABLE_DOCLING. ENABLE_RERANKER добавляется в Phase 22 вместе с TEI reranker.

**Depends on:** Phase 19
**Requirements:** XINF-01, XINF-02, XINF-03

**Success Criteria** (what must be TRUE):

1. После установки с профилем по умолчанию `docker ps` не показывает контейнер xinference — сервис либо удалён из docker-compose, либо перенесён в disabled/legacy profile, который не активируется автоматически
2. Переменная `ETL_ENHANCED` больше не используется ни в wizard, ни в docker-compose, ни в .env — вместо неё `ENABLE_DOCLING=true/false` управляет Docling сервисом (ENABLE_RERANKER добавляется в Phase 22)
3. Docling контейнер работает в profile `docling` независимо от xinference — `ENABLE_DOCLING=true` поднимает только docling без xinference
4. `load_reranker()` в lib/models.sh не вызывает Xinference HTTP API — функция либо удалена, либо переписана на TEI-rerank endpoint

**Plans:** 2/2 plans complete

Plans:
- [x] 20-01-PLAN.md — Core: remove Xinference from docker-compose + migrate ETL_ENHANCED to ENABLE_DOCLING in lib/ scripts + env templates
- [x] 20-02-PLAN.md — Peripheral: remove Xinference from scripts, configs, docs + add orphan cleanup to update.sh

---

### Phase 21: Embeddings Wizard + Docker

**Goal:** Пользователь выбирает embedding модель в отдельном шаге визарда, выбор записывается в .env и используется docker-compose для TEI-embed контейнера.

**Depends on:** Phase 20
**Requirements:** EMBD-01, EMBD-02

**Success Criteria** (what must be TRUE):

1. В wizard появился шаг `Embeddings` с меню выбора: BAAI/bge-m3, Qwen3-Embedding-0.6B, multilingual-e5-large-instruct, ввод вручную — каждый вариант показывает краткое описание
2. После прохождения визарда `.env` содержит `EMBEDDING_MODEL=<выбранная_модель>` и `EMBED_PROVIDER=tei` — значения подхватываются docker-compose без ручного редактирования
3. При NON_INTERACTIVE режиме с `EMBEDDING_MODEL` из env визард использует переданное значение, при отсутствии — применяет дефолт (bge-m3)

**Plans:** 1/1 plans complete

Plans:
- [x] 21-01-PLAN.md — Rewrite embedding wizard step with TEI model menu + parameterize docker-compose TEI service

---

### Phase 22: Reranker Wizard + Docker + VRAM

**Goal:** Пользователь опционально включает reranker в визарде, выбирает модель, TEI-rerank контейнер поднимается в отдельном profile, VRAM реранкера учитывается в бюджете.

**Depends on:** Phase 20
**Requirements:** RNKR-01, RNKR-02, RNKR-03

**Success Criteria** (what must be TRUE):

1. В wizard появился шаг `Reranker` с вариантами: нет (по умолчанию) / bge-reranker-large / bge-reranker-base / gte-reranker / ввод вручную — при выборе "нет" никакой reranker контейнер не поднимается
2. При `ENABLE_RERANKER=true` docker-compose поднимает отдельный TEI-rerank контейнер в profile `reranker` с `RERANK_MODEL` из .env — контейнер отвечает на health-check
3. VRAM реранкера (~0.5-1 GB в зависимости от модели) учитывается при расчёте VRAM бюджета — сводка установки и VRAM guard знают о реранкере
4. При `ENABLE_RERANKER=false` profile `reranker` не активируется, TEI-rerank контейнер не запускается, VRAM реранкера не вычитается из бюджета

**Plans:** 2/2 plans complete

Plans:
- [x] 22-01-PLAN.md — Wizard reranker function + VRAM guard integration (RNKR-01, RNKR-03)
- [x] 22-02-PLAN.md — Docker-compose tei-rerank service + compose profile + config + env templates (RNKR-02)

---

### Phase 23: LLM Model List + Effective VRAM

**Goal:** Список моделей vLLM обновлён до 17 моделей с корректными AWQ/bf16/MoE секциями, VRAM рекомендации учитывают TEI offset для более точных рекомендаций.

**Depends on:** Phase 19 (BFIX-45 — effective_vram fix)
**Requirements:** LLMM-01, LLMM-02

**Success Criteria** (what must be TRUE):

1. В меню выбора модели vLLM wizard показывает 17 моделей, разбитых на секции AWQ / bf16 / MoE — каждая с корректным VRAM requirement и меткой `[рекомендуется]` при наличии достаточного effective_vram
2. VRAM requirement учитывает TEI offset (~2 GB): на GPU с 24 GB VRAM wizard рекомендует модели до ~22 GB, а не до 24 GB — модель с vram_req=24 получает предупреждение о нехватке
3. TEI offset в рекомендациях конфигурируем (не hardcoded) — берётся из переменной или функции, чтобы учитывать разные конфигурации embedding/reranker

**Plans:** 1/1 plans complete

Plans:
- [x] 23-01-PLAN.md — Dynamic _get_vram_offset() + model VRAM audit

---

### Phase 24: Wizard Restructure + VRAM Summary + Profiles

**Goal:** Визард перестроен в новый порядок шагов (LLM -> Embeddings -> Reranker -> VectorDB -> ...), в конце показывается VRAM план с бюджетом, COMPOSE_PROFILES формируется с новыми профилями tei/reranker/docling.

**Depends on:** Phase 21, Phase 22, Phase 23
**Requirements:** WIZS-01, WIZS-02, PROF-01

**Success Criteria** (what must be TRUE):

1. Визард проходит шаги в порядке: Профиль -> LLM -> Модель LLM -> Embeddings -> Reranker -> VectorDB -> Docling -> Мониторинг -> TLS -> Алерты -> UFW -> Tunnel -> Бэкапы -> Сводка — порядок соответствует WIZS-01
2. В сводке установки (последний экран визарда) показан VRAM план: vLLM X GB + TEI-embed Y GB + TEI-rerank Z GB = Total vs Available GPU VRAM — если Total > Available, выводится жёлтое предупреждение
3. `COMPOSE_PROFILES` в .env после визарда содержит профили `tei`, `reranker`, `docling` в зависимости от выбора пользователя — каждый профиль включается/выключается отдельным флагом (`EMBED_PROVIDER=tei`, `ENABLE_RERANKER=true`, `ENABLE_DOCLING=true`)
4. При NON_INTERACTIVE режиме COMPOSE_PROFILES формируется корректно из env-переменных без участия визарда — все новые профили учитываются

**Plans**: 1 plan

Plans:
- [x] 24-01-PLAN.md — Reorder wizard steps + VRAM summary + verify compose profiles

</details>

---

## v2.6 Install Stability + Update Robustness (In Progress)

**Milestone Goal:** Закрыть баги установки (certbot race, squid LAN, health таймауты) и hardening операций дня-2 (PG upgrade safety, rollback verify, release notes). UX polish: прогресс скачивания моделей, Telegram HTML escape.

## Phase Details

### Phase 25: Install Stability

**Goal:** Установка завершается надёжно в сложных условиях — health wait не застревает на GPU-контейнерах, TLS через letsencrypt не ломается из-за race condition, Squid в LAN не блокирует внутренние webhook-вызовы, Telegram-алерты не ломаются на спецсимволах, credentials.txt честно предупреждает об ограничениях.

**Depends on:** Phase 24
**Requirements:** ISTB-01, ISTB-02, ISTB-03, ISTB-04, ISTB-05

**Success Criteria** (what must be TRUE):

1. При запуске `install.sh` с vLLM на медленном GPU health wait показывает реальный прогресс ("Downloading 45%", "Loading model") вместо счётчика секунд — таймаут срабатывает только при 60+ секундах без новых строк в логах, а не по абсолютному времени
2. При `TLS_MODE=letsencrypt` nginx стартует сразу с self-signed placeholder cert (без ожидания certbot), certbot получает настоящий сертификат и nginx перезагружается без ошибок — `curl -k https://HOST/` возвращает 200 сразу после установки
3. В LAN профиле Dify sandbox может вызывать webhook на RFC1918 адрес (например, `http://192.168.1.10:8080/webhook`) через Squid — запрос проходит без ошибки `403 Forbidden`
4. Telegram-уведомление с текстом, содержащим `<`, `>`, `&`, доставляется без ошибки Telegram Bot API (error 400) — спецсимволы экранированы перед отправкой
5. `credentials.txt` после установки содержит предупреждение вида "Эти пароли актуальны на момент установки. При смене пароля через UI обновите credentials.txt вручную." — пользователь знает о возможном расхождении

**Plans:** 2/2 plans complete

Plans:
- [ ] 25-01-PLAN.md — GPU health wait log progress + Telegram HTML escape (ISTB-01, ISTB-04)
- [ ] 25-02-PLAN.md — Certbot placeholder cert + Squid LAN RFC1918 + credentials disclaimer (ISTB-02, ISTB-03, ISTB-05)

---

### Phase 26: Update Robustness

**Goal:** Операции обновления и отката надёжно защищены от критичных сценариев — PostgreSQL major upgrade предотвращён с явным предупреждением, release notes доступны без перехода в браузер, post-rollback health подтверждён автоматически, CI синхронизирует manifest без ручной работы.

**Depends on:** Phase 25
**Requirements:** UPDT-01, UPDT-02, UPDT-03, UPDT-04

**Success Criteria** (what must be TRUE):

1. При попытке `agmind update` с новым release, в котором PostgreSQL major версия изменилась (16→17), обновление останавливается с сообщением вида "WARNING: PostgreSQL major upgrade detected (16→17). Run pg_dump first. See docs/pg-upgrade.md." — контейнеры не пересоздаются
2. `agmind update --check` выводит полные release notes (до 10 строк) прямо в терминале, а также ссылку на GitHub release для просмотра полного changelog — оператор принимает решение об обновлении без открытия браузера
3. После успешного `agmind update --rollback` автоматически запускается `agmind doctor --json` и его результат сохраняется в install.log — если doctor находит проблемы, оператор видит предупреждение с деталями
4. При создании нового GitHub Release CI action автоматически обновляет `release-manifest.json` в репозитории с новым тегом и датой — мейнтейнеру не нужно редактировать файл вручную

**Plans:** 2/2 plans complete

Plans:
- [ ] 26-01-PLAN.md — PG major upgrade guard + full release notes + post-rollback doctor (UPDT-01, UPDT-02, UPDT-03)
- [ ] 26-02-PLAN.md — CI auto-sync release-manifest.json on GitHub Release (UPDT-04)

---

### Phase 27: UX Polish

**Goal:** Оператор видит наглядный прогресс при скачивании моделей и может безопасно проверить конфигурацию установки без запуска контейнеров.

**Depends on:** Phase 25
**Requirements:** UXPL-01

**Success Criteria** (what must be TRUE):

1. При скачивании модели в TTY отображается стриминговый вывод `docker logs -f` (vLLM/TEI) или нативный прогресс Ollama — оператор видит прогресс загрузки в реальном времени, а не пустой экран; в non-TTY — только статусные сообщения
2. При таймауте контейнер остаётся работать, выводится WARNING с docker-командами для мониторинга (`docker logs -f agmind-vllm`) и ручного pull (`docker exec agmind-ollama ollama pull <model>`), инсталлятор продолжает со следующими фазами

**Plans:** 1/1 plans complete

Plans:
- [ ] 27-01-PLAN.md — Streaming model download progress (vLLM/TEI docker logs) + provider-specific timeout recovery (UXPL-01)

---


---

## v2.7 Release Workflow + Platform Expansion (In Progress)

**Milestone Goal:** Release branch workflow для стабильных обновлений (`agmind update` тянет из `release`, новые установки клонируют `release`), Docling CUDA/OCR расширения, мелкие фиксы надёжности (Dify init retry, credentials.txt endpoints, FILES_URL), pre-pull валидация образов, --dry-run preflight checks и финальный e2e тест offline bundle.

## Phase Details

### Phase 28: Release Branch Workflow

**Goal:** Installer и `agmind update` работают через ветку `release` — пользователи получают стабильные версии; быстрые UX-фиксы поставляются вместе с этой инфраструктурой.

**Depends on:** Phase 27
**Requirements:** RELU-01, RELU-02, RELU-03, RELU-05, RELU-06, RELU-07, RELU-08

**Success Criteria** (what must be TRUE):

1. Свежая установка клонирует ветку `release`, а не `main` — `git branch` в INSTALL_DIR показывает `release`; README содержит актуальную инструкцию по установке
2. `agmind update` забирает `versions.env` и скрипты из ветки `release` через git pull; installer-generated файлы (`.env`, `credentials.txt`, checkpoints) не перезаписаны и не вызывают `git pull` конфликтов
3. `agmind update --main` переключает на ветку `main`; команда не отображается в `agmind update --help` (dev only)
4. `agmind update --check` выводит полный текст release notes и ссылку на GitHub release — оператор принимает решение без открытия браузера
5. Telegram-уведомление с текстом `container & status > OK` доставляется без ошибки Telegram Bot API 400 — спецсимволы `<`, `>`, `&` экранированы
6. Model API endpoints (Ollama URL, vLLM URL, TEI URL) записаны в `credentials.txt` после установки
7. `FILES_URL` в `.env` содержит домен/IP, указанный в wizard — Dify использует правильный URL без ручной правки

**Plans:** 3/3 plans complete

Plans:
- [ ] 28-01-PLAN.md — Telegram HTML escape, Model API endpoints в credentials.txt, FILES_URL auto-populate
- [ ] 28-02-PLAN.md — Git-based release branch workflow (.gitignore, update.sh, agmind.sh, README)
- [ ] 28-03-PLAN.md — Full release notes в agmind update --check

---

### Phase 29: Docling GPU/OCR

**Goal:** Wizard предлагает ручной выбор Docling образа (Нет/CPU/GPU CUDA), GPU-пункт скрыт без nvidia runtime, model cache переживает recreate через existing volume, русский OCR (rus,eng) включён по умолчанию, offline bundle поддерживает CUDA-образ по флагу.

**Depends on:** Phase 28
**Requirements:** DOCL-01, DOCL-02, DOCL-03, DOCL-04

**Success Criteria** (what must be TRUE):

1. На хосте с NVIDIA GPU (nvidia container toolkit подтверждён через `docker info`) wizard предлагает GPU-образ (`quay.io/docling-project/docling-serve-cu128`); без GPU — CPU образ (`ghcr.io`); выбор отражён в `DOCLING_IMAGE` в `.env`
2. После `docker compose up --force-recreate docling` volume `agmind_docling_cache` сохраняется — модели не скачиваются повторно
3. Контейнер Docling стартует с `OCR_LANG=rus,eng` — русскоязычный PDF распознаётся без дополнительной настройки
4. Offline bundle включает CPU-образ по умолчанию; `INCLUDE_DOCLING_CUDA=true` добавляет CUDA-образ (+5-8 GB)

**Plans:** 2/2 plans complete

Plans:
- [ ] 29-01-PLAN.md — Wizard тройной выбор Docling + env pipeline (versions.env, templates, config.sh)
- [ ] 29-02-PLAN.md — Docker-compose dynamic image + offline bundle CUDA flag

---

### Phase 30: Reliability & Validation

**Goal:** Dify init retry с flock, `--dry-run` preflight checks, HTTP HEAD валидация образов перед pull, offline bundle E2E тест — полный цикл проверок надёжности установки.

**Depends on:** Phase 28, Phase 29
**Requirements:** RLBL-01, RLBL-02, RLBL-03, RELU-04

**Success Criteria** (what must be TRUE):

1. При медленном старте Dify init повторяется автоматически до 3 раз с интервалом >= 60 секунд; лог повторов пишется в install.log с префиксом `[dify-init]`; flock предотвращает параллельный запуск
2. `install.sh --dry-run` проверяет зависимости (docker, docker compose, curl), порты (80, 443, 5432), диск (>= 20 GB) и DNS — выводит итог PASS/FAIL по каждому пункту без запуска контейнеров
3. При `--dry-run` с заблокированным портом 443 вывод содержит строку вида `FAIL: port 443 is in use` — оператор устраняет конфликт до установки
4. Перед `compose_pull()` функция `validate_images_exist()` в `lib/compose.sh` выполняет HTTP HEAD к registry API для каждого образа из активных профилей — несуществующий тег выводит `WARNING: image not found: name:tag` и установка останавливается до pull
5. В offline профиле (`DEPLOY_PROFILE=offline`) валидация пропускается; `SKIP_IMAGE_VALIDATION=true` отключает проверку для CI
6. Проверка использует HTTP HEAD (не `docker manifest inspect`) — не потребляет Docker Hub rate-limit quota и не требует push scope
7. `build-offline-bundle.sh` включает все v2.7 образы; запуск без `INCLUDE_DOCLING_CUDA` собирает CPU-only bundle; с флагом — CUDA вариант
8. При сборке `build-offline-bundle.sh` верифицирует состав bundle: список образов в tar.gz совпадает с `docker compose config --images` для всех профилей; missing образы = exit 1
9. Manifest с размерами каждого образа выводится при сборке bundle; extra образы (в bundle, но не в compose) показываются как warning

**Plans:** 3/3 plans complete

Plans:
- [ ] 30-01-PLAN.md — Dify init retry 60s + flock + --dry-run preflight с DNS
- [ ] 30-02-PLAN.md — HTTP HEAD валидация образов (validate_images_exist)
- [ ] 30-03-PLAN.md — Offline bundle verification + manifest

---

</details>

<details>
<summary>v2.8 New Services + Wizard Simplification (Phases 31-36) — IN PROGRESS</summary>

### Phase 31: Wizard Simplify + Caddy Branch

**Goal:** Wizard сокращён до LAN/VDS. Offline профиль и build-offline-bundle.sh удалены. Ветка agmind-caddy создана. health.sh/detect.sh затрекены в git.

**Depends on:** Phase 30
**Requirements:** WZRD-01, WZRD-02, WZRD-03, WZRD-04, WZRD-05

**Success Criteria** (what must be TRUE):

1. Wizard deploy profile показывает 2 пункта: `1) LAN` и `2) VDS/VPS`; выбор VDS/VPS выполняет `git fetch origin agmind-caddy && git checkout agmind-caddy && exec bash install.sh --vds`
2. Все упоминания `offline` профиля удалены из wizard.sh, install.sh, lib/compose.sh, lib/detect.sh, lib/config.sh; `DEPLOY_PROFILE=offline` нигде не обрабатывается
3. `scripts/build-offline-bundle.sh` удалён из репозитория
4. Ветка `agmind-caddy` существует в origin, создана от main
5. `lib/health.sh` и `lib/detect.sh` отслеживаются git (`git ls-files lib/health.sh lib/detect.sh` возвращает оба файла)
6. `git reset --hard origin/main` не удаляет health.sh и detect.sh

**Plans:** 2/2 plans complete

Plans:
- [ ] 31-01-PLAN.md — Wizard simplify to LAN/VDS-VPS + offline removal from all scripts
- [ ] 31-02-PLAN.md — Create agmind-caddy branch + add --vds flag + final verification

---

### Phase 32: LiteLLM — AI Gateway

**Goal:** LiteLLM как core-сервис: единый OpenAI-совместимый прокси ко всем LLM, fallback, cost tracking. Wizard генерирует litellm-config.yaml.

**Depends on:** Phase 31
**Requirements:** CSVC-01, CSVC-02

**Success Criteria** (what must be TRUE):

1. Контейнер `agmind-litellm` запускается на порту 4000, использует существующий PostgreSQL для хранения ключей и cost tracking
2. `litellm-config.yaml` генерируется в `phase_config()` на основе выбранных LLM провайдеров (Ollama/vLLM/external API); включает fallback chain
3. Dify и Open WebUI получают `LLM_BASE_URL=http://agmind-litellm:4000/v1` в `.env` — все LLM-запросы идут через LiteLLM
4. `agmind doctor` проверяет health endpoint LiteLLM; `credentials.txt` содержит LiteLLM URL и master key
5. После установки `curl http://localhost:4000/health` возвращает HTTP 200

**Plans:** 2/2 plans complete

Plans:
- [ ] 32-01-PLAN.md — LiteLLM docker-compose, versions.env, litellm-config.yaml generation, env templates, init SQL
- [ ] 32-02-PLAN.md — Nginx proxy, credentials.txt, agmind doctor, wait_healthy integration

---

### Phase 33: SearXNG — Private Search

**Goal:** SearXNG как core-сервис: приватный метапоисковик с JSON API для AI-агентов.

**Depends on:** Phase 31
**Requirements:** CSVC-03, CSVC-04

**Success Criteria** (what must be TRUE):

1. Контейнер `agmind-searxng` запускается на порту 8888; JSON API включён (`formats: [html, json]` в settings.yml)
2. Минимальный конфиг содержит движки: Google, Bing, DuckDuckGo, Wikipedia
3. `curl http://localhost:8888/search?q=test&format=json` возвращает JSON с результатами
4. `agmind doctor` проверяет SearXNG health; `credentials.txt` содержит SearXNG URL
5. Потребление RAM контейнера не превышает 512 MB в idle

**Plans:** TBD

---

### Phase 34: Open Notebook

**Goal:** Open Notebook как опциональный сервис (wizard y/N): аналог Google NotebookLM — загрузка документов, диалог с цитатами.

**Depends on:** Phase 32 (LiteLLM)
**Requirements:** OSVC-01

**Success Criteria** (what must be TRUE):

1. Wizard спрашивает `Установить Open Notebook? (аналог Google NotebookLM) [y/N]`; при `y` добавляет `notebook` в COMPOSE_PROFILES
2. Контейнер `agmind-notebook` использует PostgreSQL и LiteLLM (не прямой Ollama)
3. Отдельный порт в credentials.txt; `agmind doctor` проверяет health если профиль включён
4. При `N` — никаких следов сервиса в docker compose ps

**Plans:** TBD

---

### Phase 35: DB-GPT — AI Database Analytics

**Goal:** DB-GPT как опциональный сервис (wizard y/N): Text-to-SQL, AI-аналитика по базам данных за любой период.

**Depends on:** Phase 32 (LiteLLM)
**Requirements:** OSVC-02

**Success Criteria** (what must be TRUE):

1. Wizard спрашивает `Установить DB-GPT? (AI-аналитика по базам данных) [y/N]`; при `y` добавляет `dbgpt` в COMPOSE_PROFILES
2. Контейнер `agmind-dbgpt` использует LiteLLM для LLM-запросов; подключение к клиентским БД настраивается после установки
3. Отдельный порт в credentials.txt; `agmind doctor` проверяет health если профиль включён
4. При `N` — никаких следов сервиса в docker compose ps

**Plans:** TBD

---

### Phase 36: Crawl4AI — Web Crawler for RAG

**Goal:** Crawl4AI как опциональный сервис (wizard y/N): веб-краулер, Markdown output, REST API для наполнения RAG.

**Depends on:** Phase 31
**Requirements:** OSVC-03

**Success Criteria** (what must be TRUE):

1. Wizard спрашивает `Установить Crawl4AI? (веб-краулер для наполнения RAG) [y/N]`; при `y` добавляет `crawl4ai` в COMPOSE_PROFILES
2. Контейнер `agmind-crawl4ai` с REST API; deep crawl, anti-bot detection, proxy support
3. `agmind doctor` проверяет health если профиль включён; credentials.txt содержит Crawl4AI URL
4. При `N` — никаких следов сервиса в docker compose ps; ~2 GB RAM при включении (Chromium)

**Plans:** TBD

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
- [x] **Phase 16: Critical Bugfixes** — VRAM guard в NON_INTERACTIVE + run_diagnostics при resume с любой фазы (completed 2026-03-22)
- [x] **Phase 17: Wizard Model List Update** — Новые модели Qwen3/MoE в wizard + скорректированные VRAM req + MODEL_SIZES (completed 2026-03-23)
- [x] **Phase 18: GPU Management CLI** — agmind gpu status/assign + docker-compose env-переменные для CUDA_VISIBLE_DEVICES (completed 2026-03-23)
- [x] **Phase 19: Bugfixes + GPU Enhancement** — preflight port filter, effective_vram fix, xinference reranker broken flag, gpu status container names (v2.5) (completed 2026-03-23)
- [x] **Phase 20: Xinference Removal** — Убрать xinference из обязательного стека, ETL_ENHANCED -> ENABLE_DOCLING, docling profile (v2.5) (completed 2026-03-23)
- [x] **Phase 21: Embeddings Wizard + Docker** — Шаг визарда для выбора embedding модели + .env + docker-compose интеграция (v2.5) (completed 2026-03-23)
- [x] **Phase 22: Reranker Wizard + Docker + VRAM** — Шаг визарда для reranker + TEI-rerank контейнер в profile reranker + VRAM учёт (v2.5) (completed 2026-03-23)
- [x] **Phase 23: LLM Model List + Effective VRAM** — 17 моделей AWQ/bf16/MoE + TEI offset в рекомендациях (v2.5) (completed 2026-03-23)
- [x] **Phase 24: Wizard Restructure + VRAM Summary + Profiles** — Новый порядок шагов визарда + VRAM сводка + COMPOSE_PROFILES с tei/reranker/docling (v2.5) (completed 2026-03-23)
- [x] **Phase 25: Install Stability** — Health wait по прогрессу логов, certbot placeholder, Squid RFC1918, Telegram HTML escape, credentials disclaimer (v2.6)
 (completed 2026-03-24)
- [x] **Phase 26: Update Robustness** — PG major upgrade warning, full release notes в --check, post-rollback doctor, CI manifest auto-sync (v2.6) (completed 2026-03-24)
- [x] **Phase 27: UX Polish** — Streaming model download progress (all providers), graceful timeout with recovery instructions (v2.6) (completed 2026-03-24)
- [x] **Phase 28: Release Branch Workflow** — Installer/agmind update via release branch, full release notes, Telegram escape, credentials.txt endpoints, FILES_URL auto-populate (v2.7) (completed 2026-03-29)
- [x] **Phase 29: Docling GPU/OCR** — CUDA image auto-selection, persistent model volumes, Russian OCR default, model preload at install (v2.7) (completed 2026-03-29)
- [x] **Phase 30: Reliability & Validation** — Dify init retry, --dry-run preflight, HTTP HEAD image validation, offline bundle E2E test (v2.7) (completed 2026-03-30)
- [x] **Phase 31: Wizard Simplify + Caddy Branch** — LAN/VDS wizard, удаление Offline, ветка agmind-caddy, track health.sh/detect.sh (v2.8) (completed 2026-03-30)
- [x] **Phase 32: LiteLLM** — AI Gateway, litellm-config.yaml из wizard, fallback chain, cost tracking (v2.8) (completed 2026-03-30)
- [ ] **Phase 33: SearXNG** — Приватный поиск, JSON API, 243 движка (v2.8)
- [ ] **Phase 34: Open Notebook** — Опциональный, wizard y/N, аналог Google NotebookLM (v2.8)
- [ ] **Phase 35: DB-GPT** — Опциональный, wizard y/N, Text-to-SQL AI-аналитика (v2.8)
- [ ] **Phase 36: Crawl4AI** — Опциональный, wizard y/N, веб-краулер для RAG (v2.8)

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
| 15. Pull & Download UX | v2.3 | 1/1 | Complete | 2026-03-22 |
| 16. Critical Bugfixes | v2.4 | 1/1 | Complete | 2026-03-22 |
| 17. Wizard Model List Update | v2.4 | 1/1 | Complete | 2026-03-23 |
| 18. GPU Management CLI | v2.4 | 1/1 | Complete | 2026-03-23 |
| 19. Bugfixes + GPU Enhancement | v2.5 | 2/2 | Complete | 2026-03-23 |
| 20. Xinference Removal | v2.5 | 2/2 | Complete | 2026-03-23 |
| 21. Embeddings Wizard + Docker | v2.5 | 1/1 | Complete | 2026-03-23 |
| 22. Reranker Wizard + Docker + VRAM | v2.5 | 2/2 | Complete | 2026-03-23 |
| 23. LLM Model List + Effective VRAM | v2.5 | 1/1 | Complete | 2026-03-23 |
| 24. Wizard Restructure + VRAM Summary + Profiles | v2.5 | 1/1 | Complete | 2026-03-23 |
| 25. Install Stability | 2/2 | Complete    | 2026-03-24 | — |
| 26. Update Robustness | 2/2 | Complete    | 2026-03-24 | — |
| 27. UX Polish | 1/1 | Complete    | 2026-03-24 | — |
| 28. Release Branch Workflow | 3/3 | Complete    | 2026-03-29 | — |
| 29. Docling GPU/OCR | 2/2 | Complete    | 2026-03-29 | — |
| 30. Reliability & Validation | v2.7 | 3/3 | Complete | 2026-03-30 |
| 31. Wizard Simplify + Caddy Branch | 2/2 | Complete    | 2026-03-30 | — |
| 32. LiteLLM | 2/2 | Complete   | 2026-03-30 | — |
| 33. SearXNG | v2.8 | 0/TBD | Not started | — |
| 34. Open Notebook | v2.8 | 0/TBD | Not started | — |
| 35. DB-GPT | v2.8 | 0/TBD | Not started | — |
| 36. Crawl4AI | v2.8 | 0/TBD | Not started | — |

---
*Roadmap created: 2026-03-17*
*Last updated: 2026-03-30 — Phase 32 LiteLLM planned: 2 plans, 2 waves*
