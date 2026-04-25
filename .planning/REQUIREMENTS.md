# REQUIREMENTS — v3.0.1 hotfix

## Active (v3.0.1)

### MDNS — mDNS reliability (Phase 1)

- [x] **MDNS-01**: `_register_local_dns` в `lib/config.sh` определяет `server_ip` из primary default-route interface (IP address of that interface), НЕ из `hostname -I | awk '{print $1}'`. Корректно при любом порядке IP в выводе (docker bridges / QSFP вторичные NIC не перехватывают).
- [x] **MDNS-02**: `install.sh` в новой функции `phase_preflight_network` (или расширенной `phase_preflight`) **abort'ит exit 1** при обнаружении non-avahi процесса на UDP/5353, с actionable error message (как disable NoMachine EnableLocalNetworkBroadcast, iTunes Bonjour, etc.). Legacy `log_warn && continue` regression — не допустимо.
- [x] **MDNS-03**: systemd unit `agmind-mdns.service` (из `_register_local_dns`) использует `BindsTo=avahi-daemon.service` + `PartOf=avahi-daemon.service` + `After=` — wrapper process follows avahi lifecycle. После `systemctl restart avahi-daemon` wrapper restarts automatically в пределах 10 сек. Verify через integration test.
- [x] **MDNS-04**: `scripts/mdns-status.sh` (новый CLI, exposed через `agmind mdns-status`) выводит: (a) published names + resolved IP через `avahi-resolve -n`, (b) status `agmind-mdns.service` (active/failed + timestamp), (c) foreign responder на :5353 check, (d) ping primary_uplink test. Exit 0 при all-green, exit 1 при любом issue. Output человекочитаемый + `--json` flag для machine parsing.
- [x] **MDNS-05**: Регрессии покрыты: unit test `tests/unit/test_mdns_status.sh` (mocks + edge cases: wrong IP, dead service, foreign responder), integration test `tests/integration/test_mdns_reboot.sh` (после reboot имена всё ещё резолвятся за <30 сек). Оба в CI.

### PEER — Dual-Spark peer detection (Phase 2)

- [x] **PEER-01**: `hw_detect_peer` в `lib/detect.sh` (новая функция) — primary channel LLDP (`lldpctl show neighbors -f json`), fallback ping sweep на QSFP subnet `${AGMIND_CLUSTER_SUBNET:-192.168.100.0/24}`. Timeout 3 sec — при fail возвращает empty (single-node). Никогда non-zero exit.
- [x] **PEER-02**: Auto-install `lldpd` если отсутствует (`apt install -y lldpd` + `systemctl enable --now lldpd`). Только если apt доступен (offline / air-gap → skip с warn). Не ломает offline профиль.
- [x] **PEER-03**: `hw_detect_peer` результат (peer hostname + peer IP) передаётся в wizard (через env vars `PEER_HOSTNAME`, `PEER_IP`) — wizard показывает mode menu ТОЛЬКО при detected peer.
- [x] **PEER-04**: Persistent state `/var/lib/agmind/state/cluster.json` сохраняет `{mode, peer_hostname, peer_ip, subnet}`. Re-run install — читает cluster.json, не re-prompt'ит mode. Override через env `AGMIND_MODE_OVERRIDE=single|master|worker` (для CI/non-interactive).
- [x] **PEER-05**: `phase_deploy_peer` (новая фаза в `install.sh`, вызывается после `phase_start` если `MODE=master`): `scp templates/docker-compose.worker.yml + rendered .env` на peer → `ssh peer 'cd /opt/agmind && docker compose -f docker-compose.worker.yml up -d'` → wait `curl http://${PEER_IP}:8000/v1/models` returns 200 (timeout 30 min для первой скачки модели) → `cluster.json.status=running`.
- [x] **PEER-06**: `phase_post_install_smoke` на master включает peer check: `curl -sSf http://${PEER_IP}:8000/v1/models | jq '.data[0].id'` возвращает выбранную модель. Smoke exit 1 при failure (STRICT).

### CLUSTER — Mode selection & persistence (Phase 2)

- [x] **CLUSTER-01**: `cluster_mode_select` TUI (в `lib/wizard.sh` или новом `lib/cluster_mode.sh`) показывает 3 options: single / master / worker. Dialog/whiptail primary + readline fallback. Persist `cluster.json` atomic (`.tmp` + `mv`).
- [x] **CLUSTER-02**: Mode menu вызывается в `run_wizard()` **сразу после** `phase_preflight` (который вызвал `hw_detect_peer`). Если peer not detected — menu skip'ается, `mode=single` default (uncommitted в cluster.json).

### COMPOSE — Compose split for master/worker (Phase 2)

- [x] **COMPOSE-01**: `templates/docker-compose.worker.yml` (новый) содержит только: `vllm` (с ${VLLM_*} env), `socket-proxy` (wollomatic, для docker API access на peer если потребуется), опционально `node-exporter` (prometheus scrape target). Нет Dify, Postgres, Redis, etc. — они только на master. Labels совместимы с master'ским мониторингом (scrape endpoint discovery).

### SSH — Passwordless SSH setup (Phase 2)

