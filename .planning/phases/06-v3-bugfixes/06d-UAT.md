---
status: diagnosed
phase: 06-v3-bugfixes (STAB-01, STAB-02, STAB-03)
source: 06-01-SUMMARY.md, 06-02-SUMMARY.md
started: 2026-03-21T18:00:00Z
updated: 2026-03-21T18:00:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Cold Start Smoke Test
expected: Kill any running stack. Run `sudo bash install.sh` from scratch. All containers start, redis-lock-cleaner completes, plugin-daemon boots without errors.
result: issue
reported: "redis-lock-cleanup.sh создаётся как директория — скрипт не генерируется инсталлером до docker compose up. Docker видит bind mount на несуществующий файл и создаёт директорию. Cleaner стартует молча без ошибок, но ничего не делает."
severity: blocker

### 2. Plugin-daemon waits for dify_plugin DB (STAB-01)
expected: `docker compose up` after fresh boot — plugin-daemon does NOT start until PostgreSQL healthcheck confirms dify_plugin DB exists. No "DB not ready" errors.
result: pass

### 3. Redis stale locks cleaned on restart (STAB-02)
expected: Running `docker compose up` a second time after crash clears stale Redis locks automatically. No manual `redis-cli DEL` needed. Plugin installations don't hang on "starting".
result: issue
reported: "redis-lock-cleanup.sh создаётся как директория (BUG-V3-028). Cleaner стартует но ничего не делает — скрипт не сгенерирован инсталлером до compose up."
severity: blocker

### 4. GPU containers auto-start after reboot (STAB-03)
expected: After `sudo reboot`, all GPU containers (vLLM/Ollama/TEI/Xinference) running within 2 minutes. `agmind status` confirms healthy. Profile containers (docling, monitoring) also start.
result: issue
reported: "systemd service без COMPOSE_PROFILES (BUG-V3-029). agmind-stack.service делает docker compose up -d без --profile etl --profile monitoring. Профильные контейнеры (docling, xinference, prometheus, grafana, alertmanager, cadvisor) не стартуют после ребута. Core GPU containers (ollama, vllm) стартуют."
severity: major

## Summary

total: 4
passed: 1
issues: 3
pending: 0
skipped: 0

## Gaps

- truth: "redis-lock-cleanup.sh is a valid script file when docker compose up runs"
  status: failed
  reason: "User reported: redis-lock-cleanup.sh не генерируется инсталлером до docker compose up. Docker видит bind mount на несуществующий файл и создаёт директорию. Cleaner стартует молча, ничего не делает."
  severity: blocker
  test: 1, 3
  root_cause: "install.sh _copy_runtime_files() не включает redis-lock-cleanup.sh в список копируемых скриптов. Файл существует в repo scripts/ но не копируется в ${INSTALL_DIR}/scripts/ перед compose up. Docker создаёт директорию вместо файла при bind mount на несуществующий путь."
  artifacts:
    - path: "install.sh"
      issue: "_copy_runtime_files() scripts array missing redis-lock-cleanup.sh (line ~181)"
    - path: "scripts/redis-lock-cleanup.sh"
      issue: "Source script correct, just not deployed"
  missing:
    - "Add redis-lock-cleanup.sh to _copy_runtime_files() scripts array in install.sh"

- truth: "systemd service starts all containers including profile-based ones after reboot"
  status: failed
  reason: "User reported: agmind-stack.service делает docker compose up -d без COMPOSE_PROFILES. Профильные контейнеры (docling, xinference, prometheus, grafana, alertmanager, cadvisor) не стартуют после ребута."
  severity: major
  test: 4
  root_cause: "COMPOSE_PROFILES вычисляется в памяти build_compose_profiles() и передаётся inline в compose_up(). Значение не сохраняется в .env файл. systemd service не имеет EnvironmentFile= директивы. После ребута docker compose up запускается без COMPOSE_PROFILES — профильные контейнеры игнорируются."
  artifacts:
    - path: "templates/agmind-stack.service.template"
      issue: "No EnvironmentFile= directive, ExecStart has no profile env"
    - path: "lib/compose.sh"
      issue: "build_compose_profiles() result never persisted to .env"
    - path: "lib/config.sh"
      issue: "generate_config() never writes COMPOSE_PROFILES to .env"
  missing:
    - "Persist COMPOSE_PROFILES to ${INSTALL_DIR}/docker/.env after build_compose_profiles()"
    - "Add EnvironmentFile=-__INSTALL_DIR__/docker/.env to systemd service template"
