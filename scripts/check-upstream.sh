#!/usr/bin/env bash
# ============================================================================
# Upstream Version Checker
# Compares pinned versions in templates/versions.env against latest releases.
# Creates /tmp/upstream-report.md if updates are found.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSIONS_FILE="${REPO_DIR}/templates/versions.env"
REPORT_FILE="/tmp/upstream-report.md"
TODAY=$(date +%Y-%m-%d)
DAY=$(date +%d)
MONTH=$(date +%m)

# --- Component definitions: "Name|VERSION_VAR|repo|source" ---
# source: gh = GitHub Releases (default), hub = Docker Hub tags

# All components checked daily — API calls are lightweight (~30 requests)
ALL_CHECKS=(
    # --- Core Platform ---
    "Dify|DIFY_VERSION|langgenius/dify|gh"
    "Open WebUI|OPENWEBUI_VERSION|open-webui/open-webui|gh"
    "Plugin Daemon|PLUGIN_DAEMON_VERSION|langgenius/dify-plugin-daemon|gh"
    "Sandbox|SANDBOX_VERSION|langgenius/dify-sandbox|gh"
    # --- LLM / Embedding / Reranking ---
    "Ollama|OLLAMA_VERSION|ollama/ollama|gh"
    "vLLM|VLLM_VERSION|vllm-project/vllm|gh"
    "TEI|TEI_VERSION|huggingface/text-embeddings-inference|gh"
    "TEI-Embed|TEI_EMBED_VERSION|huggingface/text-embeddings-inference|gh"
    "TEI-Rerank|TEI_RERANK_VERSION|huggingface/text-embeddings-inference|gh"
    # --- Vector Stores ---
    "Weaviate|WEAVIATE_VERSION|weaviate/weaviate|gh"
    "Qdrant|QDRANT_VERSION|qdrant/qdrant|gh"
    # --- ETL / AI Gateway ---
    "Docling|DOCLING_SERVE_VERSION|docling-project/docling-serve|gh"
    "LiteLLM|LITELLM_VERSION|BerriAI/litellm|gh"
    # --- Optional Services ---
    "SearXNG|SEARXNG_VERSION|searxng/searxng|hub"
    "Open Notebook|OPEN_NOTEBOOK_VERSION|lfnovo/open-notebook|gh"
    "DB-GPT|DBGPT_VERSION|eosphoros-ai/DB-GPT|gh"
    "Crawl4AI|CRAWL4AI_VERSION|unclecode/crawl4ai|gh"
    "SurrealDB|SURREALDB_VERSION|surrealdb/surrealdb|gh"
    # --- Security ---
    "Authelia|AUTHELIA_VERSION|authelia/authelia|gh"
    "Certbot|CERTBOT_VERSION|certbot/certbot|gh"
    # --- Infrastructure ---
    "Nginx|NGINX_VERSION|nginx|hub"
    "Squid|SQUID_VERSION|ubuntu/squid|hub"
    "PostgreSQL|POSTGRES_VERSION|postgres|hub"
    "Redis|REDIS_VERSION|redis|hub"
    "Portainer|PORTAINER_VERSION|portainer/portainer-ce|hub"
    # --- Monitoring ---
    "Prometheus|PROMETHEUS_VERSION|prometheus/prometheus|gh"
    "Alertmanager|ALERTMANAGER_VERSION|prometheus/alertmanager|gh"
    "Grafana|GRAFANA_VERSION|grafana/grafana|gh"
    "Loki|LOKI_VERSION|grafana/loki|gh"
    "Promtail|PROMTAIL_VERSION|grafana/promtail|gh"
    "Node Exporter|NODE_EXPORTER_VERSION|prometheus/node_exporter|gh"
    "cAdvisor|CADVISOR_VERSION|google/cadvisor|gh"
)

# --- State ---
declare -A CURRENT_VERSIONS
ALL_RESULTS=()  # "name|current|latest|status"  (status: update/ok/branch/error)

# Components whose Docker images do NOT use v-prefix in tags.
# GitHub releases use v-prefix (v1.36.6) but Docker Hub has bare (1.36.6).
declare -A NO_V_PREFIX=(
    [Weaviate]=1
    [Grafana]=1
    [Prometheus]=1
    [Alertmanager]=1
    [Loki]=1
    [Promtail]=1
    [Node\ Exporter]=1
    [cAdvisor]=1
)

# Components whose Docker image tags carry a -local suffix not present
# in the upstream GitHub release tags (e.g. GitHub 0.5.4 → Docker 0.5.4-local).
declare -A LOCAL_SUFFIX=(
    [Plugin\ Daemon]=1
)

# ============================================================================
# Version helpers
# ============================================================================

