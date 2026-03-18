# Technology Stack

**Analysis Date:** 2026-03-18

## Languages

**Primary:**
- Bash - Main installation and orchestration language (all shell scripts in `/lib/` and `/scripts/`)
- Python 3 - CI/validation utilities (`scripts/check-manifest-versions.py`)
- YAML - Docker Compose and configuration (`templates/docker-compose.yml`, monitoring configs)

**Secondary:**
- JSON - Configuration manifests and branding (`templates/release-manifest.json`, `branding/theme.json`)
- Nginx configuration - Reverse proxy rules (`templates/nginx.conf.template`)

## Runtime

**Environment:**
- Docker/Docker Compose - Primary deployment platform
  - Minimum: Docker 24.0+, Docker Compose 2.20+
  - Supported architectures: `linux/amd64`, `linux/arm64`

**Target Operating Systems:**
- Linux: Ubuntu 20.04+, Debian 11+, CentOS 8+, Fedora 38+
- macOS: Darwin with `sw_vers` support (limited deployment)
- Minimum system: 4 GB RAM, 2 cores, 20 GB disk
- Recommended: 16+ GB RAM, 4+ cores, 50+ GB disk

**Package Managers:**
- None at base level - project is Docker-native and doesn't require system package management for core services
- Python 3 for validation scripts

## Frameworks & Core Services

**Dify Stack:**
- Dify API v1.13.0 - Core AI workflow engine and backend API
- Dify Web v1.13.0 - Management console UI (Next.js-based)
- Dify Plugin Daemon v0.5.3-local - Plugin execution system
- Dify Sandbox v0.2.12 - Isolated code execution environment

**UI & Web:**
- Open WebUI v0.5.20 - Chat interface and LLM management (white-label compatible)
- Nginx v1.27.3-alpine - Reverse proxy, TLS termination, static serving

**LLM & Embedding:**
- Ollama v0.6.2 - Local LLM runtime and model management
- Xinference v0.16.3 - Reranker service for retrieval enhancement

**Vector Storage (selectable):**
- Weaviate v1.27.6 - Vector database (primary profile: `weaviate`)
- Qdrant v1.12.1 - Alternative vector store (profile: `qdrant`)

**Data Storage:**
- PostgreSQL v15.10-alpine - Primary relational database
- Redis v7.4.1-alpine - Cache, task queue (Celery broker)

**Document Processing (ETL Profile):**
- Docling Serve v1.14.3 - Advanced document parsing and extraction

**Monitoring Stack (monitoring profile):**
- Prometheus v2.54.1 - Metrics collection and alerting
- Alertmanager v0.27.0 - Alert routing and management
- Grafana v11.4.0 - Metrics visualization
- Loki v3.3.2 - Log aggregation
- Promtail v3.3.2 - Log shipper
- cAdvisor v0.55.1 - Container metrics
- Node Exporter v1.8.2 - Host metrics

**Optional Services:**
- Portainer v2.21.4 - Container management UI (monitoring profile)
- Authelia v4.38 - Authentication and authorization proxy (authelia profile)
- Certbot v3.1.0 - ACME TLS certificate automation (vps profile)

**Infrastructure:**
- Squid v6.6-24.04_edge - SSRF proxy for code execution isolation

## Key Dependencies

**Critical Infrastructure:**
- PostgreSQL - Stores all Dify configuration, workflows, knowledge bases, audit logs
- Redis - Celery task queue (async job processing), caching, session storage
- Vector database (Weaviate or Qdrant) - Embedding storage for RAG knowledge retrieval

**LLM Runtime:**
- Ollama - Loads and runs local language models, embeddings
  - Default models provided by user configuration (e.g., `qwen2.5:14b`)
  - Default embedding model: `bge-m3`

**Code Execution:**
- Dify Sandbox - Isolated code execution with network SSRF proxy
- Squid Proxy - Prevents sandbox from accessing internal services

**Security & Networking:**
- TLS/SSL stack - Via certbot for LetsEncrypt (vps profile) or manual certs
- UFW/Fail2Ban - Host-level firewalling and rate limiting (security profiles)

## Configuration

**Environment:**
- Configured via `.env` files generated from templates in `templates/`
- Template variants: `env.vps.template`, `env.lan.template`, `env.vpn.template`, `env.offline.template`
- Version pinning: `templates/versions.env` (single source of truth for all image versions)

