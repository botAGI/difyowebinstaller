# External Integrations

**Analysis Date:** 2026-04-04

## APIs & External Services

**LLM Providers (via LiteLLM gateway):**
- **OpenAI** - ChatGPT/GPT-4 API support
  - SDK: LiteLLM proxy
  - Auth: `OPENAI_API_KEY` (env var)
  - Config: `templates/litellm-config.yaml`

- **Anthropic** - Claude API support
  - SDK: LiteLLM proxy
  - Auth: `ANTHROPIC_API_KEY` (env var)
  - Config: `templates/litellm-config.yaml`

- **Azure OpenAI** - Azure deployment support
  - SDK: LiteLLM proxy
  - Auth: `AZURE_API_KEY` (env var)
  - Config: `templates/litellm-config.yaml`

- **Ollama Local** - Local inference (no external auth needed)
  - Endpoint: `http://ollama:11434`
  - Models: Downloaded to `/root/.ollama` (container volume)

- **vLLM Local** - High-performance local inference
  - Endpoint: `http://vllm:8000` (OpenAI-compatible API)
  - Models: HuggingFace models via `HF_TOKEN` env var

**Search & Scraping:**
- **SearXNG** - Private metasearch engine
  - Endpoint: `http://searxng:8080/search?q=...&format=json`
  - Integration: Dify agent tools, custom workflows
  - No auth required (internal only)

- **Crawl4AI** - Web content extraction API
  - Endpoint: `http://crawl4ai:11235`
  - Features: Chromium rendering, JavaScript execution, AI parsing
  - No auth required (internal only)

**Embedding Providers:**
- **HuggingFace Hub** - Model repository & inference API
  - Auth: `HF_TOKEN` (optional, for private models)
  - Usage: TEI downloads embedding models from HuggingFace
  - Config: `EMBEDDING_MODEL` (e.g., `deepvk/USER-bge-m3`)
  - Env var location: `templates/docker-compose.yml` (TEI service)

- **TEI (Local)** - Text Embeddings Inference
  - Endpoint: `http://tei:80/embed` (internal)
  - Models: Loaded from HuggingFace via `EMBEDDING_MODEL`

**Reranking:**
- **TEI Reranker (Local)** - Cross-encoder re-ranking
  - Endpoint: `http://tei-rerank:80/rerank` (internal)
  - Models: `BAAI/bge-reranker-base` (default, configurable)
  - No external auth needed

**Document Processing:**
- **Docling** - Document processing with OCR
  - Endpoint: `http://docling:8765/convert`
  - Models: Downloaded to `/home/docling/.cache` (container volume)
  - OCR: Tesseract backend (multilingual: `OCR_LANG=rus,eng`)
  - GPU support: NVIDIA CUDA (optional via `NVIDIA_VISIBLE_DEVICES`)

**Monitoring/Alerting:**
- **Telegram** - Alert notifications
  - Auth: `ALERT_TELEGRAM_TOKEN` (bot token)
  - Config: `ALERT_TELEGRAM_CHAT_ID` (recipient)
  - Handler: Alertmanager → Telegram webhook

- **Generic Webhooks** - Custom alert routing
  - Config: `ALERT_WEBHOOK_URL` (HTTP POST endpoint)
  - Payload: Standard Alertmanager format

## Data Storage

**Databases:**

**PostgreSQL** (always enabled)
- Provider: `postgres:15-alpine`
- Connection: `postgresql://${DB_USERNAME}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_DATABASE}`
- Env vars: `DB_HOST=db`, `DB_PORT=5432`, `DB_DATABASE=dify`, `DB_USERNAME=postgres`
- ORM: SQLAlchemy (Dify), psycopg2
- Databases created automatically:
  - `dify` - Dify core (workflows, models, knowledge bases, files)
  - `dify_plugin` - Plugin daemon (plugin registry, permissions)
  - `litellm` - LiteLLM (API keys, usage logs, models)
- Connection pooling: SQLAlchemy
  - `SQLALCHEMY_POOL_SIZE=30` (max concurrent connections)
  - `SQLALCHEMY_POOL_RECYCLE=3600` (recycle after 1 hour)
- SSL ready: `password_encryption=scram-sha-256`
- Backup: PostgreSQL dump via `scripts/backup.sh`

