---
sidebar_position: 1
---

# Security Overview

AGMind implements defense-in-depth security following CIS Docker Benchmark and OWASP guidelines.

## Security Architecture

```
Internet
    │
    ▼
┌─────────────┐
│  UFW / F2B  │ ← Host firewall + intrusion detection
└──────┬──────┘
       │
┌──────┴──────┐
│    Nginx    │ ← Rate limiting, security headers, TLS
│  (frontend  │   X-Frame-Options, CSP, HSTS
│   network)  │
└──────┬──────┘
       │
┌──────┴──────┐
│   Backend   │ ← Internal network (no external access)
│   Network   │   no-new-privileges, cap_drop: ALL
│             │
│  ┌───┐ ┌──┐│
│  │API│ │WK││ ← Application services
│  └───┘ └──┘│
│  ┌──┐ ┌───┐│
│  │DB│ │RDS││ ← Data services (scram-sha-256, requirepass)
│  └──┘ └───┘│
└─────────────┘
```

## Security Features

| Layer | Feature | Default |
|-------|---------|---------|
| **Host** | UFW firewall | VPS: ON |
| **Host** | Fail2ban IDS | VPS/LAN: ON |
| **Network** | Frontend/backend isolation | Always ON |
| **Network** | Internal-only data network | Always ON |
| **Container** | no-new-privileges | Always ON |
| **Container** | cap_drop: ALL | Always ON |
| **Container** | Read-only filesystems | nginx, redis |
| **Container** | Resource limits | All services |
| **Application** | Rate limiting (Nginx) | Always ON |
| **Application** | Security headers | Always ON |
| **Data** | scram-sha-256 (PostgreSQL) | Always ON |
| **Data** | Redis requirepass + command disable | Always ON |
| **Data** | Backup encryption (age) | Optional |
| **Secrets** | Auto-generated (openssl rand) | Always ON |
| **Secrets** | SOPS encryption | VPS: ON |
| **Secrets** | Secret rotation | Optional |

## No Default Passwords

Every secret is generated at install time using `openssl rand -base64 32`. The installer validates that no known defaults (like `difyai123456`, `changeme`, `password`) remain in the configuration.

## Compliance

- **CIS Docker Benchmark** — no-new-privileges, cap_drop ALL, logging limits
- **OWASP Headers** — X-Frame-Options, X-Content-Type-Options, CSP, HSTS
- **Network Segmentation** — frontend (bridge) + backend (internal: true)
