---
phase: 11-bundle-update-rewrite
verified: 2026-03-22T11:30:00Z
status: passed
score: 7/7 must-haves verified
re_verification: false
gaps: []
---

# Phase 11: Bundle Update Rewrite — Verification Report

**Phase Goal:** Переписать `agmind update` с per-component логики на bundle workflow через GitHub Releases API. Оператор получает diff версий, подтверждает, получает rolling restart с автооткатом при неудаче. Emergency-режим `--component` сохранён с предупреждением.
**Verified:** 2026-03-22T11:30:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                                   | Status      | Evidence                                                                                  |
|----|---------------------------------------------------------------------------------------------------------|-------------|-------------------------------------------------------------------------------------------|
| 1  | `agmind update --check` вызывает GitHub Releases API и показывает diff версий current vs latest        | VERIFIED    | `GITHUB_API_URL` line 19; `fetch_release_info()` line 267; `display_bundle_diff()` line 334; `CHECK_ONLY` path line 933 |
| 2  | `agmind update --check` выводит "You are up to date (vX.Y.Z)" при current == latest                    | VERIFIED    | `log_success "You are up to date (${current_release})"` line 340; `return 1` from `display_bundle_diff()` triggers SKIP path in `main()` |
| 3  | `agmind update` скачивает versions.env из release, показывает diff, спрашивает confirm, backup, pull изменённых, rolling restart, healthcheck | VERIFIED | Full bundle flow: lines 921–995; `DOWNLOADED_VERSIONS_FILE` global wiring lines 318 + 971–972; `save_rollback_state()` line 950; `perform_bundle_update()` line 981 |
| 4  | Ошибка healthcheck после bundle update запускает автооткат из `.rollback/`                              | VERIFIED    | `else` branch of `perform_bundle_update` result: `perform_rollback()` line 990, `verify_rollback()` line 991, `exit 1` line 994 |
| 5  | `agmind update --component X --version Y` показывает warning с `[y/N]` confirmation                   | VERIFIED    | `update_component()` lines 701–715: FORCE check, WARNING banner, `Continue anyway? [y/N]:` prompt line 711 |
| 6  | `agmind update --component X --version Y --force` пропускает warning                                   | VERIFIED    | `if [[ "$FORCE" != "true" ]]; then` guard line 702; `FORCE=true` set by `--force` arg line 155 |
| 7  | `agmind update --rollback` откатывает к предыдущему bundle из `.rollback/`                             | VERIFIED    | `rollback_bundle()` lines 640–666; called from `main()` when `ROLLBACK_MODE=true` and `ROLLBACK_TARGET=""` (lines 884–891); restores `.env`, `versions.env`, `RELEASE.bak` |

**Score:** 7/7 truths verified

---

## Required Artifacts

| Artifact             | Expected                                            | Status      | Details                                                                                      |
|----------------------|-----------------------------------------------------|-------------|----------------------------------------------------------------------------------------------|
| `scripts/update.sh`  | Bundle update system with GitHub Releases API       | VERIFIED    | 998 lines; all required functions present; bash -n passes; no REMOTE_VERSIONS_URL            |
| `scripts/agmind.sh`  | Updated help text reflecting new bundle update commands | VERIFIED | Lines 405–412: `--check` (GitHub Releases), `--component` (Emergency), `--force`, `--rollback` (bundle/legacy); dispatch line 434 wires to update.sh |

---

## Key Link Verification

| From                                | To                                                                     | Via                                    | Status   | Details                                                                                          |
|-------------------------------------|------------------------------------------------------------------------|----------------------------------------|----------|--------------------------------------------------------------------------------------------------|
| `scripts/update.sh`                 | `https://api.github.com/repos/botAGI/difyowebinstaller/releases/latest` | `curl` in `fetch_release_info()`      | WIRED    | Line 19: `GITHUB_API_URL="https://api.github.com/repos/botAGI/difyowebinstaller/releases/latest"` used in `curl` at line 271 |
| `fetch_release_info()` → `main()`   | `DOWNLOADED_VERSIONS_FILE` global variable                             | Set in `fetch_release_info()`, consumed in `main()` | WIRED | Line 318: `DOWNLOADED_VERSIONS_FILE="$tmp_versions"`; lines 971–972: `cp "$DOWNLOADED_VERSIONS_FILE" "$VERSIONS_FILE"` |
| `scripts/update.sh`                 | `/opt/agmind/RELEASE`                                                  | `RELEASE_FILE` read/write              | WIRED    | Line 20: `RELEASE_FILE="${INSTALL_DIR}/RELEASE"`; `get_current_release()` reads it (line 257); `main()` writes it at line 983; `save_rollback_state()` backs it up at line 423 |
| `scripts/update.sh`                 | `/opt/agmind/.rollback/`                                               | `save_rollback_state()` + `perform_rollback()` on failure | WIRED | `ROLLBACK_DIR` defined line 14; `save_rollback_state()` line 398 saves `.env`, `versions.env`, `RELEASE.bak`; `perform_rollback()` lines 429–451 restores all; auto-triggered at lines 989–994 |
| `update_component()` → `FORCE`      | Skip warning when `--force` passed                                     | `if [[ "$FORCE" != "true" ]]` check    | WIRED    | Line 702: guard present; `FORCE=true` set by arg parser line 155                                |
| `rollback_bundle()`                 | `/opt/agmind/.rollback/`                                               | `perform_rollback()` + RELEASE.bak restore | WIRED | Lines 656–661: `perform_rollback()` called, then `RELEASE.bak` copied back to `$RELEASE_FILE`; `verify_rollback()` called line 663 |
| `scripts/agmind.sh`                 | `scripts/update.sh`                                                    | `exec` dispatch with args              | WIRED    | Line 434: `exec "${SCRIPTS_DIR}/update.sh" "$@"` after `_require_root update` check            |

