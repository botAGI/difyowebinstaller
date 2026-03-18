# External Integrations

**Analysis Date:** 2026-03-18

## APIs & External Services

**Model Providers:**
- Ollama - Local LLM inference
  - SDK/Client: langgenius/dify-api (built-in)
  - Connection: `OLLAMA_API_BASE=http://ollama:11434`
  - Auth: No auth required (internal network)

- vLLM (OpenAI-compatible) - High-performance LLM serving
  - SDK/Client: OpenAI Python client
  - Connection: `OPENAI_API_BASE_URL=http://vllm:8000/v1` (when LLM_PROVIDER=vllm)
  - Auth: No auth (internal)

- HuggingFace Hub - Model weights and model registry
  - SDK/Client: huggingface_hub Python library
  - Auth: `HF_TOKEN` (environment variable, optional for public models)
  - Used by: vLLM, TEI for downloading model weights

**Embedding & Semantic Search:**
- Weaviate - Vector database for semantic search
  - SDK/Client: weaviate-client Python library
  - Connection: `WEAVIATE_ENDPOINT=http://weaviate:8080`
  - Auth: `WEAVIATE_API_KEY` (required, generated at install-time)
  - Default vector store: `VECTOR_STORE=weaviate`

- Qdrant - Alternative vector database (interchangeable)
  - SDK/Client: qdrant-client Python library
  - Connection: `QDRANT_HOST=qdrant`, `QDRANT_PORT=6333`
  - Auth: `QDRANT_API_KEY` (required, generated at install-time)
  - Selection: `VECTOR_STORE=qdrant`

- Text Embeddings Inference (TEI) - HuggingFace embeddings
  - SDK/Client: Direct REST API (langgenius/dify-api calls)
  - Connection: Integrated within Dify (internal network)
  - Model: BAAI/bge-m3 (default)
  - Auth: `HF_TOKEN` (for HuggingFace Hub model access)

**Reranking & Retrieval Enhancement:**
- Xinference - Distributed inference for reranking
  - SDK/Client: REST API (langgenius/dify-api)
  - Connection: `XINFERENCE_BASE_URL=http://xinference:9997`
  - Model: bce-reranker-base_v1 (default, configurable)
  - Auth: None required
  - Purpose: Rerank search results for improved relevance

**Document Processing & ETL:**
- Docling - Advanced document parsing and layout understanding
  - SDK/Client: REST API
  - Connection: `UNSTRUCTURED_API_URL=http://docling:8765` (when ETL_TYPE=unstructured_api)
  - Supported formats: PDF, docx, xlsx, ppt, images
  - Auth: None required (internal)

- Unstructured.io API - External document processing (optional)
  - SDK/Client: HTTP REST
  - Connection: `UNSTRUCTURED_API_URL=<external-url>` (when configured)
  - Auth: API key-based (if using SaaS)
  - Default: Not enabled (ETL_TYPE=dify uses built-in parsing)

**Plugin System:**
- Dify Plugin Daemon - Runtime for Dify plugins
  - SDK/Client: gRPC (internal)
  - Connection: `PLUGIN_DAEMON_URL=http://plugin_daemon:5002`
  - Auth: `PLUGIN_DAEMON_KEY` (internal service key)
  - Purpose: Execute third-party plugins, extend functionality

## Data Storage

**Databases:**
- PostgreSQL 15.10-alpine
  - Connection: `postgresql://postgres:<DB_PASSWORD>@db:5432/dify`
  - Credentials: `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`, `DB_HOST`, `DB_PORT`
  - Purpose: Primary relational database (workflows, users, knowledge bases, logs)
  - Client: SQLAlchemy ORM (Python)
  - Hardened: Password encryption (scram-sha-256), max_connections=128, logging enabled