# Strip prefixes (v, cuda-) and suffixes (-alpine, -local, -edge, etc.)
# Returns bare numeric version: 1.13.0, 16, 7.4.1
normalize_version() {
    local v="$1"
    v="${v#v}"
    v="${v#cuda-}"
    # Extract leading digits[.digits]* pattern
    echo "$v" | sed 's/^\([0-9][0-9.]*\).*/\1/'
}

# Compare two versions → major|minor|patch|same
classify_change() {
    local current="$1" latest="$2"
    local c l
    c=$(normalize_version "$current")
    l=$(normalize_version "$latest")

    [[ "$c" == "$l" ]] && echo "same" && return

    IFS='.' read -ra cp <<< "$c"
    IFS='.' read -ra lp <<< "$l"

    if [[ "${cp[0]:-0}" != "${lp[0]:-0}" ]]; then
        echo "major"
    elif [[ "${cp[1]:-0}" != "${lp[1]:-0}" ]]; then
        echo "minor"
    else
        echo "patch"
    fi
}

# True if latest > current (numeric comparison of normalized versions)
is_newer() {
    local current="$1" latest="$2"
    local c l
    c=$(normalize_version "$current")
    l=$(normalize_version "$latest")

    [[ "$c" == "$l" ]] && return 1

    # Compare using sort -V (version sort)
    local highest
    highest=$(printf '%s\n%s\n' "$c" "$l" | sort -V | tail -1)
    [[ "$highest" == "$l" ]]
}

# ============================================================================
# API checkers
# ============================================================================

github_curl() {
    local -a args=(curl -sf --max-time 15)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        args+=(-H "Authorization: token ${GITHUB_TOKEN}")
    fi
    "${args[@]}" "$@"
}

