#!/usr/bin/env bash
# service-map.sh — Canonical service mapping definitions.
# Single source of truth for: name->version key, name->compose services,
# service groups, and compose profile list.
# Sourced by: lib/health.sh, scripts/update.sh, lib/compose.sh
# Dependencies: none (pure data, no side effects)
set -euo pipefail

# Guard against double-sourcing
if [[ -n "${_SERVICE_MAP_LOADED:-}" ]]; then return 0; fi
_SERVICE_MAP_LOADED=1

# Short component name -> versions.env variable key
# shellcheck disable=SC2034  # sourced globals used by health.sh, update.sh, compose.sh
declare -A NAME_TO_VERSION_KEY=(
    [dify-api]=DIFY_VERSION
    [dify-worker]=DIFY_VERSION
    [dify-web]=DIFY_VERSION
    [openwebui]=OPENWEBUI_VERSION
    [ollama]=OLLAMA_VERSION
    [vllm]=VLLM_VERSION
    [tei]=TEI_VERSION
    [tei-embed]=TEI_EMBED_VERSION
    [tei-rerank]=TEI_RERANK_VERSION
    [vllm-embed]=VLLM_VERSION
    [vllm-rerank]=VLLM_VERSION
    [postgres]=POSTGRES_VERSION
    [redis]=REDIS_VERSION
    [weaviate]=WEAVIATE_VERSION
    [qdrant]=QDRANT_VERSION
    [docling]=DOCLING_SERVE_VERSION
    [sandbox]=SANDBOX_VERSION
    [nginx]=NGINX_VERSION
    [plugin-daemon]=PLUGIN_DAEMON_VERSION
    [grafana]=GRAFANA_VERSION
    [portainer]=PORTAINER_VERSION
    [docker-socket-proxy]=DOCKER_SOCKET_PROXY_VERSION
    [prometheus]=PROMETHEUS_VERSION
    [alertmanager]=ALERTMANAGER_VERSION
    [loki]=LOKI_VERSION
    [alloy]=ALLOY_VERSION
    [node-exporter]=NODE_EXPORTER_VERSION
    [cadvisor]=CADVISOR_VERSION
    [authelia]=AUTHELIA_VERSION
    [certbot]=CERTBOT_VERSION
    [squid]=SQUID_VERSION
    [litellm]=LITELLM_VERSION
    [searxng]=SEARXNG_VERSION
    [surrealdb]=SURREALDB_VERSION
    [open-notebook]=OPEN_NOTEBOOK_VERSION
    [dbgpt]=DBGPT_VERSION
    [crawl4ai]=CRAWL4AI_VERSION
    [minio]=MINIO_VERSION
    [n8n]=N8N_VERSION
    [milvus]=MILVUS_VERSION
    [milvus-etcd]=MILVUS_ETCD_VERSION
)

# Short component name -> compose service name(s) to restart on update
# shellcheck disable=SC2034  # sourced global
declare -A NAME_TO_SERVICES=(
    [dify-api]="api worker web sandbox plugin_daemon"
    [dify-worker]="api worker web sandbox plugin_daemon"
    [dify-web]="api worker web sandbox plugin_daemon"
    [openwebui]="open-webui"
    [ollama]="ollama"
    [vllm]="vllm"
    [tei]="tei"
    [tei-embed]="tei"
    [tei-rerank]="tei-rerank"
    [vllm-embed]="vllm-embed"
    [vllm-rerank]="vllm-rerank"
    [postgres]="db"
    [redis]="redis"
    [weaviate]="weaviate"
    [qdrant]="qdrant"
    [docling]="docling"
    [sandbox]="api worker web sandbox plugin_daemon"
    [nginx]="nginx"
    [plugin-daemon]="api worker web sandbox plugin_daemon"
    [grafana]="grafana"
    [portainer]="portainer"
    [docker-socket-proxy]="docker-socket-proxy"
    [prometheus]="prometheus"
    [alertmanager]="alertmanager"
    [loki]="loki"
    [alloy]="alloy"
    [node-exporter]="node-exporter"
    [cadvisor]="cadvisor"
    [authelia]="authelia"
    [certbot]="certbot"
    [squid]="ssrf_proxy"
    [litellm]="litellm"
    [searxng]="searxng"
    [surrealdb]="surrealdb"
    [open-notebook]="open-notebook"
    [dbgpt]="dbgpt"
    [crawl4ai]="crawl4ai"
    [minio]="minio"
    [n8n]="n8n"
    [milvus]="milvus milvus-etcd"
    [milvus-etcd]="milvus-etcd"
)