**Redis** (always enabled)
- Provider: `redis:6-alpine`
- Connection: `redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/${REDIS_DB}`
- Env vars: `REDIS_HOST=redis`, `REDIS_PORT=6379`, `REDIS_DB=0`
- Client: `redis-py`
- Uses:
  - Celery message broker (Dify workers)
  - Session cache (Open WebUI)
  - Rate limiting state
  - Distributed locks
- Persistence: RDB snapshots (configurable in `volumes/redis/redis.conf`)
- Backup: Redis BGSAVE via `scripts/backup.sh`

**Vector Databases (one selected):**

**Weaviate** (profile: `weaviate`, default)
- Provider: `semitechnologies/weaviate:1.27.0`
- Connection: `http://weaviate:8080` (internal only, no auth by default)
- Env vars: `WEAVIATE_ENDPOINT=http://weaviate:8080`, `WEAVIATE_API_KEY=...`
- Auth: API key stored in env var, hardcoded user `hello@dify.ai`
- REST API: `GET /v1/.well-known/ready` (healthcheck)
- Client: `weaviate-client` (Python)
- Data: `/var/lib/weaviate` (persistent volume)
- Features: Semantic search, reranking, multi-vectorizer

**Qdrant** (profile: `qdrant`, alternative)
- Provider: `qdrant/qdrant:v1.8.3`
- Connection: `http://qdrant:6333` (internal only)
- Env vars: `QDRANT_HOST=qdrant`, `QDRANT_PORT=6333`, `QDRANT_API_KEY=...`
- REST API: TCP health check on port 6333
- Client: `qdrant-client` (Python)
- Data: `/qdrant/storage` (persistent volume)
- Features: Hybrid search, local filters, snapshot management

**SurrealDB** (profile: `notebook`, optional)
- Provider: `surrealdb/surrealdb:v2.2.1`
- Connection: `ws://surrealdb:8000/rpc` (WebSocket)
- Auth: `SURREAL_USER=root`, `SURREAL_PASSWORD=${SURREALDB_PASSWORD:-changeme}`
- Backend: RocksDB embedded database
- Data: `/mydata/database.db` (persistent volume)
- Usage: Open Notebook document storage
- Client: `surrealdb` Python SDK

**File Storage:**
- **Local filesystem** (always enabled by default)
  - Mount: `./volumes/app/storage:/app/api/storage` (Dify API container)
  - Path: `/app/api/storage` (internal Dify path)
  - Env var: `STORAGE_TYPE=local`
  - Features: User uploads, file management, RAG corpus
  - Backup: Included in daily PostgreSQL + volume snapshots

**Caching:**
- **Redis** - Distributed cache & session store
  - Used by: Dify (rate limits, sessions), Open WebUI (auth tokens)
  - TTL: Configurable per use case

## Authentication & Identity

**Internal Authentication:**

**Dify Admin Account** - Created during installation
- Method: Local credentials (username/password)
- Init: Via env var `INIT_PASSWORD` (base64-encoded)
- Storage: PostgreSQL `account` table
- UI: Accessible at `http://{domain}:3000/`

**Open WebUI Login** - Integrated auth
- Method: Local users (signup optionally disabled)
- Init: Admin user created in Phase 6
- Storage: SQLite or PostgreSQL
- Features: Role-based access control (`DEFAULT_USER_ROLE=user`)

**LiteLLM API Keys** - For programmatic access
- Generation: `LITELLM_MASTER_KEY` env var (master key for dashboard)
- Usage: Dify ↔ LiteLLM API authentication
- Storage: LiteLLM PostgreSQL database
- Management: Via LiteLLM dashboard at `http://localhost:4001`

**Plugin Daemon Authorization** - Internal service auth
- Method: API key-based
- Keys: `PLUGIN_DAEMON_KEY`, `PLUGIN_INNER_API_KEY`
- Storage: Env vars, passed to plugin-daemon container

**Optional: Authelia 2FA/SSO** (profile: `authelia`)
- Provider: `authelia/authelia:4.38`
- Port: 9091
- Features: TOTP, WebAuthn, LDAP, OAuth2 delegation
- Integration: Via nginx reverse proxy
- Config: `./authelia/configuration.yml`, `./authelia/users_database.yml`

**External OAuth Providers** (future integration point):
- Not currently configured in stock installation
- Would be supported via: Authelia SSO backend, LiteLLM OAuth

## Monitoring & Observability

