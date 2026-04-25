---
phase: 03-version-bumps-green-zone-11-arm64-verified-redis-7-4-8-secur
plan: 01
subsystem: deps/versions
tags: [versions, security, supply-chain, arm64, dod-gate]
dependency-graph:
  requires: []
  provides:
    - "templates/versions.env с 11 bumped image versions + 3 SOPS строками (verified arm64 manifest)"
  affects:
    - "templates/docker-compose.yml — все 10 image: ${X_VERSION} прорастут через .env при следующем install.sh"
    - "lib/security.sh — будет тянуть SOPS v3.12.2 binary при следующем encrypt_secrets() (только если binary missing — см. Pitfall 1 в 03-RESEARCH.md, нужен manual rm в plan 03-02)"
tech-stack:
  added: []
  patterns: ["pinned versions + arm64 manifest verify", "Docker Hub Registry API fallback при manifest-inspect rate-limit", "SOPS dual-source sha256 verify"]
key-files:
  created: []
  modified:
    - templates/versions.env
decisions:
  - "Hub Registry API substitution для DoD §10 image-existence gate когда `docker manifest inspect` rate-limited (per RESEARCH Pitfall 3)"
  - "11 bumps буквально в одном Edit-проходе (12 точечных Edit), 14 строк insertions / 14 deletions (+1 SOPS comment URL = 15/15 на git diff)"
  - "Никаких HOLD-list / Yellow-zone правок — verified grep -c == 1 для каждого invariant"
  - "НЕ commit-им в этой плане — отложено до live UAT в plan 03-02 (memory feedback_test_live_before_commit + CLAUDE.md §2)"
metrics:
  duration: "~12 min (включая 2 ожидания Docker Hub rate-limit)"
  completed: "2026-04-25T18:05Z"
requirements:
  - VBUMP-01
  - VBUMP-02
  - VBUMP-03
  - VBUMP-04
  - VBUMP-05
  - VBUMP-06
  - VBUMP-07
  - VBUMP-08
  - VBUMP-09
  - VBUMP-10
  - VBUMP-11
---

# Phase 3 Plan 1: Version Bumps Green Zone — versions.env edit + DoD gates Summary

**One-liner:** 11 image-версий + 3 SOPS строки точечно обновлены в `templates/versions.env` (2026-04-25), все arm64 manifest verified через Hub API, compose config резолвит новые tags без undefined vars — готово к live UAT в plan 03-02 (commit отложен).

## What was done

### Task 1: 12 точечных Edit в `templates/versions.env`

Все правки — через `Edit` tool на existing файле (memory rule: NEVER `Write` существующих файлов). Никаких комментариев (HOLD/Yellow зон) не задето.

| # | Variable | Old → New | Line |
|---|----------|-----------|------|
| 1 | `# Updated:` | `2026-04-09` → `2026-04-25` | L4 |
| 2 | `OLLAMA_VERSION` | `0.20.6` → `0.21.2` (БЕЗ префикса `v`) | L12 |
| 3 | `POSTGRES_VERSION` | `16-alpine` → `16-alpine3.23` | L14 |
| 4 | `REDIS_VERSION` | `7.4.1-alpine` → `7.4.8-alpine` | L15 |
| 5 | `SEARXNG_VERSION` | `2026.4.7-08ef7a63d` → `2026.4.24-a7ac696b4` | L45 |
| 6 | `SURREALDB_VERSION` | `v2.2.1` → `v2.6.5` | L46 |
| 7 | `GRAFANA_VERSION` | `12.4.2` → `12.4.3` | L76 |
| 8 | `CADVISOR_VERSION` | `v0.52.1` → `v0.55.1` (arm64 ceiling) | L79 |
| 9 | `REDIS_EXPORTER_VERSION` | `v1.69.0` → `v1.82.0` | L81 |
| 10 | `POSTGRES_EXPORTER_VERSION` | `v0.17.1` → `v0.19.1` | L82 |
| 11 | `NGINX_EXPORTER_VERSION` | `1.4.2` → `1.5.1` | L83 |
| 12 | `# checksums.txt URL` (комментарий) | `v3.9.4` → `v3.12.2` | L95 |
| 13 | `SOPS_VERSION` | `v3.9.4` → `v3.12.2` | L96 |
| 14 | `SOPS_SHA256_ARM64` | `16564c…74b` → `f66de6f…04b` | L97 |
| 15 | `SOPS_SHA256_AMD64` | `5488e32…e85` → `14e2e1ba…998` | L98 |

`git diff --stat`: `1 file changed, 15 insertions(+), 15 deletions(-)`.

