---
phase: 05-devops-ux
plan: 02
subsystem: infra
tags: [nginx, health-endpoint, cron, bats, cli, agmind, rate-limiting, authelia]

# Dependency graph
requires:
  - phase: 05-01
    provides: agmind.sh CLI with status --json and doctor subcommands

provides:
  - scripts/health-gen.sh — atomic health.json generator via agmind status --json
  - nginx /health endpoint serving static JSON with rate limiting and Authelia bypass
  - docker-compose health.json volume mount for nginx container
  - install.sh: agmind.sh + health-gen.sh + detect.sh copied to INSTALL_DIR
  - install.sh: /usr/local/bin/agmind symlink created after install
  - install.sh: /etc/cron.d/agmind-health cron job for health.json refresh
  - tests/test_agmind_cli.bats — 42 structural BATS tests for CLI and health-gen

affects: [monitoring, uptime-kuma, phase-verify]

# Tech tracking
tech-stack:
  added: [bats-core tests, nginx alias directive, cron.d job, atomic write via mktemp+mv]
  patterns:
    - atomic file write via mktemp + mv prevents nginx serving partial JSON
    - exact-match nginx location (location = /health) bypasses auth_request from location /
    - #__AUTHELIA__ commented directives for conditional Authelia bypass
    - health-gen.sh delegates to agmind.sh status --json for schema consistency

key-files:
  created:
    - scripts/health-gen.sh
    - tests/test_agmind_cli.bats
  modified:
    - templates/nginx.conf.template
    - templates/docker-compose.yml
    - install.sh

key-decisions:
  - "health-gen.sh uses atomic write (mktemp+mv) to prevent nginx serving partial JSON during update"
  - "/health location uses auth_request off via #__AUTHELIA__ pattern — explicit Authelia bypass visible and intentional"
  - "Initial health.json placeholder created in phase_config() so nginx can start without 404"
  - "cron.d/agmind-health logs to INSTALL_DIR/health-gen.log for operator visibility"
  - "Summary box updated to reference agmind CLI commands instead of raw script paths"

patterns-established:
  - "Pattern 1: health-gen delegates to agmind.sh — single source of truth for JSON schema"
  - "Pattern 2: #__AUTHELIA__    auth_request off inside exact-match locations for bypass"
  - "Pattern 3: BATS tests use grep/head pattern validation without requiring Docker runtime"

requirements-completed: [DEVX-03, DEVX-01, DEVX-02]

# Metrics
duration: 15min
completed: 2026-03-18
---

# Phase 5 Plan 02: Health Endpoint + Installer Integration Summary

**nginx /health JSON endpoint with atomic cron-driven updates, /usr/local/bin/agmind global CLI symlink, and 42 BATS structural tests**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-18T09:43:00Z
- **Completed:** 2026-03-18T09:58:00Z
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments
- `scripts/health-gen.sh` generates health.json atomically (mktemp+mv) by calling `agmind status --json`; fallback writes degraded status on failure
- nginx `/health` location added to HTTP and TLS server blocks with `zone=health` rate limiting (1r/s) and `auth_request off` for Authelia bypass
- `install.sh` integrates full CLI lifecycle: copies agmind.sh/health-gen.sh/detect.sh, creates symlink, installs cron, generates initial JSON

## Task Commits

Each task was committed atomically:

1. **Task 1: health-gen.sh + nginx /health + docker-compose volume** - `55aa420` (feat)
2. **Task 2: install.sh integration — scripts, symlink, cron, health.json** - `e37dbec` (feat)
3. **Task 3: BATS tests for CLI and health-gen** - `80b795c` (test)

**Plan metadata:** committed after SUMMARY creation (docs)

## Files Created/Modified
- `scripts/health-gen.sh` — atomic health.json generator, delegates to agmind.sh status --json
- `templates/nginx.conf.template` — added zone=health rate limit, location = /health with auth bypass
- `templates/docker-compose.yml` — added health.json volume mount for nginx container
- `install.sh` — script copies, initial health.json placeholder, symlink, cron, summary update
- `tests/test_agmind_cli.bats` — 42 BATS structural tests

## Decisions Made
- `auth_request off` placed inside `location = /health` using `#__AUTHELIA__` pattern — makes bypass explicit and visible, uncommented when Authelia is activated for VPN profiles
- Initial `health.json` with `"status": "starting"` created in `phase_config()` so nginx has a valid file at container start (prevents 404 before first cron tick)
- `cron.d/agmind-health` logs to `${INSTALL_DIR}/health-gen.log` for operator debugging

## Deviations from Plan

None — план выполнен точно по спецификации.

## Issues Encountered
- `bash -n tests/test_agmind_cli.bats` возвращает ошибку синтаксиса из-за BATS-специфичного синтаксиса `@test` — это ожидаемо, BATS тесты не предназначены для проверки через `bash -n`. Содержимое файла корректно.

## Next Phase Readiness
- Phase 5 полностью завершён: agmind CLI (план 01) + health endpoint + installer integration (план 02)
- Внешние инструменты мониторинга (Uptime Kuma и др.) могут опрашивать `/health` для получения JSON-статуса стека
- Готово к `/gsd:verify-work 5`

---
*Phase: 05-devops-ux*
*Completed: 2026-03-18*
