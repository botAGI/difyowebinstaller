# External Integrations

**Analysis Date:** 2026-03-20

## APIs & External Services

**LLM Providers (conditional):**
- **OpenAI-compatible APIs** - External LLM inference
  - Config: `OPENAI_API_BASE_URL`, `OPENAI_API_KEY`
  - When: `LLM_PROVIDER=external`
  - Supported via Dify's native LLM integrations
  - Example: OpenAI, Anthropic, custom OpenAI-compatible endpoints

- **Ollama (local)** - Default on-premise LLM server
  - Connection: `OLLAMA_API_BASE=http://ollama:11434`
  - When: `LLM_PROVIDER=ollama`
  - Profile: `--profile ollama`

- **vLLM (local)** - Production inference engine
  - Connection: `http://vllm:8000` (internal)
  - When: `LLM_PROVIDER=vllm`
  - Profile: `--profile vllm`
  - OpenAI-compatible `/v1/completions` API

**Embedding Providers (conditional):**
- **Ollama Embeddings** - Default local embeddings
  - Connection: `OLLAMA_API_BASE=http://ollama:11434`
  - When: `EMBED_PROVIDER=ollama`
  - Models: bge-m3 (default)

- **TEI (Text Embeddings Inference)** - HuggingFace embeddings
  - Connection: `http://tei:8080` (internal)
  - When: `EMBED_PROVIDER=tei`
  - Profile: `--profile tei`
  - Models: Based on TEI image, bge-m3 compatible

- **External Embedding API** - Third-party services
  - When: `EMBED_PROVIDER=external`
  - Configured via Dify UI after installation

**Marketplace & Updates:**
- **Dify Marketplace** - Plugin and extension hub
  - Endpoint: `CHECK_UPDATE_URL=https://updates.dify.ai`
  - Purpose: Version checks, plugin discovery
  - Configurable via environment variable

- **HuggingFace Hub** - Model repository
  - Used by: vLLM, TEI, Ollama (for model downloads)
  - Token: `HF_TOKEN` (optional, for gated model access)
  - When: Pulling quantized models during initialization

## Data Storage

**Databases:**
- **PostgreSQL 16** - Primary database for Dify metadata
  - Connection: `postgresql://${DB_USERNAME}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_DATABASE}`
  - Default host: `db` (container name, internal)
  - Default port: 5432
  - Default database: `dify`
  - Client: psycopg2 (Python driver in Dify)
  - Schema: Auto-migrated by Dify on startup (`MIGRATION_ENABLED=true`)
  - Volumes: `./volumes/db/data:/var/lib/postgresql/data`

- **Plugin Database (separate PostgreSQL)** - Plugin daemon metadata
  - Database: `dify_plugin` (separate from main `dify` db)
  - Connection: `postgresql://...@db:5432/dify_plugin`
  - Used by: Plugin daemon container

**Vector Stores (selectable):**
- **Weaviate 1.27.6** - Default vector database
  - Endpoint: `WEAVIATE_ENDPOINT=http://weaviate:8080`
  - API Key: `WEAVIATE_API_KEY` (empty = no auth by default)
  - Authentication: Anonymous disabled, API key required
  - Admin users: `hello@dify.ai`
  - Port: 8080 (internal only)
  - Volumes: `./volumes/weaviate:/var/lib/weaviate`
  - Use case: RAG document embeddings

- **Qdrant v1.12.1** - Alternative vector database
  - Endpoint: `QDRANT_HOST=qdrant`, `QDRANT_PORT=6333`
  - API Key: `QDRANT_API_KEY` (optional)
  - Port: 6333 (internal only)
  - Volumes: `./volumes/qdrant:/qdrant/storage`
  - When: `VECTOR_STORE=qdrant`

**File Storage:**
- **Local filesystem (default)** - Document and file storage
  - Type: `STORAGE_TYPE=local`
  - Path: `/app/api/storage` (container) → `./volumes/app/storage` (host)
  - Permissions: Mounted as bind mount, read-write
  - Use case: RAG documents, file uploads

- **S3 (optional)** - Remote object storage
  - When: `ENABLE_S3_BACKUP=true`
  - Config: S3 bucket and credentials
  - Variables: `S3_BUCKET`, `S3_PATH`, `S3_REMOTE_NAME`
  - Purpose: Backup destination for data replication

**Caching:**
- **Redis 7.4.1** - In-memory cache and message broker
  - Connection: `redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/${REDIS_DB}`
  - Default host: `redis` (container)
  - Default port: 6379
  - Default database: 0 (cache), 1 (Celery broker)
  - Celery broker URL: `redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/1`
  - Use case: Session cache, Celery task queue, rate limiting
  - Volumes: `./volumes/redis/data:/data`
  - Auth: Optional password via `REDIS_PASSWORD`

