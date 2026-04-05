---
phase: 28-release-branch-workflow
verified: 2026-03-29T00:00:00Z
status: passed
score: 11/11 must-haves verified
re_verification: false
---

# Phase 28: Release Branch Workflow Verification Report

**Phase Goal:** Release branch workflow для стабильных обновлений (agmind update тянет из release, новые установки клонируют release), Telegram HTML escape, Model API endpoints в credentials.txt, FILES_URL auto-populate для LAN/VPN/Offline профилей, полные release notes в --check.
**Verified:** 2026-03-29
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|----------|
| 1  | Telegram notification с `<`, `>`, `&` доставляется без Telegram Bot API 400 | VERIFIED | `_escape_html()` в update.sh строки 165-172; вызов `message="$(_escape_html "$message")"` в начале `send_notification()` строка 177 |
| 2  | credentials.txt содержит секцию Model API Endpoints с URL активных провайдеров | VERIFIED | `_save_credentials()` в install.sh строки 371-390; условные блоки для Ollama/vLLM/TEI/TEI-rerank внутри `{ } > credentials.txt` |
| 3  | FILES_URL в .env заполняется из IP сервера для LAN/VPN/Offline профилей | VERIFIED | `lib/config.sh` строки 249-294 — вычисление `files_url` и sed-замена `__FILES_URL__`; шаблоны содержат `FILES_URL=__FILES_URL__` |
| 4  | VPS профиль FILES_URL неизменён (использует DOMAIN) | VERIFIED | `templates/env.vps.template:38` — `FILES_URL=https://__DOMAIN__` (не тронут) |
| 5  | Fresh install клонирует ветку release | VERIFIED | README.md строка 42: bootstrap URL с `/release/bootstrap.sh`; строка 48: `git clone -b release` |
| 6  | agmind update тянет скрипты из ветки release через git pull | VERIFIED | `update_scripts()` в update.sh строки 214-260: `git stash`, `git fetch origin $branch`, `git checkout $branch`, `git pull --ff-only origin $branch`; вызов в main() строка 1050 |
| 7  | agmind update --main делает разовый fetch из main; следующий запуск возвращается к release | VERIFIED | update.sh строки 158, 253-256; предупреждение "One-time pull from 'main' complete" + `UPDATE_BRANCH` defaults к "release" |
| 8  | Флаг --main НЕ виден в agmind update --help | VERIFIED | `grep --main scripts/agmind.sh` — ноль совпадений в help-тексте; только `--scripts-only` добавлен (строка 728) |
| 9  | .gitignore покрывает все файлы генерируемые установщиком | VERIFIED | .gitignore строки 28-37: credentials.txt, RELEASE, docker/, logs/, .rollback/, .dify_initialized, .admin_password, .checkpoint_*, *.bak, *.tmp |
| 10 | agmind update --check показывает полные release notes без обрезки | VERIFIED | `display_bundle_diff()` строки 482-494: while-read loop без ограничения строк, переменная `line_count -ge 10` полностью удалена |
| 11 | GitHub API 403/429 показывает предупреждение, не ложное "up to date" | VERIFIED | update.sh строки 367-377: HTTP код проверяется, 403/429 — `log_warn`; строки 491-494: "Release notes unavailable (GitHub API error or rate limit)." |

**Score:** 11/11 truths verified

---

### Required Artifacts

| Artifact | Предоставляет | Status | Детали |
|----------|---------------|--------|--------|
| `scripts/update.sh` | HTML escape + git update + full release notes | VERIFIED | `_escape_html()` на строке 165; `update_scripts()` на строке 214; `display_bundle_diff()` без обрезки на строке 482 |
| `install.sh` | Model API Endpoints в credentials.txt | VERIFIED | Секция на строках 371-390 внутри `{ } > credentials.txt` |
| `lib/config.sh` | FILES_URL замена для LAN/VPN/Offline шаблонов | VERIFIED | Вычисление `files_url` строки 249-257; sed-замена `__FILES_URL__` строка 294 |
| `templates/env.lan.template` | Плейсхолдер FILES_URL для LAN | VERIFIED | Строка 38: `FILES_URL=__FILES_URL__` |
| `templates/env.vpn.template` | Плейсхолдер FILES_URL для VPN | VERIFIED | Строка 38: `FILES_URL=__FILES_URL__` |
| `templates/env.offline.template` | Плейсхолдер FILES_URL для Offline | VERIFIED | Строка 38: `FILES_URL=__FILES_URL__` |
| `scripts/agmind.sh` | Passthrough флагов + --scripts-only в help | VERIFIED | Строка 728: `--scripts-only` в help; `--main` отсутствует; exec `"$@"` передаёт все флаги |
| `.gitignore` | Исключения всех runtime-файлов установщика | VERIFIED | Строки 28-37: все 10 требуемых паттернов присутствуют |
| `README.md` | Инструкции установки через release ветку | VERIFIED | Строки 42, 48: bootstrap + git clone -b release |

---

### Key Link Verification

