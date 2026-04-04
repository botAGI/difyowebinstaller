#!/usr/bin/env bash
# service-map.sh — Canonical service mapping definitions.
# Single source of truth for: name->version key, name->compose services,
# service groups, and compose profile list.
# Sourced by: lib/health.sh, scripts/update.sh, lib/compose.sh
# Dependencies: none (pure data, no side effects)
set -euo pipefail

# Guard against double-sourcing
[[ -n "${_SERVICE_MAP_LOADED:-}" ]] && return 0
_SERVICE_MAP_LOADED=1

# Short component name -> versions.env variable key
declare -A NAME_TO_VERSION_KEY=(
    [dify-api]=DIFY_VERSION
    [dify-worker]=DIFY_VERSION
    [dify-web]=DIFY_VERSION
    [openwebui]=OPENWEBUI_VERSION
    [pipelines]=PIPELINES_VERSION
    [ollama]=OLLAMA_VERSION
    [vllm]=VLLM_VERSION
    [tei]=TEI_VERSION
    [tei-embed]=TEI_EMBED_VERSION
    [tei-rerank]=TEI_RERANK_VERSION
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
    [prometheus]=PROMETHEUS_VERSION
    [alertmanager]=ALERTMANAGER_VERSION
    [loki]=LOKI_VERSION
    [promtail]=PROMTAIL_VERSION
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
)

# Short component name -> compose service name(s) to restart on update
declare -A NAME_TO_SERVICES=(
    [dify-api]="api worker web sandbox plugin_daemon"
    [dify-worker]="api worker web sandbox plugin_daemon"
    [dify-web]="api worker web sandbox plugin_daemon"
    [openwebui]="open-webui"
    [pipelines]="pipelines"
    [ollama]="ollama"
    [vllm]="vllm"
    [tei]="tei"
    [tei-embed]="tei"
    [tei-rerank]="tei-rerank"
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
    [prometheus]="prometheus"
    [alertmanager]="alertmanager"
    [loki]="loki"
    [promtail]="promtail"
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
)

# Components sharing the same Docker image (restart all when one updates)
declare -A SERVICE_GROUPS=(
    [dify]="dify-api dify-worker dify-web sandbox plugin-daemon"
)

# All known compose profiles (for compose down --remove-orphans)
ALL_COMPOSE_PROFILES="vps,monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei,reranker,docling,litellm,searxng,notebook,dbgpt,crawl4ai"
