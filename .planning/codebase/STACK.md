# Technology Stack

**Analysis Date:** 2026-03-20

## Languages

**Primary:**
- **Bash 5+** - Main installer language, all scripting and orchestration
  - Used in: `install.sh`, `lib/*.sh`, `scripts/*.sh`
  - Strict mode: `set -euo pipefail` enforced across all scripts
  - Linting: shellcheck compliance required (CI/CD gates)
  - Testing: BATS framework for unit and integration tests

**Secondary:**
- **YAML** - Configuration format for Docker Compose, Kubernetes manifests, monitoring configs
  - Used in: `templates/docker-compose.yml`, `monitoring/*.yml`, `templates/authelia/*`
- **JSON** - Configuration and manifest files
  - Used in: `templates/release-manifest.json`, `.planning/config.json`, `workflows/*.json`

## Runtime

**Environment:**
- **Linux** (primary) - Ubuntu 20.04+, Debian 11+, CentOS Stream 9+, RHEL, Fedora, Rocky, AlmaLinux
- **macOS** - Secondary support via Docker Desktop
- **Windows** - Not directly supported; requires WSL2 or Docker Desktop with Linux VM
- **Docker** - Container runtime for all services
  - Minimum version: 24.0
  - Recommended: 27.0+
  - Auto-installed by installer if missing
- **Docker Compose** - Orchestration plugin
  - Minimum version: 2.20
  - Recommended: 2.29+
  - Installed as Docker plugin (not standalone `docker-compose`)

**Architecture Support:**
- `linux/amd64` - Primary (x86_64)
- `linux/arm64` - Secondary (aarch64)
- `linux/arm/v7` - Limited support (armv7l)
- Auto-detected via `uname -m` in `lib/detect.sh`

## Frameworks

**Core Application Stack:**
- **Dify 1.13.0** - Open-source RAG/LLM application platform
  - Image: `langgenius/dify-api:1.13.0`, `langgenius/dify-web:1.13.0`
  - Components: API server (Python), Web console (Next.js), Worker (Celery)
  - Database: PostgreSQL (schema managed by Dify migrations)
  - Queue: Redis (Celery broker)

- **Open WebUI v0.5.20** - Chat interface for LLM interaction
  - Image: `ghcr.io/open-webui/open-webui:v0.5.20`
  - NOTE: Version pinned for white-label/branding compatibility - do not change to `:main` or `:latest` without testing branding features
  - Pipelines: `ghcr.io/open-webui/pipelines:main`

**LLM/Inference Providers (selectable):**
- **Ollama 0.6.2** - Local inference server (default)
  - Image: `ollama/ollama:0.6.2`
  - Supports: Model pulling, quantization, multi-GPU
  - Use case: Development, edge deployment
  - Profile: `--profile ollama`

- **vLLM v0.17.1** - Production-grade LLM inference
  - Image: `vllm/vllm-openai:v0.17.1`
  - CUDA suffix: Configurable for GPU acceleration
  - OpenAI-compatible API
  - Tensor parallel support
  - Profile: `--profile vllm`

- **Text Embeddings Inference (TEI) cuda-1.9.2** - HuggingFace embedding server
  - Image: `ghcr.io/huggingface/text-embeddings-inference:cuda-1.9.2`
  - Profile: `--profile tei`

**Vector Stores (selectable):**
- **Weaviate 1.27.6** - Default vector database
  - Image: `semitechnologies/weaviate:1.27.6`
  - Default vector store in `VECTOR_STORE=weaviate`

- **Qdrant v1.12.1** - Alternative vector database
  - Image: `qdrant/qdrant:v1.12.1`
  - Selectable via `VECTOR_STORE=qdrant`

**Data & Caching:**
- **PostgreSQL 16-alpine** - Relational database for Dify metadata
  - Image: `postgres:16-alpine`
  - Database: `dify` (configurable)
  - Port: 5432 (internal only, not exposed)

- **Redis 7.4.1-alpine** - In-memory cache and Celery broker
  - Image: `redis:7.4.1-alpine`
  - Used for: Session cache, Celery queue, rate limiting
  - Port: 6379 (internal only)

