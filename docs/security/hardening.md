---
sidebar_position: 2
---

# Container Hardening

All AGMind containers follow CIS Docker Benchmark Level 1 recommendations.

## Security Defaults

Applied to every service via YAML anchor `x-security-defaults`:

```yaml
x-security-defaults: &security-defaults
  security_opt:
    - no-new-privileges:true
  cap_drop:
    - ALL
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "5"
```

### Per-Service Capabilities

| Service | Additional `cap_add` | `read_only` | Notes |
|---------|---------------------|-------------|-------|
| nginx | — | Yes | tmpfs: /tmp, /var/cache/nginx |
| redis | — | Yes | tmpfs: /tmp |
| ollama | SYS_ADMIN | No | Required for GPU access |
| db | — | No | Needs write for data |
| All others | — | No | Default security profile |

## Network Isolation

Two Docker networks with different access levels:

### `agmind-frontend` (bridge)
- External access allowed (port mapping)
- Services: nginx, grafana, portainer

### `agmind-backend` (internal: true)
- **No external access** — containers only
- Services: db, redis, api, worker, web, ollama, weaviate/qdrant, plugin_daemon
- No ports exposed to host

```bash
# Verify backend is internal
docker network inspect agmind-backend | jq '.[0].Internal'
# Should return: true

# Verify no DB/Redis ports on host
ss -tlnp | grep -E "5432|6379"
# Should return nothing
```

## PostgreSQL Hardening

```bash
# Verify SSL enabled
docker compose exec db psql -U postgres -c "SHOW ssl"
# → on

# Verify scram-sha-256
docker compose exec db psql -U postgres -c "SHOW password_encryption"
# → scram-sha-256
```

## Redis Hardening

```bash
# Verify authentication required
docker compose exec redis redis-cli PING
# → NOAUTH Authentication required

# Verify dangerous commands disabled
docker compose exec redis redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory
# → ERR unknown command 'CONFIG'
```

Disabled commands: `FLUSHALL`, `FLUSHDB`, `CONFIG`, `DEBUG`, `SHUTDOWN` (renamed).

## Nginx Hardening

### Security Headers

```
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=()
```

With TLS enabled, adds:
```
Strict-Transport-Security: max-age=31536000; includeSubDomains
```

### Rate Limiting

| Zone | Rate | Burst | Applied To |
|------|------|-------|------------|
| api | 10 req/s | 20 | `/dify/console/api/` |
| login | 3 req/s | 5 | `/dify/console/api/login` |

### Admin Token URL Blocked

Any attempt to access `/<hex-string-24+>/` returns 404:

```bash
curl http://your-server/abc123def456789012345678/
# → 404 Not Found
```
