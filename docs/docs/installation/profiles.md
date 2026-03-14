---
sidebar_position: 2
---

# Deployment Profiles

AGMind supports 4 deployment profiles, each with different security defaults and network configurations.

## Profile Comparison

| Feature | VPS | LAN | VPN | Offline |
|---------|-----|-----|-----|---------|
| Public internet access | Yes | No | Via VPN | No |
| UFW firewall | Enabled | Disabled | Disabled | Disabled |
| Fail2ban | Enabled | Enabled | Enabled | Disabled |
| SOPS encryption | Enabled | Disabled | Disabled | Disabled |
| TLS/SSL | Recommended | Optional | Optional | N/A |
| Tunnel support | Cloudflare/ngrok | N/A | N/A | N/A |

## VPS Profile

Best for: cloud servers, public-facing deployments.

```bash
export DEPLOY_PROFILE=vps
```

Security defaults (auto-enabled):
- UFW firewall with ports 22, 80, 443 open
- Fail2ban with nginx jail
- SOPS secret encryption
- Rate limiting on API endpoints

## LAN Profile

Best for: office/home network, internal use.

```bash
export DEPLOY_PROFILE=lan
```

- Binds to `0.0.0.0` (accessible on local network)
- Fail2ban enabled by default
- No firewall rules (assumes trusted network)

## VPN Profile

Best for: access via WireGuard/OpenVPN tunnel.

```bash
export DEPLOY_PROFILE=vpn
```

- Binds to VPN interface
- Fail2ban enabled
- Network restricted to VPN subnet

## Offline Profile

Best for: air-gapped environments, no internet access.

```bash
export DEPLOY_PROFILE=offline
```

- All Docker images must be pre-loaded
- No external connectivity checks
- See [Offline Installation](offline-install) for details

## Configuration Variables

All profiles support these environment variables:

```bash
# Core
DEPLOY_PROFILE=vps          # vps|lan|vpn|offline
INSTALL_DIR=/opt/agmind     # Installation directory
DOMAIN=ai.example.com       # Domain name (for TLS)

# Features
VECTOR_STORE=weaviate       # weaviate|qdrant
MONITORING_MODE=local       # local|none
ETL_TYPE=dify               # dify|unstructured_api

# Security overrides
ENABLE_UFW=true             # UFW firewall
ENABLE_FAIL2BAN=true        # Fail2ban IDS
ENABLE_SOPS=false           # Secret encryption
DISABLE_SECURITY_DEFAULTS=false  # Override all security defaults

# Backup
BACKUP_SCHEDULE="0 3 * * *" # Cron schedule
ENABLE_S3_BACKUP=false      # S3 remote backup
ENABLE_BACKUP_ENCRYPTION=false  # Age encryption
```
