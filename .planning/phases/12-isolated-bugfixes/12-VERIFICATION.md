---
phase: 12-isolated-bugfixes
verified: 2026-03-23T21:45:00Z
status: passed
score: 7/7 must-haves verified
re_verification: false
---

# Phase 12: Isolated Bugfixes Verification Report

**Phase Goal:** Операторский инструментарий и runtime-конфиг работают корректно без ложных ошибок — doctor не показывает FAIL без прав, Redis ACL не блокирует нужные команды, upstream-отчёт показывает правильные теги, Dify admin init не прерывается на медленном железе.
**Verified:** 2026-03-23T21:45:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                     | Status     | Evidence                                                                                        |
|----|-------------------------------------------------------------------------------------------|------------|-------------------------------------------------------------------------------------------------|
| 1  | agmind doctor без sudo показывает SKIP для .env проверок с сообщением 'Запустите: sudo agmind doctor' | VERIFIED | `scripts/agmind.sh:305` — `_check SKIP ".env" "Нет прав чтения" "Запустите: sudo agmind doctor"` inside `[[ ! -r "$ENV_FILE" ]]` branch |
| 2  | agmind doctor без sudo не показывает ни одного FAIL для .env переменных                   | VERIFIED   | The `! -r` guard at line 303 routes to SKIP branch and skips entire var-iteration loop; `required_vars` for-loop only executes in `else` (readable) branch |
| 3  | Redis ACL позволяет выполнять CONFIG GET, INFO, KEYS команды                              | VERIFIED   | `lib/config.sh:355-356` — no `-@dangerous`; only explicit blocklist without CONFIG/INFO/KEYS. `grep -c '@dangerous' = 0` confirmed |
| 4  | Redis ACL блокирует FLUSHALL, FLUSHDB, SHUTDOWN                                           | VERIFIED   | Both ACL user lines contain `-FLUSHALL -FLUSHDB -SHUTDOWN` (2 matches confirmed)               |
| 5  | check-upstream.sh report показывает версии без v-prefix для Weaviate, Postgres, Redis, Grafana | VERIFIED | `scripts/check-upstream.sh:58-67` — `declare -A NO_V_PREFIX` with Weaviate, Grafana and 6 more entries; `report_latest="${latest#v}"` at line 239; `UPDATES+=` uses `report_latest` at line 241 |
| 6  | Dify admin init ждёт до 5 минут (60 попыток x 5 сек)                                     | VERIFIED   | `install.sh:205` — `while [[ $attempts -lt 60 ]]`; `install.sh:210` — `if [[ $attempts -ge 60 ]]`; `install.sh:211` — `log_warn "Dify API not ready after 5 min"`. Old value 30 is absent |
| 7  | Если Dify init не удался — credentials.txt содержит fallback инструкцию                   | VERIFIED   | `install.sh:275-280` — `if [[ ! -f "${INSTALL_DIR}/.dify_initialized" ]]` block inside `_save_credentials()` writes "Dify Admin (ручная настройка)" section with URL and INIT_PASSWORD grep command |

**Score:** 7/7 truths verified

### Required Artifacts

| Artifact                       | Expected                                        | Status     | Details                                                                      |
|--------------------------------|-------------------------------------------------|------------|------------------------------------------------------------------------------|
| `scripts/agmind.sh`            | .env readability guard in cmd_doctor()          | VERIFIED   | `! -r "$ENV_FILE"` guard at line 303; SKIP branch at lines 303-305; readable else-branch preserves all existing logic lines 306-335 |
| `lib/config.sh`                | Granular Redis ACL blocklist                    | VERIFIED   | Lines 355-356: both `user default` and `user agmind` use 12-command explicit blocklist; comment updated at line 354 |
| `scripts/check-upstream.sh`    | v-prefix stripping in check_component output    | VERIFIED   | `declare -A NO_V_PREFIX` at line 58; `report_latest` local var at line 237; strip logic at line 239; UPDATES uses stripped value at line 241 |
| `install.sh`                   | Extended Dify init timeout + fallback credentials | VERIFIED | `attempts -lt 60` at line 205; `attempts -ge 60` at line 210; `_save_credentials()` fallback block at lines 275-280 |

### Key Link Verification

| From                        | To                         | Via                                              | Status   | Details                                                                                                |
|-----------------------------|----------------------------|--------------------------------------------------|----------|--------------------------------------------------------------------------------------------------------|
| `scripts/agmind.sh`         | .env Completeness block     | readability check before var iteration           | WIRED    | Outer `[[ -f "$ENV_FILE" ]]` at line 302, inner `[[ ! -r "$ENV_FILE" ]]` at line 303; SKIP issued immediately, else-branch runs var loops |
| `lib/config.sh`             | Redis ACL user lines        | explicit command blocklist replacing -@dangerous | WIRED    | Heredoc at lines 355-356 contains explicit `-FLUSHALL -FLUSHDB -SHUTDOWN -BGREWRITEAOF -BGSAVE -DEBUG -MIGRATE -CLUSTER -FAILOVER -REPLICAOF -SLAVEOF -SWAPDB`; zero occurrences of `@dangerous` |
| `scripts/check-upstream.sh` | UPDATES array               | v-prefix strip before writing to report          | WIRED    | `NO_V_PREFIX[$name]+x` lookup at line 238; `report_latest="${latest#v}"` at line 239; `UPDATES+=` and `echo` both use `report_latest` at lines 241-242; comparison (`is_newer`, `classify_change`) still uses original `$latest` |
| `install.sh`                | `_save_credentials()`       | fallback Dify init instruction when .dify_initialized missing | WIRED | `[[ ! -f "${INSTALL_DIR}/.dify_initialized" ]]` at line 275; block prints manual URL (line 279) and INIT_PASSWORD grep command (line 280) inside the `{ ... } > credentials.txt` redirection block |

