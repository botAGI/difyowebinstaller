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

# --- Component definitions: "Name|VERSION_VAR|repo|source" ---
# source: gh = GitHub Releases (default), hub = Docker Hub tags
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
    # RAGFlow self-built (ar2r223/ragflow-spark@digest) from infiniflow upstream + Hendrik
    # patches (CLAUDE.md §8 RAGFlow specifics). Track infiniflow для rebuild signal.
    # ES + MySQL = pre-built Docker Hub images.
    "RAGFlow|RAGFLOW_VERSION|infiniflow/ragflow|gh"
    "RAGFlow ES|RAGFLOW_ES_VERSION|elasticsearch|hub"
    "RAGFlow MySQL|RAGFLOW_MYSQL_VERSION|mysql|hub"
    # --- Storage ---
    "MinIO|MINIO_VERSION|minio/minio|hub"
    "MinIO Client|MC_VERSION|minio/mc|hub"
    # --- Security ---
    "Authelia|AUTHELIA_VERSION|authelia/authelia|gh"
    "Certbot|CERTBOT_VERSION|certbot/certbot|gh"
    # SOPS — security-sensitive (SHA256_ARM64/AMD64 в versions.env обязан совпадать).
    # При bump'е надо вручную обновить SOPS_SHA256_* из checksums.txt релиза.
    "SOPS|SOPS_VERSION|getsops/sops|gh"
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
    "Alloy|ALLOY_VERSION|grafana/alloy|gh"
    "Node Exporter|NODE_EXPORTER_VERSION|prometheus/node_exporter|gh"
    "cAdvisor|CADVISOR_VERSION|google/cadvisor|gh"
    "Redis Exporter|REDIS_EXPORTER_VERSION|oliver006/redis_exporter|gh"
    "Postgres Exporter|POSTGRES_EXPORTER_VERSION|prometheus-community/postgres_exporter|gh"
    "Nginx Exporter|NGINX_EXPORTER_VERSION|nginx/nginx-prometheus-exporter|gh"
    # --- Load Testing ---
    "K6|K6_VERSION|grafana/k6|gh"
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
    [Alloy]=1
    [Node\ Exporter]=1
    [cAdvisor]=1
)

# Components whose Docker image tags carry a -local suffix not present
# in the upstream GitHub release tags (e.g. GitHub 0.5.4 → Docker 0.5.4-local).
declare -A LOCAL_SUFFIX=(
    [Plugin\ Daemon]=1
)

# ============================================================================
# Hold list — components с известными upstream блокерами (CLAUDE.md §8).
# Workflow выявит новый upstream tag, но НЕ предложит обновляться.
# Формат: [Component Name]="reason for hold"
# ============================================================================
declare -A HOLD_REASONS=(
    ["Plugin Daemon"]="0.5.4/5/6 broken (#640 null content / #672 migrate / #521 CLI). Wait for 0.5.7+ from upstream."
    [Docling]="v1.17 RapidOcr ONNX regression — startup FAIL без pre-warm step. Stay на v1.16.1."
    [cAdvisor]="v0.56.0/1/2 — release tag exists, но container manifest БЕЗ arm64 (CLAUDE.md §8). Stay ≤v0.55.1."
    [vLLM]="v1.x major. Spark-builds (eugr/vllm-node-tf5, gemma4-cu130) пинятся отдельно через VLLM_SPARK_IMAGE — bump только после теста на GB10 sm_121a."
    [LiteLLM]="1.83.x = nightly. Wait for next .stable.patch.X tag перед bump."
    [Ollama]="0.20+ major jump. Verify Open WebUI compatibility before upgrade."
    [Weaviate]="Major/minor требует data migration testing."
    [Qdrant]="Major/minor требует data migration testing."
    [SurrealDB]="v3.x has breaking API changes — review before bump."
    [Authelia]="Config format может сломаться между minors — review changelog."
    [Prometheus]="v3.x major: новый storage format, careful migration."
    [Dify]="Plugin Daemon co-bump обязателен (Dify 1.13.3 пинит daemon 0.5.3-local). Check upstream docker-compose.yaml."
    [RAGFlow]="Self-built v0.24.0 (ar2r223/ragflow-spark@digest) из infiniflow upstream + Hendrik patches. Manual rebuild + arm64 verify нужны для bump."
    [SOPS]="Security-sensitive: при bump обязательно обновить SOPS_SHA256_ARM64/AMD64 из checksums.txt релиза."
)