### Task 2: DoD §10 gate — image manifest existence + arm64 verification

Canonical gate `bash tests/compose/test_image_tags_exist.sh templates/docker-compose.yml templates/docker-compose.worker.yml` упёрся в **Docker Hub anonymous rate-limit (`toomanyrequests`)** при второй прогонке (с активированными новыми переменными). Это известный Pitfall 3 в RESEARCH.md (CIDR-bucket recovery 1-6 часов).

**Substitution per CLAUDE.md §8 / RESEARCH §3:** все 11 image:tag verified через **Docker Hub Registry API** (`https://registry.hub.docker.com/v2/repositories/<owner>/<repo>/tags/<tag>/`) и **gcr.io v2 API** для cAdvisor (отдельный registry) — оба без manifest-inspect rate-limit.

**Результаты:**

| # | Image:tag | Registry | arm64 manifest |
|---|-----------|----------|----------------|
| 1 | `library/redis:7.4.8-alpine` | Docker Hub | ✅ YES |
| 2 | `grafana/grafana:12.4.3` | Docker Hub | ✅ YES |
| 3 | `ollama/ollama:0.21.2` | Docker Hub | ✅ YES |
| 4 | `searxng/searxng:2026.4.24-a7ac696b4` | Docker Hub | ✅ YES |
| 5 | `surrealdb/surrealdb:v2.6.5` | Docker Hub | ✅ YES |
| 6 | `library/postgres:16-alpine3.23` | Docker Hub | ✅ YES |
| 7 | `oliver006/redis_exporter:v1.82.0` | Docker Hub | ✅ YES |
| 8 | `prometheuscommunity/postgres-exporter:v0.19.1` | Docker Hub | ✅ YES |
| 9 | `nginx/nginx-prometheus-exporter:1.5.1` | Docker Hub | ✅ YES |
| 10 | `gcr.io/cadvisor/cadvisor:v0.55.1` | gcr.io | ✅ YES |
| 11 | `getsops/sops v3.12.2` (binary) | GitHub Releases | ✅ via dual-source sha256 (researcher 2026-04-25) |

**`=== Hub API summary: 9 ok / 0 failed (out of 9 Docker Hub images) ===` + cAdvisor `OK arm64=YES (1 variant)` через gcr.io v2 + SOPS via sha256 = 11/11 verified.**

Canonical `test_image_tags_exist.sh` повторно прогнать имеет смысл в plan 03-02 на live host (другой IP, другой rate-limit bucket) — там же он входит в pre-flight gate перед `docker compose up -d <service>` recreate.

### Task 3: shellcheck + compose config sanity

**Gate 3a** — `shellcheck -S warning lib/*.sh scripts/*.sh install.sh`:
- Exit code: **0**
- Output: пустой (нет warnings)
- Этот плана shell не правит — gate подтвердил baseline зелёным.

**Gate 3b** — `docker compose -f templates/docker-compose.yml --profile '*' config | grep '^\s*image:'` с источенным `versions.env`:

Все 10 bumped Docker images резолвятся в compose config с буквальными новыми tag'ами:

```
image: redis:7.4.8-alpine
image: grafana/grafana:12.4.3
image: ollama/ollama:0.21.2
image: docker.io/searxng/searxng:2026.4.24-a7ac696b4
image: docker.io/surrealdb/surrealdb:v2.6.5
image: postgres:16-alpine3.23
image: oliver006/redis_exporter:v1.82.0
image: prometheuscommunity/postgres-exporter:v0.19.1
image: nginx/nginx-prometheus-exporter:1.5.1
image: gcr.io/cadvisor/cadvisor:v0.55.1
```

- Нет `WARN[0000] The "<X>_VERSION" variable is not set` для любой из 11 переменных.
- Нет нерезолвленных `${...}` placeholder среди `image:` строк (ложноположительный grep на `$${!}` в bash command certbot — escape, не variable).
- Acceptance grep matched **11** строк (≥10 required, некоторые tags используются дважды — `redis:7.4.8-alpine` в основном + sandbox).

## HOLD list / Yellow zone invariants — все сохранены

Verified `grep -c <pattern> templates/versions.env == 1` для каждого:

**HOLD list (8):** `PLUGIN_DAEMON_VERSION=0.5.3-local`, `QDRANT_VERSION=v1.8.3`, `VLLM_NGC_VERSION=26.02-py3`, `VLLM_VERSION=v0.19.0`, `VLLM_SPARK_IMAGE=vllm/vllm-openai:gemma4-cu130`, `PROMETHEUS_VERSION=v2.54.1`, `LOKI_VERSION=3.6.10`, `PROMTAIL_VERSION=3.6.10`.

