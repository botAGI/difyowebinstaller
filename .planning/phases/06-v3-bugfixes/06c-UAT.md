---
status: testing
phase: 06-v3-bugfixes (BUG-V3-011..021 + UX)
source: git log 01f744b..b5a9a6a (9 bugfix commits)
started: 2026-03-20T12:00:00Z
updated: 2026-03-20T12:00:00Z
---

## Current Test

number: 1
name: Cold Start Smoke Test
expected: |
  sudo bash install.sh runs all 9 phases without errors.
  All containers start. Phase Health passes (exit 0).
  Phase 9 (Complete) finishes — summary displayed, credentials.txt written.
awaiting: user response

## Tests

### 1. Cold Start Smoke Test
expected: sudo bash install.sh runs all 9 phases. All containers start. Phase Health passes. Phase 9 completes with summary and credentials.txt.
result: [pending]

### 2. vLLM + TEI shared GPU (BUG-V3-011)
expected: When both vLLM and TEI are enabled on same GPU, docker-compose.yml shows --gpu-memory-utilization 0.75 (not 0.90). vLLM starts without OOM. TEI healthy at ~1.6GB VRAM.
result: [pending]

### 3. Phase Health passes when all OK (BUG-V3-012)
expected: All containers [OK] → "All services running" → Phase Health exits 0. No "Phase Health failed (code: 1)" error.
result: [pending]

### 4. Resume from Phase 6+ (BUG-V3-013)
expected: Re-run install.sh, resume from phase 6+. No "unbound variable DEPLOY_PROFILE" crash in _save_credentials().
result: [pending]

### 5. agmind status (BUG-V3-014/015)
expected: agmind status shows all containers with [OK]/[!!] status. No "log_warn: command not found". ssrf_proxy, plugin_daemon, open-webui correctly matched to agmind-ssrf-proxy, agmind-plugin-daemon, agmind-openwebui.
result: [pending]

### 6. Open WebUI admin creation (BUG-V3-013/rewrite)
expected: Admin created via signup API at admin@agmind.local. webui.db deleted before first start so ENABLE_SIGNUP=true takes effect. .admin_created marker written. On re-run, skips with "already configured".
result: [pending]

### 7. Dify 1.13 init (BUG-V3-021)
expected: Dify admin initialized via two-step API (POST /console/api/init → POST /console/api/setup). .dify_initialized marker written. On re-run, skips.
result: [pending]

### 8. Per-service credentials in summary
expected: Final summary shows separate Login/Pass per service: Open WebUI, Dify Console, Grafana (with password), Portainer (with first-login hint). credentials.txt matches.
result: [pending]

### 9. health.json not a directory (BUG-V3-019)
expected: /opt/agmind/docker/nginx/health.json is a FILE, not directory. Phase 9 _install_crons() writes JSON without "Is a directory" error.
result: [pending]

### 10. Pull progress indicator (UX)
expected: During install, image pull shows progress line with count and image names (e.g. "Pulling images... 12/24 [postgres ✓ redis ✓ ...]"). No spam of individual layer progress lines.
result: [pending]

## Summary

total: 10
passed: 0
issues: 0
pending: 10
skipped: 0

## Gaps

[none yet]
