---
phase: 26-update-robustness
verified: 2026-03-25T00:00:00Z
status: passed
score: 5/5 must-haves verified
re_verification: false
gaps: []
human_verification:
  - test: "Запустить agmind update --check при наличии доступного релиза с PG 17 в versions.env"
    expected: "Вывод должен показывать release notes (до 10 строк) и ссылку Full changelog:, но НЕ блокировать — только --check"
    why_human: "Требует реального GitHub Release с versions.env asset и live окружения"
  - test: "Запустить agmind update при POSTGRES_VERSION 16->17 без --force"
    expected: "Команда завершается с exit 1, выводит pg_dumpall инструкцию и ссылку на pg-upgrade.md"
    why_human: "Требует двух версий versions.env (текущей и новой) и live окружения"
  - test: "Запустить agmind rollback и проверить install.log"
    expected: "В install.log появляется блок '--- Post-rollback doctor ... ---' с JSON-выводом agmind doctor"
    why_human: "Требует live Docker окружения с запущенным стеком"
  - test: "Создать тестовый GitHub Release с versions.env asset и проверить CI run"
    expected: "CI job sync-release выполняется успешно, в репозитории появляется обновлённый templates/release-manifest.json с новым version и release_date"
    why_human: "Требует реального GitHub Actions окружения"
---

# Phase 26: Update Robustness — Verification Report

**Phase Goal:** Операции обновления и отката надёжно защищены от критичных сценариев — PostgreSQL major upgrade предотвращён с явным предупреждением, release notes доступны без перехода в браузер, post-rollback health подтверждён автоматически, CI синхронизирует manifest без ручной работы.
**Verified:** 2026-03-25
**Status:** PASSED (с рекомендуемой ручной проверкой)
**Re-verification:** Нет — первичная верификация

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | PG major upgrade (16->17) блокирует обновление с явным предупреждением и инструкцией pg_dump | VERIFIED | `check_pg_major_upgrade()` функция в update.sh:256; вызов в main():1004 ПОСЛЕ `CHECK_ONLY` exit:999 |
| 2 | `agmind update --check` выводит до 10 строк release notes + GitHub URL | VERIFIED | `display_bundle_diff()` update.sh:415-432; цикл с `line_count -ge 10`; `Full changelog: https://github.com/botAGI/AGmind/releases/tag/${RELEASE_TAG}` |
| 3 | После rollback `agmind doctor --json` запускается автоматически и результат логируется в install.log | VERIFIED | `rollback_bundle()` update.sh:707-722; doctor вызов, `mkdir -p logs`, append в `${INSTALL_DIR}/logs/install.log` |
| 4 | При публикации GitHub Release, CI автоматически обновляет release-manifest.json | VERIFIED | `.github/workflows/sync-release.yml:43` вызывает `python3 scripts/update-release-manifest.py`; `git add templates/release-manifest.json` на строке 60 |
| 5 | Обновлённый manifest содержит новый tag, release_date и версии образов | VERIFIED | `scripts/update-release-manifest.py` — `manifest["version"] = tag`, `manifest["release_date"] = release_date`, обход KEY_MAP из 25 записей |

**Score:** 5/5 truths verified

---

### Required Artifacts

| Artifact | Назначение (по плану) | Status | Детали |
|----------|-----------------------|--------|--------|
| `scripts/update.sh` | PG guard, release notes display, post-rollback doctor | VERIFIED | Существует, содержит все три функции, bash syntax OK (`bash -n` exit 0) |
| `.github/workflows/sync-release.yml` | CI action для синхронизации release-manifest.json | VERIFIED | Существует, вызывает python script, добавляет manifest в git add |
| `scripts/update-release-manifest.py` | Python helper для патча manifest | VERIFIED | Создан (deviation от плана — вынесен из inline python3 -c), содержит KEY_MAP, sys.argv, корректно обновляет version/release_date/images |
| `templates/release-manifest.json` | Manifest с version, release_date, images | VERIFIED | Существует, содержит все обязательные поля; обновляется CI при каждом Release |

---

### Key Link Verification

| From | To | Via | Status | Детали |
|------|-----|-----|--------|--------|
| `update.sh:main()` | `check_pg_major_upgrade()` | вызов на строке 1004 | WIRED | Вызов ПОСЛЕ `CHECK_ONLY` exit (строка 999-1001) — `--check` не блокируется |
| `update.sh:check_pg_major_upgrade()` | `POSTGRES_VERSION comparison` | `pg_major_old="${current_pg%%[.-]*}"` | WIRED | Строки 263-264: правильное извлечение major версии из формата `16-alpine` |
| `update.sh:display_bundle_diff()` | RELEASE_NOTES output | цикл `while IFS= read -r line` с `line_count -ge 10` | WIRED | Строки 415-432; пропуск ведущих пустых строк; счётчик; URL |
| `update.sh:rollback_bundle()` | `agmind doctor --json` | вызов после `verify_rollback` | WIRED | Строки 707-722; stdout+stderr захвачены; tee в install.log с timestamp |
| `sync-release.yml:Update repo files` | `templates/release-manifest.json` | `python3 scripts/update-release-manifest.py "$TAG"` | WIRED | Строка 43 workflow; строка 60 — git add включает manifest |
| `sync-release.yml` | `templates/versions.env` | `gh release download` + `cp` | WIRED | Строки 26, 40-41 — существующая функциональность сохранена |

---

### Requirements Coverage

