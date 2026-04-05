# Technology Stack

**Analysis Date:** 2026-04-04

## Languages

**Primary:**
- **Bash** 5+ - Installation orchestrator, CLI utilities, configuration generation
  - Used in: `install.sh`, `lib/*.sh`, `scripts/*.sh`
  - Strict mode: `set -euo pipefail`, shellcheck-compliant
  - All scripts require Bash 5+ for features like `${var[@]}` and advanced globbing

**Secondary:**
- **YAML** - Docker Compose configuration, Prometheus/Loki/Nginx configs
- **Python** - Dify/Open WebUI backend, plugin daemon, data analysis (DB-GPT)
- **JavaScript/TypeScript** - Dify Web Console (Next.js), Open WebUI frontend

## Runtime

**Environment:**
- **Linux** (Ubuntu 22.04+, Debian 12+, recommended: Ubuntu 24.04 LTS)
- **Docker** (installed automatically by install.sh phase 3)
- **NVIDIA Container Runtime** (optional, auto-detected for GPU support)

**Package Manager:**
- **Docker** (primary orchestration)
- **Docker Compose** v2+ (via `docker compose` commands)
- No lockfile mechanism — all images pinned to exact versions in `templates/versions.env`

## Frameworks

**Core Application Stack:**
- **Dify** `1.13.3` - Workflow orchestration & RAG backend
  - Components: API (`langgenius/dify-api`), Web Console (`langgenius/dify-web`), Worker (Celery)
  - Language: Python
  - Port: API 5001, Web 3000

- **Open WebUI** `v0.8.12` - Chat interface & model proxy
  - Base image: `ghcr.io/open-webui/open-webui`
  - Language: Python/Next.js frontend
  - Port: 8080

- **Pipelines** (Open WebUI extensions) - Custom workflow runner
  - Image: `ghcr.io/open-webui/pipelines:main`
  - Language: Python
  - Port: 9099

**LLM Inference Providers (selectable):**
- **Ollama** `0.6.2` - Local model runner (CPU/GPU)
  - Image: `ollama/ollama`
  - Port: 11434
  - Profile: `ollama`

- **vLLM** `v0.18.1` - High-throughput LLM inference (GPU-optimized)
  - Image: `vllm/vllm-openai`
  - Port: 8000
  - Profile: `vllm`
  - CUDA support with automatic suffix injection (`VLLM_CUDA_SUFFIX`)

**Embedding Providers:**
- **TEI (Text Embeddings Inference)** `cuda-1.9.3` - Fast embedding generation
  - Image: `ghcr.io/huggingface/text-embeddings-inference`
  - Port: 80 (embedding), 80 (reranking)
  - Profiles: `tei`, `reranker`
  - GPU allocation: CUDA for embeddings, CPU for reranking

**Vector Databases (selectable):**
- **Weaviate** `1.27.0` - Semantic search & vector storage
  - Image: `semitechnologies/weaviate`
  - Port: 8080
  - Profile: `weaviate`
  - Auth: API key required

- **Qdrant** `v1.8.3` - Alternative vector database
  - Image: `qdrant/qdrant`
  - Port: 6333
  - Profile: `qdrant`
  - Auth: API key required

**Data Processing & ETL:**
- **Docling** `v1.14.3` - Document processing with OCR
  - Images: CPU (`ghcr.io/docling-project/docling-serve`) or CUDA (`quay.io/docling-project/docling-serve-cu128`)
  - Port: 8765
  - Profile: `docling`
  - Features: PDF parsing, image extraction, table detection, OCR (multilingual)

**AI Gateway:**
- **LiteLLM** `v1.82.3-stable.patch.2` - Unified LLM API gateway
  - Image: `ghcr.io/berriai/litellm`
  - Port: 4000 (API), 4001 (Dashboard)
  - Profile: `litellm`
  - Features: Provider fallback, rate limiting, request logging

**Optional Services:**
- **SearXNG** `2026.3.29-7ac4ff39f` - Private metasearch engine
  - Image: `docker.io/searxng/searxng`
  - Port: 8888
  - Profile: `searxng`

- **Open Notebook** `v1-latest` - Research assistant (PDF/video/audio summarization)
  - Image: `docker.io/lfnovo/open_notebook`
  - Port: 8502
  - Profile: `notebook`
  - Backend: SurrealDB

- **SurrealDB** `v2.2.1` - Document database for Open Notebook
  - Image: `docker.io/surrealdb/surrealdb`
  - Port: 8000
  - Profile: `notebook`

- **DB-GPT** `v0.8.0` - AI data analysis agent
  - Image: `docker.io/eosphorosai/dbgpt-openai`
  - Port: 5670
  - Profile: `dbgpt`

- **Crawl4AI** `0.8.6` - Web data extraction API
  - Image: `docker.io/unclecode/crawl4ai`
  - Port: 11235
  - Profile: `crawl4ai`
  - Features: Chromium rendering, JavaScript execution, AI parsing

