#!/usr/bin/env bash
# test_build_compose_profiles.sh — Полное покрытие веток lib/compose.sh::build_compose_profiles().
# Эта функция — единая точка решения «какие docker-compose profiles активировать»,
# на её корректности завязан выбор vector store / LLM провайдера / monitoring /
# RAGFlow MinIO auto-pull / OpenWebUI / Crawl4AI и др.
#
# Любая регрессия здесь молча даст «не тот стек поднимется» — install.sh пройдёт
# зелёным, юзер увидит «странно, у меня MinIO не запустился вместе с RAGFlow» уже
# на этапе пользовательского installs. Поэтому покрываем явно.
#
# Exit: 0 = all PASS, 1 = any FAIL, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_SH="${REPO_ROOT}/lib/compose.sh"

if [[ ! -f "$COMPOSE_SH" ]]; then
    echo "SKIP: ${COMPOSE_SH} not found"
    exit 77
fi

echo "## test_build_compose_profiles"

fail=0
pass=0

# Запускает build_compose_profiles в чистом subshell с заданными env vars,
# возвращает результирующий COMPOSE_PROFILE_STRING.
_run() {
    local env_setup="$1"
    bash -c "
        set +e
        # Stub log_* (compose.sh ожидает их из common.sh, но для unit-теста не нужны)
        log_info()    { :; }
        log_warn()    { :; }
        log_error()   { :; }
        log_success() { :; }
        export -f log_info log_warn log_error log_success
        ${env_setup}
        # shellcheck disable=SC1090
        source '${COMPOSE_SH}' 2>/dev/null
        build_compose_profiles >/dev/null 2>&1
        echo \"\${COMPOSE_PROFILE_STRING}\"
    "
}

_assert_contains() {
    local label="$1" expected_token="$2" actual_csv="$3"
    if [[ ",${actual_csv}," == *",${expected_token},"* ]]; then
        echo "  PASS: ${label} (contains '${expected_token}')"
        pass=$((pass+1))
    else
        echo "  FAIL: ${label}"
        echo "        expected token: ${expected_token}"
        echo "        actual csv:     ${actual_csv}"
        fail=$((fail+1))
    fi
}

_assert_not_contains() {
    local label="$1" forbidden_token="$2" actual_csv="$3"
    if [[ ",${actual_csv}," != *",${forbidden_token},"* ]]; then
        echo "  PASS: ${label} (does NOT contain '${forbidden_token}')"
        pass=$((pass+1))
    else
        echo "  FAIL: ${label}"
        echo "        forbidden token: ${forbidden_token}"
        echo "        actual csv:      ${actual_csv}"
        fail=$((fail+1))
    fi
}

# --- Vector store branches ---

result="$(_run 'VECTOR_STORE=weaviate')"
_assert_contains    "VECTOR_STORE=weaviate → weaviate profile" "weaviate" "$result"
_assert_not_contains "VECTOR_STORE=weaviate → no qdrant"        "qdrant"   "$result"

result="$(_run 'VECTOR_STORE=qdrant')"
_assert_contains    "VECTOR_STORE=qdrant → qdrant profile"   "qdrant"   "$result"
_assert_not_contains "VECTOR_STORE=qdrant → no weaviate"      "weaviate" "$result"

# Default = weaviate (most common deploy path).
result="$(_run '')"
_assert_contains "VECTOR_STORE unset → defaults to weaviate" "weaviate" "$result"

# --- LLM provider branches ---

result="$(_run 'LLM_PROVIDER=ollama')"
_assert_contains "LLM_PROVIDER=ollama → ollama profile" "ollama" "$result"

result="$(_run 'LLM_PROVIDER=vllm LLM_ON_PEER=false')"
_assert_contains "LLM_PROVIDER=vllm + LLM_ON_PEER=false → vllm local" "vllm" "$result"

result="$(_run 'LLM_PROVIDER=vllm LLM_ON_PEER=true PEER_IP=192.168.100.2')"
_assert_not_contains "LLM_ON_PEER=true → vllm NOT in local profiles (runs on peer)" \
    "vllm" "$result"

# --- Embed/rerank ---

result="$(_run 'EMBED_PROVIDER=tei')"
_assert_contains "EMBED_PROVIDER=tei → tei profile" "tei" "$result"

result="$(_run 'EMBED_PROVIDER=vllm-embed')"
_assert_contains "EMBED_PROVIDER=vllm-embed → vllm-embed profile" "vllm-embed" "$result"

