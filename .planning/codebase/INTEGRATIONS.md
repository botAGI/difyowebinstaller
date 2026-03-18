# External Integrations

**Analysis Date:** 2026-03-18

## APIs & External Services

**Dify Marketplace:**
- Marketplace API - Plugin and extension management
  - SDK: Dify Plugin Daemon (`langgenius/dify-plugin-daemon`)
  - Endpoint: `${CHECK_UPDATE_URL:-https://updates.dify.ai}`
  - Purpose: Update checks, marketplace discovery

**Ollama Integration:**
- Ollama HTTP API - Local LLM and embedding model serving
  - Base URL: `${OLLAMA_API_BASE:-http://ollama:11434}`
  - Purpose: LLM inference, embedding generation
  - Models: Configurable via `LLM_MODEL` and `EMBEDDING_MODEL` env vars
  - Default embedding: `bge-m3`

**Document Processing (Optional ETL):**
- Docling API - Advanced document parsing and conversion
  - Endpoint: `http://docling:8765`
  - Purpose: PDF/document extraction for knowledge base ingestion
  - Profile: `etl` (enabled with `ETL_ENHANCED=yes`)
  - Client: Docling Serve container

**Reranking Service (Optional ETL):**
- Xinference API - Cross-encoder reranking for search results
  - Base URL: `${XINFERENCE_BASE_URL:-http://xinference:9997}`
  - Model: `${RERANK_MODEL_NAME:-bce-reranker-base_v1}`
  - Purpose: Re-rank retrieval results for better relevance
  - Profile: `etl` (enabled with `ETL_ENHANCED=yes`)

**Plugin Daemon Internal API:**
- Dify Plugin System - Plugin execution and management
  - Daemon URL: `${PLUGIN_DAEMON_URL:-http://plugin_daemon:5002}`
  - Dify API: `${PLUGIN_DIFY_INNER_API_URL:-http://api:5001}`
  - Auth: `${PLUGIN_DAEMON_KEY}` and `${PLUGIN_INNER_API_KEY}`
  - Purpose: Plugin installation, execution, lifecycle management

**Update Checks:**
- AGMind/Dify Updates - Version checking from remote registry
  - URL: `${CHECK_UPDATE_URL:-https://updates.dify.ai}`
  - Purpose: Marketplace updates, plugin availability

