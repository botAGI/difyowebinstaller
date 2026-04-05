---
phase: 25-install-stability
verified: 2026-03-24T22:45:11Z
status: passed
score: 5/5 must-haves verified
re_verification: false
gaps: []
---

# Phase 25: Install Stability — Verification Report

**Phase Goal:** Установка завершается надёжно в сложных условиях — health wait не застревает на GPU-контейнерах, TLS через letsencrypt не ломается из-за race condition, Squid в LAN не блокирует внутренние webhook-вызовы, Telegram-алерты не ломаются на спецсимволах, credentials.txt честно предупреждает об ограничениях.
**Verified:** 2026-03-24T22:45:11Z
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 1 | GPU health wait shows real progress from docker logs (Downloading %, Loading model) instead of blind second counter | VERIFIED | `_parse_gpu_progress()` at lib/health.sh:105; used at line 316; matches vLLM/Ollama/TEI patterns |
| 2 | GPU health wait times out on 60s inactivity (no new log lines) instead of absolute timeout | VERIFIED | `inactivity_timeout=60` at line 251; per-service `last_log_hash`/`last_change_ts` arrays at lines 249-256; stall detection at lines 292-299 |
| 3 | Telegram alert with HTML special chars (`<`, `>`, `&`) delivers without Bot API error 400 | VERIFIED | bash param expansion at lines 546-548: `&` escaped first (`&amp;`), then `<` (`&lt;`), then `>` (`&gt;`); `tg_message` used in curl at line 551 |
| 4 | With TLS_MODE=letsencrypt nginx starts immediately with self-signed placeholder cert; certbot obtains real cert after nginx is healthy; nginx reloads | VERIFIED | `letsencrypt)` case in handle_tls_config calls `_generate_self_signed_cert "$ssl_dir"` (lib/config.sh:608); placeholder path `/etc/nginx/ssl/cert.pem` at line 390; `_obtain_letsencrypt_cert()` called inside `phase_health()` at install.sh:141; `certbot certonly --webroot` at line 355; `nginx -s reload` at line 372 |
| 5 | In LAN profile Dify sandbox can call webhooks on RFC1918 addresses through Squid; VPS/VPN still block RFC1918 | VERIFIED | `if [[ "${DEPLOY_PROFILE:-vps}" == "lan" \|\| ... == "offline" ]]` at lib/config.sh:496 skips `acl private_nets` blocks; else branch adds `http_access deny private_nets` for VPS/VPN; metadata (169.254.x) always blocked |
| 6 | credentials.txt contains bilingual disclaimer about passwords potentially being stale after UI changes | VERIFIED | Russian disclaimer at install.sh:333-334; English disclaimer at lines 335-336; inside `_save_credentials()` subshell before `chmod 600` at line 338 |

**Score:** 6/6 truths verified (requirements ISTB-01 through ISTB-05 all covered)

---

### Required Artifacts

