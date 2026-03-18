---
phase: quick-260318-e1f
plan: 01
completed: 2026-03-18
---

# Quick Task: Fix remaining bugs — atomic sed, BUG-015, restart policies, plugin pool, logrotate

## Accomplishments

### Task 1: Atomic sed in config.sh (18 → 0 sed -i.bak)
- Created `_atomic_sed()` helper function: `sed ... file > tmp.$$ && mv tmp.$$ file`
- Replaced all 18 `sed -i.bak` calls in: generate_nginx_config (5), enable_gpu_compose (7), configure_alertmanager (2), generate_sandbox_config (1), enable_authelia_nginx (1), TLS cert paths (1), server name (1)
- Verified: `grep -c 'sed -i' lib/config.sh` returns 0

### Task 2: BUG-015 proper error handling
- Replaced `docker compose up -d 2>/dev/null || true` with `docker compose up -d 2>&1 | tail -5` (errors visible)
- Added post-loop check: if containers still stuck after 3 retries, logs stuck container names and warns
- Same fix applied to final compose up after admin creation

### Task 3: Monitoring restart policies (8 services)
- Changed prometheus, alertmanager, loki, promtail, node-exporter, cadvisor, grafana, portainer from `restart: always` to `restart: on-failure:5`
- Prevents OOM restart loops: containers stop after 5 consecutive failures instead of infinite loop
- Core services (db, redis, api, worker, nginx) remain `restart: always` — they must stay up

### Task 4: Plugin daemon ROUTINE_POOL_SIZE capped
- Changed default from 100 to 10: `${ROUTINE_POOL_SIZE:-10}`
- Rationale: 10 workers × ~100MB = ~1GB peak, fits within 2g mem_limit

### Task 5: Logrotate config for cron logs
- Created `templates/logrotate-agmind.conf` — rotates daily, 7 days retention, compress, 0600 perms
- Covers: `INSTALL_DIR/*.log` + `/var/log/agmind-*.log`
- Installed in `phase_complete()` to `/etc/logrotate.d/agmind`

## Files Modified
- `lib/config.sh` — _atomic_sed helper + 18 sed replacements
- `install.sh` — BUG-015 fix + logrotate installation
- `templates/docker-compose.yml` — restart policies + pool size
- `templates/logrotate-agmind.conf` — new file

## Verification
- `bash -n install.sh` → OK
- `bash -n lib/config.sh` → OK
- `grep -c 'sed -i' lib/config.sh` → 0
- `grep -c 'on-failure' templates/docker-compose.yml` → 8
- All syntax checks pass
