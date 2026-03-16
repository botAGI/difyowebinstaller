---
sidebar_position: 2
---

# Backup & Restore

AGMind provides automated backups with rotation, encryption, and remote storage.

## Backup

### What's Backed Up

| Data | Method | File |
|------|--------|------|
| PostgreSQL (Dify) | `pg_dump` | `dify_db.sql.gz` |
| PostgreSQL (Plugins) | `pg_dump` | `dify_plugin_db.sql.gz` |
| Weaviate data | Volume tar | `weaviate.tar.gz` |
| Qdrant data | Volume tar | `qdrant.tar.gz` |
| Dify uploads | Volume tar | `dify-storage.tar.gz` |
| Open WebUI data | Volume tar | `openwebui.tar.gz` |
| Ollama models | Volume tar | `ollama.tar.gz` |
| Configuration | File copy | `env.backup`, `nginx.conf.backup` |
| Integrity | SHA-256 | `sha256sums.txt` |

### Manual Backup

```bash
sudo /opt/agmind/scripts/backup.sh
```

Backups are saved to `/var/backups/agmind/YYYY-MM-DD_HHMM/`.

### Scheduled Backups

Configured during installation. Default: daily at 3:00 AM.

```bash
# Check current schedule
crontab -l | grep agmind

# Modify schedule
crontab -e
# Change: 0 3 * * * /opt/agmind/scripts/backup.sh ...
```

### Backup Options

```bash
# Environment variables in backup.conf
BACKUP_RETENTION_DAYS=7      # Delete backups older than N days
BACKUP_RETENTION_COUNT=10    # Keep only N most recent backups
```

### Encryption

```bash
# Enable in .env
ENABLE_BACKUP_ENCRYPTION=true
```

Backups are encrypted with `age` using the key at `/opt/agmind/.age/agmind.key`.

:::caution
Store your age key separately! It is NOT included in backups for security.
:::

### S3 Remote Backup

```bash
# Configure in .env
ENABLE_S3_BACKUP=true
S3_REMOTE_NAME=s3
S3_BUCKET=agmind-backups
S3_PATH=hostname
```

Requires `rclone` configured with your S3 credentials.

## Restore

### Quick Restore

```bash
# List available backups
ls /var/backups/agmind/

# Restore from specific backup
sudo /opt/agmind/scripts/restore.sh /var/backups/agmind/2026-03-14_0300
```

### Verified Restore (7-Step Runbook)

For critical restores, use the verified runbook:

```bash
sudo /opt/agmind/scripts/restore-runbook.sh /var/backups/agmind/2026-03-14_0300
```

Steps:
1. Verify backup integrity (checksums)
2. Pre-restore environment check
3. Stop running services
4. Execute restore
5. Start services and wait for health
6. Post-restore health verification
7. Functional verification (API endpoints)

### Restore Encrypted Backups

The restore script auto-detects `.age` encrypted files and decrypts them using the key at `/opt/agmind/.age/agmind.key`.

```bash
# If key is in a different location
AGE_KEY=/path/to/key sudo /opt/agmind/scripts/restore.sh /var/backups/agmind/2026-03-14_0300
```

## DR Drills

Monthly DR drills validate the entire backup/restore pipeline:

```bash
# Backup-only drill (no downtime)
sudo /opt/agmind/scripts/dr-drill.sh --skip-restore

# Full drill (includes restore test — causes brief downtime)
sudo /opt/agmind/scripts/dr-drill.sh

# Dry run (no changes)
sudo /opt/agmind/scripts/dr-drill.sh --dry-run
```

DR drill reports are saved to `/opt/agmind/logs/dr-drills/`.
