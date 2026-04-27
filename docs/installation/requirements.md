---
sidebar_position: 5
---

# System Requirements

## Hardware

| Component | Minimum | Recommended | With GPU |
|-----------|---------|-------------|----------|
| CPU | 2 cores | 4+ cores | 4+ cores |
| RAM | 4 GB | 16 GB | 32 GB |
| Disk | 20 GB | 50 GB | 100+ GB |
| GPU | — | — | NVIDIA 8GB+ VRAM |

## Software

| Software | Minimum Version | Notes |
|----------|----------------|-------|
| Docker | 24.0 | Docker Engine (not Desktop) |
| Docker Compose | 2.20 | V2 plugin (not standalone) |
| Ubuntu | 20.04 LTS | Recommended: 22.04 LTS |
| Debian | 11 (Bullseye) | |
| CentOS | 8 Stream | RHEL 8+ also supported |

## Network Ports

| Port | Service | Required |
|------|---------|----------|
| 80 | HTTP (Nginx) | Yes |
| 443 | HTTPS (Nginx) | If TLS enabled |
| 22 | SSH | For management |
| 3001 | Grafana | If monitoring enabled |
| 9000 | Portainer | If Portainer enabled |

## Pre-flight Checks

The installer runs automated pre-flight checks:

```bash
# Run manually
sudo bash install.sh  # checks run automatically

# Or via health script
sudo /opt/agmind/scripts/health.sh
```

Checks include:
- OS version compatibility
- Docker and Compose versions
- Available disk space (FAIL < 10GB, WARN < 30GB)
- Available RAM (FAIL < 4GB)
- CPU cores (WARN < 2)
- Port availability (80, 443)
- Docker daemon status
- Internet connectivity (skipped for offline profile)
