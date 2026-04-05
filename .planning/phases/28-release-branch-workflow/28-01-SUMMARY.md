---
phase: 28-release-branch-workflow
plan: "01"
subsystem: notifications, credentials, env-templates
tags: [telegram, html-escape, credentials, files-url, ux-fix]
dependency_graph:
  requires: []
  provides: [telegram-html-escape, model-api-endpoints-in-credentials, files-url-auto-populate]
  affects: [scripts/update.sh, install.sh, lib/config.sh, templates/env.lan.template, templates/env.vpn.template, templates/env.offline.template]
tech_stack:
  added: []
  patterns: [bash-string-replacement, conditional-credentials-output, sed-placeholder-substitution]
key_files:
  created: []
  modified:
    - scripts/update.sh
    - install.sh
    - lib/config.sh
    - templates/env.lan.template
    - templates/env.vpn.template
    - templates/env.offline.template
decisions:
  - "TEI/TEI-rerank port in credentials.txt is 80 (actual container port), not 8080 (plan was incorrect)"
  - "Host-access URLs omitted for all model providers — none publish ports to host in docker-compose template"
metrics:
  duration: "~10 minutes"
  completed_date: "2026-03-29"
  tasks_completed: 2
  files_modified: 6
---

# Phase 28 Plan 01: UX Fixes (Telegram Escape, Credentials, FILES_URL) Summary

**One-liner:** HTML-escape Telegram notifications, auto-populate FILES_URL from server IP for LAN/VPN/Offline, and add active Model API Endpoints section to credentials.txt.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Telegram HTML escape + FILES_URL auto-populate | a9885f1 | scripts/update.sh, lib/config.sh, templates/env.{lan,vpn,offline}.template |
| 2 | Model API Endpoints in credentials.txt | f691cc7 | install.sh |

## What Was Built

### Task 1: Telegram HTML escape

Added `_escape_html()` to `scripts/update.sh` that escapes `&`, `<`, `>` (in that order to avoid double-escaping). The function is called at the top of `send_notification()` before the alert mode switch, so all notification paths (Telegram and webhook) receive escaped text.

### Task 1: FILES_URL auto-populate

- Templates `env.lan.template`, `env.vpn.template`, `env.offline.template` now contain `FILES_URL=__FILES_URL__` (was empty).
- `lib/config.sh` computes `files_url="http://${server_ip}"` for non-VPS profiles, then substitutes `__FILES_URL__` via sed.
- VPS template unchanged — already has `FILES_URL=https://__DOMAIN__`.

### Task 2: Model API Endpoints in credentials.txt

`_save_credentials()` in `install.sh` now writes a "Model API Endpoints:" section with conditional blocks per active provider:
- Ollama: shown when `LLM_PROVIDER=ollama` or `EMBED_PROVIDER=ollama`
- vLLM: shown when `LLM_PROVIDER=vllm`
- TEI Embedding: shown when `EMBED_PROVIDER=tei`
- TEI Reranker: shown when `ENABLE_RERANKER=true`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Corrected TEI container port from 8080 to 80**
- **Found during:** Task 2
- **Issue:** Plan specified `http://agmind-tei:8080` and `http://agmind-tei-rerank:8080`, but the actual docker-compose template runs TEI with `--port 80` and health checks confirm `localhost:80`.
- **Fix:** Used port 80 in Docker-network URLs.
- **Files modified:** install.sh
- **Commit:** f691cc7

**2. [Rule 1 - Bug] Omitted Host-access URLs for all model providers**
- **Found during:** Task 2
- **Issue:** Plan requested "Host access: http://ip:11434" style URLs, but none of Ollama, vLLM, TEI, or TEI-rerank have `ports:` mappings in the docker-compose template. Those ports are not accessible from the host.
- **Fix:** Wrote Docker-network URLs only. This avoids misleading users with non-working host URLs.
- **Files modified:** install.sh
- **Commit:** f691cc7

## Profiles Affected

| Profile | Impact |
|---------|--------|
| LAN | FILES_URL now auto-populated from server IP |
| VPN | FILES_URL now auto-populated from server IP |
| Offline | FILES_URL now auto-populated from server IP |
| VPS | Unchanged — FILES_URL=https://__DOMAIN__ already worked |

## Verification

```
grep "_escape_html" scripts/update.sh           # function + call exist
grep "Model API Endpoints" install.sh           # section exists
grep "__FILES_URL__" templates/env.{lan,vpn,offline}.template  # placeholders present
grep "files_url\|FILES_URL" lib/config.sh       # computation + sed replacement
```

## Self-Check: PASSED