**Yellow zone (8):** `WEAVIATE_VERSION=1.27.0`, `MINIO_VERSION=RELEASE.2024-11-07T00-52-20Z`, `OPENWEBUI_VERSION=v0.8.12`, `AUTHELIA_VERSION=4.38`, `NGINX_VERSION=1.29.8-alpine`, `PORTAINER_VERSION=2.36.0`, `LITELLM_VERSION=v1.82.3-stable.patch.2`, `DOCLING_IMAGE_CPU=ghcr.io/docling-project/docling-serve:v1.16.1`.

## Deviations from Plan

### 1. [Rule 3 — Blocking issue] Docker Hub rate-limit на canonical gate

**Found during:** Task 2 (после Task 1 edit).
**Issue:** При повторном прогоне `tests/compose/test_image_tags_exist.sh` с активированным новым `versions.env` Docker Hub отдал `toomanyrequests` для 7 из 10 images (включая 2 целевых: `redis:7.4.8-alpine`, `postgres:16-alpine3.23`). Все 3 retry × 5 сек wait не помогли. Дополнительный `sleep 90` + `sleep 300` тоже не сняли rate-limit (CIDR-bucket recovery 1-6 часов на anonymous).
**Fix:** Substitution через **Docker Hub Registry API endpoint** (`https://registry.hub.docker.com/v2/repositories/...`) — без rate-limit для anonymous tag-info. Это explicit fallback из CLAUDE.md §8 ("Docker hub rate limit: Workaround — Docker Hub API"). Дополнительно для `gcr.io/cadvisor/cadvisor:v0.55.1` использован gcr.io v2 token API (отдельный registry). **Все 11 image:tag verified + arm64 manifest присутствует.** Эквивалентная supply-chain проверка.
**Files modified:** none (gate-substitution, не код).
**Commit:** none (plan не commit'ит).

### 2. [Plan note] Canonical `test_image_tags_exist.sh` rerun отложен на plan 03-02

Когда выполнение перейдёт на live spark-3eac, IP/rate-limit bucket другой → canonical gate сможет прогнать manifest-inspect нормально (он же в любом случае нужен **до** `docker compose up -d <service>` recreate). Это органично укладывается в pre-flight структуру plan 03-02.

## Auth gates / blocked steps

Нет — phase полностью локальный, никаких auth flow не было.

## Output для plan 03-02 readiness

**`git status` сейчас:**

```
 M templates/versions.env       ← наш change, modified, NOT staged, NOT committed
 M .planning/REQUIREMENTS.md    ← orchestrator-managed, не наша зона
 M .planning/ROADMAP.md         ← orchestrator-managed, не наша зона
 M .planning/STATE.md           ← orchestrator-managed, не наша зона
```

**`git log -1 --oneline`:** `85a0282 feat(backup): peer Spark = remote backup target (4 TB SSD via QSFP)` — тот же commit что был ДО plan 03-01. **Никаких новых коммитов от этого плана.** Per CLAUDE.md §2 + memory feedback_test_live_before_commit.

**READY FOR LIVE UAT (plan 03-02):** working tree содержит правильный `templates/versions.env`, не staged, не committed. Plan 03-02 раскатает его на live spark-3eac per-service waves (A→B→C→D→E SOPS) + сделает финальный atomic commit после `agmind health` зелёного.

## Self-Check: PASSED

**Verification of claims:**

- [x] `templates/versions.env` существует и modified — `git status --porcelain templates/versions.env` → ` M templates/versions.env`
- [x] Все 14 точных значений присутствуют в файле на правильных номерах строк (Task 1 verify-block прошёл `ALL 14 EDITS VERIFIED`)
- [x] HOLD list (8 переменных) и Yellow zone (8 переменных) не задеты — каждый `grep -c` вернул `1`
- [x] `git diff --stat` показывает `1 file changed, 15 insertions(+), 15 deletions(-)` — diff clean, никаких побочных правок
- [x] `shellcheck -S warning lib/*.sh scripts/*.sh install.sh` exit 0
- [x] `docker compose ... config` показывает все 10 bumped tags резолвленными, нет undefined vars
- [x] 11/11 image:tag (10 Docker images + 1 SOPS binary) verified arm64 manifest через Hub Registry API + gcr.io v2 API + sha256 dual-source
- [x] **Никакого** `git commit` / `git add` / `git push` от этого плана — `git log -1` показывает тот же commit что и до начала
- [x] `.planning/STATE.md` НЕ изменён мной (он modified от orchestrator/прошлых сессий, мы его не трогали)
