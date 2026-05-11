# Security Policy

AGmind ставит корпоративную RAG-платформу (Dify + RAGFlow + vLLM + Open WebUI
+ vector stores + мониторинг) одной командой на DGX Spark. Установщик трогает
firewall, генерирует секреты, поднимает ~30 контейнеров — security-баги здесь
имеют высокий blast radius.

## Reporting a Vulnerability

**Не открывайте публичный GitHub issue для security-проблем.**

Сообщайте через один из приватных каналов:

1. **GitHub Security Advisories** (предпочтительно) —
   [Report a vulnerability](https://github.com/botAGI/AGmind/security/advisories/new)
   на вкладке Security репозитория. Это даёт приватную ветку обсуждения
   и координированное раскрытие.

2. **Email** — если GHSA недоступен, напишите мейнтейнерам (адрес в профиле
   организации / README). В письме укажите:
   - затронутую версию / commit
   - шаги воспроизведения
   - предполагаемый impact (RCE / privilege escalation / data exposure / DoS)
   - предлагаемый фикс, если есть

Мы стараемся ответить в течение **72 часов** и выпустить фикс в течение
**14 дней** для critical/high severity. Если эти сроки нарушаются — напишите
повторно.

## Scope

В scope (сообщайте):
- `install.sh`, `lib/*.sh`, `scripts/*.sh` — установщик и runtime-скрипты
- `templates/docker-compose*.yml`, `templates/*.template` — конфигурация стека
- `.github/workflows/*.yml` — CI/CD pipeline
- credentials handling, firewall/SSH/TLS setup, secret generation/rotation
- supply chain (pinned image tags, GitHub Actions, downloaded binaries +
  их SHA256)

Вне scope:
- уязвимости в upstream-образах (Dify, RAGFlow, vLLM, Postgres, etc) — сообщайте
  напрямую их мейнтейнерам; мы pin'им версии и реагируем на их advisories
- проблемы только при намеренно небезопасной конфигурации (`SKIP_DOCKER_HARDENING=true`,
  `AGMIND_ALLOW_AMD64=true`, отключённый fail2ban и т.п.) — это явный opt-out
- DoS через перегрузку (RAG-индексация тяжёлых документов и т.п.) — это resource
  management, не security boundary
- self-XSS / атаки требующие физического/админ-доступа к хосту

## Supported Versions

Поддерживается только последний релиз. Бэкпорты security-фиксов в старые
релизы не делаем — обновляйтесь до latest. Версии компонентов pin'ятся в
`templates/versions.env`; security-bumps летят через обычный release cycle
(или hotfix для critical).

## Security Practices in This Repo

- Все image:tag pin'ятся к конкретным версиям (никаких `:latest`) с verified
  arm64 manifest — проверяется CI (`tests/compose/test_image_tags_exist.sh`).
- Все GitHub Actions pin'ятся к полному commit SHA — проверяется zizmor в CI.
- Скачиваемые бинарники (SOPS и т.п.) проверяются по SHA256 — refuse install
  на mismatch.
- Trivy config scan + zizmor static analysis + OpenSSF Scorecard в CI.
- Институциональная память по прошлым инцидентам — в `CLAUDE.md` §8 (часть
  правил оттуда enforce'ится как regression-тесты в `tests/unit/`).
- Credentials хранятся в `chmod 600` файлах, передаются через env/secrets,
  не выводятся в stdout/логи/UI.