| From | To | Via | Status | Детали |
|------|----|-----|--------|--------|
| `scripts/update.sh` | Telegram Bot API | `_escape_html()` вызывается в `send_notification()` до curl | WIRED | Строки 165-177: функция определена и сразу вызвана |
| `install.sh` | `credentials.txt` | `_save_credentials()` пишет секцию Model API Endpoints | WIRED | Строки 371-396: блок внутри `{ } > credentials.txt` |
| `lib/config.sh` | `templates/env.*.template` | sed заменяет `__FILES_URL__` на вычисленный URL | WIRED | `files_url` вычисляется строки 250-257; sed применяется строка 294 |
| `scripts/agmind.sh` | `scripts/update.sh` | cmd_update передаёт `--main`, `--scripts-only` через `exec "$@"` | WIRED | Флаги принимает update.sh строки 158-159; passthrough подтверждён |
| `scripts/update.sh` | git | `git pull --ff-only origin $branch` в `update_scripts()` | WIRED | Строки 235-249: fetch, checkout, pull — все три шага |
| `.gitignore` | installer-generated files | gitignore-паттерны предотвращают конфликты git pull | WIRED | `credentials.txt` строка 28 и 9 прочих паттернов строки 29-37 |
| `scripts/update.sh` | GitHub Releases API | fetch_release_info() через raw.githubusercontent.com для versions.env | WIRED | Строка 398: `versions_url="https://raw.githubusercontent.com/botAGI/AGmind/${UPDATE_BRANCH}/templates/versions.env"` |

---

### Requirements Coverage

| Requirement | Source Plan | Описание | Status | Evidence |
|-------------|-------------|----------|--------|----------|
| RELU-01 | 28-02-PLAN | Installer клонирует ветку release по умолчанию | SATISFIED | README.md строки 42, 48; git clone -b release |
| RELU-02 | 28-02-PLAN | agmind update тянет скрипты из release через git pull | SATISFIED | `update_scripts()` с `git pull --ff-only origin release` |
| RELU-03 | 28-02-PLAN | agmind update --main переключает на main (скрыт из --help) | SATISFIED | Флаг обрабатывается, из help убран |
| RELU-05 | 28-03-PLAN | Полные release notes в agmind update --check | SATISFIED | `display_bundle_diff()` без ограничения строк |
| RELU-06 | 28-01-PLAN | Telegram HTML escape спецсимволов | SATISFIED | `_escape_html()` + вызов в `send_notification()` |
| RELU-07 | 28-01-PLAN | Model API endpoints записываются в credentials.txt | SATISFIED | Секция "Model API Endpoints:" с условными блоками |
| RELU-08 | 28-01-PLAN | Dify FILES_URL auto-populate из IP при установке | SATISFIED | lib/config.sh + 3 шаблона с `__FILES_URL__` |

**Отсутствующие в фазе требования (не входят в scope):**
- RELU-04 (Pre-pull валидация образов) — назначен Phase 31, не входит в Phase 28

Все 7 требований из scope Phase 28 выполнены.

---

### Anti-Patterns Found

Сканирование файлов изменённых в фазе:

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| install.sh | 436, 455 | "placeholder" | Info | Легитимные ссылки на TLS-сертификаты и health.json — не заглушки кода |
| lib/config.sh | 259, 399, 660 | "placeholder" | Info | Легитимные ссылки на начальные сертификаты — не заглушки кода |

Блокирующих anti-patterns не обнаружено.

---

### Human Verification Required

#### 1. Telegram HTML escape — end-to-end проверка

**Test:** Настроить ALERT_MODE=telegram в .env с реальным ботом. Запустить `agmind update` в ситуации, где имя хоста или версия содержат `<`, `>` или `&`. Проверить, что сообщение доставлено без 400 Bad Request от Telegram API.
**Expected:** Сообщение приходит без ошибки; спецсимволы отображаются корректно в Telegram.
**Why human:** Требует реальный Telegram Bot Token и отправку HTTP запроса к API.

#### 2. FILES_URL в реальном .env после install.sh

**Test:** Выполнить `sudo bash install.sh` с профилем LAN. После установки проверить `grep FILES_URL /opt/agmind/docker/.env`.
**Expected:** `FILES_URL=http://<server-ip>` (реальный IP, не плейсхолдер).
**Why human:** Требует реальный запуск install.sh на Linux-сервере.

#### 3. agmind update — git pull в production окружении

**Test:** На сервере с `git clone -b release` выполнить `agmind update --scripts-only`. Проверить что скрипты обновились без ошибок.
**Expected:** Вывод "Scripts updated from branch: release"; статус git показывает актуальный HEAD.
**Why human:** Требует реальное git-репозиторий с веткой release на GitHub и сеть.

---

### Gaps Summary

Пробелов не обнаружено. Все артефакты существуют, реализованы и соединены. Все 7 требований фазы 28 удовлетворены.

**Примечание о решении исполнителя:** Секция Model API Endpoints в credentials.txt содержит только Docker-network URL (без Host-access URL). Это намеренное отклонение от плана — исполнитель обнаружил, что порты не публикуются в docker-compose, и host-access URL были бы нерабочими. Решение корректно.

---

_Verified: 2026-03-29_
_Verifier: Claude (gsd-verifier)_
