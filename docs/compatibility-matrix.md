# Compatibility Matrix

> **Source of truth for image:tag:** [templates/versions.env](../templates/versions.env)
>
> This matrix documents *tested combinations* at AGmind release v3.0.2 (see [release-manifest.json](../templates/release-manifest.json)). For exact pinned tags always consult `versions.env`.

## Why these versions?

AGmind targets DGX Spark only (aarch64 / GB10) since v3.1. Every image must have a verified arm64 manifest before it can be added or bumped. Several components are pinned **below** their latest upstream release because newer tags dropped arm64 support or regress on GB10 unified memory architecture — those rows link the relevant ADR so the hold rationale is preserved.

---

## Platform

| Component | Tested version | Notes |
|-----------|---------------|-------|
| **DGX OS** | `7.5.0` | Ubuntu 24.04 LTS arm64 base; ships NVIDIA driver 580.142 as the only qualified release for GB10 |
| **NVIDIA Driver** | `580.142` | **HOLD — do not update past 580.126.09** — CUDAGraph deadlock + UMA memory leak + TMA bug on GB10 at 590+/595+. See [ADR-0005](adr/0005-driver-580-hold.md) |
| **Docker Engine** | `≥ 29.0` | Enforces minimum API 1.44; affects Portainer — must be ≥ 2.33.5/2.36.0 (see Notes in Core Stack) |
| **Docker Compose** | `v2.x` | Plugin form: `docker compose` (no hyphen). `docker-compose` v1 not supported |
| **vm.max_map_count** | `≥ 262144` | Required for Elasticsearch 9.x (RAGFlow profile). Set automatically by `install.sh` / `agmind doctor --fix` via `/etc/sysctl.d/99-agmind-es.conf` |
| **Architecture** | `aarch64` only | x86_64/amd64 support removed since v3.1. Override `AGMIND_ALLOW_AMD64=true` exists for CI only — no support guarantee. See [ADR-0001](adr/0001-arm64-only.md) |

---

## Core Stack

