---
sidebar_position: 2
---

# Disaster Recovery Procedures

## Recovery Objectives

| Metric | Target | Measured |
|--------|--------|----------|
| **RPO** (Recovery Point Objective) | 24 hours | Daily backups at 03:00 |
| **RTO** (Recovery Time Objective) | 60 minutes | Tested via monthly DR drills |

## Recovery Scenarios

### Scenario 1: Single Service Failure

**Symptoms:** One container down, others healthy.

```bash
# 1. Restart the service
docker compose -f /opt/agmind/docker/docker-compose.yml restart <service>

# 2. Wait 30s, verify
docker compose -f /opt/agmind/docker/docker-compose.yml ps <service>
sudo /opt/agmind/scripts/health.sh
```

**RTO:** < 5 minutes

### Scenario 2: Full Stack Failure

**Symptoms:** All containers down (e.g., host reboot, Docker crash).

```bash
# 1. Ensure Docker is running
sudo systemctl start docker

# 2. Start all services
cd /opt/agmind/docker && docker compose up -d

# 3. Wait 2 minutes for health checks
sleep 120 && sudo /opt/agmind/scripts/health.sh
```

**RTO:** < 10 minutes

### Scenario 3: Data Corruption

**Symptoms:** Application errors, inconsistent data, database corruption.

```bash
# 1. Stop all services
cd /opt/agmind/docker && docker compose down

# 2. Run verified restore from latest backup
sudo /opt/agmind/scripts/restore-runbook.sh /var/backups/agmind/<latest>

# 3. The runbook performs 7-step verification automatically
```

**RTO:** 30-60 minutes (depends on data volume)

### Scenario 4: Failed Upgrade

**Symptoms:** Services unhealthy after update.

```bash
# Option A: Auto-rollback (update.sh does this automatically)
# Check update log for rollback status:
cat /opt/agmind/logs/update_history.log

# Option B: Manual rollback from saved state
cp /opt/agmind/.rollback/dot-env.bak /opt/agmind/docker/.env
cp /opt/agmind/.rollback/versions.env.bak /opt/agmind/versions.env
cd /opt/agmind/docker && docker compose up -d

# Option C: Full restore from pre-update backup
sudo /opt/agmind/scripts/restore.sh /var/backups/agmind/pre-update-*
```

**RTO:** 15-30 minutes

### Scenario 5: Complete Host Loss

**Symptoms:** Server destroyed, need to rebuild.

```bash
# On new server:

# 1. Install AGMind
git clone https://github.com/agmind/agmind-installer.git
cd agmind-installer && sudo bash install.sh

# 2. Copy backup from remote/S3
# If S3: rclone copy s3:agmind-backups/hostname/<latest> /var/backups/agmind/<latest>
# If rsync: rsync -azP backup-server:/var/backups/agmind/<latest> /var/backups/agmind/

# 3. Restore
sudo /opt/agmind/scripts/restore-runbook.sh /var/backups/agmind/<latest>
```

**RTO:** 30-60 minutes (plus transfer time)

## Monthly DR Drill

Run the automated DR drill monthly:

```bash
# Backup-only drill (no downtime)
sudo /opt/agmind/scripts/dr-drill.sh --skip-restore

# Full drill with restore test (brief downtime)
sudo /opt/agmind/scripts/dr-drill.sh

# View previous drill reports
ls -lt /opt/agmind/logs/dr-drills/
```

The DR drill automatically:
1. Validates environment
2. Checks current service health
3. Creates fresh backup
4. Verifies backup integrity
5. Tests restore (optional)
6. Verifies post-restore health
7. Generates report with RTO measurement

## Backup Verification Checklist

- [ ] Daily backups running (check `crontab -l`)
- [ ] Backup rotation working (check backup count)
- [ ] Checksums verified (`sha256sum -c sha256sums.txt`)
- [ ] Remote backup syncing (if configured)
- [ ] Encryption working (if enabled)
- [ ] DR drill passed this month
- [ ] Age keys stored separately from backups
