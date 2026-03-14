# AGMind Compatibility Matrix

## Tested Component Versions

| Component | Version | Min Supported | Notes |
|-----------|---------|---------------|-------|
| Dify API/Worker/Web | 1.13.0 | 1.9.2 | Requires weaviate-client v4 |
| Open WebUI | v0.5.20 | v0.5.20 | Pinned for white-label branding |
| Ollama | 0.6.2 | 0.3.0 | GPU support varies by version |
| PostgreSQL | 15.10-alpine | 15.0 | scram-sha-256 requires ≥14 |
| Redis | 7.4.1-alpine | 7.0 | Used for caching + Celery broker |
| Weaviate | 1.27.6 | 1.27.0 | ⚠️ <1.27.0 causes data loss with Dify ≥1.9.2 |
| Qdrant | v1.12.1 | v1.8.0 | Alternative vector store |
| Nginx | 1.27.3-alpine | 1.25.0 | HTTP/2, sub_filter required |
| Sandbox | 0.2.12 | 0.2.0 | Dify code execution |
| Squid (SSRF Proxy) | 6.6-24.04_edge | 6.0 | SSRF protection proxy |
| Plugin Daemon | 0.5.3 | 0.5.0 | ⚠️ <0.5.0 is ancient/broken |
| Certbot | v3.1.0 | v2.0.0 | Let's Encrypt certificates |
| Docling | 2.15.0 | 2.10.0 | ETL document processing |
| Xinference | v0.16.3 | v0.14.0 | Reranker model serving |
| Authelia | 4.38 | 4.37 | Optional 2FA |
| Grafana | 11.4.0 | 10.0.0 | Monitoring dashboards |
| Portainer | 2.21.4 | 2.19.0 | Container management UI |
| cAdvisor | v0.49.1 | v0.47.0 | Container metrics |
| Prometheus | v2.54.1 | v2.45.0 | Metrics storage |
| Loki | 3.3.2 | 3.0.0 | Log aggregation |
| Promtail | 3.3.2 | 3.0.0 | Log collector |

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
- **Docker <24.0**: Missing healthcheck features and compose v2 compatibility.
- **ARM64**: Most images support arm64 except sandbox, plugin-daemon, docling, xinference.