# WHY: Expanded from single [dify]= entry in Phase 2 (agmind status). Additive —
# Phase 9 refines into 8 named profiles; keep additive, don't remove keys.
#
# Service grouping for `agmind status` table headers + disabled-detection.
# Keys = group label; values = space-separated SHORT service names (the names
# `agmind status` rows by; container = "agmind-${name//_/-}").
# shellcheck disable=SC2034  # sourced globals used by lib/status.sh, scripts/update.sh
declare -A SERVICE_GROUPS=(
    [core]="db redis nginx ssrf_proxy"
    [dify]="api worker web sandbox plugin-daemon"
    [llm]="vllm vllm-embed vllm-rerank tei tei-rerank ollama litellm docling"
    [rag]="weaviate qdrant milvus milvus-etcd"
    [observability]="prometheus alertmanager loki alloy node-exporter cadvisor redis-exporter postgres-exporter nginx-exporter grafana portainer"
    [ragflow]="ragflow ragflow_mysql ragflow_es01"
    [optional]="searxng minio authelia open-webui surrealdb open-notebook dbgpt crawl4ai n8n"
)

# Group display order for `agmind status` table (assoc arrays have no guaranteed order).
# shellcheck disable=SC2034  # sourced global used by lib/status.sh
SERVICE_GROUP_ORDER="core dify llm rag ragflow observability optional"

# All known compose profiles (for compose down --remove-orphans)
# shellcheck disable=SC2034  # sourced global used by compose.sh _compose_down_all
ALL_COMPOSE_PROFILES="monitoring,portainer,qdrant,weaviate,milvus,authelia,ollama,vllm,tei,reranker,vllm-embed,vllm-rerank,docling,litellm,searxng,notebook,dbgpt,crawl4ai,openwebui,minio,n8n,ragflow,loadtest,vps"

# ============================================================================
# NAMED META-PROFILES (Phase 9) — 8 user-facing profiles over the ~20 raw profiles
# ============================================================================
#
# Each named profile = a comma-separated list of RAW compose profiles. Wizard /
# build_compose_profiles also sets implied ENABLE_*/<X>_PROVIDER defaults per
# named profile (those defaults live in lib/compose.sh::_np_apply_defaults so
# they can use `: "${VAR:=val}"` — user env-override always wins).
#
# XOR pairs (mutually exclusive — port/GPU conflicts; a named profile picks ONE):
#   vector DB:  weaviate XOR qdrant XOR milvus  (milvus EXPERIMENTAL — not in any named profile incl. 'full')
#   embed:      vllm-embed XOR tei              (TEI has no arm64 manifest on DGX Spark — use vllm-embed)
#   reranker:   vllm-rerank XOR reranker
#   LLM:        vllm XOR ollama                 (ollama hidden — not in any named profile; override: LLM_PROVIDER=ollama)
#
# 'ragflow' is intentionally NOT a raw profile here — it's pulled in via the
# ENABLE_RAGFLOW=true implied default (build_compose_profiles already adds the
# ragflow+minio raw profiles when ENABLE_RAGFLOW=true). The [ragflow] entry below
# lists only 'minio' (RAGFlow's S3 bucket); 'ragflow' raw profile is added by the
# ENABLE_RAGFLOW path.
# shellcheck disable=SC2034  # sourced global used by lib/compose.sh + scripts/agmind.sh (cmd_profiles/cmd_estimate)
declare -A NAMED_PROFILE_EXPANSION=(
    [core]="vllm,litellm"
    [rag]="vllm,litellm,weaviate,docling,vllm-embed"
    [ragflow]="minio"
    [observability]="monitoring,portainer"
    [security]="authelia"
    [agents]="litellm,crawl4ai,searxng,dbgpt,openwebui,notebook,n8n"
    [full]="vllm,litellm,weaviate,docling,vllm-embed,vllm-rerank,minio,monitoring,portainer,authelia,crawl4ai,searxng,dbgpt,openwebui,notebook,n8n"
    [dev]="vllm,litellm,weaviate,docling,monitoring,portainer"
)

