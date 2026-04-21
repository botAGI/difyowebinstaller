---
phase: 02-dual-spark-detect-master-worker-wizard-compose-split
plan: "01"
subsystem: infra
tags: [lldp, lldpcli, fping, peer-detection, qsfp, dgx-spark, bash, unit-test]

requires:
  - phase: 01-mdns-preflight-hardening
    provides: "preflight_checks (sets DETECTED_NETWORK), _assert_no_foreign_mdns, phase_diagnostics structure"

provides:
  - "_ensure_lldpd: auto-install + restart lldpd with DETECTED_NETWORK air-gap guard"
  - "_peer_ping_fallback: fping scan of first 10 IPs on QSFP subnet"
  - "hw_detect_peer: LLDP primary + fping fallback; exports PEER_HOSTNAME/PEER_IP/PEER_USER"
  - "phase_diagnostics integration: peer detection runs after preflight_checks"
  - "Unit test 6 scenarios + mock/fixture infrastructure for Plans 02-02..02-04"

affects:
  - "02-02 (wizard cluster mode — consumes PEER_HOSTNAME/PEER_IP/PEER_USER)"
  - "02-04 (SSH trust — reuses tests/mocks/ssh and tests/mocks/curl)"

tech-stack:
  added:
    - "lldpcli (lldpd 1.0.18) — LLDP neighbor discovery via JSON output"
    - "fping — subnet ping sweep (300ms/target, 10 targets = 3s budget)"
    - "jq startswith() — IP prefix filter replacing broken gsub+regex approach"
  patterns:
    - "DETECTED_NETWORK env var gate: soft-dependency functions check existing env instead of re-probing network (idempotent, no 3-sec curl delay)"
    - "PATH-prepend mock harness: tests/mocks/ overrides real binaries in unit test subshells"
    - "Soft-return 0 pattern: peer detection functions always exit 0, never block install"

key-files:
  created:
    - tests/unit/test_hw_detect_peer.sh
    - tests/fixtures/lldp_peer.json
    - tests/fixtures/lldp_self_only.json
    - tests/fixtures/lldp_empty.json
    - tests/mocks/lldpcli
    - tests/mocks/fping
    - tests/mocks/apt-get
    - tests/mocks/curl
    - tests/mocks/ssh
  modified:
    - lib/detect.sh (+146 lines: _ensure_lldpd, _peer_ping_fallback, hw_detect_peer)
    - install.sh (+5 lines: _ensure_lldpd + hw_detect_peer in phase_diagnostics)
    - tests/mocks/hostname (MOCK_HOSTNAME env override for no-arg calls)

key-decisions:
  - "lldpcli -f json instead of lldpctl: lldpctl produces incompatible JSON on lldpd 1.0.18 (RESEARCH.md §1 live-verified)"
  - "systemctl restart lldpd mandatory: QSFP interface enp1s0f0np0 not in neighbour table without restart (lldpd 1.0.18 quirk)"
  - "DETECTED_NETWORK env var gate in _ensure_lldpd instead of curl archive.ubuntu.com: eliminates 3-sec delay on offline hosts (BLOCKER-2 fix)"
  - "jq startswith() for IP prefix filter: gsub+regex produced double-backslash escape failures; startswith is cleaner and correct"
  - "fping first 10 IPs only: QSFP direct-attach = max 2 nodes; 300ms/target x 10 = 3s budget compliance"
  - "PEER_USER default agmind2: live-verified on spark-69a2 (not agmind); overridable via AGMIND_PEER_USER"

patterns-established:
  - "Soft-return 0: all peer detection functions return 0 on every branch (offline, no lldpd, no peer, partial data)"
  - "MOCK_HOSTNAME env override in tests/mocks/hostname: enables self-filter testing without modifying real hostname"
  - "Wave-1 mock infrastructure: curl/ssh mocks created now for reuse in Plans 02-03/02-04"

requirements-completed:
  - PEER-01
  - PEER-02
  - PEER-03

duration: ~20min
completed: 2026-04-21
---

# Phase 02 Plan 01: hw_detect_peer + lldpd — Wave 1 Summary

**LLDP-first peer discovery via lldpcli -f json + fping fallback on QSFP subnet; exports PEER_HOSTNAME/PEER_IP/PEER_USER with air-gap guard and 3-sec budget compliance**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-04-21T00:00:00Z
- **Completed:** 2026-04-21T19:48:38Z
- **Tasks:** 3
- **Files modified/created:** 11

## Accomplishments

- Three new functions in `lib/detect.sh`: `_ensure_lldpd`, `_peer_ping_fallback`, `hw_detect_peer` — soft-return 0 on every code path
- `phase_diagnostics` in `install.sh` now calls `_ensure_lldpd` + `hw_detect_peer` after `preflight_checks` — PEER_HOSTNAME/PEER_IP/PEER_USER available for wizard
- Unit test `tests/unit/test_hw_detect_peer.sh` passes 6/6 scenarios with full mock/fixture infrastructure; curl+ssh mocks pre-built for Plans 02-04

## Task Commits

1. **Task 1: _ensure_lldpd + hw_detect_peer + _peer_ping_fallback** - `4e0faad` (feat)
2. **Task 2: phase_diagnostics integration** - `c7bd482` (feat)
3. **Task 3: unit tests + mocks + fixtures** - `6a3ffb0` (test)