result="$(_run 'ENABLE_RERANKER=true RERANKER_PROVIDER=tei')"
_assert_contains "ENABLE_RERANKER=true (tei) → reranker profile" "reranker" "$result"

result="$(_run 'ENABLE_RERANKER=true RERANKER_PROVIDER=vllm-rerank')"
_assert_contains "ENABLE_RERANKER=true (vllm-rerank) → vllm-rerank profile" \
    "vllm-rerank" "$result"

# --- Optional services ---

result="$(_run 'MONITORING_MODE=local')"
_assert_contains "MONITORING_MODE=local → monitoring profile" "monitoring" "$result"

result="$(_run 'ENABLE_AUTHELIA=true')"
_assert_contains "ENABLE_AUTHELIA=true → authelia profile" "authelia" "$result"

result="$(_run 'ENABLE_LITELLM=true')"
_assert_contains "ENABLE_LITELLM=true → litellm profile" "litellm" "$result"

result="$(_run 'ENABLE_SEARXNG=true')"
_assert_contains "ENABLE_SEARXNG=true → searxng profile" "searxng" "$result"

result="$(_run 'ENABLE_OPENWEBUI=true')"
_assert_contains "ENABLE_OPENWEBUI=true → openwebui profile" "openwebui" "$result"

result="$(_run 'ENABLE_CRAWL4AI=true')"
_assert_contains "ENABLE_CRAWL4AI=true → crawl4ai profile" "crawl4ai" "$result"

# --- Docling auto-detection (legacy ETL_ENHANCED + ETL_TYPE compat) ---

result="$(_run 'ENABLE_DOCLING=true')"
_assert_contains "ENABLE_DOCLING=true → docling profile" "docling" "$result"

result="$(_run 'ETL_TYPE=unstructured_api')"
_assert_contains "ETL_TYPE=unstructured_api → docling profile (compat)" "docling" "$result"

result="$(_run 'ETL_ENHANCED=true')"
_assert_contains "ETL_ENHANCED=true (legacy) → docling profile (compat)" "docling" "$result"

# --- RAGFlow auto-pulls MinIO (regression: must NOT duplicate minio token) ---

result="$(_run 'ENABLE_RAGFLOW=true')"
_assert_contains "ENABLE_RAGFLOW=true → ragflow profile" "ragflow" "$result"
_assert_contains "ENABLE_RAGFLOW=true → auto-pulls minio profile" "minio" "$result"

# count occurrences of 'minio' to prevent dedup regression
minio_count="$(echo "$result" | tr ',' '\n' | grep -cx 'minio' || true)"
if [[ "$minio_count" -le 1 ]]; then
    echo "  PASS: ENABLE_RAGFLOW=true + ENABLE_MINIO unset → minio not duplicated (count=${minio_count})"
    pass=$((pass+1))
else
    echo "  FAIL: minio appears ${minio_count} times in '${result}' (expected ≤1)"
    fail=$((fail+1))
fi

# Если ENABLE_MINIO=false explicitly + ENABLE_RAGFLOW=true → minio все равно автоматически нужен
# (RAGFlow зависит от MinIO для object storage).
result="$(_run 'ENABLE_RAGFLOW=true ENABLE_MINIO=false')"
_assert_not_contains "ENABLE_MINIO=false + RAGFlow → user opt-out respected" "minio" "$result"

# --- Combined real-world scenario: typical AGmind LAN deploy ---

result="$(_run 'VECTOR_STORE=weaviate LLM_PROVIDER=vllm LLM_ON_PEER=true EMBED_PROVIDER=vllm-embed ENABLE_RERANKER=true RERANKER_PROVIDER=vllm-rerank ENABLE_LITELLM=true MONITORING_MODE=local ENABLE_RAGFLOW=true')"
_assert_contains "Real-world: weaviate present" "weaviate" "$result"
_assert_contains "Real-world: vllm-embed present" "vllm-embed" "$result"
_assert_contains "Real-world: vllm-rerank present" "vllm-rerank" "$result"
_assert_contains "Real-world: litellm present" "litellm" "$result"
_assert_contains "Real-world: monitoring present" "monitoring" "$result"
_assert_contains "Real-world: ragflow present" "ragflow" "$result"
_assert_contains "Real-world: minio auto-pulled" "minio" "$result"
_assert_not_contains "Real-world: vllm NOT local (LLM_ON_PEER=true)" "vllm" "$result"

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
