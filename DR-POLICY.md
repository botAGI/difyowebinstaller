# AGMind Disaster Recovery Policy

## Recovery Objectives

| Metric | Target | Notes |
|--------|--------|-------|
| RPO (Recovery Point Objective) | 24 hours | Default daily backup schedule |
| RTO (Recovery Time Objective) | 1 hour | Includes restore + verification |
| MTTR (Mean Time To Repair) | 30 minutes | For single service failure |

## Backup Strategy

### Automated Backups
- **Schedule**: Daily at 02:00 (configurable via `BACKUP_SCHEDULE`)
- **Retention**: 10 backups (configurable via `BACKUP_RETENTION_COUNT`)
- **Contents**: PostgreSQL dump, vector store snapshot, volumes, .env config
- **Integrity**: SHA256 checksums for all backup files
- **Encryption**: Optional age encryption (`ENABLE_BACKUP_ENCRYPTION=true`)
- **Off-site**: Optional S3 upload (`ENABLE_S3_BACKUP=true`)

### Critical Data
1. PostgreSQL database (Dify workflows, users, API keys)
2. Vector store data (Weaviate/Qdrant embeddings)
3. `.env` configuration (secrets, API keys)
4. Ollama model data (can be re-downloaded)
5. Open WebUI user data

## Recovery Procedures

### Scenario 1: Single Service Failure
1. Check logs: `docker compose logs <service>`
2. Restart service: `docker compose restart <service>`
3. If persistent: `docker compose up -d --force-recreate <service>`
4. Verify: `./scripts/health.sh`

### Scenario 2: Full System Restore
1. Run restore runbook: `./scripts/restore-runbook.sh /var/backups/agmind/<date>`
2. Verify 7-step checklist passes
3. Check application functionality

### Scenario 3: Failed Update Rollback
1. Update system auto-rollbacks on failure
2. Manual rollback: copy `.rollback/` files back
3. `docker compose up -d`
4. Verify with health check

### Scenario 4: Infrastructure Migration
1. Create full backup on source
2. Transfer backup to target
3. Run installer on target with same .env values
4. Run restore from backup
5. Update DNS/networking

## Monthly DR Drill
- Restore latest backup to test environment
- Verify all 7 runbook steps pass
- Document any issues found
- Schedule: First Monday of each month

## Monitoring & Alerts
- Container health: Prometheus + Alertmanager
- Disk space: Alert at 15% free, critical at 5%
- Backup age: Alert if last backup >48h old
- Service restarts: Alert on >3 restarts in 15min

## Escalation
1. **L1**: Check health.sh, restart failed services
2. **L2**: Review logs, restore from backup if needed
3. **L3**: Full system restore from backup