**Error Tracking:**
- None configured by default
- Optional: Sentry integration supported
  - Env var: `WEB_SENTRY_DSN` (Dify Web Console)
  - Env var: `PLUGIN_SENTRY_DSN` (Plugin Daemon)

**Logs:**

**Local approach** (always available):
- Docker container logs: `docker logs {container-name}`
- Dify API logs: Available in container stderr
- Location: Docker daemon logs (depends on logging driver)

**Centralized approach** (profile: `monitoring`):
- **Loki** `3.3.2` - Log aggregation backend
  - Endpoint: `http://loki:3100`
  - Storage: `/loki` (persistent volume)
  - Retention: Configurable in `monitoring/loki-config.yml`

- **Promtail** `3.3.2` - Log shipper
  - Config: `monitoring/promtail-config.yml`
  - Scrapes: Docker container logs via socket `/var/run/docker.sock`
  - Labels: Automatic container label extraction

- **Grafana** - Log visualization
  - Datasource: Loki (pre-configured)
  - Dashboard: `monitoring/grafana/dashboards/logs.json`
  - Query: LogQL syntax in Grafana UI

**Metrics:**

**System & Container Metrics:**
- **Prometheus** `v2.54.1` - Time-series metrics database
  - Config: `monitoring/prometheus.yml`
  - Retention: 15 days (default, configurable)
  - Storage: `/prometheus` (persistent volume)
  - Scrape targets: Configured in `prometheus.yml`

- **Node Exporter** `v1.8.2` - Host system metrics
  - Port: 9100
  - Metrics: CPU, memory, disk, network, process count
  - Volumes: Read-only access to `/proc`, `/sys`, `/`

- **cAdvisor** `v0.55.1` - Container metrics
  - Port: 8080
  - Metrics: Per-container CPU, memory, network, I/O
  - Access: Docker socket (privileged)

- **Grafana** `12.4.1` - Metrics visualization
  - Port: 3001 (localhost-only)
  - Datasources: Prometheus (pre-configured)
  - Dashboards (shipped):
    - `monitoring/grafana/dashboards/overview.json` - System overview
    - `monitoring/grafana/dashboards/containers.json` - Container metrics
    - `monitoring/grafana/dashboards/alerts.json` - Alert status
  - Admin password: `GRAFANA_ADMIN_PASSWORD` (auto-generated, stored in `.env`)

**Alerting:**
- **Prometheus Alert Rules** - Threshold-based alerting
  - Config: `monitoring/alert_rules.yml`
  - Rules: CPU > 80%, memory > 90%, disk > 85%, service down

- **Alertmanager** `v0.27.0` - Alert routing
  - Config: `monitoring/alertmanager.yml`
  - Receivers:
    - Telegram: Bot token (`ALERT_TELEGRAM_TOKEN`) + chat ID (`ALERT_TELEGRAM_CHAT_ID`)
    - Webhook: Generic HTTP POST (`ALERT_WEBHOOK_URL`)
  - Grouping: By severity and service

**Portainer** - Container management UI
- Port: 9443 (localhost-only)
- Access: HTTPS only, no auth by default (local network)
- Docker socket: Read-write (full container control)
- Use: Visual container logs, stats, exec shell

## CI/CD & Deployment

