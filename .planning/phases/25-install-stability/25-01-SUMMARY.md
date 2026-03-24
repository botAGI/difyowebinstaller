---
phase: 25-install-stability
plan: "01"
subsystem: health
tags: [gpu-wait, progress, inactivity-timeout, telegram, html-escape]
dependency_graph:
  requires: []
  provides: [progress-aware-gpu-wait, html-safe-telegram-alerts]
  affects: [lib/health.sh]
tech_stack:
  added: []
  patterns:
    - bash associative arrays for per-service inactivity tracking
    - bash parameter expansion for HTML entity escaping (no subshell)
    - docker compose logs --tail=1 --no-log-prefix for progress parsing
key_files:
  created: []
  modified:
    - lib/health.sh
decisions:
  - "_parse_gpu_progress() reads last log line via docker compose logs --tail=1 --no-log-prefix to show real download/load progress instead of blind timer"
  - "60s inactivity (no new log line) marks GPU service as stalled; hard safety cap gpu_timeout=600s preserved as outer while condition"
  - "HTML escaping uses bash parameter expansion order: & first, then < and > to prevent double-encoding"
metrics:
  duration: "1m 58s"
  completed_date: "2026-03-25"
  tasks_completed: 2
  tasks_total: 2
  files_changed: 1
---

# Phase 25 Plan 01: GPU Health Wait Progress Parsing + Telegram HTML Escape Summary

**One-liner:** Progress-aware GPU wait reads docker log lines for Downloading/Loading/Pulling status with 60s inactivity stall detection, and Telegram alerts escape `&`, `<`, `>` via bash parameter expansion before sending.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | GPU health wait with log-based progress and inactivity timeout | 29f84ce | lib/health.sh |
| 2 | Telegram HTML entity escaping in send_alert | d0897d9 | lib/health.sh |

## What Was Built

### Task 1 — GPU progress display + inactivity timeout

Added `_parse_gpu_progress(svc, compose_file)` helper above `wait_healthy()` that:
- Reads the last log line via `docker compose logs --tail=1 --no-log-prefix`
- Matches vLLM patterns: `downloading|fetching` → "Downloading X%", `loading model|loading weights|loading safetensors` → "Loading model...", `warming up|compilation` → "Warming up..."
- Matches Ollama patterns: `pulling.*manifest|pulling.*layer|verifying` → "Pulling X%"
- Matches TEI patterns: `downloading model|downloading.*shard|warming up model` → "Loading X%"
- Falls back to "starting..." or "waiting..." if no pattern matches

Replaced GPU wait loop's blind second counter with:
- Per-service associative arrays `last_log_hash[$svc]` and `last_change_ts[$svc]` (bash 5+)
- `inactivity_timeout=60`: service marked stalled when no new log line for 60s
- Progress display: `printf "\r  %-80s" "${progress_info}"` showing `svc: progress | svc2: progress`
- Hard safety cap `gpu_timeout` (default 600s) preserved as while-loop condition

### Task 2 — Telegram HTML escaping

In `send_alert()` telegram branch, added local variable `tg_message` with escaping:
```bash
tg_message="${tg_message//&/&amp;}"   # & first — prevent double-encoding
tg_message="${tg_message//</&lt;}"
tg_message="${tg_message//>/&gt;}"
```
curl `-d "text=..."` now uses `${tg_message}` instead of raw `${message}`. Webhook branch unchanged.

## Verification

- `bash -n lib/health.sh` — PASS (no syntax errors)
- `grep -c '_parse_gpu_progress' lib/health.sh` → 3 (definition + 2 call sites)
- `grep 'inactivity_timeout=60'` — PASS
- `grep 'last_change_ts'` — PASS (3 occurrences: declaration, init, update)
- `grep 'docker compose.*logs.*--tail=1.*--no-log-prefix'` — PASS (2 occurrences)
- `grep -E 'Downloading|Loading model|Pulling'` — PASS
- `grep 'gpu_timeout'` — PASS (hard safety cap preserved at line 153/259)
- `grep '&amp;\|&lt;\|&gt;\|tg_message'` — PASS

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

Files exist:
- lib/health.sh — FOUND (modified)
- .planning/phases/25-install-stability/25-01-SUMMARY.md — FOUND (this file)

Commits exist:
- 29f84ce — feat(25-01): GPU health wait with log-based progress and inactivity timeout
- d0897d9 — feat(25-01): Telegram HTML entity escaping in send_alert