**Infrastructure:**
- **PostgreSQL** `15-alpine` - Primary database (Dify, LiteLLM, Plugin Daemon)
  - Image: `postgres:15-alpine`
  - Port: 5432
  - Databases: `dify`, `dify_plugin`, `litellm`
  - Features: SSL-ready, connection pooling tuned for Dify

- **Redis** `6-alpine` - Cache, message broker (Celery)
  - Image: `redis:6-alpine`
  - Port: 6379
  - Features: Persistence enabled, password auth, healthcheck via `redis-cli ping`

- **Nginx** `latest` - Reverse proxy, TLS termination
  - Image: `nginx:latest-alpine`
  - Ports: 80, 443, 3000, 4001, 5670, 8502, 8888, 11235
  - Features: Rate limiting, compression, health endpoint at `/health`

- **Certbot** `v3.1.0` - Let's Encrypt certificate management (VPS profile only)
  - Image: `certbot/certbot`
  - Profile: `vps`
  - Auto-renewal: 12-hour check interval

- **SSRF Proxy (Squid)** `latest` - Sandbox code execution security
  - Image: `ubuntu/squid`
  - Port: 3128
  - Network: `ssrf-network` (isolated)

- **Sandbox** `0.2.14` - Code execution sandbox (Dify workflows)
  - Image: `langgenius/dify-sandbox`
  - Port: 8194
  - Capabilities: SYS_ADMIN (required for chroot/namespaces)
  - Network isolation via SSRF proxy

**Plugin Daemon:**
- **Plugin Daemon** `0.5.3-local` - Dify plugin execution engine
  - Image: `langgenius/dify-plugin-daemon`
  - Port: 5002
  - Database: `dify_plugin` (PostgreSQL)

**Monitoring & Observability:**
- **Prometheus** `v2.54.1` - Metrics collection & alerting
  - Image: `prom/prometheus`
  - Port: 9090
  - Profile: `monitoring`

- **Grafana** `12.4.1` - Metrics visualization
  - Image: `grafana/grafana`
  - Port: 3001 (localhost-only)
  - Profile: `monitoring`

- **Loki** `3.3.2` - Log aggregation
  - Image: `grafana/loki`
  - Port: 3100
  - Profile: `monitoring`

- **Promtail** `3.3.2` - Log shipper
  - Image: `grafana/promtail`
  - Profile: `monitoring`
  - Features: Docker socket integration, container label scraping

- **Node Exporter** `v1.8.2` - Host metrics
  - Image: `prom/node-exporter`
  - Port: 9100
  - Profile: `monitoring`

- **cAdvisor** `v0.55.1` - Container metrics
  - Image: `gcr.io/cadvisor/cadvisor`
  - Port: 8080
  - Profile: `monitoring`
  - Privileges: Required for cgroup access

- **Alertmanager** `v0.27.0` - Alert routing & deduplication
  - Image: `prom/alertmanager`
  - Port: 9093
  - Profile: `monitoring`

- **Portainer** `2.21.4` - Docker container UI
  - Image: `portainer/portainer-ce`
  - Port: 9443 (localhost-only)
  - Profile: `monitoring`

**Authentication & Authorization:**
- **Authelia** `4.38` - 2FA, SSO middleware
  - Image: `authelia/authelia`
  - Port: 9091
  - Profile: `authelia`
  - Features: TOTP, WebAuthn, LDAP integration

## Key Dependencies

**Critical (always loaded):**
- `postgresql:15-alpine` - Core data persistence
- `redis:6-alpine` - Message queue & session store
- `langgenius/dify-api` - RAG workflow engine
- `ghcr.io/open-webui/open-webui` - Chat interface
- `nginx` - Public ingress & routing

**Infrastructure (conditional):**
- `langgenius/dify-sandbox` - Code execution (required for Dify workflows)
- `ghcr.io/open-webui/pipelines` - Custom workflow extensions
- Embedding models (TEI or Ollama) - RAG feature prerequisite
- Vector DB (Weaviate or Qdrant) - Vector search backend

**Optional Service Packages:**
- `ghcr.io/berriai/litellm` - Unified LLM API (optional, default: enabled)
- `docker.io/searxng/searxng` - Web search for agents (opt-in)
- `docker.io/lfnovo/open_notebook` + `surrealdb/surrealdb` - Research tools (opt-in)
- `eosphorosai/dbgpt-openai` - Data analysis (opt-in)
- `unclecode/crawl4ai` - Web scraping (opt-in)

**Monitoring Stack (optional):**
- Prometheus + Grafana + Loki + Promtail - Full observability (opt-in via profile)
- Portainer - Container management UI (opt-in, localhost-only)

## Configuration

