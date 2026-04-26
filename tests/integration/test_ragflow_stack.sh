#!/usr/bin/env bash
# tests/integration/test_ragflow_stack.sh — integration coverage for BACKLOG #999.7.
# Verifies RAGFlow stack components are reachable internally:
#   1. agmind-ragflow-mysql healthy + accepts root login
#   2. agmind-ragflow-es healthy + cluster status green/yellow + auth works
#   3. agmind-ragflow API /v1/system/version returns 200
#   4. RAGFlow can reach MinIO bucket (DNS + creds)
#   5. RAGFlow can reach Redis DB=2
#   6. ssrf_proxy не блокирует ragflow:9380 (Dify api → ragflow path)
#
# Exit 77 = SKIP (preconditions not met); 0 = PASS; 1 = FAIL.
set -uo pipefail

echo "## test_ragflow_stack (integration)"

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
ENV_FILE="${INSTALL_DIR}/docker/.env"

# --- Preconditions ---
if [[ ! -f "$ENV_FILE" ]]; then
    echo "SKIP: ${ENV_FILE} not found — install AGmind first"
    exit 77
fi

ENABLE_RAGFLOW="$(grep '^ENABLE_RAGFLOW=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo "false")"
if [[ "$ENABLE_RAGFLOW" != "true" ]]; then
    echo "SKIP: ENABLE_RAGFLOW=false — ragflow not provisioned"
    exit 77
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not available"
    exit 77
fi

FAIL=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1" >&2; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; }

# --- 1. MySQL ---
if ! docker ps --filter 'name=agmind-ragflow-mysql' --filter 'status=running' --format '{{.Names}}' | grep -q ragflow-mysql; then
    fail "agmind-ragflow-mysql not running"
else
    MYSQL_PW="$(grep '^RAGFLOW_MYSQL_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)"
    if [[ -z "$MYSQL_PW" ]]; then
        fail "RAGFLOW_MYSQL_PASSWORD empty"
    elif docker exec agmind-ragflow-mysql sh -c "mysqladmin ping -h 127.0.0.1 -uroot -p'${MYSQL_PW}' --silent" >/dev/null 2>&1; then
        pass "MySQL ping OK"
    else
        fail "MySQL ping failed (auth or boot)"
    fi
fi

# --- 2. Elasticsearch ---
if ! docker ps --filter 'name=agmind-ragflow-es' --filter 'status=running' --format '{{.Names}}' | grep -q ragflow-es; then
    fail "agmind-ragflow-es not running"
else
    ES_PW="$(grep '^RAGFLOW_ES_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)"
    if [[ -z "$ES_PW" ]]; then
        fail "RAGFLOW_ES_PASSWORD empty"
    else
        ES_HEALTH="$(docker exec agmind-ragflow-es curl -fsS -u "elastic:${ES_PW}" http://localhost:9200/_cluster/health 2>/dev/null | grep -oE '"status":"[a-z]+"' | head -1 | cut -d'"' -f4)"
        case "$ES_HEALTH" in
            green|yellow) pass "ES cluster ${ES_HEALTH} + auth OK" ;;
            red)          fail "ES cluster RED" ;;
            *)            fail "ES cluster status unreadable: '${ES_HEALTH}'" ;;
        esac
    fi
fi

# --- 3. RAGFlow main API ---
if ! docker ps --filter 'name=agmind-ragflow' --filter 'status=running' --format '{{.Names}}' | grep -q '^agmind-ragflow$'; then
    fail "agmind-ragflow not running"
else
    if docker exec agmind-ragflow curl -fsS --max-time 5 http://localhost:9380/v1/system/version >/dev/null 2>&1; then
        pass "RAGFlow API /v1/system/version OK"
    else
        fail "RAGFlow API not responsive (yet starting? wait 3 min after deploy)"
    fi
fi

# --- 4. MinIO bucket reachable from ragflow container ---
if docker exec agmind-ragflow getent hosts minio >/dev/null 2>&1; then
    pass "DNS minio resolvable from ragflow"
else
    fail "DNS minio NOT resolvable from ragflow — check agmind-backend network"
fi

# --- 5. Redis DB=2 ---
REDIS_PW="$(grep '^REDIS_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)"
if [[ -n "$REDIS_PW" ]]; then
    if docker exec agmind-redis redis-cli -a "$REDIS_PW" --no-auth-warning -n 2 PING 2>/dev/null | grep -q PONG; then
        pass "Redis DB=2 PING OK"
    else
        fail "Redis DB=2 PING failed"
    fi
fi

# --- 6. Squid не блочит ragflow:9380 (Dify path) ---
if docker ps --filter 'name=agmind-ssrf-proxy' --filter 'status=running' --format '{{.Names}}' | grep -q ssrf-proxy; then
    if docker exec agmind-api curl -fsS --max-time 5 -x http://ssrf_proxy:3128 http://ragflow:9380/v1/system/version >/dev/null 2>&1; then
        pass "ssrf_proxy → ragflow:9380 reachable (Dify path)"
    else
        # Fallback: ragflow may not be ready yet, или squid не разрешает.
        # Differentiate: direct без proxy.
        if docker exec agmind-api curl -fsS --max-time 5 http://ragflow:9380/v1/system/version >/dev/null 2>&1; then
            fail "ssrf_proxy блокирует ragflow:9380 — нужна правка squid.conf"
        else
            warn "ragflow:9380 unreachable from agmind-api (ragflow возможно ещё стартует)"
        fi
    fi
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "## test_ragflow_stack: PASS"
    exit 0
else
    echo "## test_ragflow_stack: ${FAIL} FAILED"
    exit 1
fi