# ============================================================================
# Docker image для arm64 manifest verification.
# CLAUDE.md §8: image:tag должен иметь подтверждённый arm64 в multi-arch
# manifest. Если репо upstream != Docker image — указывай явно.
# Для source=hub репо берётся из ALL_CHECKS как-есть.
# ============================================================================
declare -A ARM64_DOCKER_IMAGE=(
    [Dify]="langgenius/dify-api"
    ["Plugin Daemon"]="langgenius/dify-plugin-daemon"
    [Sandbox]="langgenius/dify-sandbox"
    ["Open WebUI"]="ghcr.io/open-webui/open-webui"
    [Ollama]="ollama/ollama"
    [vLLM]="vllm/vllm-openai"
    [Weaviate]="cr.weaviate.io/semitechnologies/weaviate"
    [Qdrant]="qdrant/qdrant"
    [Docling]="ghcr.io/docling-project/docling-serve"
    [LiteLLM]="ghcr.io/berriai/litellm"
    ["Open Notebook"]="lfnovo/open-notebook"
    ["DB-GPT"]="eosphorosai/dbgpt"
    [Crawl4AI]="unclecode/crawl4ai"
    [SurrealDB]="surrealdb/surrealdb"
    [Authelia]="authelia/authelia"
    [Certbot]="certbot/certbot"
    [Prometheus]="prom/prometheus"
    [Alertmanager]="prom/alertmanager"
    [Grafana]="grafana/grafana"
    [Loki]="grafana/loki"
    [Alloy]="grafana/alloy"
    ["Node Exporter"]="prom/node-exporter"
    [cAdvisor]="gcr.io/cadvisor/cadvisor"
    ["Redis Exporter"]="oliver006/redis_exporter"
    ["Postgres Exporter"]="quay.io/prometheuscommunity/postgres-exporter"
    ["Nginx Exporter"]="nginx/nginx-prometheus-exporter"
    [K6]="grafana/k6"
    [RAGFlow]="infiniflow/ragflow"
    # TEI variants pin "cuda-X.Y.Z"/"cpu-X.Y.Z" Docker tags, GH тегает "vX.Y.Z" —
    # mapping не 1:1, arm64 verify через manifest неточен. Пропускаем.
    # SOPS — это бинарник из релиза (lib/security.sh скачивает), не Docker image.
)