# Human-readable one-line description per named profile (for `agmind profiles`).
# shellcheck disable=SC2034  # sourced global used by scripts/agmind.sh::cmd_profiles
declare -A NAMED_PROFILE_DESC=(
    [core]="Dify core + vLLM + LiteLLM (minimal — no RAG)"
    [rag]="Core + Weaviate + Docling + vLLM-embed (recommended full RAG stack)"
    [ragflow]="RAGFlow + Elasticsearch + MySQL + MinIO"
    [observability]="Prometheus + Grafana + Loki + exporters + Portainer"
    [security]="Authelia + fail2ban/hardening"
    [agents]="LiteLLM + Crawl4AI + SearXNG + dbGPT + Open WebUI + Notebook + n8n"
    [full]="Everything: vLLM + Weaviate + Docling + monitoring + agents + n8n (Milvus skipped — XOR with Weaviate)"
    [dev]="Core + observability (fast iteration; no RAGFlow/agents/security)"
)

# Implied ENABLE_*/<X>_PROVIDER defaults per named profile, as a space-separated
# VAR=val list. build_compose_profiles applies these with :=
# (env-override wins). Keep in sync with NAMED_PROFILE_EXPANSION above.
# shellcheck disable=SC2034  # sourced global used by lib/compose.sh::_np_apply_defaults + lib/wizard.sh
declare -A NAMED_PROFILE_IMPLIED=(
    [core]="LLM_PROVIDER=vllm ENABLE_LITELLM=true"
    [rag]="LLM_PROVIDER=vllm ENABLE_LITELLM=true VECTOR_STORE=weaviate ENABLE_DOCLING=true EMBED_PROVIDER=vllm-embed"
    [ragflow]="ENABLE_RAGFLOW=true ENABLE_MINIO=true"
    [observability]="MONITORING_MODE=local ENABLE_PORTAINER=true"
    [security]="ENABLE_AUTHELIA=true"
    [agents]="ENABLE_LITELLM=true ENABLE_CRAWL4AI=true ENABLE_SEARXNG=true ENABLE_DBGPT=true ENABLE_OPENWEBUI=true ENABLE_NOTEBOOK=true ENABLE_N8N=true"
    [full]="LLM_PROVIDER=vllm ENABLE_LITELLM=true VECTOR_STORE=weaviate ENABLE_DOCLING=true EMBED_PROVIDER=vllm-embed ENABLE_RERANKER=true RERANKER_PROVIDER=vllm-rerank ENABLE_MINIO=true MONITORING_MODE=local ENABLE_PORTAINER=true ENABLE_AUTHELIA=true ENABLE_CRAWL4AI=true ENABLE_SEARXNG=true ENABLE_DBGPT=true ENABLE_OPENWEBUI=true ENABLE_NOTEBOOK=true ENABLE_N8N=true"
    [dev]="LLM_PROVIDER=vllm ENABLE_LITELLM=true VECTOR_STORE=weaviate ENABLE_DOCLING=true MONITORING_MODE=local ENABLE_PORTAINER=true"
)
