# Component Dependency Groups

Components within each group should be updated and tested together.
Groups are based on shared configuration, version coupling, or runtime dependencies.

## dify-core

| Component | Version Key | Notes |
|-----------|-------------|-------|
| dify-api | DIFY_VERSION | API backend |
| dify-web | DIFY_VERSION | Frontend |
| plugin-daemon | PLUGIN_DAEMON_VERSION | Plugin execution engine |
| sandbox | SANDBOX_VERSION | Code execution sandbox |

> Always use the same `DIFY_VERSION` for api and web.
> Check plugin-daemon and sandbox compatibility on each Dify release.

## gpu-inference

| Component | Version Key | Notes |
|-----------|-------------|-------|
| vllm | VLLM_VERSION | GPU inference server |
| tei | TEI_VERSION | Text embeddings |

> Both depend on CUDA version and GPU driver.
> Update together when changing CUDA base.

## monitoring

| Component | Version Key | Notes |
|-----------|-------------|-------|
| grafana | GRAFANA_VERSION | Dashboards |
| prometheus | PROMETHEUS_VERSION | Metrics collection |
| loki | LOKI_VERSION | Log aggregation |
| promtail | PROMTAIL_VERSION | Log shipping |
| alertmanager | ALERTMANAGER_VERSION | Alert routing |
| node-exporter | NODE_EXPORTER_VERSION | Host metrics |
| cadvisor | CADVISOR_VERSION | Container metrics |

> Independent from AI stack. Can be updated freely.
> Keep loki and promtail on the same major version.

## standalone

| Component | Version Key | Notes |
|-----------|-------------|-------|
| ollama | OLLAMA_VERSION | Local LLM runtime |
| openwebui | OPENWEBUI_VERSION | Chat UI |
| portainer | PORTAINER_VERSION | Container management |
| authelia | AUTHELIA_VERSION | SSO/2FA gateway |
| certbot | CERTBOT_VERSION | TLS certificates |
| docling | DOCLING_SERVE_VERSION | Document conversion |
| xinference | XINFERENCE_VERSION | Model serving |

> No cross-dependencies within this group. Update individually.

## infra

| Component | Version Key | Notes |
|-----------|-------------|-------|
| postgres | POSTGRES_VERSION | Primary database |
| redis | REDIS_VERSION | Cache and locks |
| nginx | NGINX_VERSION | Reverse proxy |
| weaviate | WEAVIATE_VERSION | Vector store |
| qdrant | QDRANT_VERSION | Vector store (alternative) |
| squid | SQUID_VERSION | SSRF proxy |

> **Postgres major version upgrade requires migration** (pg_dump / pg_restore).
> Redis and nginx are backward compatible — safe to update.
> Vector stores: update only when Dify release notes mention compatibility.
