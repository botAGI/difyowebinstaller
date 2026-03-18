# Technology Stack

**Analysis Date:** 2026-03-18

## Languages

**Primary:**
- Bash 5+ - Installation automation, orchestration scripts, configuration generation
- YAML - Docker Compose, Kubernetes configs, Prometheus/Alertmanager/Loki configurations
- JavaScript/TypeScript - Docusaurus documentation site (React-based)

**Secondary:**
- Python - Dify API and Worker services, Docling/Xinference services
- Go - Ollama, vLLM, TEI services (all Go-based ML servers)

## Runtime

**Environment:**
- Docker 24.0+ (installed via install.sh)
- Docker Compose 2.20+ (installed via install.sh)

**Package Manager:**
- Bash package management: apt-get (Debian/Ubuntu), dnf (Fedora/CentOS)
- Node.js: npm (for Docusaurus docs only, optional)

## Frameworks

**Core:**
- Dify 1.13.0 - RAG/LLM application platform (API + Web console)
- Open WebUI v0.5.20 - Chat interface for LLM interaction
- Ollama 0.6.2 - Local LLM inference runtime

**Inference Engines:**
- vLLM v0.8.4 - High-performance LLM server (alternative to Ollama, GPU-optimized)
- Text Embeddings Inference (TEI) cuda-1.9.2 - Hugging Face embedding service
- Xinference v0.16.3 - Distributed inference framework (reranker)

**Document Processing:**
- Docling v1.14.3 - Advanced document understanding and ETL

**Testing:**
- BATS (Bash Automated Testing System) - Shell script testing framework
- Config: `tests/test_config.bats`

**Build/Dev:**
- Docusaurus 3.7.0 - Documentation site generator (for `/docs`)
- Linting: shellcheck (for bash scripts)

## Key Dependencies

**Critical:**
- PostgreSQL 15.10-alpine - Primary database for Dify data (users, workflows, knowledge bases)
- Redis 7.4.1-alpine - Session cache, Celery job queue, real-time features
- Weaviate 1.27.6 - Vector database for RAG embeddings (default vector store)
- Qdrant v1.12.1 - Alternative vector database (interchangeable with Weaviate)

**Infrastructure:**
- Nginx 1.27.3-alpine - Reverse proxy, TLS termination, load balancing
- Dify Sandbox 0.2.12 - Isolated code execution environment for workflow scripts
- Squid 6.6 - SSRF proxy for outbound request filtering (security)
- Plugin Daemon 0.5.3-local - Dify plugin system runtime

**Monitoring & Observability:**
- Prometheus v2.54.1 - Metrics collection and alerting
- Grafana 11.4.0 - Metrics visualization dashboards
- Loki 3.3.2 - Log aggregation system
- Promtail 3.3.2 - Log shipper (Loki agent)
- Node Exporter v1.8.2 - System metrics exporter
- cAdvisor v0.55.1 - Container metrics collector
- Alertmanager v0.27.0 - Alert deduplication and routing

**Authentication & Authorization:**
- Authelia 4.38 - SSO/2FA provider (optional, profile-based)
- Certbot v3.1.0 - Let's Encrypt certificate automation (VPS profile)

**Container Management:**
- Portainer 2.21.4 - Web UI for container/volume management (monitoring profile)

## Configuration

**Environment:**
- Single source of truth: `templates/versions.env` - All service versions pinned
- Profile-specific templates: `templates/env.{lan|vpn|vps|offline}.template`
- Generated at install-time: `/opt/agmind/docker/.env` (secrets injected)
- No dynamic .env loading - all values resolved during `docker compose up`

**Key env var patterns:**
- Secrets: `__SECRET_KEY__`, `__DB_PASSWORD__`, `__REDIS_PASSWORD__` (placeholders replaced during install)
- Service endpoints: `*_ENDPOINT`, `*_HOST`, `*_PORT`, `*_API_KEY` (internal network or external)
- Model configuration: `LLM_MODEL`, `EMBEDDING_MODEL`, `VLLM_MODEL`
- Provider selection: `LLM_PROVIDER` (ollama|vllm|external|skip), `EMBED_PROVIDER`
- Feature flags: `ENABLE_OLLAMA_API`, `ENABLE_OPENAI_API`, `MARKETPLACE_ENABLED`, `MIGRATION_ENABLED`

**Build:**
- `templates/docker-compose.yml` - Master compose file with all services
- `lib/config.sh` - Configuration generation script (sed-based templating)
- Service version override: `export DIFY_VERSION=X.Y.Z` (before running installer)

**Security Hardening:**
- Cap drop defaults: `*security-defaults` anchor drops 28 unnecessary capabilities
- Read-only root filesystem: nginx, redis (container-level)
- Tmpfs: /tmp, /var/cache/nginx (ephemeral storage)
- Secrets rotation support: `ENABLE_SECRET_ROTATION` flag
- SOPS encryption: Optional (VPS profile)

## Platform Requirements

**Development:**
- Ubuntu 20.04+, Debian 11+, CentOS 8+, Fedora 38+
- Bash 5+
- Minimum 4GB RAM, 2 CPU cores
- 20GB free disk space
- Docker socket access (root or docker group)

**Production:**
- Deployment target: Self-hosted (on-premises) via Docker Compose
- Supported deployment modes: LAN, VPN, VPS (with Let's Encrypt), Offline (air-gapped)
- Scaling: Single-node deployment (horizontal scaling not yet supported)
- High-availability: Manual failover, persistent volumes on shared storage
- GPU support: NVIDIA (CUDA), AMD (ROCm), Intel (compute), Apple Silicon (native Metal)

**Network Requirements:**
- IPv6 disabled by default: `net.ipv6.conf.all.disable_ipv6=1` (sysctl)
- DNS: System resolver (Go uses cgo resolver when GODEBUG=netdns=cgo set)
- Proxy: Optional SSRF proxy (Squid) for code execution sandboxing

---

*Stack analysis: 2026-03-18*