## Test Output

```
=== test_hw_detect_peer.sh ===

  PASS: LLDP happy path => H='spark-69a2' IP='192.168.100.2' U='agmind2'
  PASS: LLDP self-only + fping finds peer => H='' IP='192.168.100.2' U='agmind2'
  PASS: LLDP empty + fping finds peer => H='' IP='192.168.100.2' U='agmind2'
  PASS: No peer at all (single mode) => H='' IP='' U='agmind2'
  PASS: LLDP unavailable, fping finds peer => H='' IP='192.168.100.5' U='agmind2'
  PASS: LLDP self-only + fping empty => H='' IP='' U='agmind2'

=== Summary: 6 passed, 0 failed ===
```

## Files Created/Modified

- `/home/agmind/AGmind/lib/detect.sh` — +146 lines: PEER DETECTION block (3 functions)
- `/home/agmind/AGmind/install.sh` — +5 lines: `_ensure_lldpd` + `hw_detect_peer` in `phase_diagnostics`
- `/home/agmind/AGmind/tests/unit/test_hw_detect_peer.sh` — 6-scenario unit test driver
- `/home/agmind/AGmind/tests/fixtures/lldp_peer.json` — happy-path LLDP fixture (spark-69a2)
- `/home/agmind/AGmind/tests/fixtures/lldp_self_only.json` — self-detection fixture (spark-3eac)
- `/home/agmind/AGmind/tests/fixtures/lldp_empty.json` — empty LLDP response
- `/home/agmind/AGmind/tests/mocks/lldpcli` — MOCK_LLDP_SCENARIO-driven fixture output
- `/home/agmind/AGmind/tests/mocks/fping` — MOCK_FPING_ALIVE echo mock
- `/home/agmind/AGmind/tests/mocks/apt-get` — MOCK_APT_OK success/fail control
- `/home/agmind/AGmind/tests/mocks/curl` — reusable for Plan 02-04 (MOCK_CURL_RESPONSE/EXIT)
- `/home/agmind/AGmind/tests/mocks/ssh` — reusable for Plan 02-04 (MOCK_SSH_STDOUT/EXIT)
- `/home/agmind/AGmind/tests/mocks/hostname` — added MOCK_HOSTNAME env override

## Decisions Made

- **lldpcli not lldpctl**: `lldpctl` produces different JSON on lldpd 1.0.18, incompatible with parsing. Live-verified.
- **DETECTED_NETWORK gate**: eliminated synchronous `curl --max-time 3 archive.ubuntu.com` from `_ensure_lldpd`. Offline hosts get a warn+skip in <1ms instead of 3-sec delay.
- **jq startswith() for IP prefix**: original plan used `gsub+regex` which produced double-backslash failures; `startswith($pfx + ".")` is simpler and correct.
- **fping 10-target cap**: keeps total detection budget under 3 seconds for direct QSFP topology.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] jq IP filter gsub+regex produced empty IP**
- **Found during:** Task 3 (unit test run — Scenario 1 FAIL: PEER_IP='')
- **Issue:** `gsub("\\."; "\\\\.")` inside single-quoted jq string produced `192\\.168\\.100` (double backslash) — jq regex then failed to match `192.168.100.2`
- **Fix:** Replaced `map(select(test("^" + ($pfx | gsub(...)) + "\\.")))` with `map(select(startswith($pfx + ".")))` — functionally equivalent, no regex escaping needed
- **Files modified:** `lib/detect.sh` (line 557)
- **Verification:** `bash tests/unit/test_hw_detect_peer.sh` → 6 passed, 0 failed
- **Committed in:** `6a3ffb0` (Task 3 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — Bug in jq expression)
**Impact on plan:** Fix was essential for LLDP IP extraction correctness. No scope creep.

## Known Stubs

None — all exported env vars (`PEER_HOSTNAME`, `PEER_IP`, `PEER_USER`) are real values (or empty on no-peer), not placeholders.

## Issues Encountered

- `MOCK_HOSTNAME` support needed in existing `tests/mocks/hostname` for Scenarios 2 and 6 (self-filter test). Added `${MOCK_HOSTNAME:-mock-host}` fallback — backward compatible, existing tests unaffected.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `PEER_HOSTNAME`, `PEER_IP`, `PEER_USER` exported and available for `_wizard_cluster_mode` (Plan 02-02)
- Override env vars documented: `AGMIND_PEER_USER` (default `agmind2`), `AGMIND_CLUSTER_SUBNET_PREFIX` (default `192.168.100`)
- `tests/mocks/curl` and `tests/mocks/ssh` pre-built for Plan 02-04 SSH trust tests
- Live LLDP validation on spark-3eac: run `bash -c 'source lib/common.sh; source lib/detect.sh; _ensure_lldpd; hw_detect_peer; echo "H=$PEER_HOSTNAME IP=$PEER_IP U=$PEER_USER"'` — expects `H=spark-69a2 IP=192.168.100.2 U=agmind2`

---
*Phase: 02-dual-spark-detect-master-worker-wizard-compose-split*
*Completed: 2026-04-21*
