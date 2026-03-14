---
sidebar_position: 3
---

# Secret Management

## Auto-Generated Secrets

During installation, all secrets are generated using cryptographically secure random:

```bash
openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
```

Generated secrets include:
- `SECRET_KEY` — Dify application secret
- `DB_PASSWORD` — PostgreSQL password
- `REDIS_PASSWORD` — Redis authentication
- `GRAFANA_ADMIN_PASSWORD` — Grafana admin
- `SANDBOX_API_KEY` — Dify sandbox API key
- `PLUGIN_DAEMON_KEY` — Plugin daemon key
- `PLUGIN_INNER_API_KEY` — Plugin internal API key

## File Permissions

```bash
# .env file: root-only readable
chmod 600 /opt/agmind/docker/.env
chown root:root /opt/agmind/docker/.env

# Admin password file
chmod 600 /opt/agmind/docker/.admin_password
```

## SOPS Encryption

When `ENABLE_SOPS=true` (default for VPS profile), the `.env` file is encrypted at rest:

```bash
# Encrypt
sops --encrypt --age $(cat /opt/agmind/.age/agmind.key | grep 'public key:' | cut -d: -f2-) \
  /opt/agmind/docker/.env > /opt/agmind/docker/.env.enc

# Decrypt (done automatically at startup)
sops --decrypt --age /opt/agmind/.age/agmind.key \
  /opt/agmind/docker/.env.enc > /opt/agmind/docker/.env
```

## Secret Rotation

Optional automatic secret rotation:

```bash
# Manual rotation
sudo /opt/agmind/scripts/rotate_secrets.sh

# Enable monthly auto-rotation
ENABLE_SECRET_ROTATION=true  # in .env
```

The rotation script:
1. Generates new secrets
2. Updates `.env`
3. Restarts affected services
4. Sends notification

## Validation

The installer validates that no default/weak secrets exist:

```bash
# Should return nothing (no known defaults)
grep -E "(changeme|password|difyai123456|QaHbTe77|admin123)" /opt/agmind/docker/.env
```

Checked defaults: `difyai123456`, `QaHbTe77`, `changeme`, `password`, `admin123`, `secret`, `default`, `test1234`.
