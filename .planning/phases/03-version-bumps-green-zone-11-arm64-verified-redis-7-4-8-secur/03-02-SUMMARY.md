---
plan: 03-02
phase: 03-version-bumps-green-zone-11-arm64-verified
status: complete
started: 2026-04-25
completed: 2026-04-25
host: spark-3eac (master, LLM_ON_PEER mode)
---

# Plan 03-02 — Live UAT Summary

## Что сделано

Live deployment 11 version bumps на работающем стеке spark-3eac. Per-service recreate в 4-х волнах + SOPS skip (по конфигу хоста), без force-recreate, без касания GPU/HOLD-list контейнеров. Финальная регрессия: 13/14 prometheus targets up, agmind health 0 unhealthy.

## Wave-by-wave

| Wave | Сервисы | Image bumps | Health | Time |
|------|---------|-------------|--------|------|
| A | redis, grafana, surrealdb | 7.4.1→7.4.8-alpine, 12.4.2→12.4.3, v2.2.1→v2.6.5 | все healthy за 15 сек | ~30 сек |
| B+C | redis-exporter, postgres-exporter, nginx-exporter, cadvisor, searxng | v1.69→v1.82, v0.17→v0.19, 1.4.2→1.5.1, v0.52.1→v0.55.1, 2026.4.7→2026.4.24-a7ac696b4 | все running, distroless HC=`<nil>` (Pitfall 6 mitigated) | ~45 сек |
| D | db (postgres) | 16-alpine → 16-alpine3.23 | healthy за 10 сек, api/worker/plugin_daemon RC=0 (psycopg pool retry без помощи) | ~15 сек |
| E | SOPS binary | n/a — `ENABLE_SOPS=false` на этом host'е, skip | versions.env обновлён для будущих installs | — |

## Что НЕ задеплоено на этом host'е

- **VBUMP-04 Ollama** — нет `agmind-ollama` контейнера (LLM_ON_PEER mode, vLLM на peer-spark-69a2). `OLLAMA_VERSION=0.21.2` обновлён в `versions.env` для fresh installs.
- **VBUMP-03 SOPS** — `ENABLE_SOPS=false` в `/opt/agmind/docker/.env`. `SOPS_VERSION=v3.12.2` + `SOPS_SHA256_*` в `versions.env` готовы — при следующем `install.sh` с `ENABLE_SOPS=true` `lib/security.sh` подтянет новый бинарник с verified hashes.

## Pitfall mitigation

| Pitfall (RESEARCH.md) | Status |
|---|---|
| 1. SOPS silent skip on existing host | n/a (skip Wave E на этом host'е) |
| 2. Postgres recreate connection drop | ✓ pool retry отработал бесшумно за 10 сек, fallback restart не понадобился |
| 3. Docker Hub anonymous rate-limit | ✓ Plan 03-01 использовал Hub Registry API fallback; live pull проходил без issues |
| 4. Ollama tag без `v` | ✓ `OLLAMA_VERSION=0.21.2` (без префикса) в обоих versions.env и .env |
| 5. SearXNG hash-suffix | ✓ `2026.4.24-a7ac696b4` в обоих файлах |
| 6. Distroless exporter healthcheck regression | ✓ redis-exporter, nginx-exporter `Healthcheck=<nil>` после bump'а — без false-unhealthy |
| 7. Force-recreate trap | ✓ все waves через `compose up -d <service>`, vLLM-embed/rerank/docling RC=0 неприкосновенны |

## Final state

- `agmind health`: 0 unhealthy, 3 transient warns (Docker Hub timeout, DOMAIN/DEPLOY_PROFILE optional — те же что в baseline)
- HTTP 200: Dify Console, Grafana 12.4.3 (verified `database:ok`), Open WebUI, Searxng, Weaviate
- Prometheus: 13/14 targets up (1 `agmind-vllm` down — это baseline LLM_ON_PEER mode)
- Peer reachable, peer vLLM :8000 OK, cluster.json status OK

## Files modified (live host, NOT committed to repo)

- `/opt/agmind/docker/.env` — 10 версий sync'нуты, backup в `/opt/agmind/docker/.env.bak.phase3`

## Files modified (repo, commit pending user approval)

- `templates/versions.env` (15 правок: 11 image + 3 SOPS строки + header date + URL комментарий)
- `.planning/REQUIREMENTS.md` (VBUMP-01..11 секция)
- `.planning/ROADMAP.md` (Phase 3 expanded с goal/SC + plans complete checkbox)
- `.planning/STATE.md` (Phase 3 complete)
- `.planning/phases/03-version-bumps-green-zone-11-arm64-verified-redis-7-4-8-secur/03-CONTEXT.md`
- `.planning/phases/03-version-bumps-green-zone-11-arm64-verified-redis-7-4-8-secur/03-RESEARCH.md`
- `.planning/phases/03-version-bumps-green-zone-11-arm64-verified-redis-7-4-8-secur/03-01-PLAN.md`
- `.planning/phases/03-version-bumps-green-zone-11-arm64-verified-redis-7-4-8-secur/03-01-SUMMARY.md`
- `.planning/phases/03-version-bumps-green-zone-11-arm64-verified-redis-7-4-8-secur/03-02-PLAN.md`

## Self-Check: PASSED
