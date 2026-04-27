---
sidebar_position: 1
---

# Version Upgrade Guide

## Upgrade Process

### Standard Upgrade

```bash
# 1. Check available updates
sudo /opt/agmind/scripts/update.sh --check-only

# 2. Run update (creates automatic backup)
sudo /opt/agmind/scripts/update.sh
```

### From versions.env

To upgrade specific components, edit `versions.env`:

```bash
# 1. Edit versions
sudo nano /opt/agmind/versions.env

# 2. Run update
sudo /opt/agmind/scripts/update.sh --auto
```

## Version Compatibility

Always check [COMPATIBILITY.md](https://github.com/agmind/agmind-installer/blob/main/COMPATIBILITY.md) before upgrading.

### Known Constraints

| Component | Constraint | Reason |
|-----------|-----------|--------|
| Weaviate | ≥ 1.27.0 | Dify requires weaviate-client v4 |
| Plugin Daemon | ≥ 0.5.3 | Breaking API changes in 0.2+ |
| Ollama | Match API version | Open WebUI compatibility |
| PostgreSQL | Same major version | pg_dump compatibility |

## Rollback

### Automatic Rollback

The update script automatically rolls back on failure:

1. Service fails health check → service image reverted
2. Cascade failure → full config + restart

### Manual Rollback

```bash
# From pre-update backup (created automatically)
ls /var/backups/agmind/pre-update-*
sudo /opt/agmind/scripts/restore.sh /var/backups/agmind/pre-update-YYYYMMDD_HHMMSS

# From rollback state
cp /opt/agmind/.rollback/dot-env.bak /opt/agmind/docker/.env
cp /opt/agmind/.rollback/versions.env.bak /opt/agmind/versions.env
cd /opt/agmind/docker && docker compose up -d
```

## Major Version Upgrades

For major version changes (e.g., Dify 1.x → 2.x):

1. **Read release notes** for breaking changes
2. **Create full backup**: `sudo /opt/agmind/scripts/backup.sh`
3. **Test on staging** if possible
4. **Update versions.env** with new versions
5. **Run update**: `sudo /opt/agmind/scripts/update.sh`
6. **Verify**: `sudo /opt/agmind/scripts/health.sh`
7. **Run DR drill**: `sudo /opt/agmind/scripts/dr-drill.sh --skip-restore`
