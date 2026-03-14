---
sidebar_position: 3
---

# Updates

AGMind uses a rolling update system with automatic rollback on failure.

## Update Process

```bash
# Check for available updates (no changes)
sudo /opt/agmind/scripts/update.sh --check-only

# Interactive update
sudo /opt/agmind/scripts/update.sh

# Automatic update (no prompts)
sudo /opt/agmind/scripts/update.sh --auto
```

### Update Flow

1. **Pre-flight checks** — disk space, Docker status
2. **Version comparison** — current vs. new versions table
3. **Pre-update backup** — automatic backup with `pre-update-*` tag
4. **Rollback state saved** — configs and image digests preserved
5. **Rolling restart** — services updated one-by-one:
   - Infrastructure: db → redis
   - Application: api → worker → web → plugin_daemon
   - Frontend: nginx → open-webui → ollama
6. **Health check** — each service verified healthy before proceeding
7. **Notification** — success/failure alert sent

### Rollback

If any service fails health check after update:

1. **Automatic service rollback** — failed service reverted to previous image
2. **If cascade failure** — full rollback: configs restored, all services restarted
3. **Notification sent** — alert with failure details

### Manual Rollback

```bash
# Restore from pre-update backup
sudo /opt/agmind/scripts/restore.sh /var/backups/agmind/pre-update-*

# Or restore .env manually
cp /opt/agmind/docker/.env.pre-update /opt/agmind/docker/.env
cd /opt/agmind/docker && docker compose up -d
```

## Version Management

All versions are pinned in `versions.env` (single source of truth):

```bash
cat /opt/agmind/versions.env
```

No service uses `:latest` tags. Every update is explicit and reproducible.

## Update History

```bash
cat /opt/agmind/logs/update_history.log
```
