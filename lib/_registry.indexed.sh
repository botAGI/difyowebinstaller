#!/usr/bin/env bash
# _registry.indexed.sh — DO NOT HAND-EDIT
# Generated from templates/services/registry.yaml (schema_version=1)
# Source SHA-12: 2557f030b18c
# Regenerate via: make registry-codegen
# CI gate: tests/integration/test_registry_codegen_drift.sh fails on stale artifact.
#
# Provides these public symbols (mirrors lib/service-map.sh pre-Phase-12 contract):
#   NAME_TO_VERSION_KEY  NAME_TO_SERVICES  SERVICE_GROUPS  SERVICE_GROUP_ORDER
#   ALL_COMPOSE_PROFILES  NAMED_PROFILE_EXPANSION  NAMED_PROFILE_DESC
#   NAMED_PROFILE_IMPLIED
#
# NAME_TO_VERSION_KEY + NAME_TO_SERVICES contain one row per compose
# service AND one row per declared alias (see services.<svc>.aliases in
# registry.yaml). Aliases preserve the `agmind update <name>` CLI contract.

set -euo pipefail
if [[ -n "${_REGISTRY_INDEXED_LOADED:-}" ]]; then return 0; fi
_REGISTRY_INDEXED_LOADED=1

# shellcheck disable=SC2034
declare -A NAME_TO_VERSION_KEY=(
    [alertmanager]=ALERTMANAGER_VERSION
    [alloy]=ALLOY_VERSION
    [api]=DIFY_VERSION
    [dify-api]=DIFY_VERSION
    [authelia]=AUTHELIA_VERSION
    [cadvisor]=CADVISOR_VERSION
    [certbot]=CERTBOT_VERSION
    [crawl4ai]=CRAWL4AI_VERSION
    [db]=POSTGRES_VERSION
    [postgres]=POSTGRES_VERSION
    [dbgpt]=DBGPT_VERSION
    [docker-socket-proxy]=DOCKER_SOCKET_PROXY_VERSION
    [docling]=DOCLING_SERVE_VERSION
    [grafana]=GRAFANA_VERSION
    [k6]=K6_VERSION
    [litellm]=LITELLM_VERSION
    [loki]=LOKI_VERSION
    [milvus]=MILVUS_VERSION
    [milvus-etcd]=MILVUS_ETCD_VERSION
    [milvus-init]=MC_VERSION
    [minio]=MINIO_VERSION
    [n8n]=N8N_VERSION
    [nginx]=NGINX_VERSION
    [nginx-exporter]=NGINX_EXPORTER_VERSION
    [node-exporter]=NODE_EXPORTER_VERSION
    [ollama]=OLLAMA_VERSION
    [open-notebook]=OPEN_NOTEBOOK_VERSION
    [open-webui]=OPENWEBUI_VERSION
    [openwebui]=OPENWEBUI_VERSION
    [plugin_daemon]=PLUGIN_DAEMON_VERSION
    [plugin-daemon]=PLUGIN_DAEMON_VERSION
    [portainer]=PORTAINER_VERSION
    [postgres-exporter]=POSTGRES_EXPORTER_VERSION
    [prometheus]=PROMETHEUS_VERSION
    [qdrant]=QDRANT_VERSION
    [ragflow]=RAGFLOW_VERSION
    [ragflow_es01]=RAGFLOW_ES_VERSION
    [ragflow_es_exporter]=ELASTICSEARCH_EXPORTER_VERSION
    [ragflow_mysql]=RAGFLOW_MYSQL_VERSION
    [redis]=REDIS_VERSION
    [redis-exporter]=REDIS_EXPORTER_VERSION
    [redis-lock-cleaner]=REDIS_VERSION
    [sandbox]=SANDBOX_VERSION
    [searxng]=SEARXNG_VERSION
    [ssrf_proxy]=SQUID_VERSION
    [squid]=SQUID_VERSION
    [surrealdb]=SURREALDB_VERSION
    [tei]=TEI_EMBED_VERSION
    [tei-embed]=TEI_EMBED_VERSION
    [tei-rerank]=TEI_RERANK_VERSION
    [vllm]=VLLM_VERSION
    [vllm-embed]=VLLM_NGC_VERSION
    [vllm-rerank]=VLLM_NGC_VERSION
    [weaviate]=WEAVIATE_VERSION
    [web]=DIFY_VERSION
    [dify-web]=DIFY_VERSION
    [worker]=DIFY_VERSION
    [dify-worker]=DIFY_VERSION
)

# shellcheck disable=SC2034
declare -A NAME_TO_SERVICES=(
    [alertmanager]="alertmanager"
    [alloy]="alloy"
    [api]="api worker web sandbox plugin_daemon"
    [dify-api]="api worker web sandbox plugin_daemon"
    [authelia]="authelia"
    [cadvisor]="cadvisor"
    [certbot]="certbot"
    [crawl4ai]="crawl4ai"
    [db]="db"
    [postgres]="db"
    [dbgpt]="dbgpt"
    [docker-socket-proxy]="docker-socket-proxy"
    [docling]="docling"
    [grafana]="grafana"
    [k6]="k6"
    [litellm]="litellm"
    [loki]="loki"
    [milvus]="milvus milvus-etcd"
    [milvus-etcd]="milvus-etcd"
    [milvus-init]="milvus-init"
    [minio]="minio"
    [n8n]="n8n"
    [nginx]="nginx"
    [nginx-exporter]="nginx-exporter"
    [node-exporter]="node-exporter"
    [ollama]="ollama"
    [open-notebook]="open-notebook"
    [open-webui]="open-webui"
    [openwebui]="open-webui"
    [plugin_daemon]="api worker web sandbox plugin_daemon"
    [plugin-daemon]="api worker web sandbox plugin_daemon"
    [portainer]="portainer"
    [postgres-exporter]="postgres-exporter"
    [prometheus]="prometheus"
    [qdrant]="qdrant"
    [ragflow]="ragflow"
    [ragflow_es01]="ragflow_es01"
    [ragflow_es_exporter]="ragflow_es_exporter"
    [ragflow_mysql]="ragflow_mysql"
    [redis]="redis"
    [redis-exporter]="redis-exporter"
    [redis-lock-cleaner]="redis-lock-cleaner"
    [sandbox]="api worker web sandbox plugin_daemon"
    [searxng]="searxng"
    [ssrf_proxy]="ssrf_proxy"
    [squid]="ssrf_proxy"
    [surrealdb]="surrealdb"
    [tei]="tei"
    [tei-embed]="tei"
    [tei-rerank]="tei-rerank"
    [vllm]="vllm"
    [vllm-embed]="vllm-embed"
    [vllm-rerank]="vllm-rerank"
    [weaviate]="weaviate"
    [web]="api worker web sandbox plugin_daemon"
    [dify-web]="api worker web sandbox plugin_daemon"
    [worker]="api worker web sandbox plugin_daemon"
    [dify-worker]="api worker web sandbox plugin_daemon"
)