**Environment Variables:**
All configuration via `.env` file located at `${INSTALL_DIR}/docker/.env` (default: `/opt/agmind/docker/.env`).

**Core Configuration Sources:**
- `templates/versions.env` - Image versions & tag management (read-only reference)
- `templates/env.*.template` - Profile-specific env templates (LAN, VPS, Offline)
- Generated `.env` - Produced by `lib/config.sh:generate_config()` during installation

**Configuration Generation:**
```bash
# Main orchestrator
install.sh (Phase 4)
  ├─ lib/config.sh:generate_config()
  │   ├─ _generate_secrets()        # Random keys, passwords
  │   ├─ _generate_env_file()       # Profile-specific .env
  │   ├─ _append_provider_vars()    # LLM/embed provider setup
  │   ├─ generate_nginx_config()    # Reverse proxy
  │   ├─ generate_redis_config()    # Cache settings
  │   ├─ generate_sandbox_config()  # Code execution security
  │   └─ _generate_litellm_config() # AI gateway
```

**Key Config Groups:**
1. **Secrets** - Autogenerated via `openssl rand -hex 32`
   - `SECRET_KEY`, `DB_PASSWORD`, `REDIS_PASSWORD`
   - `SANDBOX_API_KEY`, `PLUGIN_DAEMON_KEY`, `WEAVIATE_API_KEY`, `QDRANT_API_KEY`
   - Stored at chmod 600 (root-owned on Linux)

2. **Database** - PostgreSQL connection
   - `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`
   - Pool settings: `SQLALCHEMY_POOL_SIZE=30`, `SQLALCHEMY_POOL_RECYCLE=3600`

3. **Vector Store Selection** - Via `VECTOR_STORE` env var
   - `weaviate` → Weaviate profile enabled, Qdrant disabled
   - `qdrant` → Qdrant profile enabled, Weaviate disabled

4. **LLM Provider** - Via `LLM_PROVIDER` and `EMBED_PROVIDER`
   - `ollama` - Builtin model runner
   - `vllm` - High-performance inference
   - `openai`, `anthropic`, `azure`, etc. - External APIs

5. **ETL Processing** - Via `ETL_TYPE`
   - `dify` - Built-in (default)
   - `unstructured` - External API

6. **URLs & Access** - Profile-dependent
   - LAN: `http://localhost` (no domain)
   - VPS: `https://{domain}` (auto-TLS via certbot)
   - Offline: `http://localhost` (air-gapped)

**Build & Deployment:**
- **Docker Compose File** - `templates/docker-compose.yml` → `/opt/agmind/docker/docker-compose.yml`
- **Profiles System** - Used to enable/disable optional services
  - Examples: `ollama`, `vllm`, `tei`, `monitoring`, `litellm`, `searxng`, `notebook`, `dbgpt`, `crawl4ai`, `authelia`, `vps`
- **Network Architecture** - 3 Docker networks
  - `agmind-frontend` - Nginx ↔ Web/Grafana/Portainer
  - `agmind-backend` - All internal services
  - `ssrf-network` - Isolated: Sandbox ↔ Squid proxy only

## Platform Requirements

**Development (Installation):**
- Linux kernel 4.4+ (for Docker & namespaces)
- 4 CPU cores (minimum), 8+ recommended
- 8 GB RAM (minimum), 32 GB recommended for multiple GPU services
- 20 GB disk (minimum), 100 GB SSD recommended (PostgreSQL + vector DB + model cache)
- Bash 5.0+
- `curl`, `wget` (for health checks)
- `jq` (optional, for JSON parsing in scripts)

**GPU Support (Optional):**
- NVIDIA: CUDA 11.8+, nvidia-docker runtime
- AMD: ROCm 5.0+
- Auto-detected in Phase 1 (Diagnostics), can be overridden with `FORCE_GPU_TYPE` env var

**Production (Deployment):**
- **Recommended:** Ubuntu 24.04 LTS or Debian 12
- **Docker:** 24.0+ (with Compose v2)
- **Networking:** Open ports 80/443 (web), optionally 9443 (Portainer), 3001 (Grafana) for mgmt
- **Backups:** Systemd timer for daily PostgreSQL + Redis snapshots (or S3)
- **Monitoring:** Optional Prometheus/Grafana stack (separate profile)

**Hardware Scaling:**
| Component | Min | Recommended | Notes |
|-----------|-----|-------------|-------|
| API/Worker | 2GB | 4GB | Dify CPU-bound |
| vLLM | 12GB VRAM | 24GB+ VRAM | Per model loaded |
| TEI Embeddings | 4GB | 8GB VRAM | Batch processing |
| PostgreSQL | 2GB | 8GB | Connection pool + index |
| Redis | 1GB | 4GB | Celery broker + cache |
| Weaviate/Qdrant | 2GB | 8GB+ | Vector index size |

---

*Stack analysis: 2026-04-04*
