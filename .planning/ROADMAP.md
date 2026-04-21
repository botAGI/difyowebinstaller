# ROADMAP — v3.0.1 hotfix (dual-Spark + mDNS stability)

**Milestone:** v3.0.1
**Started:** 2026-04-21
**Deadline:** 2026-04-23 (2-day sprint)
**Status:** Planning

**Goal:** После `sudo bash install.sh` на свежей Spark — mDNS имена (`agmind-*.local`) резолвятся стабильно из Windows/macOS/Linux без ручной настройки, и wizard автодетектит вторую Spark через QSFP, предлагая mode (single/master/worker) с автоматическим deploy vLLM на peer через SSH.

---

## Phases

### Phase 1: mDNS reliability — fix 3 bugs + diagnostic CLI

**Goal:** `agmind-*.local` публикуются через правильный IP primary uplink (не docker0 и не QSFP), install.sh **abort**'ит при foreign :5353 responder (NoMachine), systemd unit wrapper `agmind-mdns.service` переживает перезапуск avahi-daemon. Плюс CLI `agmind mdns-status` для self-diagnose в field.

**Depends on:** nothing (hotfix на текущем main)
**Requirements:** MDNS-01, MDNS-02, MDNS-03, MDNS-04, MDNS-05
**Success Criteria:**
1. `avahi-resolve -n agmind-dify.local` возвращает **primary uplink IP**, не docker bridge, не QSFP — корректно при любом порядке `hostname -I`
2. `install.sh` на хосте с активным NoMachine (или любым foreign mDNS on :5353) **exits 1** в phase_preflight с actionable инструкцией, не продолжает молча
3. После `systemctl restart avahi-daemon` — `agmind-mdns.service` автоматически рестартится и продолжает публиковать имена в течение <10 сек
4. `agmind mdns-status` выводит: список published имён + их resolved IP + статус systemd unit + foreign responder check + ping test из master. Один exit code: 0 = all good, 1 = any issue
5. Регрессия защищена unit test (`tests/unit/test_mdns_status.sh`) + integration test на clean reboot (`tests/integration/test_mdns_reboot.sh`)

**UI hint:** no

**Plans:** 2/2 plans complete
- [x] 01-01-PLAN.md — Core mDNS fixes (MDNS-01 primary IP helper, MDNS-02 foreign responder hard abort, MDNS-03 systemd BindsTo/PartOf + avahi --no-fail) + shellcheck gate
- [x] 01-02-PLAN.md — `agmind mdns-status` CLI (MDNS-04) + mocks + unit/integration tests + STRICT post-install smoke wiring (MDNS-05)

---

### Phase 2: Dual-Spark detect + master/worker wizard + compose split

**Goal:** `hw_detect_peer` через LLDP + IP-subnet probe на QSFP находит соседа (`spark-69a2` при тесте). Wizard предлагает mode (single/master/worker), persist в `/var/lib/agmind/state/cluster.json`, re-install не re-prompt'ит. Master deploy'ит vLLM на peer через passwordless SSH + `docker compose -f docker-compose.worker.yml up -d`. Grafana alert при peer offline. Полное UAT: master-spark-3eac + worker-spark-69a2, `curl http://${PEER_IP}:8000/v1/models` из master'а healthy.

**Depends on:** Phase 1 (mDNS stability — install.sh должен быть чистый до peer deploy)
**Requirements:** PEER-01, PEER-02, PEER-03, PEER-04, PEER-05, PEER-06, CLUSTER-01, CLUSTER-02, COMPOSE-01, SSH-01
**Success Criteria:**
1. На хосте с detected peer wizard показывает 3 options (single/master/worker), default — single. Выбор persist'ится в `cluster.json`. Повторный install читает, не re-prompt'ит.
2. `hw_detect_peer` реализует LLDP primary + IP subnet probe fallback на QSFP subnet (`192.168.100.0/24`) с 3-sec timeout. Abort install **не ломается** при failed peer detect — продолжает single mode.
3. `templates/docker-compose.worker.yml` (новый файл) поднимает только vLLM + socket-proxy + node-exporter. Master compose через conditional: если `MODE=master` — vllm profile не активируется локально.
4. Passwordless SSH на peer: wizard prompt'ит один раз пароль peer, `ssh-copy-id` устанавливает key, последующие ssh беззвучные.
5. После `phase_deploy_peer` (новая фаза): `curl http://${PEER_IP}:8000/v1/models` с master'а возвращает 200 + выбранная модель. Healthy peer state видим в Grafana (новый alert rule `peer-offline.yml`, fires на 2 consecutive ping failures за 30 сек).
6. Post-install smoke на master: `agmind health` показывает секцию `peer: <name> (<ip>) ready`. На `agmind health --peer` — детальный статус peer.

**UI hint:** no (CLI/wizard only)

**Plans:** 2/5 plans executed
- [x] 02-01-PLAN.md — Peer detection (hw_detect_peer, _ensure_lldpd, _peer_ping_fallback) + phase_diagnostics wiring + unit test (PEER-01, PEER-02, PEER-03)
- [x] 02-02-PLAN.md — lib/cluster_mode.sh (select/save/read) + _wizard_cluster_mode + AGMIND_MODE_OVERRIDE + --mode flag + 2 unit tests (CLUSTER-01, CLUSTER-02, PEER-04)
- [x] 02-03-PLAN.md — templates/docker-compose.worker.yml + build_compose_profiles master-skip + lib/ssh_trust.sh + integration SSH test + image tag registry gate (COMPOSE-01, SSH-01)
- [x] 02-04-PLAN.md — phase_deploy_peer (scp+ssh compose up+vLLM poll) + STRICT _smoke_peer_vllm_check + agmind doctor --peer + _doctor_peer (PEER-05, PEER-06)
- [ ] 02-05-PLAN.md — monitoring/peer-offline.yml alerts + prometheus.yml scrape placeholder + _configure_peer_monitoring sed + plan-wide shellcheck DoD gate (PEER-05)

---

## Out of Scope (v3.0.1)

- Traefik migration (nginx уже правильно настроен — variable form + resolver, IP-lock trap closed)
- LiteLLM router (master → vLLM direct HTTP OpenAI-compat достаточно)
- Model picker wizard (v3.1 кандидат)
- VPS profile изменения (v3.1+)
- Kubernetes, multi-peer (>2 Spark), GPU budget tracker

---

## Research references

- `.planning/codebase/CONCERNS.md` — mDNS концерны из CLAUDE.md §8 синтезированы
- `.planning/codebase/ARCHITECTURE.md` — installer flow, lib/* responsibilities
- `lib/config.sh::_register_local_dns` (line 592-699) — current mDNS implementation
- `lib/detect.sh` — куда добавить `hw_detect_peer`
- `lib/wizard.sh` — куда добавить mode selection
- `templates/docker-compose.yml` — split candidate для worker compose

---

*Updated: 2026-04-21 — 2-day sprint roadmap, 2 phases*
