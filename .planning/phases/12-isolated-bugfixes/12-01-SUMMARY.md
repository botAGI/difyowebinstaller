---
phase: 12-isolated-bugfixes
plan: "01"
subsystem: infra
tags: [redis, acl, agmind-doctor, diagnostics, security]

# Dependency graph
requires: []
provides:
  - ".env readability guard in cmd_doctor() preventing false FAIL when run without root"
  - "Redis ACL explicit blocklist replacing -@dangerous category block"
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Guard readability before reading env files in diagnostic scripts"
    - "Use explicit Redis command blocklists instead of -@dangerous category"

key-files:
  created: []
  modified:
    - scripts/agmind.sh
    - lib/config.sh

key-decisions:
  - "SKIP (not FAIL) when .env is unreadable without sudo — avoids false positives in diagnostics"
  - "Explicit Redis ACL blocklist (12 commands) instead of -@dangerous so CONFIG/INFO/KEYS stay allowed for monitoring"

patterns-established:
  - "Pattern: Check file readability before iterating its contents in diagnostic functions"
  - "Pattern: Prefer explicit deny-lists over category-based blocks in security configs"

requirements-completed: [OPUX-01, OPUX-02]

# Metrics
duration: 15min
completed: 2026-03-23
---

# Phase 12 Plan 01: Isolated Bugfixes (OPUX-01, OPUX-02) Summary

**False-positive FAIL eliminated in agmind doctor via .env readability guard; Redis ACL -@dangerous replaced with 12-command explicit blocklist allowing CONFIG/INFO/KEYS for monitoring**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-23T00:00:00Z
- **Completed:** 2026-03-23T21:25:33Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `if [[ ! -r "$ENV_FILE" ]]` guard in cmd_doctor() — when .env is root-owned (chmod 600), operator gets SKIP with "Нет прав чтения" and hint "Запустите: sudo agmind doctor" instead of false FAIL per env var
- Replaced `-@dangerous` category block with explicit list of 12 truly dangerous Redis commands: FLUSHALL, FLUSHDB, SHUTDOWN, BGREWRITEAOF, BGSAVE, DEBUG, MIGRATE, CLUSTER, FAILOVER, REPLICAOF, SLAVEOF, SWAPDB
- CONFIG, INFO, KEYS are now allowed — monitoring tools (Prometheus Redis exporter, agmind doctor) can query Redis stats
- All existing logic in both files left untouched; both pass `bash -n` syntax check

## Task Commits

Each task was committed atomically:

1. **Task 1: Add .env readability guard in agmind doctor (OPUX-01)** - `491d383` (fix)
2. **Task 2: Replace Redis -@dangerous with explicit ACL blocklist (OPUX-02)** - `a1b1c7c` (fix)

**Plan metadata:** (docs commit follows this summary)

## Files Created/Modified

- `scripts/agmind.sh` - Added readability guard in `.env Completeness` block inside cmd_doctor()
- `lib/config.sh` - Updated both ACL user lines in generate_redis_config() heredoc, updated comment

## Decisions Made

- Kept SKIP (not WARN) for unreadable .env — SKIP correctly signals "check was not performed" vs WARN which implies partial data; matches existing SKIP semantics in the codebase
- Chose 12-command explicit blocklist based on Redis docs "dangerous" category contents, excluding commands needed by Prometheus/monitoring (CONFIG GET, INFO, KEYS)
- Comment updated to say "explicit blocklist instead of category-based block" without repeating the literal string `-@dangerous` to keep acceptance criteria grep clean

## Deviations from Plan

None — plan executed exactly as written.

The comment wording was adjusted slightly (removed the literal `-@dangerous` from comment text) because the acceptance criteria required `grep -c '@dangerous' = 0` while the plan's suggested comment text contained that string. The intent ("explain we use explicit blocklist because CONFIG/INFO/KEYS must be allowed") was preserved.

## Issues Encountered

Minor: Plan's suggested comment text `"not -@dangerous which blocks CONFIG/INFO/KEYS"` contained the literal string `@dangerous`, which would have caused the acceptance criteria check `grep -c '@dangerous' lib/config.sh | grep -q '^0$'` to return 1 instead of 0. Adjusted comment to convey the same meaning without the literal token.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- Phase 12 Plan 02 (IREL-01: check-upstream.sh v-prefix strip) and Plan 03 (IREL-04: Dify init timeout) are independent and can proceed
- Both OPUX fixes are additive/safe — no restart of Redis or agmind service needed for the ACL change to take effect on next `generate_redis_config()` call

---
*Phase: 12-isolated-bugfixes*
*Completed: 2026-03-23*

## Self-Check: PASSED

- FOUND: scripts/agmind.sh
- FOUND: lib/config.sh
- FOUND: .planning/phases/12-isolated-bugfixes/12-01-SUMMARY.md
- FOUND commit: 491d383 (fix(12-01): add .env readability guard)
- FOUND commit: a1b1c7c (fix(12-01): replace Redis -@dangerous with explicit ACL blocklist)