**Hosting:**
- **Self-hosted Docker Compose** on Linux VMs or bare metal
- **Cloud-ready profiles:**
  - LAN: Internal network only
  - VPS: Public domain with TLS (Let's Encrypt)
  - Offline: Air-gapped (no external API calls)

**Deployment Pipeline:**
```
User runs install.sh
  ↓ (Phase 1) Diagnostics
  ↓ (Phase 2) Wizard (interactive config)
  ↓ (Phase 3) Docker installation
  ↓ (Phase 4) Config generation (.env)
  ↓ (Phase 5) Docker image pull & validation
  ↓ (Phase 6) docker compose up -d
  ↓ (Phase 7) Health checks (wait for services)
  ↓ (Phase 8) Model downloads (LLM, embeddings)
  ↓ (Phase 9) Systemd setup, backups, CLI
```

**CI/CD Integration Points:**
- GitHub Actions: `.github/workflows/` (if added) - build/test/release
- Git tags: `templates/release-manifest.json` - version tracking
- Registry: Docker Hub (official images), ghcr.io (GHCR), quay.io (Docling)

**Systemd Integration:**
- Installed in Phase 9: `/etc/systemd/system/agmind.service`
- Features: Auto-start on boot, systemd-managed logging
- Management: `sudo systemctl start/stop/restart agmind`

**Backup & Disaster Recovery:**
- **Daily backups:** Cron job via `lib/backup.sh`
- **Destination:** `/var/backups/agmind/` (local) or S3 (optional)
- **Contents:** PostgreSQL dump, Redis RDB, volumes tarball
- **Encryption:** Optional via `ENABLE_BACKUP_ENCRYPTION=true`
- **Retention:** `BACKUP_RETENTION_COUNT=10` (keep last N backups)
- **Restore:** `agmind restore {backup-path}`

## Environment Configuration

**Required Environment Variables:**

**Secrets** (auto-generated):
- `SECRET_KEY` - Django secret key (openssl rand -hex 32)
- `DB_PASSWORD` - PostgreSQL password
- `REDIS_PASSWORD` - Redis password
- `SANDBOX_API_KEY` - Code execution auth
- `PLUGIN_DAEMON_KEY` - Plugin daemon secret
- `WEAVIATE_API_KEY` / `QDRANT_API_KEY` - Vector DB auth
- `LITELLM_MASTER_KEY` - AI gateway master key (if enabled)
- `GRAFANA_ADMIN_PASSWORD` - Monitoring dashboard password

**Database Connectivity:**
- `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_DATABASE`
- `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`

**LLM Configuration:**
- `LLM_PROVIDER` - `ollama`, `vllm`, `openai`, `anthropic`, `azure`, etc.
- `LLM_MODEL` - Model name/identifier (e.g., `qwen2.5:14b`)
- `EMBED_PROVIDER` - `ollama`, `tei`, `huggingface`, etc.
- `EMBEDDING_MODEL` - Embedding model (e.g., `deepvk/USER-bge-m3`)
- `HF_TOKEN` - HuggingFace token (for private models)

**Vector Store:**
- `VECTOR_STORE` - `weaviate` or `qdrant`
- Store-specific env vars (API keys, endpoints)

**URLs & Domains:**
- `CONSOLE_WEB_URL` - Dify console URL
- `CONSOLE_API_URL` - Dify API base URL
- `SERVICE_API_URL` - Dify service API URL
- `APP_WEB_URL` - App frontend URL
- `APP_API_URL` - App API URL
- `NGINX_SERVER_NAME` - Reverse proxy domain

**Deployment Profile:**
- `DEPLOY_PROFILE` - `lan`, `vps`, `offline`
- `DEPLOY_ENV` - `PRODUCTION` or `STAGING`

**Secrets Storage Location:**
- **Generation time:** `lib/config.sh:_generate_secrets()`
- **Storage:** `/opt/agmind/docker/.env` (chmod 600)
- **Backup:** `.env.backup.{timestamp}` files (automatic before updates)
- **Rotation:** Optional via `agmind rotate-secrets` CLI command

**Credentials File:**
- **Location:** `/opt/agmind/credentials.txt` (generated after install)
- **Contents:** Admin username, password, initial endpoints
- **Security:** Only readable by root (mode 600)
- **Printing:** `cat /opt/agmind/credentials.txt`

## Webhooks & Callbacks

**Incoming Webhooks:**
- None configured by default
- Potential integration points:
  - Dify workflows can receive HTTP POST triggers
  - Crawl4AI: Async job callbacks (future feature)

**Outgoing Webhooks:**

**Alert Notifications:**
- **Telegram:** Alertmanager → Telegram bot API
  - Endpoint: `https://api.telegram.org/bot{TOKEN}/sendMessage`
  - Auth: Bot token (`ALERT_TELEGRAM_TOKEN`)
  - Payload: Chat ID + message text

- **Generic HTTP:** Alertmanager → Custom webhook
  - Endpoint: `ALERT_WEBHOOK_URL` (user-configured)
  - Payload: Alertmanager JSON format
  - Method: HTTP POST

**Dify External Integrations:**
- **Marketplace updates:** `https://updates.dify.ai` (configurable)
  - Check new plugins, model updates
  - Env var: `CHECK_UPDATE_URL`

- **LLM provider APIs:** OpenAI, Anthropic, Azure (via LiteLLM proxy)
  - Dify → LiteLLM → External API

**Model Downloads:**
- **HuggingFace Hub:** TEI ↔ HuggingFace API
  - Models cached in `/root/.cache/huggingface` (container volume)
  - Token: `HF_TOKEN` (for private models)

---

*Integration audit: 2026-04-04*