**Infrastructure & Security:**
- **Nginx 1.27.3-alpine** - Reverse proxy and rate limiting
  - Image: `nginx:stable-alpine` → pinned to `1.27.3-alpine`
  - Rate limiting: 10r/s for API, 1r/10s login (burst=3)
  - Security headers: X-Frame-Options DENY, XSS-Protection, Referrer-Policy, Permissions-Policy
  - TLS termination (Let's Encrypt on VPS profile)

- **Dify Sandbox 0.2.12** - Isolated code execution environment
  - Image: `langgenius/dify-sandbox:0.2.12`
  - Purpose: Safe Python/JavaScript code execution for tools
  - Network isolation: ssrf-network

- **Squid 6.6-24.04_edge** - SSRF proxy (Server-Side Request Forgery protection)
  - Image: `ubuntu/squid:6.6-24.04_edge`
  - Purpose: Intercept and control outbound HTTP(S) requests from API/Worker

- **Dify Plugin Daemon 0.5.3-local** - Plugin management system
  - Image: `langgenius/dify-plugin-daemon:0.5.3-local`
  - Secondary PostgreSQL database for plugins

**Document Processing & ETL (optional):**
- **Docling 1.14.3** - OCR and document parsing
  - Image: `ghcr.io/docling-project/docling-serve:v1.14.3`
  - Port: 8765
  - Profile: `--profile etl` or when `ETL_TYPE=unstructured_api`

- **Xinference v0.16.3** - Unified inference platform for reranking
  - Image: `xprobe/xinference:v0.16.3`
  - Port: 9997
  - Used for: bce-reranker-base_v1 reranking model

**Monitoring & Observability (optional, local or external):**
- **Prometheus v2.54.1** - Metrics collection
  - Image: `prom/prometheus:v2.54.1`
  - Config: `monitoring/prometheus.yml`

- **Grafana 11.4.0** - Visualization and dashboards
  - Image: `grafana/grafana:11.4.0`
  - Port: 3001 (localhost only, `MONITORING_MODE=local`)

- **Loki 3.3.2** - Log aggregation
  - Image: `grafana/loki:3.3.2`
  - Config: `monitoring/loki-config.yml`

- **Promtail 3.3.2** - Log shipper
  - Image: `grafana/promtail:3.3.2`
  - Config: `monitoring/promtail-config.yml`

- **AlertManager v0.27.0** - Alert routing and notifications
  - Image: `prom/alertmanager:v0.27.0`
  - Config: `monitoring/alertmanager.yml`, `monitoring/alert_rules.yml`

- **cAdvisor v0.55.1** - Container metrics
  - Image: `gcr.io/cadvisor/cadvisor:v0.55.1`

- **Node Exporter v1.8.2** - Host system metrics
  - Image: `prom/node-exporter:v1.8.2`

- **Portainer CE 2.21.4** - Container management UI
  - Image: `portainer/portainer-ce:2.21.4`
  - Port: 9443 (localhost only)

**Authentication & Authorization (optional):**
- **Authelia 4.38** - 2FA and SSO gateway
  - Image: `authelia/authelia:4.38`
  - Configuration: `templates/authelia/`
  - Use case: 2FA on Dify console (`/console/*`)

- **Certbot v3.1.0** - Let's Encrypt TLS certificate management
  - Image: `certbot/certbot:v3.1.0`
  - Used on: VPS profile with automatic TLS setup

**Testing & CI/CD:**
- **BATS (Bash Automated Testing Framework)** - Bash test framework
  - Used in: `tests/*.bats` for unit/integration tests
  - CI: GitHub Actions (`/.github/workflows/`)
  - Linting: `shellcheck` on all bash scripts

## Key Dependencies

**Critical (All profiles):**
- PostgreSQL driver (psycopg2 in Dify API) - Database connectivity
- Redis client (Redis protocol implementation in Dify/Celery) - Cache/queue
- Nginx - HTTP/HTTPS proxy, rate limiting, security headers
- Docker daemon with socket mount - Container orchestration

**Infrastructure:**
- OpenSSL/TLS libraries - HTTPS support, certificate validation
- curl/wget - HTTP requests, health checks, model downloads
- jq - JSON parsing in shell scripts (optional but recommended)

**GPU Support (conditional):**
- NVIDIA CUDA Toolkit (if GPU detected) - GPU acceleration for vLLM/TEI
- nvidia-docker/nvidia-toolkit plugin - GPU device mapping
- NVIDIA Driver - GPU detection and management (nvidia-smi)

**Optional (based on profile/features):**
- Let's Encrypt (Certbot) - Automatic TLS certificates (VPS only)
- Hugging Face Hub - Model downloads (for vLLM/TEI)
- Authelia - 2FA and auth gateway (if `ENABLE_AUTHELIA=true`)
- SOPS (Secrets Operations) - Encrypted secrets management (if `ENABLE_SOPS=true`)

## Configuration

**Environment:**
- **Default `.env` location:** `/opt/agmind/docker/.env` (generated, chmod 600)
- **Template sources:** `templates/env.{lan,vps,vpn,offline}.template`
- **Profile-specific configuration:**
  - `lan` - Local network, no TLS, no domain required
  - `vps` - Public VPS, Let's Encrypt TLS, domain required
  - `vpn` - VPN access, self-signed TLS or custom cert
  - `offline` - No internet, pre-cached models only

**Version Pinning:**
- **Single source of truth:** `templates/versions.env`
- All service image versions defined here
- No `:latest` tags (production safety requirement)
- Updated only via official release process

**Build & Deployment:**
- **Docker Compose manifest:** `templates/docker-compose.yml`
- **Nginx configuration:** `templates/nginx.conf.template` → `/opt/agmind/docker/nginx/nginx.conf`
- **Monitoring configs:** `monitoring/prometheus.yml`, `monitoring/alertmanager.yml`, `monitoring/alert_rules.yml`
- **Redis configuration:** Generated by `lib/config.sh` → `/opt/agmind/docker/volumes/redis/redis.conf`

**Secrets Management:**
- Generated during installation: `SECRET_KEY`, `DB_PASSWORD`, `REDIS_PASSWORD`, `SANDBOX_API_KEY`, `PLUGIN_DAEMON_KEY`
- Stored in: `/opt/agmind/docker/.env` (chmod 600, root:root)
- Never committed to git (`.env` in `.gitignore`)
- Admin credentials saved to: `/opt/agmind/credentials.txt` (chmod 600)

## Platform Requirements

**Development:**
- Bash 5+ shell (standard on modern Linux/macOS)
- Docker 24.0+ with Compose plugin
- Root or sudo access (for Docker daemon, firewall rules, system packages)
- 4 GB RAM minimum, 16+ GB recommended
- 20 GB free disk minimum, 100 GB+ SSD recommended
- Network: Internet access for initial image pulls and model downloads

**Production (VPS/Bare Metal):**
- Ubuntu 22.04 LTS, Debian 12+, or RHEL 9+ (tested primary targets)
- Docker 27.0+ with Compose plugin (auto-installed)
- NVIDIA GPU (optional but recommended for vLLM/TEI):
  - NVIDIA Pascal+ for older systems
  - Ampere+ recommended (RTX 30-90 series, A100)
  - CUDA 12.0+ capable
  - 8-40 GB VRAM depending on model size
- PostgreSQL 16+ compatibility (runs in container, no external DB required)
- Redis 7+ compatibility (runs in container)
- Static IP address (for VPS profile with Let's Encrypt validation)
- Outbound HTTPS port 443 (for model downloads, updates, marketplace)

**Deployment Profiles:**
- **LAN**: Behind firewall, no public IP, mDNS or static LAN IP
- **VPS**: Public IP with domain, Let's Encrypt TLS, fail2ban SSH jail
- **VPN**: Behind VPN, static VPN IP, self-signed or custom TLS
- **Offline**: No internet after setup, pre-cached models required

---

*Stack analysis: 2026-03-20*
