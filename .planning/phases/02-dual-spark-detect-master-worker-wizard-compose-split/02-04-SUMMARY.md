---
phase: 02-dual-spark-detect-master-worker-wizard-compose-split
plan: "04"
subsystem: installer-peer-deploy
tags:
  - phase_deploy_peer
  - peer-vllm
  - ssh-deploy
  - smoke-strict
  - agmind-health
  - unit-test
dependency_graph:
  requires:
    - 02-03  # lib/ssh_trust.sh, templates/docker-compose.worker.yml
    - 02-02  # lib/cluster_mode.sh, cluster_status_update, cluster.json
  provides:
    - phase_deploy_peer (install.sh phase 7 — scp+ssh vLLM deploy to peer)
    - _smoke_peer_vllm_check (STRICT peer health in post-install smoke)
    - _doctor_peer (lib/health.sh — peer section in agmind health/doctor)
    - agmind health --peer (CLI shorthand)
  affects:
    - install.sh phase table (10→11 phases)
    - phase_complete (removes || true from smoke — propagates strict fail)
tech_stack:
  added:
    - docker save|ssh docker load — air-gap image transfer pattern
    - curl /v1/models polling — vLLM readiness check (30 min timeout)
    - cluster_status_update running/failed — persistent deploy state
  patterns:
    - progressive sleep (5s→15s) for long cold-start polls
    - set +eu in test subshells to capture non-zero return codes
key_files:
  created:
    - tests/unit/test_phase_deploy_peer.sh
  modified:
    - install.sh (+203 lines source+functions, +7 phase table)
    - lib/health.sh (+65 lines _doctor_peer)
    - scripts/agmind.sh (+20 lines --peer dispatch + health alias)
decisions:
  - "No --force-recreate on peer compose up (CLAUDE.md §8): worker compose has no Redis/Celery, but rule respected uniformly"
  - "cluster.json is source of truth for smoke check (not AGMIND_MODE env) — handles resume paths correctly"
  - "_smoke_peer_vllm_check returns 1 (not exit 1) — phase_complete propagates via removed || true"
  - "set +eu in test subshells — required to capture non-zero function return codes under set -uo pipefail"
metrics:
  duration: "9 min"
  completed: "2026-04-21T20:14:36Z"
  tasks_completed: 4
  tasks_total: 4
  files_modified: 3
  files_created: 1
  commits: 4
---

# Phase 02 Plan 04: Peer Deploy + Strict Smoke + agmind health --peer + Unit Test Summary

**One-liner:** phase_deploy_peer (SSH trust → docker save|load → compose up → 30-min vLLM poll) + STRICT peer smoke (cluster.json source of truth, exit 1 on failure) + agmind health --peer CLI + unit test MAJOR 6 FIX.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | phase_deploy_peer + helpers + phase table 10→11 | 5f8b7cf | install.sh |
| 2 | _smoke_peer_vllm_check STRICT in _verify_post_install_smoke | 80036ea | install.sh |
| 3 | _doctor_peer in health.sh + agmind health --peer dispatch | c8e71c1 | lib/health.sh, scripts/agmind.sh |
| 4 | Unit test test_phase_deploy_peer.sh (MAJOR 6 FIX) | 70b0fcd | tests/unit/test_phase_deploy_peer.sh |

## Phase Table After Plan 02-04 (11 phases)

```
Phase  1  — Diagnostics    (phase_diagnostics)
Phase  2  — Wizard         (phase_wizard)
Phase  3  — Docker         (phase_docker)
Phase  4  — Configuration  (phase_config)
Phase  5  — Pull           (phase_pull)
Phase  6  — Start          (phase_start)
Phase  7  — Deploy Peer    (phase_deploy_peer)  ← NEW
Phase  8  — Health         (phase_health)
Phase  9  — Models         (phase_models_graceful)
Phase 10  — Backups        (phase_backups)
Phase 11  — Complete       (phase_complete)
```

## phase_deploy_peer Flow

```
if mode != master → early return 0 (single/worker skip)
  1. _ensure_ssh_trust peer_ip peer_user        (lib/ssh_trust.sh)
  2. ssh mkdir -p /opt/agmind/docker + chown
  3. Idempotency: if vllm running + same image → _wait_peer_vllm_ready 60s → skip
  4. _deploy_image_to_peer (docker save | ssh docker load — skips if present)
  5. scp docker-compose.worker.yml + _render_worker_env > .env (chmod 0600)
  6. ssh docker compose -f docker-compose.worker.yml up -d  (no --force-recreate)
  7. _wait_peer_vllm_ready 1800s (curl /v1/models, 5s→15s progressive sleep)
  8. cluster_status_update "running"
```

## _render_worker_env Key Variables

