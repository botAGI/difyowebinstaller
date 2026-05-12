# 0004. Dify Plugin Daemon Pinned at 0.5.3-local

**Date:** 2026-04-25
**Status:** Accepted

## Context and Problem Statement

Dify plugin daemon manages lifecycle and routing for Dify Marketplace and custom plugins,
including the `openai_api_compatible` connector used for vLLM and TEI endpoints.
Newer releases introduced regressions that break agent tool-calling and migration tooling.

## Decision Outcome

**Chosen option:** "Pin plugin daemon at `0.5.3-local`; do not upgrade until upstream ships a fixed release"

**Reason:** `0.5.3-local` is the last known-good build for the AGmind Dify version:
- `0.5.4` and `0.5.5`: GitHub issue #640 — null content in responses causes agent
  tool-calling to break silently (tools return empty results).
- `0.5.6`: auto-migrate removed from daemon; CLI entrypoint absent from image —
  database schema migrations cannot run, breaking fresh installs and upgrades.

## Consequences

**Good:**
- Stable agent tool-calling and working automatic schema migrations.
- `openai_api_compatible` plugin (v0.0.46+) operates correctly for embedding-only
  models and LLM chat flows.

**Bad:**
- Newer plugin-daemon features (released after 0.5.4) cannot be used until upstream
  ships a release that fixes both issues.
- Unlock condition: upstream releases 0.5.7+ with fixes for #640 and auto-migrate restoration.

## References

- Dify GitHub issue #640 (null content — agent tool-calling broken)
- Dify GitHub issue #521 (auto-migrate removed in 0.5.6)
- `docs/compatibility-matrix.md` (component version table)
- `templates/versions.env` — `PLUGIN_DAEMON_VERSION` pin
