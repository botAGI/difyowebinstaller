# Phase 34: Bugfixes — image validation, retry logic, service mapping dedup - Context

**Gathered:** 2026-04-04
**Status:** Ready for planning

<domain>
## Phase Boundary

Infrastructure bugfix phase: fix known reliability issues in image validation, container retry logic, release tag persistence, and deduplicate service mapping definitions.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion

All implementation choices are at Claude's discretion — pure infrastructure/bugfix phase. Key targets:

- BUG-V3-030: `_check_image_exists()` timeout 10s→20s, configurable via `IMAGE_VALIDATION_TIMEOUT`
- BUG-V3-043: `_retry_stuck_containers()` exponential backoff 10s→20s→40s
- BUG-V3-044: RELEASE tag fallback when RELEASE file missing (git describe or versions.env hash)
- Parallel image validation with max 5 concurrent background jobs
- Extract shared service mappings to `lib/service-map.sh`

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/compose.sh` — contains `_check_image_exists()`, `_get_registry_token()`, `validate_images_exist()`, `_retry_stuck_containers()`
- `lib/health.sh` — contains `get_service_list()` with dynamic service discovery from .env
- `scripts/update.sh` — contains `NAME_TO_SERVICES`, `NAME_TO_VERSION_KEY`, `SERVICE_GROUPS` mappings
- `lib/common.sh` — logging functions (`log_info`, `log_warn`, `log_error`, `log_success`)

### Established Patterns
- Bash 5+ strict mode (`set -euo pipefail`), shellcheck-compliant
- Functions prefixed with `_` are internal helpers
- Environment variables for configuration (e.g., `SKIP_IMAGE_VALIDATION`)
- curl with `--max-time` for HTTP requests

### Integration Points
- `lib/compose.sh` sourced by `install.sh` during installation
- `lib/health.sh` sourced by `scripts/agmind.sh` CLI and `install.sh`
- `scripts/update.sh` standalone script called by `agmind update`
- New `lib/service-map.sh` must be sourced by both `health.sh` and `update.sh`

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure bugfix phase.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
