#!/usr/bin/env bash
# ============================================================================
# generate-manifest.sh — Resolve Docker image digests and regenerate
# templates/release-manifest.json from templates/versions.env
#
# Usage: ./scripts/generate-manifest.sh [--platform linux/amd64]
# Requires: docker (with manifest inspect), jq
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSIONS_FILE="${ROOT_DIR}/templates/versions.env"
MANIFEST_FILE="${ROOT_DIR}/templates/release-manifest.json"
PLATFORM="${PLATFORM:-linux/amd64}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

for arg in "$@"; do
    case "$arg" in
        --platform=*) PLATFORM="${arg#*=}" ;;
        --help|-h)
            echo "Usage: $0 [--platform=linux/amd64]"
            echo "Resolves image digests and regenerates release-manifest.json"
            exit 0
            ;;
    esac
done

if ! command -v jq &>/dev/null; then
    echo -e "${RED}jq is required but not installed${NC}"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo -e "${RED}docker is required but not installed${NC}"
    exit 1
fi

if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo -e "${RED}versions.env not found: ${VERSIONS_FILE}${NC}"
    exit 1
fi

# Source versions
# shellcheck source=../templates/versions.env
source "$VERSIONS_FILE"

# Image-to-version mapping: service_name|registry|image|tag_var_value|platforms
# Platforms is a comma-separated list
declare -a IMAGE_MAP=(
    "dify-api|docker.io|langgenius/dify-api|${DIFY_VERSION}|linux/amd64,linux/arm64"
    "dify-web|docker.io|langgenius/dify-web|${DIFY_VERSION}|linux/amd64,linux/arm64"
    "open-webui|ghcr.io|open-webui/open-webui|${OPENWEBUI_VERSION}|linux/amd64,linux/arm64"
    "ollama|docker.io|ollama/ollama|${OLLAMA_VERSION}|linux/amd64,linux/arm64"
    "postgres|docker.io|postgres|${POSTGRES_VERSION}|linux/amd64,linux/arm64"
    "redis|docker.io|redis|${REDIS_VERSION}|linux/amd64,linux/arm64"
    "weaviate|docker.io|semitechnologies/weaviate|${WEAVIATE_VERSION}|linux/amd64,linux/arm64"
    "qdrant|docker.io|qdrant/qdrant|${QDRANT_VERSION}|linux/amd64,linux/arm64"
    "dify-sandbox|docker.io|langgenius/dify-sandbox|${SANDBOX_VERSION}|linux/amd64"
    "squid|docker.io|ubuntu/squid|${SQUID_VERSION}|linux/amd64,linux/arm64"
    "nginx|docker.io|nginx|${NGINX_VERSION}|linux/amd64,linux/arm64"
    "certbot|docker.io|certbot/certbot|${CERTBOT_VERSION}|linux/amd64,linux/arm64"
    "dify-plugin-daemon|docker.io|langgenius/dify-plugin-daemon|${PLUGIN_DAEMON_VERSION}|linux/amd64,linux/arm64"
    "docling-serve|ghcr.io|docling-project/docling-serve|${DOCLING_SERVE_VERSION}|linux/amd64"
    "xinference|docker.io|xprobe/xinference|${XINFERENCE_VERSION}|linux/amd64"
    "authelia|docker.io|authelia/authelia|${AUTHELIA_VERSION}|linux/amd64,linux/arm64"
    "grafana|docker.io|grafana/grafana|${GRAFANA_VERSION}|linux/amd64,linux/arm64"
    "portainer|docker.io|portainer/portainer-ce|${PORTAINER_VERSION}|linux/amd64,linux/arm64"
    "node-exporter|docker.io|prom/node-exporter|${NODE_EXPORTER_VERSION}|linux/amd64,linux/arm64"
    "cadvisor|gcr.io|cadvisor/cadvisor|${CADVISOR_VERSION}|linux/amd64,linux/arm64"
    "prometheus|docker.io|prom/prometheus|${PROMETHEUS_VERSION}|linux/amd64,linux/arm64"
    "alertmanager|docker.io|prom/alertmanager|${ALERTMANAGER_VERSION}|linux/amd64,linux/arm64"
    "loki|docker.io|grafana/loki|${LOKI_VERSION}|linux/amd64,linux/arm64"
    "promtail|docker.io|grafana/promtail|${PROMTAIL_VERSION}|linux/amd64,linux/arm64"
)

resolve_digest() {
    local registry="$1"
    local image="$2"
    local tag="$3"

    local full_image
    if [[ "$registry" == "docker.io" ]]; then
        full_image="${image}:${tag}"
    else
        full_image="${registry}/${image}:${tag}"
    fi

    # Try docker manifest inspect to get the digest for the target platform
    local digest
    digest=$(docker manifest inspect "$full_image" 2>/dev/null | \
        jq -r --arg platform "$PLATFORM" '
            .manifests[]? |
            select(.platform.os + "/" + .platform.architecture == $platform) |
            .digest
        ' 2>/dev/null | head -1) || true

    # Fallback: try to get the manifest list digest itself
    if [[ -z "$digest" ]]; then
        digest=$(docker manifest inspect "$full_image" 2>/dev/null | \
            jq -r '.digest // empty' 2>/dev/null) || true
    fi

    echo "${digest:-}"
}

echo "Generating release-manifest.json..."
echo "Platform: ${PLATFORM}"
echo ""

# Build JSON
images_json="{}"
errors=0

for entry in "${IMAGE_MAP[@]}"; do
    IFS='|' read -r svc registry image tag platforms <<< "$entry"

    echo -n "  ${svc} (${image}:${tag})... "

    digest=$(resolve_digest "$registry" "$image" "$tag")
    if [[ -n "$digest" ]]; then
        echo -e "${GREEN}${digest:0:20}...${NC}"
    else
        echo -e "${YELLOW}no digest (offline?)${NC}"
        errors=$((errors + 1))
    fi

    # Convert platforms to JSON array
    platforms_json=$(echo "$platforms" | jq -R 'split(",")')

    images_json=$(echo "$images_json" | jq \
        --arg svc "$svc" \
        --arg registry "$registry" \
        --arg image "$image" \
        --arg tag "$tag" \
        --arg digest "${digest:-}" \
        --argjson platforms "$platforms_json" \
        '. + {($svc): {registry: $registry, image: $image, tag: $tag, digest: $digest, platforms: $platforms}}')
done

# Build the full manifest
manifest=$(jq -n \
    --arg version "1.0.0" \
    --arg date "$(date -u +%Y-%m-%d)" \
    --arg min_ver "1.0.0" \
    --argjson images "$images_json" \
    '{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        version: $version,
        release_date: $date,
        min_installer_version: $min_ver,
        images: $images,
        compatibility: {
            dify_api_version_range: ">=1.9.2",
            weaviate_min_version: "1.27.0",
            docker_min_version: "24.0",
            compose_min_version: "2.20"
        },
        changelog_url: "https://github.com/botAGI/difyowebinstaller/blob/main/CHANGELOG.md"
    }')

echo "$manifest" > "$MANIFEST_FILE"

echo ""
total=${#IMAGE_MAP[@]}
resolved=$((total - errors))
echo "Done: ${resolved}/${total} digests resolved"
if [[ $errors -gt 0 ]]; then
    echo -e "${YELLOW}Warning: ${errors} image(s) had no digest (run with Docker Hub access)${NC}"
fi
echo "Wrote: ${MANIFEST_FILE}"