### Requirements Coverage

| Requirement | Source Plan | Description                                                              | Status    | Evidence                                                            |
|-------------|-------------|--------------------------------------------------------------------------|-----------|---------------------------------------------------------------------|
| OPUX-01     | 12-01-PLAN  | agmind doctor показывает SKIP с "Запустите: sudo agmind doctor" вместо ложных FAIL | SATISFIED | `scripts/agmind.sh:303-305` — readability guard + SKIP call confirmed present and wired |
| OPUX-02     | 12-01-PLAN  | Redis ACL точечный blocklist вместо -@dangerous, оставляя CONFIG/INFO/KEYS | SATISFIED | `lib/config.sh:355-356` — zero `@dangerous`, 12-command explicit blocklist on both user lines |
| IREL-01     | 12-02-PLAN  | check-upstream.sh стрипает v-prefix для компонентов без v в Docker-образах | SATISFIED | `scripts/check-upstream.sh:58-67,237-242` — NO_V_PREFIX array + report_latest strip |
| IREL-04     | 12-02-PLAN  | Dify admin init ждёт 60 retries; fallback в credentials.txt              | SATISFIED | `install.sh:205,210,211,275-280` — 60-retry loop + fallback credentials block |

All four requirement IDs declared in PLAN frontmatter are covered. No orphaned Phase 12 requirements found in REQUIREMENTS.md — traceability table confirms IREL-01, IREL-04, OPUX-01, OPUX-02 all map to Phase 12 and are marked Complete.

### Anti-Patterns Found

| File           | Line | Pattern       | Severity | Impact                                                      |
|----------------|------|---------------|----------|-------------------------------------------------------------|
| `lib/config.sh` | 192  | "placeholder" | Info     | Pre-existing comment about template variable substitution (`sed` replacing `__VAR__` tokens). Not a stub — unrelated to Phase 12 changes. |
| `install.sh`   | 303  | "placeholder" | Info     | Pre-existing comment about initial health.json sentinel file. Not a stub — unrelated to Phase 12 changes. |

No blockers. No warnings. Both findings are benign pre-existing comments, not introduced by Phase 12.

### Syntax Validation

All four modified files pass `bash -n`:

| File                          | Syntax Check |
|-------------------------------|-------------|
| `scripts/agmind.sh`           | PASS        |
| `lib/config.sh`               | PASS        |
| `scripts/check-upstream.sh`   | PASS        |
| `install.sh`                  | PASS        |

### Commit Verification

All four commits documented in SUMMARYs exist in git history:

| Commit    | Task                                                          |
|-----------|---------------------------------------------------------------|
| `491d383` | fix(12-01): add .env readability guard in cmd_doctor (OPUX-01) |
| `a1b1c7c` | fix(12-01): replace Redis -@dangerous with explicit ACL blocklist (OPUX-02) |
| `f2f5a5d` | fix(12-02): strip v-prefix in check-upstream.sh report for no-v components |
| `15e03d0` | fix(12-02): increase Dify init timeout to 5 min + fallback credentials |

### Human Verification Required

The following behaviors require runtime to confirm (all automated checks pass):

#### 1. agmind doctor SKIP behaviour without sudo

**Test:** Run `agmind doctor` as a non-root user on a system where `.env` is owned by root with `chmod 600`.
**Expected:** `.env Completeness:` section shows exactly one SKIP line "Нет прав чтения" with hint "Запустите: sudo agmind doctor". Zero FAIL lines for env vars.
**Why human:** Can't simulate file ownership/permission combinations in static analysis.

#### 2. Redis ACL allows CONFIG/INFO/KEYS post-deploy

**Test:** After `install.sh` runs `generate_redis_config()`, connect to Redis with the generated credentials and execute `CONFIG GET maxmemory`, `INFO server`, `KEYS *`.
**Expected:** All three commands succeed without ACL error.
**Why human:** Requires live Redis container with generated config file applied.

#### 3. FLUSHALL/FLUSHDB/SHUTDOWN blocked in Redis

**Test:** Run `FLUSHALL` and `SHUTDOWN NOSAVE` against the Redis container.
**Expected:** Both return `NOPERM` ACL error.
**Why human:** Requires live Redis runtime.

#### 4. Weaviate version in upstream report shows bare tag

**Test:** Run `scripts/check-upstream.sh` against a repo where Weaviate has a new GitHub release (e.g., `v1.37.0`) while current installed is `1.36.6`.
**Expected:** Report shows `1.37.0` (no `v` prefix) in the update entry.
**Why human:** Requires network access to GitHub API and an available Weaviate update.

#### 5. Dify init timeout and fallback credentials.txt

**Test:** Install on a slow machine where Dify takes > 150s to start. Let the install complete.
**Expected:** Init loop waits full 5 minutes (300s). If Dify still not ready, `credentials.txt` contains "Dify Admin (ручная настройка)" section with the `/install` URL and INIT_PASSWORD grep command.
**Why human:** Requires slow-hardware install environment.

### Gaps Summary

No gaps found. All 7 observable truths verified. All 4 artifacts exist, are substantive, and are properly wired. All 4 requirement IDs (OPUX-01, OPUX-02, IREL-01, IREL-04) satisfied. All syntax checks pass. All 4 commits confirmed in git log.

---

_Verified: 2026-03-23T21:45:00Z_
_Verifier: Claude (gsd-verifier)_
