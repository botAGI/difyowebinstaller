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

**Plans:** 5/5 plans complete
- [x] 02-01-PLAN.md — Peer detection (hw_detect_peer, _ensure_lldpd, _peer_ping_fallback) + phase_diagnostics wiring + unit test (PEER-01, PEER-02, PEER-03)
- [x] 02-02-PLAN.md — lib/cluster_mode.sh (select/save/read) + _wizard_cluster_mode + AGMIND_MODE_OVERRIDE + --mode flag + 2 unit tests (CLUSTER-01, CLUSTER-02, PEER-04)
- [x] 02-03-PLAN.md — templates/docker-compose.worker.yml + build_compose_profiles master-skip + lib/ssh_trust.sh + integration SSH test + image tag registry gate (COMPOSE-01, SSH-01)
- [x] 02-04-PLAN.md — phase_deploy_peer (scp+ssh compose up+vLLM poll) + STRICT _smoke_peer_vllm_check + agmind doctor --peer + _doctor_peer (PEER-05, PEER-06)
- [x] 02-05-PLAN.md — monitoring/peer-offline.yml alerts + prometheus.yml scrape placeholder + _configure_peer_monitoring sed + plan-wide shellcheck DoD gate (PEER-05)

---

## Out of Scope (v3.0.1)

- Traefik migration (nginx уже правильно настроен — variable form + resolver, IP-lock trap closed)
- LiteLLM router (master → vLLM direct HTTP OpenAI-compat достаточно)
- Model picker wizard (v3.1 кандидат)
- VPS profile изменения (v3.1+)
- Kubernetes, multi-peer (>2 Spark), GPU budget tracker
- **Open Notebook fix** — disabled on deploy, tracked in `.planning/BACKLOG.md` #999.1
  (SurrealDB auth divergence on recreate; fix approaches listed there)

---

## Research references

- `.planning/codebase/CONCERNS.md` — mDNS концерны из CLAUDE.md §8 синтезированы
- `.planning/codebase/ARCHITECTURE.md` — installer flow, lib/* responsibilities
- `lib/config.sh::_register_local_dns` (line 592-699) — current mDNS implementation
- `lib/detect.sh` — куда добавить `hw_detect_peer`
- `lib/wizard.sh` — куда добавить mode selection
- `templates/docker-compose.yml` — split candidate для worker compose

### Phase 3: Version bumps Green zone — 11 arm64-verified

**Goal:** Поднять 11 версий в `templates/versions.env` (security CVE-fixes + bugfix bumps), все верифицированы через `docker manifest inspect` с подтверждённым `architecture: arm64` для конкретного tag. Прогнать live на работающем стеке spark-3eac (master) с per-service recreate (по очереди, без глобального `compose up -d --force-recreate`), убедиться что existing функционал не сломался.

**Requirements:** VBUMP-01..VBUMP-11 (см. CONTEXT.md и BACKLOG #999.4)

**Depends on:** Phase 2

**Success Criteria:**
1. `templates/versions.env` содержит 11 обновлённых версий: Redis `7.4.8-alpine`, Grafana `12.4.3`, SOPS `v3.12.2` (+ новые `SOPS_SHA256_ARM64` и `SOPS_SHA256_AMD64` из upstream checksums), Ollama `v0.21.2`, SearXNG `2026.4.24`, SurrealDB `v2.6.5`, Postgres `16-alpine3.23`, Redis Exporter `v1.82.0`, Postgres Exporter `v0.19.1`, Nginx Exporter `1.5.1`, cAdvisor `v0.55.1`.
2. `bash tests/compose/test_image_tags_exist.sh core/compose.yml` (или эквивалент для `templates/docker-compose.yml`) PASS — все 11 image manifests resolve, arm64 architecture verified для каждого.
3. `shellcheck -S warning lib/*.sh scripts/*.sh install.sh` PASS (если правки задели shell).
4. **Live deploy на spark-3eac:** per-service recreate выполнен в правильном порядке (Postgres последним из-за depends_on api/worker service_healthy):
   - `sudo docker compose up -d redis grafana ollama surrealdb`
   - `sudo docker compose up -d redis-exporter postgres-exporter nginx-exporter cadvisor`
   - `sudo docker compose up -d searxng`
   - `sudo docker compose up -d postgres` (внимание: Dify api/worker depends_on, ~10 сек простоя)
   - SOPS binary обновлён в `/opt/agmind/bin/sops` с verified sha256.
5. После live recreate: `sudo docker ps --filter status=unhealthy` пуст, `agmind health` всё OK, `curl -sf http://agmind-dify.local/console/api/setup` → 200, Grafana login `http://agmind-grafana.local` доступен.
6. **HOLD list соблюдён** — НЕ обновлены: plugin_daemon (0.5.3-local), VLLM_NGC (26.02-py3), VLLM_SPARK (gemma4-cu130), Qdrant (RocksDB break), Prometheus v3.x, SurrealDB v3.x, Grafana v13, Loki/Promtail (отдельная фаза 999.5 → Alloy migration), cAdvisor v0.56+ (arm64 broken).
7. Yellow zone (Open WebUI, Weaviate, MinIO, Docling, LiteLLM, Portainer 2.39, Nginx 1.30, Authelia 4.39) — НЕ trogать в этой фазе, отдельный milestone.

**UI hint:** no (infra/version bumps only)

**Plans:** 2/2 plans complete

- [x] 03-01-PLAN.md — Edit templates/versions.env (11 bumps + 3 SOPS строки) + DoD §10 gates (test_image_tags_exist, shellcheck, compose config). NO commit.
- [x] 03-02-PLAN.md — Live UAT на spark-3eac: Wave A-D per-service recreate + Wave E SOPS binary + STATE.md update + STOP-gate для user apr'ува commit.

### Phase 4: Pin rolling tags — MinIO mc + Open WebUI Pipelines (close :latest gap)

**Goal:** [To be planned]
**Requirements**: TBD
**Depends on:** Phase 3
**Plans:** 0 plans

Plans:
- [ ] TBD (run /gsd-plan-phase 4 to break down)

---

*Updated: 2026-04-25 — Phase 3 planned (2 plans, 11 VBUMP requirements, autonomous: false on plan 02 due to live sudo + commit gate)*