---

## Requirements Coverage

| Requirement | Source Plan | Description                                                                                   | Status    | Evidence                                                                              |
|-------------|-------------|-----------------------------------------------------------------------------------------------|-----------|---------------------------------------------------------------------------------------|
| BUPD-01     | 11-01       | `agmind update --check` использует GitHub Releases API, показывает current vs latest diff    | SATISFIED | `fetch_release_info()` + `display_bundle_diff()` + `CHECK_ONLY` path in `main()`    |
| BUPD-02     | 11-01       | `agmind update` скачивает versions.env, diff, confirm, backup, pull изменённых, restart, healthcheck | SATISFIED | Full bundle flow lines 919–995; `DOWNLOADED_VERSIONS_FILE` link; `perform_bundle_update()` |
| BUPD-03     | 11-01       | При неудачном healthcheck — автооткат из `.rollback/`                                        | SATISFIED | `else` branch lines 989–994: `perform_rollback()` + `verify_rollback()` + `exit 1`  |
| BUPD-04     | 11-01       | `agmind update --check` при current == latest выводит "You are up to date (vX.Y.Z)"         | SATISFIED | `log_success "You are up to date (${current_release})"` line 340 in `display_bundle_diff()` |
| EMRG-01     | 11-02       | `agmind update --component X --version Y` показывает warning с `[y/N]`                      | SATISFIED | `update_component()` warning block lines 701–715; exact text "WARNING: Single-component update" + "bypasses release compatibility" + `Continue anyway? [y/N]:` |
| EMRG-02     | 11-02       | `--force` пропускает предупреждение в emergency mode                                         | SATISFIED | `if [[ "$FORCE" != "true" ]]; then` guard line 702; `--force` sets `FORCE=true` line 155 |
| RBCK-01     | 11-02       | `agmind update --rollback` откатывает к предыдущему bundle из `.rollback/`                  | SATISFIED | `rollback_bundle()` lines 640–666 called from `main()` lines 884–891 when `ROLLBACK_MODE=true` and `ROLLBACK_TARGET=""` |

**Orphaned requirements check:** REQUIREMENTS.md maps 7 IDs to Phase 11 (BUPD-01..04, EMRG-01..02, RBCK-01). All 7 are covered by plans 11-01 and 11-02. BFIX-01 is mapped to Phase 10 — not orphaned for Phase 11.

---

## Anti-Patterns Found

| File                   | Line | Pattern          | Severity | Impact |
|------------------------|------|------------------|----------|--------|
| `scripts/update.sh`    | —    | None found       | —        | —      |
| `scripts/agmind.sh`    | —    | None found       | —        | —      |

- No TODO/FIXME/HACK/PLACEHOLDER comments
- No empty stub implementations
- No stubs masking as real functions
- `LC_ALL=C` locale-safe regex present at line 8 (BFIX-01 inherited from Phase 10)

---

## Human Verification Required

### 1. Live GitHub Releases API call

**Test:** На хосте с доступом в интернет выполнить `agmind update --check`
**Expected:** Вывод с текущим и последним релизом, diff компонентов, release notes первой строки
**Why human:** Требует реального GitHub Release с assets/versions.env; сетевой вызов нельзя верифицировать статически

### 2. Bundle update end-to-end с разными версиями

**Test:** Временно изменить локальный RELEASE файл на более старый тег, запустить `agmind update`, подтвердить `y`
**Expected:** Pull только изменённых образов, rolling restart по порядку (infra->app->frontend), запись нового тега в RELEASE
**Why human:** Требует запущенный Docker Compose стек; healthcheck timeout и порядок рестартов нельзя проверить без живых контейнеров

### 3. Автооткат при неудаче healthcheck

**Test:** Вызвать update_service() с несуществующим образом, убедиться в откате
**Expected:** `perform_rollback()` вызывается, RELEASE файл восстанавливается из `.rollback/RELEASE.bak`
**Why human:** Требует симуляции pull-failure или unhealthy-state в реальном Docker

### 4. Emergency mode --force bypass

**Test:** `agmind update --component dify-api --version 1.13.0 --force`
**Expected:** Никакого WARNING banner, прямой переход к resolve_component/update
**Why human:** Интерактивный вывод (отсутствие banner) нельзя верифицировать grep'ом

---

## Gaps Summary

Нет пробелов. Все 7 must-have truths верифицированы на трёх уровнях:
- Уровень 1 (существует): оба файла присутствуют, все функции определены
- Уровень 2 (содержательность): все функции реализованы с реальной логикой, без заглушек
- Уровень 3 (подключение): все key links прослежены — GitHub API URL → `fetch_release_info()` → `DOWNLOADED_VERSIONS_FILE` → `main()` → `VERSIONS_FILE`; RELEASE_FILE читается/пишется/бекапируется; `perform_rollback()` вызывается автоматически при неудаче; FORCE guard работает в `update_component()`

Все три коммита существуют в git: `d891aca` (Plan 01 bundle rewrite), `17862de` (Plan 02 emergency warning), `7cd9e60` (Plan 02 agmind.sh help).

---

_Verified: 2026-03-22T11:30:00Z_
_Verifier: Claude (gsd-verifier)_