# Get latest release tag from GitHub Releases API
check_github_latest() {
    local repo="$1"
    local tag
    tag=$(github_curl "https://api.github.com/repos/${repo}/releases?per_page=5" \
        | python3 -c "
import sys, json
releases = json.load(sys.stdin)
for r in releases:
    if not r.get('prerelease') and not r.get('draft'):
        print(r.get('tag_name', ''))
        break
" 2>/dev/null) || return 1
    echo "$tag"
}

# Get latest matching tag from Docker Hub
check_dockerhub_latest() {
    local repo="$1" current="$2"

    # Determine suffix from current version (-alpine, etc.)
    local suffix=""
    if [[ "$current" == *-alpine* ]]; then suffix="-alpine"; fi

    # Build Docker Hub URL
    local url
    if [[ "$repo" == */* ]]; then
        url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=50&ordering=last_updated"
    else
        url="https://hub.docker.com/v2/repositories/library/${repo}/tags?page_size=50&ordering=last_updated"
    fi

    curl -sf --max-time 15 "$url" \
        | python3 -c "
import sys, json, re

data = json.load(sys.stdin)
suffix = '${suffix}'
skip = {'rc', 'beta', 'alpha', 'dev', 'test', 'latest', 'slim', 'bullseye', 'bookworm', 'jammy', 'noble'}

tags = []
for r in data.get('results', []):
    t = r['name']
    if any(s in t.lower() for s in skip):
        continue
    if suffix and not t.endswith(suffix):
        continue
    base = t[:-len(suffix)] if suffix else t
    if not base or not base[0].isdigit():
        continue
    tags.append(t)

def ver_key(tag):
    base = tag[:-len(suffix)] if suffix else tag
    parts = re.split(r'[\.\-]', base)
    return [int(p) if p.isdigit() else 0 for p in parts]

tags.sort(key=ver_key, reverse=True)
print(tags[0] if tags else '')
" 2>/dev/null || return 1
}

# ============================================================================
# Core logic
# ============================================================================

load_current_versions() {
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | tr -d '[:space:]')
        CURRENT_VERSIONS["$key"]="$value"
    done < "$VERSIONS_FILE"
    # Synthesize DOCLING_SERVE_VERSION from DOCLING_IMAGE_CPU tag
    # (versions.env uses full image refs, not separate version vars)
    local docling_img="${CURRENT_VERSIONS[DOCLING_IMAGE_CPU]:-}"
    if [[ -n "$docling_img" && "$docling_img" == *":"* ]]; then
        CURRENT_VERSIONS[DOCLING_SERVE_VERSION]="${docling_img##*:}"
    fi
}

check_component() {
    local name="$1" var="$2" repo="$3" source="${4:-gh}"
    local current="${CURRENT_VERSIONS[$var]:-}"

    if [[ -z "$current" ]]; then
        echo "  SKIP: ${name} — ${var} not found in versions.env" >&2
        return
    fi

    # Detect branch-based versions (e.g. "main", "main-local")
    local is_branch=false
    if [[ "$current" =~ ^[a-z]+(-[a-z]+)*$ ]]; then
        is_branch=true
    fi

    local latest=""
    if [[ "$source" == "hub" ]]; then
        latest=$(check_dockerhub_latest "$repo" "$current") || true
    else
        latest=$(check_github_latest "$repo") || true
    fi

    if [[ -z "$latest" ]]; then
        echo "  WARN: ${name} — could not fetch latest from ${source}:${repo}" >&2
        ALL_RESULTS+=("${name}|${current}|???|error")
        return
    fi

    # Strip v-prefix for components whose Docker images don't use it
    local report_latest="$latest"
    if [[ -n "${NO_V_PREFIX[$name]+x}" ]]; then
        report_latest="${latest#v}"
    fi
    # Append -local suffix for components that use it in Docker tags
    if [[ -n "${LOCAL_SUFFIX[$name]+x}" ]]; then
        report_latest="${report_latest%-local}-local"
    fi

    if [[ "$is_branch" == "true" ]]; then
        echo "  BRANCH: ${name} ${current} -> latest: ${report_latest}" >&2
        ALL_RESULTS+=("${name}|${current}|${report_latest}|branch")
    elif is_newer "$current" "$latest"; then
        local change
        change=$(classify_change "$current" "$latest")
        ALL_RESULTS+=("${name}|${current}|${report_latest}|${change}")
        echo "  UPDATE: ${name} ${current} -> ${report_latest} (${change})" >&2
    else
        ALL_RESULTS+=("${name}|${current}|${report_latest}|ok")
        echo "  OK: ${name} ${current} (up to date)" >&2
    fi
}

run_checks() {
    local tier="$1"
    shift
    local components=("$@")

    echo "--- ${tier} checks ---" >&2
    for entry in "${components[@]}"; do
        IFS='|' read -r name var repo source <<< "$entry"
        check_component "$name" "$var" "$repo" "${source:-gh}"
    done
}

generate_report() {
    {
        echo "## Upstream Version Check — ${TODAY}"
        echo ""
        echo "| Component | Current | Latest | Status |"
        echo "|-----------|---------|--------|--------|"
        for entry in "${ALL_RESULTS[@]}"; do
            IFS='|' read -r name current latest status <<< "$entry"
            local badge
            case "$status" in
                ok)     badge="✅ up to date" ;;
                patch)  badge="📦 patch" ;;
                minor)  badge="🔄 minor" ;;
                major)  badge="⚠️ major" ;;
                branch) badge="🔀 branch → ${latest}" ;;
                error)  badge="❌ fetch error" ;;
                *)      badge="$status" ;;
            esac
            echo "| ${name} | ${current} | ${latest} | ${badge} |"
        done
        echo ""
        echo "### Legend"
        echo "- **✅ up to date**: No action needed."
        echo "- **📦 patch**: Safe to update. Test and release."
        echo "- **🔄 minor**: Review changelog. Test before release."
        echo "- **⚠️ major**: Breaking changes possible. Careful testing required."
        echo "- **🔀 branch**: Tracking a branch — latest stable release shown for reference."
        echo "- **❌ fetch error**: Could not reach upstream API."
        echo ""
        echo "### How to update"
        echo "1. On test server: \`agmind update --component <name> --version <latest> --force\`"
        echo "2. Run \`agmind doctor\` — verify 0 errors"
        echo "3. If OK — update \`templates/versions.env\` — commit — create Release"
        echo "4. If FAIL — \`agmind update --rollback\`"
    } > "$REPORT_FILE"
}

set_output() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "${key}=${value}" >> "$GITHUB_OUTPUT"
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    load_current_versions

    echo "=== Upstream Version Check (${TODAY}) ===" >&2
    echo "  Components: ${#ALL_CHECKS[@]}" >&2
    echo "" >&2

    run_checks "ALL" "${ALL_CHECKS[@]}"

    echo "" >&2

    # Count actual updates (not ok/branch/error)
    local update_count=0
    for entry in "${ALL_RESULTS[@]}"; do
        IFS='|' read -r _ _ _ status <<< "$entry"
        if [[ "$status" == "patch" || "$status" == "minor" || "$status" == "major" ]]; then
            ((update_count++)) || true
        fi
    done

    echo "${#ALL_RESULTS[@]} component(s) checked, ${update_count} update(s) available." >&2
    generate_report
    if [[ $update_count -gt 0 ]]; then
        set_output "has_updates" "true"
    else
        set_output "has_updates" "false"
    fi
    set_output "date" "$TODAY"
    echo "Report: ${REPORT_FILE}" >&2
}

main "$@"
