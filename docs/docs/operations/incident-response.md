---
sidebar_position: 5
---

# Incident Response

Decision tree for common AGMind incidents.

## Severity Levels

| Level | Description | Response Time | Examples |
|-------|-------------|---------------|----------|
| P1 — Critical | Service completely down | 15 min | All containers down, data loss |
| P2 — Major | Key feature unavailable | 1 hour | Dify API down, DB unreachable |
| P3 — Minor | Degraded performance | 4 hours | High CPU, slow queries |
| P4 — Low | Cosmetic/non-urgent | Next business day | Log warnings, minor UI issues |

## Decision Tree

### Container Down

```
Container is down
├── Single container?
│   ├── Yes → docker compose restart <service>
│   │   ├── Still down? → Check logs: docker compose logs <service>
│   │   │   ├── OOM killed → Increase memory limit in docker-compose.yml
│   │   │   ├── Config error → Check .env and service config
│   │   │   └── Image missing → docker compose pull <service>
│   │   └── Back up → Monitor for 10 min, check health.sh
│   └── All containers down?
│       ├── Docker daemon running? → systemctl status docker
│       │   ├── No → systemctl start docker && cd /opt/agmind/docker && docker compose up -d
│       │   └── Yes → Check disk space: df -h
│       │       ├── Disk full → docker system prune, clean logs
│       │       └── Disk OK → docker compose up -d, check logs
│       └── Host rebooted? → docker compose up -d (auto-restart should handle this)
```

### Database Issues

```
Database problem
├── Cannot connect?
│   ├── Container running? → docker compose ps db
│   │   ├── No → docker compose up -d db, wait 30s
│   │   └── Yes → Check logs: docker compose logs db
│   │       ├── "too many connections" → Restart: docker compose restart db
│   │       ├── "data directory has wrong ownership" → Fix permissions
│   │       └── Corruption → Restore from backup (see below)
│   └── Password changed?
│       └── Compare .env DB_PASSWORD with actual: docker compose exec db psql -U postgres
├── Slow queries?
│   ├── Check connections: docker compose exec db psql -U postgres -c "SELECT count(*) FROM pg_stat_activity"
│   └── Check locks: docker compose exec db psql -U postgres -c "SELECT * FROM pg_locks WHERE NOT granted"
└── Data corruption?
    ├── Stop services: docker compose down
    ├── Restore: sudo /opt/agmind/scripts/restore-runbook.sh /var/backups/agmind/<latest>
    └── Verify: health.sh
```

### High Resource Usage

```
High CPU/Memory/Disk
├── Identify culprit: docker stats --no-stream
├── CPU > 90%?
│   ├── Ollama → Normal during inference. Check OLLAMA_NUM_PARALLEL
│   ├── API/Worker → Check for stuck workflows in Dify
│   └── System → Check for crypto miners: top -c
├── Memory > 90%?
│   ├── Ollama → Reduce model size or OLLAMA_NUM_PARALLEL
│   ├── Redis → Check maxmemory setting
│   └── DB → Check max_connections, shared_buffers
└── Disk > 85%?
    ├── Docker images: docker system prune -f
    ├── Logs: truncate -s 0 /var/log/agmind-*.log
    ├── Old backups: check retention settings
    └── Ollama models: remove unused models
```

### Backup Failure

```
Backup failed
├── Check log: cat /var/log/agmind-backup.log
├── Disk space? → df -h /var/backups/agmind
├── PostgreSQL accessible? → docker compose exec db pg_isready
├── Lock file stuck? → rm /var/lock/agmind-operation.lock
└── Run manually: sudo /opt/agmind/scripts/backup.sh
```

## Recovery Procedures

### Full Restore from Backup

```bash
# 1. Find latest backup
ls -lt /var/backups/agmind/

# 2. Run verified restore
sudo /opt/agmind/scripts/restore-runbook.sh /var/backups/agmind/YYYY-MM-DD_HHMM

# 3. Verify
sudo /opt/agmind/scripts/health.sh
```

### Rollback After Failed Update

```bash
# Option A: Automatic (if .rollback exists)
# update.sh does this automatically

# Option B: Manual from pre-update backup
sudo /opt/agmind/scripts/restore.sh /var/backups/agmind/pre-update-*

# Option C: Manual config restore
cp /opt/agmind/.rollback/dot-env.bak /opt/agmind/docker/.env
cp /opt/agmind/.rollback/versions.env.bak /opt/agmind/versions.env
cd /opt/agmind/docker && docker compose up -d
```

### Complete Reinstall (Last Resort)

```bash
# 1. Backup current data
sudo /opt/agmind/scripts/backup.sh

# 2. Uninstall
sudo /opt/agmind/scripts/uninstall.sh

# 3. Fresh install
sudo bash install.sh

# 4. Restore data
sudo /opt/agmind/scripts/restore.sh /var/backups/agmind/<latest>
```

## Post-Incident

After resolving any incident:

1. **Verify** — Run `health.sh` to confirm all clear
2. **Document** — Note root cause and fix in incident log
3. **Prevent** — Add monitoring/alerts for the failure mode
4. **Test** — Run DR drill to verify recovery procedures
