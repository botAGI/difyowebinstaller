# Phase 28: Release Branch Workflow - Context

**Gathered:** 2026-03-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Installer и `agmind update` переходят на ветку `release` как стабильный источник скриптов/конфигов. Вместе с этим поставляются быстрые UX-фиксы: Telegram HTML escape, Model API endpoints в credentials.txt, FILES_URL auto-populate. Новые фичи (pre-pull validation, Docling GPU, dry-run) — это другие фазы.

</domain>

<decisions>
## Implementation Decisions

### Механизм обновления скриптов
- INSTALL_DIR (`/opt/agmind`) становится git-репозиторием — клонируется при установке, `git pull` при обновлении
- При свежей установке: bootstrap-скрипт (curl | bash) клонирует ветку `release` в `/opt/agmind` и запускает `install.sh`. README обновляется с новой инструкцией
- `agmind update` = git pull (скрипты/конфиги с release) + docker pull (образы). Раздельно: `--scripts-only` обновляет только скрипты, а `--main` разово тянет скрипты из main без перекачки образов (RELU-03 scope — dev only, скрыт из --help)
- `agmind update --main` — разовый fetch из ветки main. Следующий `agmind update` снова берёт из release. Не переключает ветку насовсем
- Offline-профиль тоже подключается к интернету при обновлении — git pull работает для всех профилей

### Защита пользовательских файлов
- Расширенный .gitignore: `.env`, `credentials.txt`, `docker/` (весь runtime), `RELEASE`, checkpoints, `logs/`, volumes, `*.bak`, `*.tmp`
- Стратегия: .gitignore + git stash push перед pull как страховка для untracked файлов
- При ошибке git pull (конфликт, сеть): остановить обновление, показать ясную ошибку с командой для ручного исправления. Не продолжать обновление образов на старых скриптах

### Release notes и --check
- `agmind update --check`: полный текст release notes из GitHub Releases API + URL на GitHub release в конце
- Сравнение с локальным: читаем RELEASE файл, сравниваем с latest release. Если совпадают — короткое сообщение "AGMind vX.Y.Z — актуальная версия". Если нет — показываем notes
- При ошибке API (rate limit 403/429) — сообщить об ошибке, не падать

### Telegram HTML escape
- Функция escape: `<` → `&lt;`, `>` → `&gt;`, `&` → `&amp;` (в этом порядке, чтобы избежать двойного escape)
- Применять ко всем сообщениям перед отправкой через send_notification()

### Model API endpoints в credentials.txt
- Писать только активные провайдеры: Ollama URL (если ollama profile), vLLM URL (если vllm), TEI Embed URL (если tei), TEI Rerank URL (если reranker)
- Формат: оба варианта — Docker-сетевой (agmind-ollama:11434) для inter-container и внешний (localhost:11434) для пользовательских приложений
- Отдельная секция "Model API Endpoints" в credentials.txt

### FILES_URL auto-populate
- VPS: уже работает — `https://${DOMAIN}` (сохранить)
- LAN: подставить `http://<server_ip>` — нужно для доступа с других хостов в сети
- VPN: аналогично LAN — подставить IP
- Offline: подставить IP

### Claude's Discretion
- Точный формат bootstrap-скрипта (curl | bash)
- Порядок операций внутри `agmind update` (git pull → versions diff → docker pull)
- Формат секции "Model API Endpoints" в credentials.txt
- Обработка edge cases при git pull (dirty working tree, detached HEAD)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Update mechanism
- `.planning/research/ARCHITECTURE.md` §4 — Git-Based Release Branch Workflow, Option A (branch-based versions.env fetch), recommended approach
- `.planning/research/PITFALLS.md` — C-01 (git pull overwrite), M-03 (.gitignore audit), N-04 (API rate limit)

### Requirements
- `.planning/REQUIREMENTS.md` — RELU-01..08 requirements for this phase
- `.planning/ROADMAP.md` §Phase 28 — success criteria (7 points)

### Current implementation
- `scripts/update.sh` lines 161-196 — send_notification() (Telegram, needs HTML escape)
- `scripts/update.sh` lines 295-363 — current fetch mechanism (GitHub Releases API)
- `scripts/update.sh` lines 415-433 — current release notes display (truncated)
- `scripts/agmind.sh` lines 702-735 — help text (--main must NOT appear here)
- `install.sh` lines 335-380 — _save_credentials() (add Model API endpoints)
- `lib/config.sh` lines 226-261 — .env generation, FILES_URL substitution
- `templates/env.lan.template` line 38 — FILES_URL currently empty for LAN
- `.gitignore` — current state, needs expansion for installer-generated files

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `send_notification()` in update.sh — уже поддерживает Telegram и webhook, нужно только добавить HTML escape
- `_save_credentials()` in install.sh — существующая функция для записи credentials.txt, расширяем секцией endpoints
- `_get_ip()` in install.sh — определяет IP сервера, используется для URLs
- `lib/config.sh` `_generate_env_file()` — подстановка переменных в шаблоны .env

### Established Patterns
- Argument parsing в update.sh: case-switch по флагам (lines 138-158) — добавляем `--main`, `--scripts-only`
- RELEASE файл: содержит только тег версии — нужно обновить формат
- Compose profiles: `COMPOSE_PROFILES` env var определяет активные провайдеры — используем для определения endpoints

### Integration Points
- `scripts/agmind.sh` cmd_update dispatch → update.sh — проброс новых флагов
- README.md — обновить инструкцию установки (curl | bash вместо ручного clone)
- `.gitignore` в корне репо — расширить для installer-generated файлов
- `RELEASE` файл — формат может измениться (добавить branch context)

</code_context>

<specifics>
## Specific Ideas

- `--main` должен быть именно разовым: оператор проверяет dev-версию, но не "застревает" на main навсегда
- Разделение `--scripts-only` важно: можно быстро обновить скрипты без тяжёлого docker pull
- Offline-профиль подключается к интернету при обновлении — не нужна специальная обработка

</specifics>

<deferred>
## Deferred Ideas

None — обсуждение осталось в рамках фазы.

</deferred>

---

*Phase: 28-release-branch-workflow*
*Context gathered: 2026-03-29*
