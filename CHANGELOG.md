# Changelog

All notable changes to AGMind Installer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-alpha.1] — 2026-03-14

### Fixed
- **BUG-001**: Weaviate version pinned to 1.27.6 (was 1.19.0 — incompatible with Dify ≥1.9.2, data loss risk)
- **BUG-002**: Plugin Daemon version updated to 0.5.3 (was 0.1.0-local — ancient/broken)
- **BUG-003**: All Docker images pinned to specific versions (removed all `:latest` tags)
- **BUG-004**: Single source of truth for versions via `versions.env` (removed duplicate `*_VERSION=` from all env templates)

### Security
- **SEC-001**: Removed admin secret URL pattern — Dify Console now at `/dify/` with standard authentication
- **SEC-002**: All secrets generated via `openssl rand` at install time; validation rejects known defaults
- **SEC-003**: Redis hardened — dangerous commands disabled, maxmemory 512mb, connection limits
- **SEC-004**: PostgreSQL hardened — scram-sha-256 auth, connection/query logging
- **SEC-005**: Docker container hardening — `no-new-privileges`, `cap_drop: ALL`, json-file logging with rotation, network isolation (frontend/backend/ssrf), read-only filesystems for nginx/redis
- **SEC-006**: Nginx hardened — security headers (X-Frame-Options, CSP, HSTS), rate limiting, server_tokens off, improved TLS ciphers
- **SEC-007**: Security-on-by-default for VPS profile (UFW, fail2ban, SOPS); fail2ban for LAN/VPN

### Added
- Release manifest (`release-manifest.json`) for version governance
- Compatibility matrix (`COMPATIBILITY.md`) with tested component versions and host OS support
- Rollback state saving in update system
- `validate_no_default_secrets()` function to catch weak passwords
- Hex token URL blocking rule in nginx (`^/[a-f0-9]{24,}/` returns 404)

### Changed
- Docker networks split: `agmind-frontend` (bridge) + `agmind-backend` (internal) replacing single `agmind-network`
- Grafana/Portainer on both frontend+backend networks for host access
- Nginx and Redis containers now `read_only: true` with tmpfs

## [0.9.0] — 2026-03-01

### Added
- Initial installer with 4 deployment profiles (vps, lan, vpn, offline)
- Dify + Open WebUI + Ollama stack
- TLS support (Let's Encrypt, self-signed, custom)
- Monitoring stack (Prometheus, Grafana, Portainer, cAdvisor, Loki, Promtail)
- ETL stack (Docling, Xinference)
- Authelia 2FA integration
- Backup/restore system with age encryption and S3 upload
- Multi-instance support
- GPU detection (NVIDIA, AMD ROCm, Intel Arc)
- Non-interactive mode for automation