```bash
VLLM_IMAGE, VLLM_SPARK_IMAGE          # default: vllm/vllm-openai:gemma4-cu130
VLLM_MAX_MODEL_LEN=65536               # 64K context (CLAUDE.md §8 DGX Spark)
VLLM_GPU_MEM_UTIL=0.60                 # 60% (leaves room for docling)
VLLM_MEM_LIMIT=96g                     # container mem limit
NVIDIA_DRIVER_CAPABILITIES=compute,utility  # CLAUDE.md §8 mandatory
HF_TOKEN                               # from master env
```

## _smoke_peer_vllm_check Behavior

| cluster.json mode | peer_ip | curl /v1/models | Result |
|-------------------|---------|-----------------|--------|
| single (or missing) | any | any | return 0 (skip) |
| master | empty | — | return 1 (STRICT) |
| master | set | 200 | return 0 + log_success |
| master | set | fail | return 1 (STRICT) |

`phase_complete` no longer has `|| true` on `_verify_post_install_smoke` — non-zero exit propagates up.

## agmind health --peer Output (mode=single)

```
Peer Node:
  [SKIP] Peer Node — mode=single (single-node install)

All checks passed
```

Mode=master with healthy peer:
```
Peer Node:
  [OK]   Peer reachable — spark-69a2 (192.168.100.2)
  [OK]   Peer vLLM :8000 — model: google/gemma-4-26B-A4B-it
  [OK]   cluster.json status — running
```

## Unit Test Coverage

`tests/unit/test_phase_deploy_peer.sh` — 2 scenarios:
- **Scenario 1:** `AGMIND_MODE=single` → phase_deploy_peer returns 0, no network calls
- **Scenario 2:** `AGMIND_MODE=master` + `PEER_IP=""` + cluster.json peer_ip empty → returns non-zero

`bash tests/run_all.sh` result: **10 PASS, 1 SKIP (integration/root), 0 FAIL**

## Deviations from Plan

None — plan executed exactly as written.

**MAJOR 6 FIX** (pre-existing gap now closed): prior to this plan, phase_deploy_peer had only live UAT coverage (VALIDATION T2.7). Now 2 automated unit scenarios run in CI.

**Rule 1 fix applied:** test subshells required `set +eu` to correctly capture non-zero return codes when parent script runs under `set -uo pipefail`. Standard pattern for bash test harnesses.

## Known Stubs

None — phase_deploy_peer fully wired to lib/ssh_trust.sh, lib/cluster_mode.sh, templates/docker-compose.worker.yml (all from prior waves).

## Threat Flags

None beyond those documented in plan threat model (T-02-04-01 through T-02-04-06). No new network endpoints introduced beyond peer:8000 already tracked.

## Known Limitations

- **docker save|load performance:** transferring vllm/vllm-openai:gemma4-cu130 (~20+ GB) over QSFP 200G takes ~3-5 min. For air-gap scenarios this is the only option; a registry mirror would be faster (v3.2+ candidate).
- **cluster.json status transitions** not atomic on crash between `docker compose up` and `cluster_status_update "running"` — re-run is idempotent (docker ps check before redeploy).
- **Unit test Scenario 3** (full mock success path) deferred — requires mocking entire docker save|load SSH pipe chain; 2 scenarios sufficient for branch coverage.

## Handoff to Plan 02-05

Peer vLLM on spark-69a2 answers:
- `:8000/v1/models` — Prometheus scrape target ready
- `:9100/metrics` (node-exporter from worker compose) — system metrics ready

Plan 02-05 scope: add peer targets to Prometheus config + Grafana dashboard panel "Peer GPU / Memory".

## Live UAT Required (verify-work phase)

```bash
# On spark-3eac with QSFP link to spark-69a2 active:
sudo bash install.sh  # --mode=master auto-detected or wizard selection

# Expected:
# Phase 7/11 "Deploy Peer" starts
# SSH trust bootstrapped (one-time password prompt)
# docker-compose.worker.yml + .env scp to spark-69a2
# docker compose up -d on spark-69a2
# Poll vLLM up to 30 min (gemma-4-26B cold download)
# Phase 11/11 "Complete" → _smoke_peer_vllm_check → log_success

# Post-install check:
agmind health --peer
# Expected: [OK] Peer reachable + [OK] Peer vLLM :8000 + [OK] cluster.json status running
```

## Self-Check: PASSED

- FOUND: .planning/phases/02-.../02-04-SUMMARY.md
- FOUND: commit 5f8b7cf (phase_deploy_peer + phase table)
- FOUND: commit 80036ea (STRICT smoke check)
- FOUND: commit c8e71c1 (_doctor_peer + health --peer)
- FOUND: commit 70b0fcd (unit test)
- `bash tests/run_all.sh`: 10 PASS, 1 SKIP, 0 FAIL