| Requirement | Source Plan | Описание | Status | Evidence |
|-------------|------------|----------|--------|----------|
| UPDT-01 | 26-01-PLAN.md | update.sh при изменении major версии PG останавливает обновление с warning и pg_dump инструкцией | SATISFIED | `check_pg_major_upgrade()` блокирует exit 1; `FORCE=true` обходит; `pg_dumpall` инструкция; ссылка на `pg-upgrade.md` |
| UPDT-02 | 26-01-PLAN.md | update --check показывает полные release notes (до 10 строк + ссылка на GitHub) | SATISFIED | `display_bundle_diff()` цикл до 10 строк; `Full changelog:` URL с `${RELEASE_TAG}` |
| UPDT-03 | 26-01-PLAN.md | После rollback автоматически запускается agmind doctor --json для верификации health | SATISFIED | `rollback_bundle()` вызывает doctor, логирует в install.log, не fatal при ошибках |
| UPDT-04 | 26-02-PLAN.md | CI action автоматически синхронизирует release-manifest.json при создании GitHub Release | SATISFIED | `sync-release.yml` вызывает `update-release-manifest.py`; commit включает manifest |

**Orphaned requirements (Phase 26 в REQUIREMENTS.md, не заявленные в планах):** Нет.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| Нет | — | — | — | — |

Проверены все изменённые файлы: `scripts/update.sh`, `.github/workflows/sync-release.yml`, `scripts/update-release-manifest.py`. Placeholder-ов, TODO/FIXME, пустых реализаций и console.log-only блоков не обнаружено.

---

### Детали по ключевым решениям

**UPDT-01 — PG guard placement:**
`check_pg_major_upgrade` вызывается на строке 1004, ПОСЛЕ блока `CHECK_ONLY` exit (строки 999-1001). Это корректно: `--check` показывает diff включая изменение версии PG (оператор видит предупреждение в составе diff), но не блокируется. Фактическое обновление блокируется. `--force` обходит guard с явным предупреждением об ответственности оператора.

**UPDT-04 — Deviation от плана (documented):**
Вместо inline `python3 -c "..."` в YAML создан отдельный файл `scripts/update-release-manifest.py`. Причина: YAML-парсер отвергал многострочный Python с двоеточиями и кавычками. Функциональность эквивалентна, тестируемость улучшена. Отклонение задокументировано в 26-02-SUMMARY.md.

**Замечание по acceptance criteria UPDT-04:**
Критерий "grep release-manifest.json returns >= 3 matches в sync-release.yml" не выполняется буквально (файл имеет 2 совпадения в workflow + 7 в Python-скрипте). Это прямое следствие документированного отклонения. Функциональный результат (manifest обновляется и коммитится) достигнут.

---

### Human Verification Required

#### 1. PG major upgrade block (UPDT-01)

**Test:** На тестовом сервере с PostgreSQL 16: изменить в versions.env `POSTGRES_VERSION=17-alpine`, запустить `agmind update` (без `--force`).
**Expected:** Команда выводит `PostgreSQL major upgrade detected: 16 -> 17`, инструкции pg_dumpall, ссылку на pg-upgrade.md, завершается exit 1.
**Why human:** Требует live Docker окружения с PostgreSQL 16 и тестового release с POSTGRES_VERSION=17.

#### 2. PG guard bypass с --force (UPDT-01)

**Test:** То же, но добавить `--force`.
**Expected:** Вывод предупреждения "Continuing with --force (PostgreSQL major upgrade — operator responsibility)", обновление продолжается.
**Why human:** Требует live окружения.

#### 3. Release notes в --check output (UPDT-02)

**Test:** Запустить `agmind update --check` при наличии нового релиза.
**Expected:** Выводятся до 10 строк release notes, затем строка "Full changelog: https://github.com/botAGI/AGmind/releases/tag/vX.Y.Z". Если заметок > 10 строк — показывается "... (N lines total)".
**Why human:** Требует реального GitHub Release с заполненными release notes.

#### 4. Post-rollback doctor logging (UPDT-03)

**Test:** Выполнить `agmind rollback`, затем проверить `tail -50 /opt/agmind/logs/install.log`.
**Expected:** В install.log появляется блок с заголовком `--- Post-rollback doctor YYYY-MM-DD HH:MM:SS ---`, JSON-вывод doctor, `--- End doctor ---`.
**Why human:** Требует live Docker окружения с запущенным стеком AGMind.

#### 5. CI manifest sync (UPDT-04)

**Test:** Создать тестовый GitHub Release с прикреплённым assets/versions.env (с изменённым DIFY_VERSION). Дождаться завершения CI job sync-release.
**Expected:** В коммите CI появляется обновлённый `templates/release-manifest.json` — `version` равен тегу релиза, `release_date` — дате публикации, `dify-api.tag` и `dify-web.tag` — новой версии Dify.
**Why human:** Требует реального GitHub Actions окружения и прав на создание релизов.

---

## Итоговая оценка

Все пять проверяемых кодом истин подтверждены. Реализации содержательны — нет заглушек, все ключевые связи установлены. Bash-синтаксис update.sh валиден. Единственное отклонение от плана (вынос Python в отдельный файл) задокументировано и улучшает качество кода.

Фаза достигла своей цели: операции обновления и отката защищены от всех четырёх критичных сценариев.

---

_Verified: 2026-03-25_
_Verifier: Claude (gsd-verifier)_
