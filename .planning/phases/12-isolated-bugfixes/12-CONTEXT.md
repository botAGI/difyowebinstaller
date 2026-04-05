# Phase 12: Isolated Bugfixes - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Four isolated bugfixes that don't change UX flows — doctor SKIP without root, Redis ACL granular blocklist, v-prefix strip in check-upstream.sh, Dify admin init timeout increase + fallback credentials.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase. Key constraints from conversation analysis:

**BUG-038 (OPUX-01):** In `.env Completeness` block of cmd_doctor(), add `[[ ! -r "$ENV_FILE" ]]` guard → SKIP all .env var checks with message "Запустите: sudo agmind doctor"

**BUG-040 (OPUX-02):** Replace `-@dangerous` with explicit blocklist: `-FLUSHALL -FLUSHDB -SHUTDOWN -BGREWRITEAOF -BGSAVE -DEBUG -MIGRATE -CLUSTER -FAILOVER -REPLICAOF -SLAVEOF -SWAPDB`

**BUG-035 (IREL-01):** In check_component(), after fetching `latest` from GitHub, strip v-prefix for components whose Docker Hub images don't use v. Use associative array of known no-v components or strip v and verify via normalize logic.

**BUG-039 (IREL-04):** Increase retry from 30 to 60 in _init_dify_admin(). If init fails, add fallback instruction in _save_credentials() with INIT_PASSWORD grep command.

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `normalize_version()` in check-upstream.sh already strips v for comparison — extend for write path
- `_check()` helper in agmind.sh supports SKIP severity — use directly
- `_save_credentials()` already has template for credentials.txt — add conditional Dify block

### Established Patterns
- check-upstream.sh: components defined as pipe-delimited strings in arrays
- agmind.sh doctor: section guards with `[[ "$output_json" != "true" ]]`
- config.sh: Redis config generated via heredoc in `generate_redis_config()`

### Integration Points
- scripts/agmind.sh:302 — `.env Completeness` block reads ENV_FILE
- lib/config.sh:355-356 — Redis ACL user lines
- scripts/check-upstream.sh:223 — UPDATES[] write
- install.sh:205 — _init_dify_admin retry loop
- install.sh:246 — _save_credentials template

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase. All fixes have clear specifications from bug analysis.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
