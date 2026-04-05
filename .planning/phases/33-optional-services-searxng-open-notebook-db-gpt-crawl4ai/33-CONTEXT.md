# Phase 33: Optional Services (SearXNG + Open Notebook + DB-GPT + Crawl4AI) - Context

**Gathered:** 2026-03-30
**Status:** Ready for planning

<domain>
## Phase Boundary

Add 4 optional services as wizard y/N choices with compose profiles. Each service follows the established pattern: docker-compose service definition, versions.env, wizard step, COMPOSE_PROFILES integration, credentials.txt, agmind doctor health check.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion

All implementation choices are at Claude's discretion — pure infrastructure phase. Follow existing patterns from docling/reranker/LiteLLM integrations exactly.

Key patterns to replicate:
- `profiles: [service_name]` in docker-compose.yml
- `ENABLE_SERVICE=true/false` env var from wizard
- `build_compose_profiles()` in lib/compose.sh for conditional profile append
- `get_service_list()` in lib/health.sh for health detection
- Conditional credentials.txt block in install.sh `_save_credentials()`
- Version pinning in versions.env (no `:latest`)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/wizard.sh`: `_ask()` and `_ask_choice()` helpers for y/N prompts
- `lib/compose.sh`: `build_compose_profiles()` — string concat pattern
- `lib/health.sh`: `get_service_list()` — env-conditional service array
- `lib/config.sh`: `_generate_litellm_config()` — config file generation pattern
- `templates/docker-compose.yml`: `*logging-defaults`, `*security-defaults` anchors

### Established Patterns
- Boolean wizard: `_ask "Включить X? [y/N]:" "n"` → `ENABLE_X=true/false`
- Profile build: `[[ "${ENABLE_X:-false}" == "true" ]] && profiles="${profiles:+$profiles,}x"`
- Health: grep .env for ENABLE flag, append to services array
- Credentials: conditional echo block inside `_save_credentials()`
- NON_INTERACTIVE: respect existing env vars, skip prompts

### Integration Points
- `docker-compose.yml`: service definitions after litellm
- `versions.env`: version tags for each service image
- `wizard.sh`: new wizard steps after LiteLLM step in `run_wizard()`
- `compose.sh`: `build_compose_profiles()` additions
- `health.sh`: `get_service_list()` additions
- `install.sh`: `_save_credentials()` additions
- `init-*-db.sql` for services needing PostgreSQL (Open Notebook, DB-GPT)

</code_context>

<specifics>
## Specific Ideas

SearXNG: порт 8888, JSON API enabled, движки Google/Bing/DuckDuckGo/Wikipedia, ~256 MB RAM limit
Open Notebook: через LiteLLM + PostgreSQL, ~512 MB RAM limit
DB-GPT: через LiteLLM, ~1 GB RAM limit
Crawl4AI: REST API, Chromium-based, ~2 GB RAM limit

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>