# shellcheck disable=SC2034
declare -A SERVICE_GROUPS=(
    [core]="db nginx redis redis-lock-cleaner ssrf_proxy"
    [dify]="api plugin_daemon sandbox web worker"
    [llm]="docling litellm ollama tei tei-rerank vllm vllm-embed vllm-rerank"
    [observability]="alertmanager alloy cadvisor docker-socket-proxy grafana loki nginx-exporter node-exporter portainer postgres-exporter prometheus redis-exporter"
    [optional]="authelia certbot crawl4ai dbgpt k6 minio n8n open-notebook open-webui searxng surrealdb"
    [rag]="milvus milvus-etcd milvus-init qdrant weaviate"
    [ragflow]="ragflow ragflow_es01 ragflow_es_exporter ragflow_mysql"
)

# shellcheck disable=SC2034
SERVICE_GROUP_ORDER="core dify llm rag ragflow observability optional"

# shellcheck disable=SC2034
ALL_COMPOSE_PROFILES="monitoring,portainer,qdrant,weaviate,milvus,authelia,ollama,vllm,tei,reranker,vllm-embed,vllm-rerank,docling,litellm,searxng,notebook,dbgpt,crawl4ai,openwebui,minio,n8n,ragflow,loadtest,vps"

# shellcheck disable=SC2034
declare -A NAMED_PROFILE_EXPANSION=(
    [agents]="litellm,crawl4ai,searxng,dbgpt,openwebui,notebook,n8n"
    [core]="vllm,litellm"
    [dev]="vllm,litellm,weaviate,docling,monitoring,portainer"
    [full]="vllm,litellm,weaviate,docling,vllm-embed,vllm-rerank,minio,monitoring,portainer,authelia,crawl4ai,searxng,dbgpt,openwebui,notebook,n8n"
    [observability]="monitoring,portainer"
    [rag]="vllm,litellm,weaviate,docling,vllm-embed"
    [ragflow]="minio"
    [security]="authelia"
)

# shellcheck disable=SC2034
declare -A NAMED_PROFILE_DESC=(
    [agents]="LiteLLM + Crawl4AI + SearXNG + dbGPT + Open WebUI + Notebook + n8n"
    [core]="Dify core + vLLM + LiteLLM (minimal — no RAG)"
    [dev]="Core + observability (fast iteration; no RAGFlow/agents/security)"
    [full]="Everything: vLLM + Weaviate + Docling + monitoring + agents + n8n (Milvus skipped — XOR with Weaviate)"
    [observability]="Prometheus + Grafana + Loki + exporters + Portainer"
    [rag]="Core + Weaviate + Docling + vLLM-embed (recommended full RAG stack)"
    [ragflow]="RAGFlow + Elasticsearch + MySQL + MinIO"
    [security]="Authelia + fail2ban/hardening"
)

# shellcheck disable=SC2034
declare -A NAMED_PROFILE_IMPLIED=(
    [agents]="ENABLE_LITELLM=true ENABLE_CRAWL4AI=true ENABLE_SEARXNG=true ENABLE_DBGPT=true ENABLE_OPENWEBUI=true ENABLE_NOTEBOOK=true ENABLE_N8N=true"
    [core]="LLM_PROVIDER=vllm ENABLE_LITELLM=true"
    [dev]="LLM_PROVIDER=vllm ENABLE_LITELLM=true VECTOR_STORE=weaviate ENABLE_DOCLING=true MONITORING_MODE=local ENABLE_PORTAINER=true"
    [full]="LLM_PROVIDER=vllm ENABLE_LITELLM=true VECTOR_STORE=weaviate ENABLE_DOCLING=true EMBED_PROVIDER=vllm-embed ENABLE_RERANKER=true RERANKER_PROVIDER=vllm-rerank ENABLE_MINIO=true MONITORING_MODE=local ENABLE_PORTAINER=true ENABLE_AUTHELIA=true ENABLE_CRAWL4AI=true ENABLE_SEARXNG=true ENABLE_DBGPT=true ENABLE_OPENWEBUI=true ENABLE_NOTEBOOK=true ENABLE_N8N=true"
    [observability]="MONITORING_MODE=local ENABLE_PORTAINER=true"
    [rag]="LLM_PROVIDER=vllm ENABLE_LITELLM=true VECTOR_STORE=weaviate ENABLE_DOCLING=true EMBED_PROVIDER=vllm-embed"
    [ragflow]="ENABLE_RAGFLOW=true ENABLE_MINIO=true"
    [security]="ENABLE_AUTHELIA=true"
)