| Component | Version (from versions.env) | Notes |
|-----------|----------------------------|-------|
| **Dify** | `1.13.3` | Plugin daemon pinned at `0.5.3-local` — see [ADR-0004](adr/0004-plugin-daemon-pin-0.5.3-local.md). Wait for 1.14.1 (Iteration+Parallel regression open in 1.14.0) |
| **Dify Plugin Daemon** | `0.5.3-local` | 0.5.4–0.5.6 carry null-content regression (#640) or missing migrate CLI — see [ADR-0004](adr/0004-plugin-daemon-pin-0.5.3-local.md) |
| **Open WebUI** | `v0.9.5` | Chat UI only (Pipelines removed 2026-04-26 — RAG lives in Dify + RAGFlow) |
| **vLLM** | `gemma4-cu130` | NVIDIA playbook build for SM_121 (GB10). FlashInfer FP8 broken on SM_121 — use `VLLM_ATTENTION_BACKEND=TRITON_ATTN`. Runs on peer node (`LLM_ON_PEER=true`) |
| **Docling-serve** | `docling-serve-cu130:v1.16.1` | Standalone GPU container for document conversion. v1.17 has RapidOcr regression (startup FAIL) — stay on 1.16.1. See [ADR-0006](adr/0006-docling-standalone-not-plugin.md) |
| **RAGFlow** | `ragflow-local:arm64` (self-built) | Upstream has no arm64 builds since 2024-09-29. Built from HendrikSchoettle/ragflow-dgx-spark fork (v0.24.0 + patches). See troubleshooting.md for build steps |
| **PostgreSQL** | `16-alpine3.23` (per versions.env) | Shared by Dify + RAGFlow (separate databases) |
| **Redis** | `7.4.8-alpine` (per versions.env) | Shared by Dify components; ACL-hardened (no FLUSHDB for default user) |
| **Weaviate** | `1.37.2` (per versions.env) | **Default** vector store. ~15 GiB heap counts against unified-memory budget. See [vector-db-decision-matrix.md](vector-db-decision-matrix.md) and [ADR-0003](adr/0003-vector-db-default-weaviate.md) |
| **Qdrant** | `v1.17.1` (per versions.env) | Lightweight alternative vector store. Opt-in: `VECTOR_STORE=qdrant`. Fully supported |
| **Milvus** | `v2.6.15` (per versions.env) | **EXPERIMENTAL** — for very large corpora (>~50M chunks). Compose blocks present but not active by default; lib integration in backlog 999.5. Not compatible with RAGFlow (upstream PR #6367 closed) |
| **nginx** | `1.30.0-alpine` (per versions.env) | All `proxy_pass` use variable form (`set $u_... http://...`) to handle Docker DNS — see [troubleshooting.md](troubleshooting.md) (502 on recreate section) |
| **cAdvisor** | `v0.55.1` | **HOLD — do not update to v0.56+** — v0.56.0/0.56.1/0.56.2 have no arm64 manifest in the container registry. See [troubleshooting.md](troubleshooting.md) for verification command |
| **MinIO** | `RELEASE.2025-09-07T16-13-09Z` | **HOLD** — newer releases (2025-09-30+) dropped arm64 from multi-arch manifest. Verify with `docker manifest inspect minio/minio:<tag> \| grep -c arm64` before any bump |
| **Portainer** | `2.41.1` (master + agent same tag) | Must be ≥ 2.33.5/2.36.0 for Docker 29 API compatibility. Master and agent **must** share the same version tag (TLS handshake drift otherwise) |
| **Loki** | `3.6.10` | Distroless image — no `/bin/sh`, no healthcheck possible. Monitored via Prometheus `up{job="loki"}` metric |
| **Authelia** | `4.39.19` (per versions.env) | SSO/OIDC provider. Config format may change on minor bumps — test before upgrading |
| **Prometheus** | `v2.54.1` (per versions.env) | 15d retention, 2 GB cap. v3.x has new storage format — major bump deferred |
| **Grafana** | `12.4.3` (per versions.env) | Dashboards provisioned from `monitoring/grafana/` |
| **Grafana Alloy** | `v1.16.1` (per versions.env) | Replaces Promtail (deprecated 2026-04-25) for log + metrics collection. Distroless — no healthcheck |
| **node-exporter** | `v1.11.1` (per versions.env) | Host metrics |
| **redis-exporter** | `v1.83.0` (per versions.env) | Distroless — no healthcheck |
| **postgres-exporter** | `v0.19.1` (per versions.env) | Has `/bin/sh` — healthcheck via `wget` works |
| **nginx-exporter** | `1.5.1` (per versions.env) | Distroless — no healthcheck |
| **Elasticsearch (RAGFlow)** | `9.4.0` (per versions.env) | Requires `vm.max_map_count ≥ 262144` (see Platform table). Native arm64 |
| **MySQL (RAGFlow)** | `8.0.39` (per versions.env) | RAGFlow has no PostgreSQL support; MySQL is hardcoded in its schema |
| **Squid** | `6.6-24.04_edge` (per versions.env) | HTTP proxy for SSRF control (docker-network-scoped allowlist) |
| **SearXNG** | `2026.5.10-df1f24fb7` (per versions.env) | Optional web search. Uses date-tag schema |
| **LiteLLM** | `v1.83.14-stable.patch.3` (per versions.env) | Optional AI gateway |

---

## See also

- [architecture/](architecture/) — service topology, data-flow, network/security zones diagrams
- [vector-db-decision-matrix.md](vector-db-decision-matrix.md) — when to choose Weaviate / Qdrant / Milvus
- [dify-vs-ragflow.md](dify-vs-ragflow.md) — component responsibility map (Dify vs RAGFlow vs Docling vs vLLM)
- [troubleshooting.md](troubleshooting.md) — top-10 problems cookbook
- [adr/](adr/) — Architecture Decision Records
