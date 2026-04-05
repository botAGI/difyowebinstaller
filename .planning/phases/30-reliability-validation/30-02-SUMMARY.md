---
phase: 30-reliability-validation
plan: 02
subsystem: infra
tags: [docker, registry, http-head, image-validation, curl, compose]

# Dependency graph
requires:
  - phase: 30-reliability-validation-01
    provides: preflight DNS checks for registry connectivity
provides:
  - validate_images_exist() in lib/compose.sh — HTTP HEAD pre-pull image validation
  - _parse_image_ref(), _get_registry_token(), _check_image_exists() helpers
  - Integration in compose_pull() — blocks install on 404
  - Integration in update.sh — warn-only validation before bundle update
affects:
  - compose_pull (lib/compose.sh)
  - perform_bundle_update (scripts/update.sh)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - HTTP HEAD to registry manifest endpoint to check image existence without consuming rate limit
    - Anonymous bearer token for Docker Hub and GHCR via token endpoint
    - rc 0/1/2 convention: 0=exists, 1=not found, 2=registry error/skip

key-files:
  created: []
  modified:
    - lib/compose.sh
    - scripts/update.sh

key-decisions:
  - "HTTP HEAD (not docker manifest inspect, not GET) — avoids push scope bug docker/cli#4345 and rate-limit"
  - "validate_images_exist() blocks compose_pull() on 404; warn-only in update.sh (user may have custom images)"
  - "DEPLOY_PROFILE=offline and SKIP_IMAGE_VALIDATION=true bypass validation — offline and override paths preserved"
  - "update.sh sources lib/compose.sh via _UPDATE_SCRIPT_DIR to get validate_images_exist() without code duplication"

patterns-established:
  - "_parse_image_ref() nameref pattern for multi-output parsing without subshells"
  - "registry error (non-200/non-404) = skip with warn, not block — registry availability is not a hard requirement"

requirements-completed: [RELU-04]

# Metrics
duration: 20min
completed: 2026-03-30
---

# Phase 30 Plan 02: Pre-pull Image Validation Summary

**HTTP HEAD валидация образов через registry API — блокирует install при 404, пропускает при ошибках registry, интегрирована в compose_pull() и update.sh без потребления Docker Hub rate limit**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-03-30T00:14:00Z
- **Completed:** 2026-03-30T00:34:36Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Три helper-функции (`_parse_image_ref`, `_get_registry_token`, `_check_image_exists`) поддерживают docker.io, ghcr.io, quay.io и другие registries
- `validate_images_exist()` проверяет все образы из `docker compose config --images` через HTTP HEAD до pull
- Интегрировано в `compose_pull()` — 404 блокирует установку с чётким сообщением о пропавших образах
- update.sh sourcит lib/compose.sh и вызывает validate_images_exist() warn-only перед bundle update

## Task Commits

1. **Task 1: Helper-функции для registry API** - `72d8e2a` (feat)
2. **Task 2: validate_images_exist() + интеграция** - `d21521c` (feat)

**Plan metadata:** _(создаётся финальным коммитом)_

## Files Created/Modified

- `lib/compose.sh` — добавлены `_parse_image_ref()`, `_get_registry_token()`, `_check_image_exists()`, `validate_images_exist()` + вызов в `compose_pull()`
- `scripts/update.sh` — добавлены source lib/compose.sh и вызов `validate_images_exist()` перед `perform_bundle_update()`

## Decisions Made

- HTTP HEAD вместо docker manifest inspect — избегает docker/cli#4345 (push scope bug) и не тратит Docker Hub rate limit (HEAD запросы бесплатны)
- В update.sh валидация только warn-only (не блокирует) — при update у пользователя могут быть кастомные образы
- Source lib/compose.sh в update.sh через `_UPDATE_SCRIPT_DIR` — переиспользование кода без дублирования
- rc=2 для любой ошибки registry (401, 403, 405, 429, 500, timeout) — пропуск с warn, не блокировка

## Deviations from Plan

None — план выполнен точно по спецификации.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Pre-pull image validation готова для всех профилей деплоя
- Offline profile и SKIP_IMAGE_VALIDATION bypass сохранены
- Следующий шаг: Phase 30 Plan 03 (bundle verification) или финализация Phase 30

## Self-Check: PASSED

- lib/compose.sh: FOUND
- scripts/update.sh: FOUND
- 30-02-SUMMARY.md: FOUND
- commit 72d8e2a: FOUND
- commit d21521c: FOUND

---
*Phase: 30-reliability-validation*
*Completed: 2026-03-30*