**External URL Configuration:**
- Console Web UI: `${CONSOLE_WEB_URL:-}` (e.g., https://domain.com)
- Console API: `${CONSOLE_API_URL:-}` (e.g., https://domain.com)
- Service API: `${SERVICE_API_URL:-}` (e.g., https://domain.com)
- App API: `${APP_API_URL:-}` (e.g., https://domain.com)
- App Web: `${APP_WEB_URL:-}` (e.g., https://domain.com)
- File Storage: `${FILES_URL:-}` (e.g., https://domain.com/files)
- File Access Timeout: `${FILES_ACCESS_TIMEOUT:-300}` seconds

## Data Storage

**Databases:**
- PostgreSQL v15.10
  - Primary database for Dify configuration, workflows, knowledge bases, audit logs
  - Connection: `postgres://${DB_USERNAME}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_DATABASE}`
  - Default: `postgres://postgres:PASSWORD@db:5432/dify`
  - Pool size: `${SQLALCHEMY_POOL_SIZE:-30}`
  - Recycle time: `${SQLALCHEMY_POOL_RECYCLE:-3600}` seconds
  - Plugin daemon uses separate database: `dify_plugin`

- Redis v7.4.1
  - Cache and Celery task queue
  - Connection: `redis://:${REDIS_PASSWORD:-}@${REDIS_HOST:-redis}:${REDIS_PORT:-6379}/1`
  - Celery broker URL: Automatically constructed from Redis config
  - DB 0: Cache (default)
  - DB 1: Celery broker
  - Auth: Optional password via `${REDIS_PASSWORD}`
  - TLS: `${REDIS_USE_SSL:-false}`, `${BROKER_USE_SSL:-false}`

**Vector Database (Selectable):**
- Weaviate v1.27.6 (profile: `weaviate`)
  - Endpoint: `${WEAVIATE_ENDPOINT:-http://weaviate:8080}`
  - API Key: `${WEAVIATE_API_KEY}`
  - Vectorizer: None (external embeddings via Ollama)
  - Purpose: RAG knowledge base storage and retrieval
  - Admin user: `hello@dify.ai`

- Qdrant v1.12.1 (profile: `qdrant`, mutually exclusive with Weaviate)
  - Host: `${QDRANT_HOST:-qdrant}`
  - Port: `${QDRANT_PORT:-6333}`
  - API Key: `${QDRANT_API_KEY}`
  - Purpose: Vector embeddings for semantic search

**File Storage:**
- Local filesystem only (current implementation)
  - Storage type: `${STORAGE_TYPE:-local}`
  - Path: `/app/api/storage` (inside API container)
  - Host mount: `./volumes/app/storage:/app/api/storage`
  - Timeout for file access: `${FILES_ACCESS_TIMEOUT:-300}` seconds
  - Future: S3-compatible storage supported via environment variables

**Backup Storage (Optional):**
- Local backup: Cron-scheduled to `${BACKUP_TARGET:-/opt/agmind/backups}`
- Remote SSH backup: Via `rsync` to host `${REMOTE_BACKUP_HOST}:${REMOTE_BACKUP_PATH}`
  - SSH credentials: `${REMOTE_BACKUP_USER}`, `${REMOTE_BACKUP_KEY}`, `${REMOTE_BACKUP_PORT:-22}`
- S3 backup (optional): Configured via environment for offsite replication
  - Bucket: `${S3_BUCKET}`
  - Encryption: `${ENABLE_BACKUP_ENCRYPTION:-false}`

**Caching:**
- Redis (integrated) - In-memory cache for sessions, temporary data

## Authentication & Identity

**Auth Provider:**
- Custom Dify authentication system
  - Implementation: Dify API manages user accounts, JWT tokens, RBAC
  - Initial admin password: `${INIT_PASSWORD}` (base64-encoded, set during install)
  - Password encryption: `scram-sha-256` (PostgreSQL configuration)
  - Session storage: Redis

**Optional: Authelia Proxy** (profile: `authelia`)
- Authelia v4.38 - SSO and multi-factor authentication layer
  - Config location: `./authelia/` directory
  - JWT secret: `${AUTHELIA_JWT_SECRET}`
  - Purpose: OAuth2/OpenID Connect, TOTP, WebAuthn support
  - Enabled via: `${ENABLE_AUTHELIA:-false}`

**Open WebUI Authentication:**
- Built-in user management
  - Signup: Disabled by default (`${ENABLE_SIGNUP:-false}`)
  - Authentication: Form-based with Open WebUI DB
  - Default role: `${DEFAULT_USER_ROLE:-user}`

## Monitoring & Observability

**Error Tracking:**
- Sentry (optional)
  - Web DSN: `${WEB_SENTRY_DSN:-}` (Open WebUI telemetry)
  - Plugin DSN: `${PLUGIN_SENTRY_DSN:-}`
  - Purpose: Frontend error tracking (disabled in offline mode)

**Logs:**
- JSON file logging (all containers)
  - Driver: `json-file`
  - Max size: `10m` per file
  - Max files: `5` (rotation)
  - Loki log aggregation: `${ENABLE_LOKI:-true}` (monitoring profile)

**Metrics:**
- Prometheus (monitoring profile)
  - Config: `monitoring/prometheus.yml`
  - Alert rules: `monitoring/alert_rules.yml`
  - Scrape interval: Default settings
  - Node Exporter: Host metrics
  - cAdvisor: Container metrics

- Grafana (monitoring profile)
  - Port: `${GRAFANA_PORT:-3001}` (localhost-only)
  - Admin password: `${GRAFANA_ADMIN_PASSWORD}`
  - Data sources: Prometheus, Loki
  - Dashboards: Pre-configured in `monitoring/grafana/dashboards/`

**Log Aggregation:**
- Loki + Promtail (monitoring profile)
  - Config: `monitoring/loki-config.yml`, `monitoring/promtail-config.yml`
  - Log shipping: Promtail collects Docker logs to Loki
  - Retention: Configurable in Loki config

## CI/CD & Deployment

**Hosting:**
- Docker Compose on Linux/macOS
- Cloud platforms: Any with Docker support (VPS, EC2, Azure, GCP, DigitalOcean, Hetzner, etc.)
- Kubernetes: Not natively supported (future: Helm charts via `/gsd:plan-phase`)

**CI Pipeline:**
- GitHub Actions (inferred from `.github/workflows/`)
  - Linting: `lint.yml` badge present in README
  - Testing: `test.yml` badge present in README
  - Manifest validation: Python script (`scripts/check-manifest-versions.py`)

**TLS Certificates:**
- Let's Encrypt (vps profile) - Automatic via Certbot
  - Domain: `${CERTBOT_DOMAIN}`
  - Email: `${CERTBOT_EMAIL}` (renewal notifications)
  - Renewal: Automated every 12 hours
  - Certificates: `./volumes/certbot/conf/` (mounted into nginx)

- Manual TLS (lan, vpn, offline profiles)
  - Certificate path: `${TLS_CERT_PATH}`
  - Key path: `${TLS_KEY_PATH}`
  - TLS mode: `${TLS_MODE:-none}` (options: none, self-signed, letsencrypt)

## Environment Configuration

**Required env vars (must be set before install):**
- `DEPLOY_PROFILE` - Deployment context (vps, lan, vpn, offline)
- `LLM_MODEL` - Language model name (e.g., `qwen2.5:14b`)
- `EMBEDDING_MODEL` - Embedding model (default: `bge-m3`)
- `ADMIN_EMAIL` or `INIT_PASSWORD` - Initial admin credentials
- `SECRET_KEY` - CSRF protection and session signing
- `DB_PASSWORD` - PostgreSQL password
- `REDIS_PASSWORD` - Redis password (optional)
- `SANDBOX_API_KEY` - Code execution sandbox auth key
- `PLUGIN_DAEMON_KEY` - Plugin system auth key
- `PLUGIN_INNER_API_KEY` - Plugin-to-Dify API auth

**Optional Configuration:**
- `VECTOR_STORE` - `weaviate` or `qdrant` (default: weaviate)
- `ETL_ENHANCED` - Enable document processing (yes/no, default: no)
- `MONITORING_MODE` - `none`, `local`, `external` (default: none)
- `ALERT_MODE` - `none`, `webhook`, `telegram` (default: none)
- `ENABLE_AUTHELIA` - Single sign-on layer (default: false)
- `ENABLE_UFW`, `ENABLE_FAIL2BAN` - Host security (default: varies by profile)
- `NGINX_HTTPS_ENABLED` - TLS termination (default: false for lan, true for vps)

**Secrets location:**
- `.env` file in `/opt/agmind/docker/` (generated at install time)
- Admin password backup: `/opt/agmind/.admin_password` (readable by root only)
- Never committed to git - `.gitignore` protects `/docker/.env*`
- Rotation: Via `scripts/rotate_secrets.sh` (with SOPS integration)

## Webhooks & Callbacks

**Incoming:**
- Dify API accepts workflow trigger webhooks (built-in, no external config needed)
- Plugin system supports incoming plugin callbacks

**Outgoing - Monitoring Alerts:**
- Webhook alerting: `${ALERT_WEBHOOK_URL}` (generic HTTP POST)
- Telegram alerting: `${ALERT_TELEGRAM_TOKEN}`, `${ALERT_TELEGRAM_CHAT_ID}`
- Alert manager config: `monitoring/alertmanager.yml` (routing rules)
- Conditions: CPU, memory, disk, container health thresholds

**Outgoing - Backup Notifications:**
- Backup completion: Logged to JSON file, optionally sent to monitoring endpoint
- Failure alerts: Via alerting system if `ALERT_MODE` configured

**Code Sandbox SSRF Mitigation:**
- Outbound proxy: Squid at `${SSRF_PROXY_HTTP_URL:-http://ssrf_proxy:3128}`
  - HTTPS proxy: `${SSRF_PROXY_HTTPS_URL:-http://ssrf_proxy:3128}`
- Purpose: Prevent code-in-box from accessing internal network services
- Config: `./volumes/ssrf_proxy/squid.conf`

---

*Integration audit: 2026-03-18*