**Build & Deployment:**
- `docker-compose.yml` - Main orchestration file with 25+ services
- Service profiles control optional component groups:
  - `weaviate` - Vector store (mutually exclusive with qdrant)
  - `qdrant` - Alternative vector store
  - `etl` - Document processing (Docling + Xinference)
  - `monitoring` - Full monitoring stack (Prometheus, Grafana, Loki)
  - `vps` - VPS-specific services (Certbot)
  - `authelia` - Authentication layer

**Install Configuration:**
- Deployment profiles: `vps`, `lan`, `vpn`, `offline` (set via `DEPLOY_PROFILE`)
- TLS modes: `none`, `self-signed`, `letsencrypt`
- Monitoring modes: `none`, `local`, `external`
- Alert modes: `none`, `webhook`, `telegram`

## Network Configuration

**Docker Networks:**
- `agmind-frontend` - Bridge network for user-facing services (nginx, grafana, portainer)
- `agmind-backend` - Internal bridge for backend services (API, worker, databases, vector stores)
- `ssrf-network` - Internal-only network for code sandbox isolation (API, worker, sandbox, squid proxy)

**Port Mappings:**
- HTTP: `${EXPOSE_NGINX_PORT:-80}` (default 80)
- HTTPS: `${EXPOSE_NGINX_SSL_PORT:-443}` (default 443)
- Dify Web Console: `${EXPOSE_DIFY_PORT:-3000}` (default 3000)
- Grafana: `${GRAFANA_PORT:-3001}` (default 3001, localhost-only)
- Portainer: `${PORTAINER_PORT:-9443}` (default 9443, localhost-only)

## Installation Scripts & Tooling

**Main Orchestrator:**
- `install.sh` - Primary installation script (v1.0.0)
  - 9-phase installation process
  - System detection and pre-flight checks
  - Interactive wizard for configuration
  - Docker installation if not present
  - Health check validation
  - Model loading orchestration

**Library Modules** (`lib/`):
- `detect.sh` - OS, GPU, RAM, disk, port detection
- `docker.sh` - Docker/Compose installation and hardening
- `config.sh` - .env generation, template processing, file validation
- `models.sh` - LLM and embedding model management in Ollama
- `backup.sh` - Backup scheduling and execution
- `health.sh` - Service health checking and rollback detection
- `security.sh` - Firewall, Fail2Ban, SOPS integration
- `authelia.sh` - Authentication setup

**Utility Scripts** (`scripts/`):
- `backup.sh` - Manual backup operations
- `restore.sh` - Disaster recovery and restoration
- `update.sh` - Version upgrades with rollback capability
- `uninstall.sh` - Safe removal
- `check-manifest-versions.py` - CI validation
- `generate-manifest.sh` - Docker image manifest creation
- `multi-instance.sh` - Multiple AGMind installations on one host
- `dr-drill.sh` - Disaster recovery testing
- `test-upgrade-rollback.sh` - Upgrade validation
- `rotate_secrets.sh` - Secret rotation automation
- `build-offline-bundle.sh` - Offline deployment bundles

## Platform Requirements

**Development:**
- Bash 4.0+ (POSIX-compliant shell)
- curl or wget for downloads
- Standard Unix utilities: sed, awk, grep, jq
- Git (for cloning repository)
- Python 3.6+ (for validation scripts)

**Production - Host:**
- Ubuntu 22.04+ / Debian 12+ / RHEL 8+ (recommended)
- Kernel 5.10+ (for Docker namespaces and cgroups)
- Minimum 4 GB RAM, 2 CPU cores, 20 GB disk
- GPU optional (NVIDIA CUDA 11.8+, AMD ROCm, Intel Arc, Apple Metal)

**Production - Container Runtime:**
- Docker 24.0+ with Compose 2.20+
- NVIDIA Container Toolkit (if using NVIDIA GPU)
- Linux kernel with user namespaces, overlay2 storage driver

**Cloud Deployment:**
- VPS with public IP and domain (vps profile)
- Private network with VPN access (vpn profile)
- Offline/air-gapped isolated network (offline profile)

---

*Stack analysis: 2026-03-18*