## Authentication & Identity

**Dify Internal Auth:**
- **Method:** Admin account creation on first startup
  - Admin setup: `INIT_PASSWORD` (base64-encoded or plaintext)
  - Stored in: PostgreSQL `account` table
  - Credentials saved to: `/opt/agmind/credentials.txt` (chmod 600)

- **Session management:** Redis sessions + Dify token system
- **API authentication:** API keys per workspace (created in Dify UI)

**Open WebUI Auth:**
- **Method:** Local user database + optional signup lockdown
  - Signup enabled: `ENABLE_SIGNUP=false` (disabled by default for security)
  - Authentication: Built-in OpenWebUI user system
  - Role-based: `DEFAULT_USER_ROLE=user` (default)
  - Credentials: Stored in Open WebUI's SQLite/PostgreSQL backend

**Authelia (optional 2FA):**
- **When:** `ENABLE_AUTHELIA=true`
- **Provider:** Configured in `templates/authelia/`
- **Protected routes:** `/console/*` (Dify UI)
- **Unprotected routes:** `/api`, `/v1`, `/files` (use Dify API keys)
- **JWT configuration:** `AUTHELIA_JWT_SECRET`
- **Storage:** One-time passwords, session state in authelia container

**LLM Provider Auth:**
- **When:** `LLM_PROVIDER=external` or external embedding
  - OpenAI API key, Anthropic API key, etc. → configured in Dify UI
  - NOT stored in .env (configured per-workspace in Dify)
- **Model provider keys:** `HF_TOKEN` (HuggingFace, optional for gated models)

## Monitoring & Observability

**Error Tracking:**
- **Sentry (optional)** - Error aggregation for Dify Web
  - DSN: `WEB_SENTRY_DSN` (environment variable, optional)
  - When: Configured, Dify Web sends JavaScript errors to Sentry

**Logs:**
- **Local JSON file logging** - Docker default
  - Driver: `json-file`
  - Options: max-size 10m, max-file 5
  - Location: `/var/lib/docker/containers/*/...`

- **Loki (optional)** - Centralized log aggregation
  - When: `MONITORING_MODE=local` and `ENABLE_LOKI=true`
  - Endpoint: `http://loki:3100` (internal)
  - Shipper: Promtail → `monitoring/promtail-config.yml`
  - Storage: Loki database

- **Prometheus** - Metrics collection
  - When: `MONITORING_MODE=local`
  - Config: `monitoring/prometheus.yml`
  - Scrape targets: Node Exporter, cAdvisor, Prometheus itself
  - Port: 9090 (internal)

**Alerting:**
- **AlertManager** - Alert routing and notifications
  - Config: `monitoring/alertmanager.yml`, `monitoring/alert_rules.yml`
  - When: `MONITORING_MODE=local`
  - Alert modes:
    - `ALERT_MODE=webhook` → `ALERT_WEBHOOK_URL`
    - `ALERT_MODE=telegram` → `ALERT_TELEGRAM_TOKEN`, `ALERT_TELEGRAM_CHAT_ID`
    - `ALERT_MODE=none` → No external alerts

- **Grafana** - Visualization and dashboarding
  - Port: 3001 (localhost only, `MONITORING_MODE=local`)
  - Admin password: `GRAFANA_ADMIN_PASSWORD`
  - Image: `grafana/grafana:11.4.0`
  - Provisioned dashboards: `monitoring/grafana/dashboards/`

**External Monitoring:**
- **When:** `MONITORING_MODE=external`
- **Endpoint:** `MONITORING_ENDPOINT` (custom monitoring system)
- **Auth:** `MONITORING_TOKEN` (bearer token)

## CI/CD & Deployment

**Hosting:**
- **Target:** Docker Compose on single or multiple servers
- **Supported platforms:**
  - Linux (Ubuntu 20.04+, Debian 11+, CentOS Stream 9+, etc.)
  - macOS (Docker Desktop)
  - Cloud VMs (AWS EC2, Azure VMs, GCP, DigitalOcean, etc.)
- **Installation:** Single command: `sudo bash install.sh`

**CI Pipeline:**
- **GitHub Actions** - Automated testing and linting
  - Workflows: `.github/workflows/`
  - Jobs:
    - `lint.yml` - shellcheck on all bash scripts
    - `test.yml` - BATS unit/integration tests
    - `lifecycle.yml` - E2E installation tests (optional)

**Release Management:**
- **Manifest:** `templates/release-manifest.json`
- **Version coordination:** `templates/versions.env` (single source of truth)
- **Process:** Manual semantic versioning in releases

## Environment Configuration