- Redis 7.4.1-alpine
  - Connection: `redis://:REDIS_PASSWORD@redis:6379/1`
  - Credentials: `REDIS_PASSWORD`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_DB`
  - Purpose: Session cache, Celery task queue (worker jobs), real-time features
  - Client: redis-py Python library
  - Hardened: requirepass enforced, dangerous commands renamed/disabled, maxmemory=512mb

**File Storage:**
- Local filesystem (default)
  - Type: `STORAGE_TYPE=local`
  - Path: `/app/api/storage` (container mount: `./volumes/app/storage`)
  - Persistence: Docker named volume `./volumes/app/storage:/app/api/storage`
  - Backups: Optional S3 integration (`ENABLE_S3_BACKUP=true`)

- S3 (AWS / Minio compatible) - Optional backup
  - SDK/Client: boto3 (implicit in backup scripts)
  - Connection: `S3_REMOTE_NAME=s3` (rclone config)
  - Auth: AWS credentials (rclone configuration)
  - Usage: Backup/restore only, not primary storage

**Caching:**
- Redis (see above) - In-process caching via Dify

## Authentication & Identity

**Auth Provider:**
- Dify built-in - Custom username/password (default)
  - Implementation: SQLAlchemy model + Flask-Login
  - Admin creation: `INIT_PASSWORD=<base64-encoded-password>` (injected at first API startup)

- Authelia (optional) - SSO/2FA
  - Profile: Enabled when `ENABLE_AUTHELIA=true` (optional, not default)
  - Implementation: TOTP (2FA), LDAP backend (configurable), File-based users
  - Config: `templates/authelia/configuration.yml.template`, `users_database.yml.template`
  - Storage: SQLite database (`/config/db.sqlite3`)
  - Auth methods: Factor 1 (password), Factor 2 (TOTP/authenticator apps)
  - Integration: nginx reverse proxy enforcement before Dify routes

## Monitoring & Observability

**Error Tracking:**
- Sentry (optional)
  - Usage: Dify Web UI error reporting
  - Env var: `WEB_SENTRY_DSN` (if configured, telemetry)
  - Default: Not configured (`NEXT_TELEMETRY_DISABLED=1`)

**Logs:**
- Loki - Log aggregation (profile: monitoring)
  - Agent: Promtail (reads Docker logs)
  - Query: Grafana integration
  - Retention: Configurable (default: 168h)
  - Config: `monitoring/loki-config.yml`, `monitoring/promtail-config.yml`

- Standard output (json-file driver)
  - Docker logging: json-file driver, max-size=10m, max-file=5
  - Path: `/var/lib/docker/containers/*/`

**Metrics:**
- Prometheus - Metrics scraping
  - Job names: cadvisor, node-exporter, prometheus
  - Config: `monitoring/prometheus.yml`
  - Scrape interval: 15s
  - Retention: Default 15 days

- Node Exporter - Host system metrics
  - Port: 9100 (internal)
  - Metrics: CPU, memory, disk, network, processes

- cAdvisor - Container metrics
  - Port: 8080 (internal)
  - Metrics: Container CPU, memory, disk I/O, network

**Alerting:**
- Alertmanager - Alert deduplication and routing
  - Config: `monitoring/alertmanager.yml`
  - Default receiver: 'default' (no action)
  - Integrations: Telegram, Webhook

**Alert Channels (optional):**
- Telegram Bot
  - Env vars: `ALERT_TELEGRAM_TOKEN`, `ALERT_TELEGRAM_CHAT_ID`
  - Mode: `ALERT_MODE=telegram`
  - Template: HTML-formatted messages with emoji status

- Webhook
  - Env vars: `ALERT_WEBHOOK_URL`
  - Mode: `ALERT_MODE=webhook`
  - Format: Alertmanager payload (JSON)

**Grafana - Visualization:**
- Port: 3001 (localhost-only by default)
- Bind: `GRAFANA_BIND_ADDR=127.0.0.1`
- Admin password: `GRAFANA_ADMIN_PASSWORD` (generated, stored in .env)
- Datasources: Prometheus (auto-provisioned)
- Dashboards: Pre-built (stored in `monitoring/grafana/dashboards/`)

## CI/CD & Deployment

**Hosting:**
- Docker Compose (local deployment)
- Deployment profiles: LAN, VPN, VPS, Offline (air-gapped)
- Single command installation: `sudo bash install.sh`

**TLS/HTTPS:**
- Let's Encrypt (VPS profile)
  - Certbot: Automatic renewal
  - Config: `volumes/certbot/` (certs + renewal hook)
  - Nginx: Automatic HTTPS redirect when TLS_MODE=letsencrypt

- Self-signed (development)
  - Generation: `openssl req -x509` in `lib/config.sh`
  - TLS_MODE=self-signed

- Custom certificates
  - TLS_MODE=custom, provide `TLS_CERT_PATH`, `TLS_KEY_PATH`

**Optional CI/CD:**
- No built-in CI/CD
- GitHub Actions: Lint (shellcheck) and test workflows (see `.github/workflows/`)
- Manual deployment: Git clone + `sudo bash install.sh`

## Environment Configuration

**Required env vars (secrets):**
- `SECRET_KEY` - Dify session key (64 random chars)
- `DB_PASSWORD` - PostgreSQL password (32 random chars)
- `REDIS_PASSWORD` - Redis password (32 random chars)
- `SANDBOX_API_KEY` - Code execution API key (dify-sandbox-{16-chars})
- `PLUGIN_DAEMON_KEY` - Plugin daemon service key (48 random chars)
- `PLUGIN_INNER_API_KEY` - Internal plugin API key (48 random chars)
- `INIT_PASSWORD` - Base64-encoded admin password
- `WEAVIATE_API_KEY` - Vector DB key (32 random chars)
- `QDRANT_API_KEY` - Alternative vector DB key (32 random chars)
- `GRAFANA_ADMIN_PASSWORD` - Grafana login (16 random chars)

**Optional integrations:**
- `HF_TOKEN` - HuggingFace API token (for private models)
- `UNSTRUCTURED_API_URL` - External document processing (Unstructured.io)
- `MONITORING_ENDPOINT` - Remote monitoring ingestion
- `MONITORING_TOKEN` - Remote monitoring auth
- `ALERT_WEBHOOK_URL` - Alertmanager webhook endpoint
- `ALERT_TELEGRAM_TOKEN` - Telegram bot token
- `ALERT_TELEGRAM_CHAT_ID` - Telegram chat ID
- `S3_REMOTE_NAME`, `S3_BUCKET`, `S3_PATH` - S3 backup (when ENABLE_S3_BACKUP=true)

**Secrets location:**
- `.env` file: `/opt/agmind/docker/.env` (mode 600, owned by root)
- Backup: `.env.backup.YYYYMMDD_HHMMSS` (before re-running installer)
- Admin password: `/opt/agmind/.admin_password` (mode 600)
- Redis config: `./volumes/redis/redis.conf` (mode 644, contains password in plaintext for redis user)

**Security features:**
- Placeholder validation: `validate_no_default_secrets()` checks for common weak passwords
- Unresolved placeholders rejected: `^[^#].*=__[A-Z_]+__` pattern
- Secret generation: `/dev/urandom` (head -c 256 + LC_ALL=C tr for safe chars)

## Webhooks & Callbacks

**Incoming:**
- Dify workflow triggers - REST API endpoints for external systems
  - Pattern: `/api/v1/workflows/<workflow-id>/run`
  - Auth: API key (Dify-internal)
  - No webhook subscription system built-in

**Outgoing:**
- Alertmanager → Telegram Bot (optional)
  - Trigger: Alert firing/resolved
  - Destination: Telegram chat
  - Integration: `telegram_configs` in alertmanager.yml

- Alertmanager → Custom Webhook (optional)
  - Trigger: Alert firing/resolved
  - Destination: User-provided webhook URL
  - Format: Alertmanager JSON payload
  - Integration: `webhook_configs` in alertmanager.yml

**Marketplace Webhooks (optional):**
- Dify Marketplace - Version update checks
  - `CHECK_UPDATE_URL=https://updates.dify.ai` (configurable)
  - Connection: Outbound HTTPS
  - Frequency: On-demand in Dify Console

---

*Integration audit: 2026-03-18*
