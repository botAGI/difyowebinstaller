---
sidebar_position: 1
---

# Quickstart

Get AGMind running in under 10 minutes.

## Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Ubuntu 20.04+ / Debian 11+ | Ubuntu 22.04 LTS |
| RAM | 4 GB | 16 GB (8GB+ for LLMs) |
| Disk | 20 GB | 50+ GB |
| CPU | 2 cores | 4+ cores |
| Docker | 24.0+ | Latest stable |
| Docker Compose | 2.20+ | Latest stable |

## Installation

### 1. Clone and run

```bash
git clone https://github.com/agmind/agmind-installer.git
cd agmind-installer
sudo bash install.sh
```

### 2. Follow the wizard

The interactive wizard will guide you through:

1. **Deployment profile** — VPS, LAN, VPN, or Offline
2. **GPU detection** — auto-detects NVIDIA/AMD/Intel or CPU fallback
3. **Vector store** — Weaviate (default) or Qdrant
4. **Monitoring** — Prometheus + Grafana stack (recommended)
5. **Backup schedule** — automated daily backups
6. **Admin credentials** — auto-generated secure passwords

### 3. Access your services

After installation completes:

| Service | URL |
|---------|-----|
| Open WebUI (Chat) | `http://your-server/` |
| Dify Console | `http://your-server/dify/` |
| Grafana (Monitoring) | `http://your-server:3001/` |

Admin credentials are displayed at the end of installation and saved to `/opt/agmind/docker/.admin_password`.

## Non-Interactive Install

For automation and CI/CD:

```bash
export NON_INTERACTIVE=true
export DEPLOY_PROFILE=vps
export VECTOR_STORE=weaviate
export MONITORING_MODE=local
export BACKUP_SCHEDULE="0 3 * * *"

sudo -E bash install.sh
```

See [Profiles](profiles) for all configuration options.

## Verify Installation

```bash
# Check all services are healthy
sudo /opt/agmind/scripts/health.sh

# Check container status
cd /opt/agmind/docker && docker compose ps
```

## Next Steps

- [Configure GPU](gpu-setup) for LLM acceleration
- [Set up alerting](../operations/alerting) for push notifications
- [Security hardening](../security/overview) review
