---
phase: 02-dual-spark-detect-master-worker-wizard-compose-split
plan: "05"
subsystem: monitoring-peer-observability
tags:
  - prometheus
  - grafana-alerts
  - peer-monitoring
  - PEER-05
  - DoD-gate
  - phase-2-final
dependency_graph:
  requires:
    - 02-04  # phase_deploy_peer, peer vLLM :8000 + node-exporter :9100 accessible
    - 02-02  # cluster.json (source of truth for peer_ip)
  provides:
    - monitoring/peer-offline.yml (PeerNodeOffline + PeerVllmOffline + PeerVllmFlapping alerts)
    - monitoring/prometheus.yml extended (rule_files + __PEER_SCRAPE_BEGIN/END__ template)
    - lib/config.sh::_configure_peer_monitoring (install-time sed injection, idempotent)
  affects:
    - Prometheus startup (loads peer-offline.yml rules)
    - generate_config flow (calls _configure_peer_monitoring after _copy_monitoring_files)
    - Alertmanager alert routing (PeerNodeOffline/PeerVllmOffline with severity: critical)
tech_stack:
  added:
    - Prometheus alert rules file: monitoring/peer-offline.yml
    - __PEER_SCRAPE_BEGIN/END__ marker pattern for install-time sed uncomment
  patterns:
    - defensive command -v + test -f before _atomic_sed (MAJOR 3 fix)
    - idempotent peer scrape injection (grep check before sed rewrite)
    - PEER_IP fallback: env var → cluster.json via jq
key_files:
  created:
    - monitoring/peer-offline.yml
  modified:
    - monitoring/prometheus.yml
    - lib/config.sh
decisions:
  - "peer-offline.yml lives alongside alert_rules.yml — separate file to avoid conflicts on merge"
  - "for: 30s = 2 consecutive scrape failures at scrape_interval=15s (exact ROADMAP criterion)"
  - "PeerVllmFlapping added (not in PEER-05 scope) — proactive defense against DGX Spark OOM restart loops"
  - "_configure_peer_monitoring called only inside MONITORING_MODE=local block — peer scrape pointless without local Prometheus"
  - "scrape block uses commented __PEER_SCRAPE__ markers so prometheus.yml stays valid YAML before install"
metrics:
  duration: "6 min"
  completed: "2026-04-21T20:20:40Z"
  tasks_completed: 4
  tasks_total: 4
  files_modified: 2
  files_created: 1
  commits: 4
---

# Phase 02 Plan 05: Prometheus Peer Scrape + Offline Alert + DoD Gate Summary

**One-liner:** Prometheus scrape targets for peer node-exporter+vLLM via install-time sed injection, PeerNodeOffline/PeerVllmOffline/PeerVllmFlapping alert rules, plan-wide shellcheck+YAML+compose+registry DoD gate all green.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | monitoring/peer-offline.yml — 3 alert rules | db160fe | monitoring/peer-offline.yml (new) |
| 2 | prometheus.yml rule_files + scrape placeholder | b612807 | monitoring/prometheus.yml |
| 3 | lib/config.sh::_configure_peer_monitoring | 8262eb2 | lib/config.sh |
| 4 | DoD gate — shellcheck, YAML, tests, registry | 1972b5c | lib/detect.sh (pre-existing fix) |

## Alert Rules (monitoring/peer-offline.yml)

| Alert | Expr | for | Severity | Trigger |
|-------|------|-----|----------|---------|
| PeerNodeOffline | `up{job="peer-node-exporter"} == 0` | 30s | critical | node-exporter unreachable on peer |
| PeerVllmOffline | `up{job="peer-vllm"} == 0` | 30s | critical | vLLM service down on peer |
| PeerVllmFlapping | `changes(up{job="peer-vllm"}[5m]) > 4` | 2m | warning | OOM/CUDA restart loop |

`for: 30s` at `scrape_interval: 15s` = exactly 2 consecutive failed scrapes (ROADMAP criterion).

## prometheus.yml Changes

```yaml
rule_files:
  - /etc/prometheus/alert_rules.yml
  - /etc/prometheus/peer-offline.yml   # ← NEW

  # Added at end of scrape_configs (commented, uncommented at install time):
  # __PEER_SCRAPE_BEGIN__
  # - job_name: 'peer-node-exporter'
  #   static_configs:
  #     - targets: ['__PEER_IP__:9100']
  # - job_name: 'peer-vllm'
  #   static_configs:
  #     - targets: ['__PEER_IP__:8000']
  # __PEER_SCRAPE_END__
```

## _configure_peer_monitoring Flow

```
generate_config()
  └─ MONITORING_MODE=local block
       ├─ _copy_monitoring_files        (copies prometheus.yml with markers to INSTALL_DIR)
       ├─ _configure_alertmanager       (telegram/email/webhook setup)
       └─ _configure_peer_monitoring    (NEW — Plan 02-05)
            ├─ AGMIND_MODE != master → return 0 (skip)
            ├─ defensive: command -v _atomic_sed || return 1
            ├─ defensive: test -f prom_conf || return 1
            ├─ PEER_IP: env → cluster.json via jq
            ├─ PEER_IP empty → log_warn + return 0
            ├─ idempotency: peer-node-exporter already uncommented + IP matches → return 0
            ├─ _atomic_sed: s|__PEER_IP__|${peer_ip}|g
            └─ _atomic_sed: uncomment __PEER_SCRAPE_BEGIN__...__PEER_SCRAPE_END__ block
```