- [x] **SSH-01**: `_ensure_ssh_trust <peer_ip>` (новый helper в `lib/detect.sh` или отдельный `lib/ssh_trust.sh`): (1) проверяет `ssh -o BatchMode=yes ${peer_user}@${peer_ip} true` — если OK, return 0. (2) Если fail — wizard prompt'ит пароль peer один раз через TUI password input. (3) `ssh-copy-id -i ~/.ssh/agmind_peer_ed25519.pub ${peer_user}@${peer_ip}` (key генерится если отсутствует). (4) Verify через `ssh -o BatchMode=yes`. Credentials (пароль) в memory only, не на disk.

### VBUMP — Version bumps Green zone, arm64-verified (Phase 3)

Source of truth: `.planning/BACKLOG.md` #999.4. arm64 manifest verified 2026-04-25 через `docker manifest inspect <image>:<tag>` (architecture: arm64 в multi-arch index). Live UAT requirement: каждая правка прогоняется на работающем стеке spark-3eac до коммита.

- [ ] **VBUMP-01**: Redis `7.4.1-alpine` → `7.4.8-alpine`. **Security** (CRLF injection fix). arm64 ✅. После recreate: `redis-cli ping` → PONG, Dify api/worker не теряют connection (depends_on с healthcheck).
- [ ] **VBUMP-02**: Grafana `12.4.2` → `12.4.3`. **Security** (CVE-2026-27876, CVE-2026-27877). arm64 ✅. После recreate: `http://agmind-grafana.local` login OK, дашборды master + peer-worker рендерятся, datasource Prometheus OK.
- [ ] **VBUMP-03**: SOPS binary `v3.9.4` → `v3.12.2`. **Bugfixes + age plugin**. ОБЯЗАТЕЛЬНО обновить `SOPS_SHA256_ARM64` и `SOPS_SHA256_AMD64` в `templates/versions.env` (новые hashes из `https://github.com/getsops/sops/releases/download/v3.12.2/sops-v3.12.2.checksums.txt`). После: `/opt/agmind/bin/sops --version` показывает `3.12.2`, decrypt существующего secrets-файла OK.
- [ ] **VBUMP-04**: Ollama `0.20.6` → `v0.21.2`. Stability. arm64 ✅. После recreate: `curl http://localhost:11434/api/tags` OK, embedding model отвечает (`agmind health`).
- [ ] **VBUMP-05**: SearXNG `2026.4.7` → `2026.4.24`. Rolling release. arm64 ✅. После recreate: search query через UI отдаёт результаты.
- [ ] **VBUMP-06**: SurrealDB `v2.2.1` → `v2.6.5` (within 2.x). **DO NOT v3.x** (major API breaking — HOLD list). arm64 ✅. Notebook сейчас disabled (BACKLOG #999.1) — но тег обновляем чтобы fresh install не тащил старый. После recreate (если ENABLE_NOTEBOOK=true): startup OK, нет ROOT auth divergence (это уже отдельный баг #999.1).
- [ ] **VBUMP-07**: Postgres `16-alpine` → `16-alpine3.23`. Alpine base bump (security patches userland). arm64 ✅. **ОСТОРОЖНО при recreate** — Dify api/worker depends_on postgres service_healthy, ~10 сек простоя ожидаемо. После: `psql` connect OK, Dify console грузится, knowledge base list работает.
- [ ] **VBUMP-08**: Redis Exporter `oliver006/redis_exporter:v1.69.0` → `v1.82.0`. Distroless, healthcheck unchanged. arm64 ✅. После recreate: `curl http://localhost:9121/metrics` отдаёт `redis_*`, Prometheus target `up{job="redis-exporter"}=1`.
- [ ] **VBUMP-09**: Postgres Exporter `prometheuscommunity/postgres-exporter:v0.17.1` → `v0.19.1`. Perf + bugfixes. arm64 ✅. После recreate: `pg_*` метрики в Prometheus OK.
- [ ] **VBUMP-10**: Nginx Exporter `nginx/nginx-prometheus-exporter:1.4.2` → `1.5.1`. Proxy v2 fix. arm64 ✅. После recreate: `nginx_*` метрики OK, dashboard "AGmind Nginx" рендерится.
- [ ] **VBUMP-11**: cAdvisor `gcr.io/cadvisor/cadvisor:v0.52.1` → `v0.55.1`. **arm64 ceiling** — v0.56.0/v0.56.1/v0.56.2 НЕ имеют arm64 manifest (CLAUDE.md §8 правило подтверждено). После recreate: `container_*` метрики, GPU containers visible, dashboard "AGmind Containers" OK.

**Live UAT acceptance (общий для VBUMP-01..11):**
- `bash tests/compose/test_image_tags_exist.sh` PASS (DoD §10 gate, ловит галлюцинации).
- `sudo docker ps --filter status=unhealthy` пуст после всех recreate.
- `agmind health` всё OK (включая peer если cluster_mode=master).
- `sudo docker compose config | grep image:` показывает все 11 новых тегов.

## Future Requirements (v3.1+)

### Model picker wizard (deferred из v3.0 discussions)
### Traefik migration (если mDNS hotfix не решит symptom — fallback)
### GPU budget tracker
### Kubernetes / multi-peer scaling

---

*Updated: 2026-04-25 — 25 requirements mapped to 3 phases (14 v3.0.1 + 11 VBUMP)*
