---
sidebar_position: 4
---

# Network Isolation

AGMind uses Docker network segmentation to isolate services by security zone.

## Network Architecture

```
┌─────────────────────────────────────────────────┐
│                  Host Machine                    │
│                                                  │
│  ┌──────────── agmind-frontend ───────────────┐ │
│  │ (bridge - external access)                  │ │
│  │                                             │ │
│  │  ┌───────┐  ┌─────────┐  ┌──────────┐     │ │
│  │  │ Nginx │  │ Grafana │  │Portainer │     │ │
│  │  │:80,:443│ │  :3001  │  │  :9000   │     │ │
│  │  └───┬───┘  └─────────┘  └──────────┘     │ │
│  │      │                                      │ │
│  └──────┼──────────────────────────────────────┘ │
│         │                                         │
│  ┌──────┼──── agmind-backend ─────────────────┐  │
│  │ (internal: true - NO external access)       │  │
│  │      │                                      │  │
│  │  ┌───┴──┐ ┌──────┐ ┌────┐ ┌──────┐        │  │
│  │  │ API  │ │Worker│ │ Web│ │Plugin│        │  │
│  │  └──┬───┘ └──────┘ └────┘ └──────┘        │  │
│  │     │                                       │  │
│  │  ┌──┴───┐ ┌──────┐ ┌────────┐ ┌──────┐    │  │
│  │  │  DB  │ │Redis │ │Weaviate│ │Ollama│    │  │
│  │  │(5432)│ │(6379)│ │ (8080) │ │(11434)│   │  │
│  │  └──────┘ └──────┘ └────────┘ └──────┘    │  │
│  │                                             │  │
│  │  ⚠ No ports exposed to host!               │  │
│  └─────────────────────────────────────────────┘  │
│                                                    │
└────────────────────────────────────────────────────┘
```

## Service Network Assignments

| Service | Frontend | Backend | Ports on Host |
|---------|----------|---------|---------------|
| nginx | ✅ | ✅ | 80, 443 |
| grafana | ✅ | ✅ | 3001 (127.0.0.1 on VPS) |
| portainer | ✅ | ✅ | 9000 (127.0.0.1 on VPS) |
| api | — | ✅ | None |
| worker | — | ✅ | None |
| web | — | ✅ | None |
| db | — | ✅ | None |
| redis | — | ✅ | None |
| weaviate | — | ✅ | None |
| ollama | — | ✅ | None |

## Verification

```bash
# Backend network is internal (no external access)
docker network inspect agmind-backend | jq '.[0].Internal'
# → true

# No database ports on host
ss -tlnp | grep 5432
# → (empty)

# No Redis ports on host
ss -tlnp | grep 6379
# → (empty)

# Services can still communicate internally
docker compose exec api curl -s http://db:5432 2>&1 | head -1
# → (connection works internally)
```

## UFW Firewall (VPS Profile)

When `ENABLE_UFW=true`:

```bash
# Allowed ports
ufw status
# → 22/tcp    ALLOW   Anywhere
# → 80/tcp    ALLOW   Anywhere
# → 443/tcp   ALLOW   Anywhere

# Everything else blocked
```

## Fail2ban (VPS/LAN Profiles)

```bash
# Check jail status
fail2ban-client status agmind-nginx

# View banned IPs
fail2ban-client status agmind-nginx | grep "Banned IP"
```

Custom filter matches:
- 5+ failed login attempts → 1 hour ban
- Scanning for admin URLs → 1 hour ban
