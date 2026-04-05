# Phase 20: Xinference Removal - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Полное удаление Xinference из стека: сервис убран из docker-compose, ETL_ENHANCED заменён на ENABLE_DOCLING, Docling переведён в отдельный profile `docling`, load_reranker() удалена. Backward compat shim для существующих установок с ETL_ENHANCED=true.

</domain>

<decisions>
## Implementation Decisions

### Xinference disposition (XINF-01)
- Полностью удалить xinference сервис из docker-compose.yml (не legacy profile)
- Удалить volume `agmind_xinference_data` из docker-compose.yml
- Удалить все упоминания xinference из: agmind.sh help text, check-upstream.sh, versions.env (XINFERENCE_VERSION), COMPATIBILITY.md, COMPONENTS.md, uninstall.sh, generate-manifest.sh, release-manifest.json, update.sh
- Удалить XINFERENCE_BASE_URL и закомментированный RERANK_MODEL_NAME из всех 4 env templates
- Удалить load_reranker() функцию и все её вызовы в models.sh (фаза 19 уже заглушила, теперь убираем полностью)

### ETL flag split (XINF-02)
- Заменить ETL_ENHANCED на ENABLE_DOCLING (только один флаг в этой фазе)
- ENABLE_RERANKER появится в фазе 22 вместе с TEI reranker
- В wizard.sh: переменная `ENABLE_DOCLING` вместо `ETL_ENHANCED`, export ENABLE_DOCLING
- В compose.sh: `ENABLE_DOCLING=true` → profile `docling` (вместо `etl`)
- В config.sh: `ENABLE_DOCLING=true` → `ETL_TYPE=unstructured_api` (Dify внутренняя переменная, менять нельзя)
- В env templates: `ENABLE_DOCLING=false` вместо ETL_ENHANCED
- Backward compat shim в compose.sh: если ETL_ENHANCED=true и ENABLE_DOCLING не задан → автоматически ENABLE_DOCLING=true (не ломает существующие .env)

### Docling profile (XINF-03)
- Profile переименован: `etl` → `docling`
- В docker-compose.yml: Docling сервис получает `profiles: [docling]`
- compose.sh: `ENABLE_DOCLING=true` → `profiles="${profiles:+$profiles,}docling"`
- Profile `etl` больше не существует — удалён вместе с xinference

### Migration / Cleanup
- В update.sh: добавить cleanup блок — остановить и удалить orphan контейнер agmind-xinference + volume agmind_xinference_data при обновлении
- В uninstall.sh: убрать упоминания xinference
- Backward compat shim: ETL_ENHANCED=true → ENABLE_DOCLING=true (в compose.sh и/или wizard.sh defaults)

### Wizard summary line
- wizard.sh:863 — исправить `ETL: Docling + Xinference` → `ETL: Docling` (косметический баг из фазы 19)

### Claude's Discretion
- Порядок cleanup операций в update.sh
- Формат warning сообщений при ETL_ENHANCED backward compat
- Нужно ли log_info при автоматической миграции ETL_ENHANCED → ENABLE_DOCLING

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose
- `templates/docker-compose.yml` §494-534 — Docling service (profile etl)
- `templates/docker-compose.yml` §515-534 — Xinference service (to be removed)
- `templates/docker-compose.yml` §1042 — agmind_xinference_data volume (to be removed)

### Profile building
- `lib/compose.sh` §17-38 — build_compose_profiles() function

### ETL flag usage
- `lib/wizard.sh` §28 — ETL_ENHANCED default
- `lib/wizard.sh` §193-209 — _wizard_etl() function
- `lib/wizard.sh` §863 — Summary ETL line (cosmetic bug)
- `lib/wizard.sh` §918 — ETL_ENHANCED export
- `lib/config.sh` §240-244 — ETL_TYPE mapping from ETL_ENHANCED
- `lib/models.sh` §7 — ETL_ENHANCED in header comments
- `lib/models.sh` §150-160 — load_reranker() stub (to be removed)
- `lib/models.sh` §202, §231 — load_reranker() call sites

### Env templates
- `templates/env.lan.template` §55-57 — Xinference/reranker vars
- `templates/env.vps.template` §55-57 — Xinference/reranker vars
- `templates/env.vpn.template` §55-57 — Xinference/reranker vars
- `templates/env.offline.template` §55-57 — Xinference/reranker vars

### Xinference in other scripts
- `scripts/agmind.sh` — help text mentions xinference in gpu assign
- `scripts/check-upstream.sh` — Xinference version check
- `scripts/update.sh` — update flow, add cleanup here
- `scripts/uninstall.sh` — Xinference cleanup
- `scripts/generate-manifest.sh` — Manifest generation
- `templates/versions.env` — XINFERENCE_VERSION
- `templates/release-manifest.json` — Xinference entry
- `COMPONENTS.md` — Xinference in dependency groups
- `COMPATIBILITY.md` — Xinference compatibility entry

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `build_compose_profiles()` in compose.sh — pattern for conditional profile building, add ENABLE_DOCLING check here
- `_wizard_etl()` in wizard.sh — existing ETL wizard step, rename variable
- backward compat pattern: `ETL_TYPE` already handled as fallback in compose.sh line 24

### Established Patterns
- Profile flags: `ENABLE_AUTHELIA`, `LLM_PROVIDER`, `EMBED_PROVIDER` → conditional profile append in compose.sh
- Env default pattern: `VAR="${VAR:-default}"` in wizard.sh defaults block
- Update cleanup: update.sh has rollback/backup patterns to follow

### Integration Points
- wizard.sh exports → used by compose.sh, config.sh, models.sh
- compose.sh builds COMPOSE_PROFILE_STRING → used by docker compose up
- config.sh writes .env → read by docker-compose.yml
- update.sh runs during `agmind update` → add xinference cleanup

</code_context>

<specifics>
## Specific Ideas

No specific requirements — standard refactoring approaches apply.

</specifics>

<deferred>
## Deferred Ideas

- ENABLE_RERANKER flag + TEI reranker container — Phase 22 (RNKR-01..03)
- Reranker profile in docker-compose — Phase 22

</deferred>

---

*Phase: 20-xinference-removal*
*Context gathered: 2026-03-23*
