---
gsd_state_version: 1.0
milestone: v3.0.1
milestone_name: milestone
status: Phase 3 complete (live UAT passed)
last_updated: "2026-04-25T19:00:00.000Z"
progress:
  total_phases: 3
  completed_phases: 3
  total_plans: 9
  completed_plans: 9
  percent: 100
---

# State: AGmind Installer v3.0.1

## Project Reference

See: `.planning/PROJECT.md`

**Core value:** Один `sudo bash install.sh` поднимает RAG-платформу на DGX Spark с надёжным mDNS резолвом и автодетекции peer для dual-Spark deploy.

**Current focus:** Phase 3 — Version bumps Green zone — 11 arm64-verified

## Current Position

Phase: 3 (Version bumps Green zone — 11 arm64-verified) — EXECUTING
Plan: 1 of 2
Milestone: v3.0.1

## Milestone Roadmap

See: `.planning/ROADMAP.md`

**2 phases:**

1. mDNS reliability — 3 bug fixes + agmind mdns-status CLI
2. Dual-Spark detect + master/worker wizard + compose split

## Baseline

- Git: `main` @ `origin/main` (`07c8dfb` — "nginx resolver fix + opt-in perf/upload toggles")
- Installer: v3.0 classic (Dify + vLLM + Ollama + Weaviate + monitoring + Authelia optional)
- `lib/config.sh::_register_local_dns` — mDNS via `avahi-publish-address` wrapper (R4 hotfix 2026-04-19)
- 45 containers в `templates/docker-compose.yml`
- **Нет** peer detect, cluster_mode, split compose — всё с нуля в Phase 2

## Research references

- `.planning/codebase/` — 7 docs (2277 строк суммарно)
- `CLAUDE.md` §6, §8, §10
- `lib/detect.sh`, `lib/config.sh`, `lib/wizard.sh`, `lib/common.sh` — основные модули для правки

## Decisions (v3.0.1)

1. **No Traefik migration** — nginx уже fixed (variable form + resolver 127.0.0.11).
2. **mDNS stays avahi** — но 3 targeted bugs fix'ятся.
3. **Peer = direct QSFP subnet** (192.168.100.0/24), LLDP primary, ping fallback.
4. **Master ↔ worker = HTTP OpenAI-compat** (no LiteLLM router).
5. **Passwordless SSH** настраивается в wizard (not pre-provisioned).
6. **Single Spark = default mode** (cluster.json `mode=single` если peer not detected).

### Plan 01-01 Decisions (2026-04-21)

7. **`_mdns_get_primary_ip` в lib/detect.sh** — shared helper (config.sh + agmind.sh + future mdns-status CLI).
8. **Hard exit 1 в phase_diagnostics** — NON_INTERACTIVE не обходит проверку foreign :5353 responder.
9. **LEGACY SAFETY NET comment** — warn-only блок в lib/config.sh сохранён как tertiary defence-in-depth.

### Plan 01-02 Decisions (2026-04-21)

10. **awk $4 (не $5)** для Local Address:Port в `ss -ulnp` — верифицировано на DGX Spark (6 полей, col4=Local).
11. **hard exit 1 в `_verify_post_install_smoke`** — единственный способ обойти `|| true` на call site (install.sh:198).
12. **export pattern для bash function fixtures** — inline `VAR=val func` работает только для внешних команд, не для bash-функций.

### Plan 02-02 Decisions (2026-04-21)

13. **default_tag="single" locked per ROADMAP SC#1** — peer detected shows HINT but never pre-selects master/worker; user must opt in explicitly.
14. **exit 1 (not return 1) on invalid AGMIND_MODE_OVERRIDE** — fails loudly to prevent silent misconfiguration in CI pipelines.
15. **child bash subprocess for invalid-override unit test** — `exit 1` in sourced function kills caller shell with `set -e`; test spawns `bash -c` subshell to capture exit code.

## Performance Metrics

| Phase | Plan | Duration | Tasks | Files |
|-------|------|----------|-------|-------|
| 01 | 01-01 | 11 min | 4/4 | 13 |
| 01 | 01-02 | 10 min | 9/9 | 14 |
| Phase 02-dual-spark-detect-master-worker-wizard-compose-split P01 | 20 | 3 tasks | 11 files |
| Phase 02-dual-spark-detect-master-worker-wizard-compose-split P02 | 25 | 5 tasks | 6 files |
| Phase 02 P03 | 4 | 5 tasks | 5 files |
| Phase 02-dual-spark-detect-master-worker-wizard-compose-split P04 | 9 | 4 tasks | 4 files |
| Phase 02 P05 | 6 | 4 tasks | 3 files |

## Roadmap Evolution

- Phase 3 added: Version bumps Green zone — 11 arm64-verified (Redis 7.4.8 security, Grafana 12.4.3 CVE, SOPS v3.12.2 + new hashes, Ollama v0.21.2, SearXNG 2026.4.24, SurrealDB v2.6.5, Postgres 16-alpine3.23, Redis Exporter v1.82.0, Postgres Exporter v0.19.1, Nginx Exporter 1.5.1, cAdvisor v0.55.1 arm64-ceiling)

## Next Action

**Phase 3 added — ready for `/gsd-plan-phase 3`.**

Phase 2 (dual-spark) complete. Phase 3 = security/version bumps batch from BACKLOG #999.4. arm64 manifest verified (cAdvisor v0.55.1 ceiling, Promtail/Alloy excluded → 999.5).

Live UAT requirement: каждая правка прогоняется на работающем стеке spark-3eac до коммита (memory: feedback_test_live_before_commit).

---

*Updated: 2026-04-25 — Phase 3 added (Version bumps Green zone)*