# ============================================================================
# Dify dependency pin tracker.
# Dify upstream docker-compose.yaml пинит конкретные версии postgres / redis /
# sandbox / plugin-daemon. Bump'ить выше = риск schema/protocol incompatibility.
# Workflow подтянет upstream compose для current DIFY_VERSION и сравнит.
#
# Pattern = grep substring до :tag в image: строке. Покрывает оба формата:
#   image: postgres:15-alpine
#   image: ${POSTGRES_IMAGE:-postgres:15-alpine}
# ============================================================================
declare -A DIFY_PINNED_PATTERN=(
    [POSTGRES_VERSION]="postgres:"
    [REDIS_VERSION]="redis:"
    [SANDBOX_VERSION]="langgenius/dify-sandbox:"
    [PLUGIN_DAEMON_VERSION]="langgenius/dify-plugin-daemon:"
    [WEAVIATE_VERSION]="semitechnologies/weaviate:"
    [QDRANT_VERSION]="qdrant/qdrant:"
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
    # Loose match: '-alpine' matches both '-alpine' and '-alpine3.23' tags.
    local suffix=""
    if [[ "$current" == *-alpine* ]]; then suffix="-alpine"; fi

    # Build Docker Hub URL.
    # name= filter — для variant-suffix'ов (alpine/distroless) Docker Hub возвращает
    # 50 latest БЕЗ alpine-вариантов (они "медленнее обновляются" в last_updated).
    # Без фильтра скрипт ловит "could not fetch" для nginx/redis/postgres-alpine.
    local name_filter=""
    if [[ -n "$suffix" ]]; then
        # strip leading dash: "-alpine" → "alpine"
        name_filter="&name=${suffix#-}"
    fi

    local url
    if [[ "$repo" == */* ]]; then
        url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&ordering=last_updated${name_filter}"
    else
        url="https://hub.docker.com/v2/repositories/library/${repo}/tags?page_size=100&ordering=last_updated${name_filter}"
    fi

    curl -sf --max-time 15 "$url" \
        | python3 -c "
import sys, json, re

data = json.load(sys.stdin)
suffix = '${suffix}'
current = '${current}'
skip = {'rc', 'beta', 'alpha', 'dev', 'test', 'latest', 'slim', 'bullseye', 'bookworm', 'jammy', 'noble', 'cicd', 'fips',
        'ppc64le', 'amd64', 's390x', 'arm32v7', 'i386', 'windowsservercore', 'nanoserver', 'linux-'}

# MinIO/MC style timestamp tags: RELEASE.YYYY-MM-DDTHH-MM-SSZ exactly.
# Strict regex: НЕ ловить '-cpuv1', '-cicd', '-fips' и прочие variant-suffixes
# (они появились 2025+ и предназначены для специфичных CPU/compliance профилей).
# Hub API already orders by last_updated DESC — first matching wins.
release_re = re.compile(r'^RELEASE\.\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z\$')
if current.startswith('RELEASE.'):
    for r in data.get('results', []):
        t = r['name']
        if release_re.match(t):
            print(t)
            break
    sys.exit(0)

tags = []
for r in data.get('results', []):
    t = r['name']
    if any(s in t.lower() for s in skip):
        continue
    # Loose suffix match: 'in t' instead of 'endswith' — handles '16-alpine3.23'
    if suffix and suffix not in t:
        continue
    base = t.split('-', 1)[0] if suffix else t
    if not base or not base[0].isdigit():
        continue
    tags.append(t)

def ver_key(tag):
    parts = re.split(r'[\\.\\-]', tag)
    return [int(p) if p.isdigit() else 0 for p in parts]

tags.sort(key=ver_key, reverse=True)
print(tags[0] if tags else '')
" 2>/dev/null || return 1
}

# ============================================================================
# arm64 manifest verification (CLAUDE.md §8 / §10 DoD)
# ============================================================================

# Returns 0 if image:tag has arm64 in its manifest, 1 otherwise, 2 on fetch error.
verify_arm64_manifest() {
    local image="$1" tag="$2"
    local out
    out=$(docker manifest inspect "${image}:${tag}" 2>/dev/null) || return 2

    echo "$out" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)

# Multi-arch manifest list (schemaVersion=2, manifests[])
if isinstance(data, dict) and 'manifests' in data:
    for m in data['manifests']:
        plat = m.get('platform', {}) or {}
        if plat.get('architecture') == 'arm64':
            sys.exit(0)
    sys.exit(1)

# Single-arch image manifest
if isinstance(data, dict) and data.get('architecture') == 'arm64':
    sys.exit(0)

sys.exit(1)
" 2>/dev/null
    return $?
}

# ============================================================================
# Dify upstream compose pin lookup
# ============================================================================

DIFY_COMPOSE_CACHE=""
DIFY_COMPOSE_FETCHED=0

fetch_dify_compose() {
    [[ "$DIFY_COMPOSE_FETCHED" -eq 1 ]] && return 0
    DIFY_COMPOSE_FETCHED=1

    local dify_ver="${CURRENT_VERSIONS[DIFY_VERSION]:-}"
    [[ -z "$dify_ver" ]] && return 1

    # Dify GH tags = '1.13.3' без v-prefix. Defensive — попробуем оба варианта.
    local tag="${dify_ver#v}"
    local url="https://raw.githubusercontent.com/langgenius/dify/${tag}/docker/docker-compose.yaml"
    DIFY_COMPOSE_CACHE=$(curl -sf --max-time 15 "$url" 2>/dev/null) || DIFY_COMPOSE_CACHE=""
    if [[ -z "$DIFY_COMPOSE_CACHE" ]]; then
        url="https://raw.githubusercontent.com/langgenius/dify/v${tag}/docker/docker-compose.yaml"
        DIFY_COMPOSE_CACHE=$(curl -sf --max-time 15 "$url" 2>/dev/null) || DIFY_COMPOSE_CACHE=""
    fi
    [[ -z "$DIFY_COMPOSE_CACHE" ]] && return 1
    return 0
}

# Extract pinned image tag from Dify upstream docker-compose.yaml.
# Returns the tag substring (e.g. "15-alpine", "0.5.3-local") or empty.
dify_pinned_version() {
    local var="$1"
    local pattern="${DIFY_PINNED_PATTERN[$var]:-}"
    [[ -z "$pattern" ]] && return 1
    fetch_dify_compose || return 1

    DIFY_PATTERN="$pattern" python3 -c "
import sys, os, re
text = sys.stdin.read()
pattern = re.escape(os.environ['DIFY_PATTERN'])
# image line может быть: 'image: foo:tag' либо 'image: \${VAR:-foo:tag}'
m = re.search(rf'image:\s*[^\n]*{pattern}([A-Za-z0-9._-]+)', text)
print(m.group(1) if m else '')
" <<< "$DIFY_COMPOSE_CACHE" 2>/dev/null
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

    # Branch-tracked components — informational only, never auto-suggest update
    if [[ "$is_branch" == "true" ]]; then
        echo "  BRANCH: ${name} ${current} -> latest: ${report_latest}" >&2
        ALL_RESULTS+=("${name}|${current}|${report_latest}|branch")
        return
    fi

    # Already up to date
    if ! is_newer "$current" "$latest"; then
        ALL_RESULTS+=("${name}|${current}|${report_latest}|ok")
        echo "  OK: ${name} ${current} (up to date)" >&2
        return
    fi

    local change
    change=$(classify_change "$current" "$latest")

    # Held by known upstream blocker (CLAUDE.md §8) — surface, but don't suggest
    if [[ -n "${HOLD_REASONS[$name]+x}" ]]; then
        local reason="${HOLD_REASONS[$name]}"
        ALL_RESULTS+=("${name}|${current}|${report_latest}|hold|${reason}")
        echo "  HOLD: ${name} ${current} -> ${report_latest} (${change}) — ${reason}" >&2
        return
    fi

    # Dify dependency pin — bumping выше pinned версии = риск schema/protocol break.
    # Cap target до Dify pin'а; если current уже ≥ Dify pin — surface как dify-pinned.
    if [[ -n "${DIFY_PINNED_PATTERN[$var]+x}" ]]; then
        local dify_pin
        dify_pin=$(dify_pinned_version "$var") || true
        if [[ -n "$dify_pin" ]]; then
            local dify_ver="${CURRENT_VERSIONS[DIFY_VERSION]:-?}"
            if is_newer "$dify_pin" "$latest"; then
                if is_newer "$current" "$dify_pin"; then
                    # current отстаёт от Dify pin — suggest bump до pin (safe)
                    local pin_change
                    pin_change=$(classify_change "$current" "$dify_pin")
                    ALL_RESULTS+=("${name}|${current}|${dify_pin}|${pin_change}|capped to Dify ${dify_ver} pin (upstream latest ${report_latest} превышает)")
                    echo "  UPDATE: ${name} ${current} -> ${dify_pin} (${pin_change}) [capped to Dify ${dify_ver}]" >&2
                else
                    # current ≥ Dify pin — bumpить выше нельзя
                    ALL_RESULTS+=("${name}|${current}|${report_latest}|dify-pinned|Dify ${dify_ver} pins ${dify_pin}; bump выше = риск schema/protocol break — ждать новый Dify minor")
                    echo "  DIFY-PINNED: ${name} ${current} -> ${report_latest} (Dify ${dify_ver} pins ${dify_pin})" >&2
                fi
                return
            fi
            # latest ≤ dify_pin → fall through (Dify ещё не апдейтился, мы можем безопасно следовать upstream)
        fi
    fi

    # arm64 manifest verification — required для DGX Spark (CLAUDE.md §8)
    local docker_image=""
    if [[ "$source" == "hub" ]]; then
        if [[ "$repo" == */* ]]; then
            docker_image="$repo"
        else
            docker_image="library/${repo}"
        fi
    elif [[ -n "${ARM64_DOCKER_IMAGE[$name]+x}" ]]; then
        docker_image="${ARM64_DOCKER_IMAGE[$name]}"
    fi

    if [[ -n "$docker_image" ]]; then
        # set -e защита: verify_arm64_manifest exit'ит non-zero под set -e убивает скрипт.
        # `|| arm_rc=$?` ловит exit код без падения.
        local arm_rc=0
        verify_arm64_manifest "$docker_image" "$report_latest" || arm_rc=$?
        case $arm_rc in
            0)
                # arm64 confirmed — proceed with normal classification
                ;;
            1)
                # Tag exists but no arm64 — explicit trap (cAdvisor v0.56.x style)
                ALL_RESULTS+=("${name}|${current}|${report_latest}|no-arm64|${docker_image}:${report_latest} manifest missing arm64")
                echo "  NO-ARM64: ${name} ${current} -> ${report_latest} (${docker_image} manifest БЕЗ arm64)" >&2
                return
                ;;
            *)
                # Couldn't fetch manifest (private/quay auth/etc.) — note but don't block
                ALL_RESULTS+=("${name}|${current}|${report_latest}|${change}|arm64 verify skipped (manifest unreachable)")
                echo "  UPDATE: ${name} ${current} -> ${report_latest} (${change}) [arm64 verify skipped]" >&2
                return
                ;;
        esac
    fi

    ALL_RESULTS+=("${name}|${current}|${report_latest}|${change}")
    echo "  UPDATE: ${name} ${current} -> ${report_latest} (${change})" >&2
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
        echo "| Component | Current | Latest | Status | Note |"
        echo "|-----------|---------|--------|--------|------|"
        for entry in "${ALL_RESULTS[@]}"; do
            IFS='|' read -r name current latest status note <<< "$entry"
            local badge
            case "$status" in
                ok)           badge="✅ up to date" ;;
                patch)        badge="📦 patch" ;;
                minor)        badge="🔄 minor" ;;
                major)        badge="⚠️ major" ;;
                branch)       badge="🔀 branch → ${latest}" ;;
                hold)         badge="⏸ HOLD" ;;
                "dify-pinned") badge="🔒 Dify-pinned" ;;
                no-arm64)     badge="🚫 no arm64" ;;
                error)        badge="❌ fetch error" ;;
                *)            badge="$status" ;;
            esac
            echo "| ${name} | ${current} | ${latest} | ${badge} | ${note:-} |"
        done
        echo ""
        echo "### Legend"
        echo "- **✅ up to date**: No action needed."
        echo "- **📦 patch**: Safe to update. Test and release."
        echo "- **🔄 minor**: Review changelog. Test before release."
        echo "- **⚠️ major**: Breaking changes possible. Careful testing required."
        echo "- **🔀 branch**: Tracking a branch — latest stable release shown for reference."
        echo "- **⏸ HOLD**: Upstream release exists, но pinned по известной причине (CLAUDE.md §8). НЕ обновлять без снятия блокера."
        echo "- **🔒 Dify-pinned**: Upstream Dify docker-compose.yaml пинит конкретную версию этого компонента. Bump выше Dify pin = риск schema/protocol incompatibility. Ждать новый Dify minor с обновлённым pin."
        echo "- **🚫 no arm64**: Upstream tag есть, но в multi-arch manifest НЕТ arm64. Несовместимо с DGX Spark — ловит cAdvisor v0.56-style ловушки (CLAUDE.md §8)."
        echo "- **❌ fetch error**: Could not reach upstream API."
        echo ""
        echo "### How to update (только для 📦 / 🔄 / ⚠️)"
        echo "1. On test server: \`agmind update --component <name> --version <latest> --force\`"
        echo "2. Run \`agmind doctor\` — verify 0 errors"
        echo "3. Verify arm64: \`bash tests/compose/test_image_tags_exist.sh core/compose.yml\` (CLAUDE.md §10 DoD)"
        echo "4. If OK — update \`templates/versions.env\` — commit — create Release"
        echo "5. If FAIL — \`agmind update --rollback\`"
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

    # Tally statuses
    local update_count=0 hold_count=0 dify_count=0 noarm_count=0
    for entry in "${ALL_RESULTS[@]}"; do
        IFS='|' read -r _ _ _ status _ <<< "$entry"
        case "$status" in
            patch|minor|major) ((update_count++)) || true ;;
            hold)              ((hold_count++)) || true ;;
            dify-pinned)       ((dify_count++)) || true ;;
            no-arm64)          ((noarm_count++)) || true ;;
        esac
    done

    echo "${#ALL_RESULTS[@]} component(s) checked: ${update_count} update(s), ${hold_count} held, ${dify_count} Dify-pinned, ${noarm_count} arm64-blocked." >&2
    generate_report
    if [[ $update_count -gt 0 ]]; then
        set_output "has_updates" "true"
    else
        set_output "has_updates" "false"
    fi
    set_output "hold_count" "$hold_count"
    set_output "dify_pinned_count" "$dify_count"
    set_output "noarm_count" "$noarm_count"
    set_output "date" "$TODAY"
    echo "Report: ${REPORT_FILE}" >&2
}

main "$@"
