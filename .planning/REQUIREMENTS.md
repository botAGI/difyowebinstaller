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
- [ ] **PEER-05**: `phase_deploy_peer` (новая фаза в `install.sh`, вызывается после `phase_start` если `MODE=master`): `scp templates/docker-compose.worker.yml + rendered .env` на peer → `ssh peer 'cd /opt/agmind && docker compose -f docker-compose.worker.yml up -d'` → wait `curl http://${PEER_IP}:8000/v1/models` returns 200 (timeout 30 min для первой скачки модели) → `cluster.json.status=running`.
- [ ] **PEER-06**: `phase_post_install_smoke` на master включает peer check: `curl -sSf http://${PEER_IP}:8000/v1/models | jq '.data[0].id'` возвращает выбранную модель. Smoke exit 1 при failure (STRICT).

### CLUSTER — Mode selection & persistence (Phase 2)

- [x] **CLUSTER-01**: `cluster_mode_select` TUI (в `lib/wizard.sh` или новом `lib/cluster_mode.sh`) показывает 3 options: single / master / worker. Dialog/whiptail primary + readline fallback. Persist `cluster.json` atomic (`.tmp` + `mv`).
- [x] **CLUSTER-02**: Mode menu вызывается в `run_wizard()` **сразу после** `phase_preflight` (который вызвал `hw_detect_peer`). Если peer not detected — menu skip'ается, `mode=single` default (uncommitted в cluster.json).

### COMPOSE — Compose split for master/worker (Phase 2)

- [ ] **COMPOSE-01**: `templates/docker-compose.worker.yml` (новый) содержит только: `vllm` (с ${VLLM_*} env), `socket-proxy` (wollomatic, для docker API access на peer если потребуется), опционально `node-exporter` (prometheus scrape target). Нет Dify, Postgres, Redis, etc. — они только на master. Labels совместимы с master'ским мониторингом (scrape endpoint discovery).

### SSH — Passwordless SSH setup (Phase 2)

- [ ] **SSH-01**: `_ensure_ssh_trust <peer_ip>` (новый helper в `lib/detect.sh` или отдельный `lib/ssh_trust.sh`): (1) проверяет `ssh -o BatchMode=yes ${peer_user}@${peer_ip} true` — если OK, return 0. (2) Если fail — wizard prompt'ит пароль peer один раз через TUI password input. (3) `ssh-copy-id -i ~/.ssh/agmind_peer_ed25519.pub ${peer_user}@${peer_ip}` (key генерится если отсутствует). (4) Verify через `ssh -o BatchMode=yes`. Credentials (пароль) в memory only, не на disk.

## Future Requirements (v3.1+)

### Model picker wizard (deferred из v3.0 discussions)
### Traefik migration (если mDNS hotfix не решит symptom — fallback)
### GPU budget tracker
### Kubernetes / multi-peer scaling

---

*Updated: 2026-04-21 — 14 requirements mapped to 2 phases*
