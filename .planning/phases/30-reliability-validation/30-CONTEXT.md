# Phase 30: Reliability & Validation - Context

**Gathered:** 2026-03-30
**Status:** Ready for planning

<domain>
## Phase Boundary

Полный цикл проверок надёжности установки: Dify init retry с увеличенным интервалом, --dry-run preflight checks с PASS/FAIL форматом, HTTP HEAD валидация образов перед pull, встроенная проверка состава offline bundle при сборке.

</domain>

<decisions>
## Implementation Decisions

### Dify init retry/flock
- Общий install lock (flock в install.sh) уже достаточен — отдельный flock для init не нужен
- Отдельный flock добавить только для CLI команды `agmind init-dify` (защита от параллельного вызова)
- Интервал между retry: 60 секунд фиксированный (сейчас 30с)
- Количество retry: 3 (без изменений)
- Логи retry пишутся в install.log с префиксом `[dify-init]` (не в отдельный файл)
- При провале всех 3 retry — установка продолжается с warn, credentials показывают «ручная настройка», пользователь может повторить через `agmind init-dify`

### --dry-run preflight checks
- Scope: только preflight_checks() — prereqs, порты, диск, DNS, Docker. Без wizard, без .env, без контейнеров
- Полный dry-run (симуляция всех фаз) отложен до v3.0 (UXPL-02)
- Формат вывода: PASS/FAIL список, каждая проверка на отдельной строке
- DNS проверка: добавить `nslookup`/`dig` для hub.docker.com и ghcr.io (сейчас проверяется только интернет через curl)
- Пропускать DNS проверку для offline профиля
- Exit code: 0 = all pass, 1 = any FAIL. Warnings не влияют на exit code
- Флаг: `install.sh --dry-run` (добавить в парсер аргументов)

### HTTP HEAD image validation
- Функция `validate_images_exist()` в lib/compose.sh (рядом с compose_pull)
- Вызывается перед `compose_pull()` в install.sh и перед pull в update.sh
- Scope: только активные профили — список из `docker compose config --images`
- При обнаружении not found (HTTP 404) — блокировать установку, показать какие образы не найдены
- При проблемах registry (405 Method Not Allowed, timeout, connection error) — skip + warn для этого образа, не блокировать
- Offline профиль (`DEPLOY_PROFILE=offline`) — пропускать валидацию
- `SKIP_IMAGE_VALIDATION=true` — отключить для CI
- Использовать HTTP HEAD (не GET) — не потребляет Docker Hub rate limit

### Offline bundle E2E
- Встроенная валидация при сборке: build-offline-bundle.sh в конце проверяет состав
- Проверка: список образов в tar.gz vs `docker compose config --images` для всех профилей
- Показать missing/extra образы
- Manifest с размерами каждого образа в выводе
- Без реального airgap симуляции — это скрипт проверки содержимого bundle
- INCLUDE_DOCLING_CUDA=true добавляет CUDA-образ в проверку

### Claude's Discretion
- Формат DNS проверки (nslookup vs dig vs getent hosts)
- Точный формат PASS/FAIL вывода
- Как парсить список образов из tar.gz (docker load --input vs tar -tzf)
- Registry token acquisition flow (anonymous token для Docker Hub v2 API)
- Формат manifest при bundle verification

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Dify init retry
- `install.sh` §_init_dify_admin (lines 241-333) — текущая логика retry, health wait, cookie handling
- `scripts/agmind.sh` §cmd_init_dify (lines 633-696) — CLI команда init-dify, нужен flock
- `install.sh` §_acquire_lock (lines 44-55) — существующий flock паттерн

### Preflight & dry-run
- `lib/detect.sh` §preflight_checks (lines 346-556) — все существующие проверки (порты, диск, RAM, Docker, интернет)
- `install.sh` §main (lines 576-584) — парсер аргументов, добавить --dry-run

### HTTP HEAD validation
- `lib/compose.sh` §compose_pull (lines 47-179) — текущий pull + _validate_pulled_images
- `scripts/update.sh` — вызов pull при обновлении, нужно добавить валидацию
- `templates/versions.env` — все образы с версиями (5+ registry: docker.io, ghcr.io, quay.io, gcr.io, prom/)

### Offline bundle
- `scripts/build-offline-bundle.sh` (1-303) — полный скрипт сборки bundle
- `templates/docker-compose.yml` — все сервисы и профили

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `preflight_checks()` в lib/detect.sh: уже проверяет порты (ss/lsof), диск (30GB), RAM (4GB), CPU (2 cores), Docker version, internet
- `_validate_pulled_images()` в lib/compose.sh: проверяет образы через `docker image inspect` после pull
- `_acquire_lock()` в install.sh: flock паттерн (Linux) + mkdir fallback (macOS)
- Retry паттерн: `for try in 1 2 3; do ... sleep N; done` используется в 5+ местах

### Established Patterns
- HTTP status extraction: `curl -sf --max-time 5 -o /dev/null -w '%{http_code}'` (lib/health.sh)
- Log prefixing: `log_info`, `log_warn`, `log_error` из lib/common.sh
- Profile-aware image list: `docker compose config --images` (lib/compose.sh:74)
- Offline skip: `[[ "$DEPLOY_PROFILE" == "offline" ]]` guards в compose.sh

### Integration Points
- install.sh: --dry-run флаг в парсер + early exit после preflight_checks()
- install.sh: _init_dify_admin() retry interval 30→60, log prefix [dify-init]
- lib/compose.sh: validate_images_exist() вызывается перед compose_pull()
- scripts/update.sh: validate_images_exist() вызывается перед pull при update
- scripts/build-offline-bundle.sh: bundle verification в конце сборки

</code_context>

<specifics>
## Specific Ideas

- DNS проверка должна пропускаться для offline профиля — нет смысла проверять DNS без интернета
- HTTP HEAD для Docker Hub v2 API требует anonymous token (GET /v2/token → HEAD /v2/library/nginx/manifests/tag)
- GHCR.io, quay.io, gcr.io могут иметь разные auth flow — fallback при 405/timeout

</specifics>

<deferred>
## Deferred Ideas

- Полный dry-run (симуляция всех 10 фаз) — v3.0 (UXPL-02)
- Реальный airgap тест с iptables блокировкой — слишком опасно для автоматизации
- Миграция DOCLING_SERVE_VERSION → DOCLING_IMAGE_CPU/CUDA в check-upstream.sh, generate-manifest.sh, update.sh — техдолг, отдельная задача

</deferred>

---

*Phase: 30-reliability-validation*
*Context gathered: 2026-03-30*