**Required env vars (secrets):**
- `SECRET_KEY` - Dify application secret (generated during setup)
- `DB_PASSWORD` - PostgreSQL password (generated)
- `REDIS_PASSWORD` - Redis auth (optional, generated if set)
- `SANDBOX_API_KEY` - Dify sandbox authorization token (default: `dify-sandbox`)
- `PLUGIN_DAEMON_KEY` - Plugin daemon API key (generated)
- `PLUGIN_INNER_API_KEY` - Internal plugin API key (generated)
- `INIT_PASSWORD` - Initial admin password (base64-encoded, generated)

**Critical env vars (configuration):**
- `DEPLOY_PROFILE` - Deployment profile: `lan`, `vps`, `vpn`, `offline`
- `LLM_PROVIDER` - Model provider: `ollama`, `vllm`, `external`, `skip`
- `EMBED_PROVIDER` - Embedding provider: `ollama`, `tei`, `external`, `same`
- `VECTOR_STORE` - Vector DB: `weaviate`, `qdrant`
- `ETL_TYPE` - Document processing: `dify`, `unstructured_api`
- `DEPLOY_ENV` - Environment mode: `PRODUCTION` or `DEVELOPMENT`

**Network Configuration:**
- `CONSOLE_WEB_URL` - Dify console public URL (auto-detected if empty)
- `CONSOLE_API_URL` - Dify API public URL (auto-detected if empty)
- `SERVICE_API_URL` - Service API public URL
- `APP_API_URL` - App API public URL
- `APP_WEB_URL` - App frontend public URL
- `FILES_URL` - File serving URL

**TLS/HTTPS:**
- `TLS_MODE` - `none`, `self-signed`, `custom`, `letsencrypt` (VPS only)
- `NGINX_HTTPS_ENABLED` - Enable HTTPS: `true` / `false`
- `NGINX_SERVER_NAME` - Domain name for TLS certificate
- Certificates: `./volumes/certbot/conf/` (Let's Encrypt) or custom location

**Secrets location:**
- **Installation directory:** `/opt/agmind/` (created by installer)
- **Docker configs:** `/opt/agmind/docker/`
- **Credentials file:** `/opt/agmind/credentials.txt` (chmod 600)
- **Environment file:** `/opt/agmind/docker/.env` (chmod 600, root:root owner)

## Webhooks & Callbacks

**Incoming:**
- **Health endpoint:** `GET /health` → JSON status of all services
  - Returns container health, GPU status, model loaded status
  - Used by: External monitoring, orchestration tools
  - Auth: None (unauthenticated, local network only)

- **Dify API endpoints:** `/api/*`, `/v1/*`
  - Standard Dify REST API
  - Rate limited: 10r/s (nginx)
  - Auth: API keys (created in Dify UI)

**Outgoing:**
- **Alert webhooks** - Notifications on system issues
  - When: `ALERT_MODE=webhook`
  - Endpoint: `ALERT_WEBHOOK_URL` (custom HTTP endpoint)
  - Payload: AlertManager JSON format
  - Use case: Slack, Discord, custom integrations

- **Telegram alerts** - Bot notifications
  - When: `ALERT_MODE=telegram`
  - Bot token: `ALERT_TELEGRAM_TOKEN`
  - Chat ID: `ALERT_TELEGRAM_CHAT_ID`

- **Marketplace updates check** - Version polling
  - Endpoint: `CHECK_UPDATE_URL=https://updates.dify.ai`
  - Frequency: Manual check via agmind CLI or periodic (if configured)
  - No authentication required

- **HuggingFace model pulls** - Model downloads
  - When: Downloading vLLM/TEI models
  - Endpoint: `https://huggingface.co`
  - Auth: Optional `HF_TOKEN` for gated models
  - Rate limiting: Automatic backoff

**Dify Integrations:**
- **Document processing** - Via Docling service
  - Internal endpoint: `http://docling:8765`
  - When: `ETL_TYPE=unstructured_api`

- **Reranking** - Via Xinference
  - Internal endpoint: `http://xinference:9997`
  - Model: `bce-reranker-base_v1` (configurable)
  - When: Reranking enabled in Dify knowledge base settings

- **Code sandbox execution** - Isolated execution
  - Internal endpoint: `http://sandbox:8194`
  - API key: `SANDBOX_API_KEY=dify-sandbox`
  - Network isolation: `ssrf-network` (separated from API)

- **SSRF proxy** - Outbound request filtering
  - Internal endpoint: `http://ssrf_proxy:3128`
  - Used by: Dify API/Worker for external HTTP(S) requests
  - Purpose: Security boundary, DNS spoofing prevention

**Plugin Daemon:**
- **Internal API** - Plugin management
  - Endpoint: `http://plugin_daemon:5002`
  - Auth: `PLUGIN_INNER_API_KEY`
  - Database: Separate PostgreSQL `dify_plugin`

---

*Integration audit: 2026-03-20*