| Artifact | Provided By | Status | Details |
|----------|-------------|--------|---------|
| `lib/health.sh` | PLAN-01 | VERIFIED | `_parse_gpu_progress` defined (line 105) and called (line 316); inactivity tracking at lines 249-299; Telegram HTML escaping at lines 545-551; `bash -n` passes |
| `lib/config.sh` | PLAN-02 | VERIFIED | `_generate_self_signed_cert "$ssl_dir"` in letsencrypt case (line 608); placeholder cert path at line 390; `_generate_squid_config` profile-aware at line 496; `bash -n` passes |
| `install.sh` | PLAN-02 | VERIFIED | `_obtain_letsencrypt_cert()` defined at line 344; called in `phase_health()` at line 141; credentials disclaimer at lines 332-336; `bash -n` passes |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/health.sh:_parse_gpu_progress` | `docker compose logs` | `docker compose -f "$compose_file" logs --tail=1 --no-log-prefix "$svc"` | WIRED | Lines 109 and 289; return value used at line 316 |
| `lib/health.sh:send_alert` (telegram) | Telegram Bot API | bash param expansion `tg_message=${tg_message//&/&amp;}` etc. | WIRED | Lines 545-548; `tg_message` used in curl `-d "text=${tg_message}"` at line 551 |
| `lib/config.sh:handle_tls_config` | `openssl req` (self-signed) | `_generate_self_signed_cert "$ssl_dir"` in letsencrypt case | WIRED | Line 608; function defined at line 616 |
| `install.sh:_obtain_letsencrypt_cert` | `docker compose exec certbot certbot certonly --webroot` | post-compose certbot obtain + nginx reload | WIRED | Function at line 344; webroot call at line 355; nginx reload at line 372; called from `phase_health()` at line 141 |
| `lib/config.sh:_generate_squid_config` | squid.conf | `DEPLOY_PROFILE == "lan"\|"offline"` conditional skips RFC1918 blocks | WIRED | Line 496; LAN/Offline: RFC1918 allowed; else: `acl private_nets` + `http_access deny private_nets` added |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| ISTB-01 | PLAN-01 | Health wait парсит Docker logs GPU-контейнеров, таймаут по отсутствию прогресса (60s) | SATISFIED | `_parse_gpu_progress` + `inactivity_timeout=60` + `last_change_ts` in lib/health.sh |
| ISTB-02 | PLAN-02 | При TLS=letsencrypt nginx стартует с self-signed placeholder; certbot получает cert; nginx reload — без race | SATISFIED | `_generate_self_signed_cert` in letsencrypt case + `_obtain_letsencrypt_cert()` in install.sh |
| ISTB-03 | PLAN-02 | В LAN профиле Squid не блокирует RFC1918 адреса для webhook-вызовов | SATISFIED | Profile-aware `_generate_squid_config` with `DEPLOY_PROFILE == "lan"\|"offline"` check |
| ISTB-04 | PLAN-01 | Telegram notifications экранируют HTML-спецсимволы (`<`, `>`, `&`) перед отправкой | SATISFIED | Bash param expansion escaping in send_alert telegram branch, lines 545-551 |
| ISTB-05 | PLAN-02 | credentials.txt содержит disclaimer: пароли могут устареть при смене через UI | SATISFIED | Bilingual disclaimer inside `_save_credentials()` at install.sh:332-336 |

No orphaned requirements — all 5 ISTB IDs from REQUIREMENTS.md are claimed and satisfied.

---

### Anti-Patterns Found

No blockers. The word "placeholder" appears in comments and log messages describing the intentional design (self-signed placeholder cert), not as stub implementations. No TODO/FIXME/empty handlers found in modified code paths.

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| lib/config.sh:388 | Comment "Initially use placeholder cert" | Info | Design comment, not a stub |
| lib/config.sh:607 | Log "generating placeholder cert for initial startup" | Info | Intentional — describes the TLS bootstrap pattern |

---

### Human Verification Required

#### 1. GPU Progress Display Rendering

**Test:** Run install on a machine with GPU; watch terminal output during vLLM/Ollama startup.
**Expected:** Terminal shows "vllm: Downloading 47% | ollama: Loading model..." updating in place via `\r` instead of seconds counter.
**Why human:** Cannot verify terminal rendering behavior or live docker log streaming programmatically.

#### 2. TLS Race Condition End-to-End

**Test:** Deploy with `TLS_MODE=letsencrypt` and a real domain. Check that nginx responds on HTTPS before certbot completes, then check that the cert switches to Let's Encrypt after certbot run.
**Expected:** `curl -k https://DOMAIN/` returns 200 immediately; after `_obtain_letsencrypt_cert` completes, `curl https://DOMAIN/` (no -k) returns 200 with valid LE cert.
**Why human:** Requires real domain, real certbot ACME challenge, external DNS resolution — cannot simulate in static analysis.

#### 3. Squid LAN Webhook Passthrough

**Test:** In LAN profile, trigger a Dify workflow that calls a webhook on a local `192.168.x.x` address.
**Expected:** Webhook request succeeds through Squid SSRF proxy; same workflow fails on VPS profile (connection refused/blocked).
**Why human:** Requires live Dify sandbox + Squid container interaction with RFC1918 target.

---

## Gaps Summary

No gaps. All five requirements (ISTB-01 through ISTB-05) are implemented, substantive (not stubs), and properly wired in the execution flow. All three files pass `bash -n` syntax check. Commits exist in git history: `29f84ce` (GPU health), `d0897d9` (Telegram HTML escape), `e8f027d` (TLS race), `5879969` (Squid LAN), `026463d` (credentials disclaimer).

---

_Verified: 2026-03-24T22:45:11Z_
_Verifier: Claude (gsd-verifier)_
