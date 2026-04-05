---
status: complete
phase: 06-v3-bugfixes
source: direct bugfix session (BUG-V3-001 through BUG-V3-006)
started: 2026-03-19T12:00:00Z
updated: 2026-03-19T12:05:00Z
---

## Current Test

[testing complete]

## Tests

### 1. BUG-001 — nginx rate limit syntax
expected: templates/nginx.conf.template uses `rate=6r/m` for login zone, not `rate=1r/10s`
result: pass

### 2. BUG-002 — wizard env override only in NON_INTERACTIVE
expected: _wizard_llm_provider, _wizard_embed_provider, _wizard_llm_model, _wizard_profile, _wizard_domain all check `NON_INTERACTIVE == true` before skipping on pre-set env vars
result: pass

### 3. BUG-003 — pipelines service in docker-compose
expected: docker-compose.yml has `pipelines` service (ghcr.io/open-webui/pipelines), open-webui has PIPELINES_URLS env and depends_on pipelines, health.sh uses `pipelines` (not `pipeline`), versions.env has PIPELINES_VERSION
result: pass

### 4. BUG-004 — phase_health error handling
expected: phase_health() does NOT use `|| true` after wait_healthy. _check_critical_services uses `return 1` not `exit 1`. run_phase_with_timeout uses `local rc=0; cmd || rc=$?` pattern (no SC2155)
result: pass

### 5. BUG-005 — wizard strings in Russian
expected: All user-facing strings in wizard.sh are in Russian. No English menu labels, prompts, or messages remain.
result: pass

### 6. BUG-006 — final summary with credentials
expected: install.sh has _show_final_summary() function showing ASCII box with URLs, login, password, profile, LLM info, container count, paths to credentials and logs. phase_complete() calls _show_final_summary() instead of bare log_success.
result: pass

## Summary

total: 6
passed: 6
issues: 0
pending: 0
skipped: 0

## Gaps

[none]
