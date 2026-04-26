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
| RAGFlow | ragflow-local:arm64 (Hendrik build, RAGFlow v0.24.0) | v0.20.3 | **Self-build via HendrikSchoettle/ragflow-dgx-spark** — upstream brozen Sep 2024, community 0xgkd v0.20.3 без GPU OCR. Hendrik = v0.24.0 + ONNX Runtime для SM_121/CUDA 13 + multilingual OCR (Latin/Cyrillic/Chinese). Plugin `witmeng/ragflow-api` |
| Elasticsearch (RAGFlow) | 9.0.2 | 8.11.0 | RAGFlow main moved 8.11→9.x. ES 9 = reindex required from 8 |
| MySQL (RAGFlow) | 8.0.39 | 8.0.30 | RAGFlow has no Postgres support |

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
- **RAGFlow upstream arm64 builds брошены с 2024-09-29.** `dev-slim-arm64` / `dev-arm64` единственные upstream arm64 теги, последнее обновление 2024-09-29 — содержат bug `get_txt` vs `get_text` в deepdoc парсере → task_executor crash loop. Все semver releases (`v0.20.x` — `v0.25.0`) и `latest-slim`/`nightly-slim` = single-manifest amd64. **Используем self-build через `HendrikSchoettle/ragflow-dgx-spark`** (v0.24.0, last update 2026-04-13) — патчит upstream под GB10/SM_121/CUDA 13 + multilingual OCR (Latin+Cyrillic+Chinese cascade). install.sh::_build_ragflow_spark делает first build 45-90 мин (ORT GPU wheel compile), subsequent ~2 мин (idempotent SHA cache). Final tag = ragflow-local:arm64.
- **RAGFlow Hendrik build + ORT eigen.cmake gitlab SHA mismatch.** ORT 1.21.1 cmake/external/eigen.cmake скачивает eigen с gitlab.com через FetchContent с захардкоженным URL_HASH, но gitlab regenerates archive zips → SHA mismatch → cmake error. install.sh::_patch_hendrik_ort_eigen_sha обновляет expected SHA в cmake/deps.txt после ORT clone (содержимое идентично — commit immutable, отличается compression). Idempotent через marker check.
- **RAGFlow + Infinity engine на arm64**: НЕ поддерживается. Использовать только `DOC_ENGINE=elasticsearch`. OpenSearch 2.19 = fallback при возражениях по Elastic License.
- **RAGFlow + DEVICE=cuda + vLLM на master**: OOM. gemma-4 (~95 GiB) + docling (16 GiB) + DeepDoc (5-15 GiB) > 121 GiB unified memory. Solution: либо `LLM_ON_PEER=true` (vLLM на peer Spark), либо `RAGFLOW_DEVICE=cpu`. Watchdog в `lib/health.sh::check_ragflow_gpu_contention`.
- **RAGFlow ES 9 + vm.max_map_count <262144**: ES bootstrap fails "max virtual memory areas too low". Auto-fixed install.sh::_ensure_es_sysctl (persists в /etc/sysctl.d/).
- **RAGFlow Dify integration via External KB API**: Работает, но плагин `witmeng/ragflow-api` (8K+ installs) предпочтительнее — 5 операций vs 1.
