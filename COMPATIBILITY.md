# AGMind Compatibility Matrix

## Tested Component Versions

| Component | Version | Min Supported | Notes |
|-----------|---------|---------------|-------|
| Dify API/Worker/Web | 1.13.0 | 1.9.2 | Requires weaviate-client v4 |
| Open WebUI | v0.5.20 | v0.5.20 | Pinned for white-label branding |
| Ollama | 0.6.2 | 0.3.0 | GPU support varies by version |
| PostgreSQL | 16-alpine | 14.0 | scram-sha-256 requires ≥14 |
| Redis | 7.4.1-alpine | 6.0 | Used for caching + Celery broker |
| Weaviate | 1.27.6 | 1.27.0 | ⚠️ <1.27.0 causes data loss with Dify ≥1.9.2 |
| Qdrant | v1.12.1 | v1.8.0 | Alternative vector store |
| Nginx | 1.27.3-alpine | 1.25.0 | HTTP/2, sub_filter required |
| Sandbox | 0.2.12 | 0.2.0 | Dify code execution |
| Squid (SSRF Proxy) | 6.6-24.04_edge | 6.0 | SSRF protection proxy |
| Plugin Daemon | 0.5.3-local | 0.5.0 | ⚠️ 0.5.4/0.5.5 break agent tool calling (#640); 0.5.6 broken auto-migrate (#521). Pinned by Dify 1.13.3 upstream |
| Certbot | v3.1.0 | v2.0.0 | Let's Encrypt certificates |
| Docling Serve | v1.16.1 | v1.10.0 | ETL document processing (cu130 = ARM64+CUDA native) |
| Authelia | 4.38 | 4.37 | Optional 2FA |
| Grafana | 12.4.2 | 10.0.0 | Monitoring dashboards |
| Portainer | 2.21.4 | 2.19.0 | Container management UI |
| cAdvisor | v0.52.1 | v0.47.0 | Container metrics |
| Prometheus | v2.54.1 | v2.45.0 | Metrics storage |
| Loki | 3.6.10 | 3.0.0 | Log aggregation |
| Promtail | 3.6.10 | 3.0.0 | Log collector |

## Host OS Matrix

| OS | Version | Status | Notes |
|----|---------|--------|-------|
| Ubuntu | 22.04 LTS | ✅ Tested | Recommended |
| Ubuntu | 24.04 LTS | ✅ Tested | |
| Ubuntu | 20.04 LTS | ⚠️ Supported | EOL April 2025 |
| Debian | 12 (Bookworm) | ✅ Tested | |
| Debian | 11 (Bullseye) | ⚠️ Supported | |
| CentOS Stream | 9 | ⚠️ Supported | |
| Rocky Linux | 9 | ⚠️ Supported | |
| AlmaLinux | 9 | ⚠️ Supported | |

## Infrastructure Requirements

| Resource | Minimum | Recommended | Notes |
|----------|---------|-------------|-------|
| Docker | 24.0 | 27.0+ | Docker Engine |
| Docker Compose | 2.20 | 2.29+ | Compose V2 plugin |
| RAM | 4 GB | 16 GB | 32 GB for GPU inference |
| Disk | 20 GB | 100 GB | SSD recommended |
| CPU | 2 cores | 4+ cores | |
| GPU (optional) | NVIDIA Pascal+ | Ampere+ | CUDA 12.0+ |

## Known Incompatibilities

- **Weaviate <1.27.0 + Dify ≥1.9.2**: Data loss risk. Dify uses weaviate-client v4 which requires server ≥1.27.0.
- **Plugin Daemon <0.5.0**: Ancient version, incompatible with current Dify plugin system.
- **Plugin Daemon 0.5.4 / 0.5.5**: PR #585 added strict validation of `PromptMessage.content`, breaking agent nodes with tool calling on OpenAI/Anthropic/Google (content: null → "content field is required"). Upstream issue: https://github.com/langgenius/dify-plugin-daemon/issues/640 (OPEN).
- **Plugin Daemon 0.5.6**: PR #672 removed auto-migrate from server startup, `migrate` CLI subcommand is not compiled into the Docker image. Fresh deploys fail with `relation "install_tasks" does not exist`. Upstream issue: https://github.com/langgenius/dify-plugin-daemon/issues/521 (OPEN).
- **Plugin Daemon recommended**: **0.5.3-local** (golden stable, pinned by Dify 1.13.3 upstream compose). Unblock to newer versions only when upstream ships a fix for both #640 and #521.
- **Docker <24.0**: Missing healthcheck features and compose v2 compatibility.
- **ARM64**: Most images support arm64. Plugin-daemon 0.5.3-local and docling-serve-cu130 are ARM64 native. Only sandbox (0.2.14) is amd64-only (runs via QEMU emulation on arm64).