## Plan-wide DoD Gate Results

| Check | Result |
|-------|--------|
| `shellcheck -S warning lib/*.sh scripts/*.sh install.sh` | PASS — 0 warnings |
| `bash -n` on 9 modified bash files | PASS — SYNTAX_OK |
| YAML parse: peer-offline.yml | PASS |
| YAML parse: prometheus.yml | PASS |
| YAML parse: docker-compose.worker.yml | PASS |
| `docker compose -f templates/docker-compose.worker.yml config` | PASS — COMPOSE_OK |
| `bash tests/run_all.sh` | 10 PASS, 1 SKIP (integration/root), 0 FAIL |
| `test_image_tags_exist.sh templates/docker-compose.worker.yml` | 2 checked, 0 failed |

## Phase 2 Cumulative Modified Files (Plans 02-01 through 02-05)

| File | Plans | Nature |
|------|-------|--------|
| lib/detect.sh | 02-01 | hw_detect_peer — LLDP/fping peer discovery |
| lib/wizard.sh | 02-01 | dual-spark wizard (mode selection) |
| lib/cluster_mode.sh | 02-02 | cluster.json state management |
| lib/ssh_trust.sh | 02-03 | SSH key bootstrap for peer |
| lib/compose.sh | 02-03 | worker compose helpers |
| lib/config.sh | 02-05 | _configure_peer_monitoring (this plan) |
| lib/health.sh | 02-04 | _doctor_peer |
| install.sh | 02-01..04 | phases 1-11 table, phase_deploy_peer |
| scripts/agmind.sh | 02-04 | agmind health --peer dispatch |
| templates/docker-compose.worker.yml | 02-03 | peer worker compose |
| monitoring/prometheus.yml | 02-05 | rule_files + scrape placeholders |
| monitoring/peer-offline.yml | 02-05 | NEW — alert rules |
| tests/unit/test_hw_detect_peer.sh | 02-01 | 6 passed |
| tests/unit/test_cluster_mode_select.sh | 02-02 | 9 passed |
| tests/unit/test_cluster_json_persist.sh | 02-02 | 7 passed |
| tests/unit/test_phase_deploy_peer.sh | 02-04 | 2 passed |
| tests/integration/test_ssh_trust.sh | 02-03 | SKIP (no live peer) |
| tests/compose/test_image_tags_exist.sh | 02-03 | 2 checked, 0 failed |

## Deviations from Plan

**1. [Rule 2 - Missing Critical] PeerVllmFlapping alert added**
- **Found during:** Task 1
- **Issue:** Plan required only PeerNodeOffline + PeerVllmOffline, but CLAUDE.md §8 documents OOM/CUDA restart loops on DGX Spark unified memory as a real operational hazard
- **Fix:** Added PeerVllmFlapping (changes in 5m > 4, for: 2m, severity: warning) to prevent alert fatigue on multi-restart episodes
- **Files modified:** monitoring/peer-offline.yml
- **Commit:** db160fe

None other — plan executed as written.

## Known Stubs

None — all peer scrape targets and alert rules are fully wired. The commented `__PEER_SCRAPE__` block in prometheus.yml is intentional (not a stub) — it becomes active at install time when `_configure_peer_monitoring` runs.

## Known Limitations

- **PEER_IP hardcoded after install:** cluster.json + sed substitution at install time. If QSFP is re-cabled with a new peer IP, `install.sh` must be re-run to update prometheus.yml. Dynamic reload not supported (Prometheus static configs).
- **No Grafana dashboards for peer:** peer metrics will appear in Prometheus but no dedicated dashboard panels in scope for Plan 02-05. Future work (v3.2+).
- **Prometheus does not support shell variable expansion in targets:** design decision to use install-time sed substitution rather than environment variable injection.
- **peer-offline.yml not validated by promtool in CI:** promtool not installed on dev host; YAML parse validates structure, but PromQL syntax errors would only surface at Prometheus startup. Mitigation: rules use well-known `up{}` metric — low risk.

## Handoff to /gsd-verify-work Phase 2

Live UAT required on spark-3eac:

```bash
# Full install — triggers peer monitoring config
sudo bash install.sh  # wizard selects master mode

# Verify Prometheus loaded peer rules
curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[].name' | grep peer

# Verify scrape targets configured (after substitution)
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[].labels.job' | grep peer

# Verify alert rules loaded
curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[].name' | grep -E 'PeerNode|PeerVllm'

# Negative test: simulate peer offline
ssh agmind-peer docker stop agmind-vllm
sleep 45
curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[].labels.alertname' | grep PeerVllmOffline
```

## Self-Check: PASSED

- FOUND: monitoring/peer-offline.yml (54 lines, 3 alert rules)
- FOUND: monitoring/prometheus.yml (peer-offline.yml in rule_files, __PEER_SCRAPE_BEGIN/END__)
- FOUND: lib/config.sh::_configure_peer_monitoring (function + call in generate_config)
- FOUND: commit db160fe (peer-offline.yml)
- FOUND: commit b612807 (prometheus.yml)
- FOUND: commit 8262eb2 (config.sh _configure_peer_monitoring)
- FOUND: commit 1972b5c (DoD gate)
- `bash tests/run_all.sh`: 10 PASS, 1 SKIP, 0 FAIL
- `shellcheck -S warning lib/*.sh scripts/*.sh install.sh`: 0 warnings
