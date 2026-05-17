#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_resolve_active_services_cache.sh
#
# Plan 14-01 / RESOLVER-01 adversarial smoke (PITFALLS-4 verbatim contract).
# Validates 7 invariants of resolve_active_services + _AGMIND_SVC_CACHE_*:
#
#   [1] Idempotence — repeated calls under same mtime emit byte-identical bytes.
#   [2] In-process cache reuse — within a single subshell, second call hits
#       the cache (cache key stable across both invocations).
#   [3] Alias parity — get_service_list() === resolve_active_services().
#   [4] Mtime-only bump (content unchanged) preserves output bytes.
#   [5] Content change (sed in-place, no key duplication) invalidates cache —
#       new output reflects the change.
#   [6] Cache key shape — "${env_file}:<unix_mtime>".
#   [7] Cache hit performance — <100ms cached per D-04 (we observe ~2ms).
#
# Subshell semantics note (Pitfall 4 caveat):
# Bash command substitution `$(...)` forks a subshell; cache vars set inside
# it do NOT write back to the parent. Therefore cache reuse can ONLY be
# proven within a single subshell — checks [2] and [6] live inside one $(...).
# Real-world callers in install.sh / agmind CLI gain cache benefit when
# resolve_active_services is invoked multiple times within the same script
# scope without `$()` indirection (e.g. piped to stdout or read into the
# stdout-collecting pattern). Plan 14-02 will add a perf gate that measures
# this in a controlled subshell harness.
#
# Exit: 0 = pass, 1 = fail.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/service-map.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/health.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/docker"
cat > "${TMP}/docker/.env" <<'EOF'
VECTOR_STORE=weaviate
LLM_PROVIDER=vllm
EMBED_PROVIDER=tei
LLM_ON_PEER=false
ENABLE_RERANKER=false
MONITORING_MODE=none
ETL_TYPE=dify
ENABLE_LITELLM=false
ENABLE_NOTEBOOK=false
ENABLE_DBGPT=false
ENABLE_OPENWEBUI=false
ENABLE_RAGFLOW=false
ENABLE_MINIO=false
ENABLE_SEARXNG=false
EOF

export INSTALL_DIR="$TMP"

pass=0; fail=0

_pass() { pass=$((pass + 1)); echo "  [PASS] $*"; }
_fail() { fail=$((fail + 1)); echo "  [FAIL] $*"; }

echo "## test_resolve_active_services_cache"
echo ""

# [1] Idempotence
first="$(resolve_active_services)"
second="$(resolve_active_services)"
if [[ "$first" == "$second" ]]; then
    _pass "[1] idempotence (same mtime → identical bytes)"
else
    _fail "[1] idempotence: first=[$first] vs second=[$second]"
fi

# [2] In-process cache reuse
status="$(
  resolve_active_services >/dev/null
  if [[ -z "${_AGMIND_SVC_CACHE_VAL:-}" ]]; then echo NOPOP; exit; fi
  k1="${_AGMIND_SVC_CACHE_KEY}"
  resolve_active_services >/dev/null
  k2="${_AGMIND_SVC_CACHE_KEY}"
  [[ "$k1" == "$k2" ]] && echo CACHED || echo MISS
)"
if [[ "$status" == "CACHED" ]]; then
    _pass "[2] in-process cache reuse (key stable across 2 calls in same subshell)"
else
    _fail "[2] in-process cache reuse: status=$status"
fi

# [3] Alias parity
third="$(get_service_list)"
if [[ "$first" == "$third" ]]; then
    _pass "[3] alias parity (get_service_list === resolve_active_services)"
else
    _fail "[3] alias parity diverged"
fi

# [4] Mtime-only bump
sleep 1; touch -m "${TMP}/docker/.env"
fourth="$(resolve_active_services)"
if [[ "$first" == "$fourth" ]]; then
    _pass "[4] mtime-only bump preserves output bytes"
else
    _fail "[4] mtime-only bump perturbed output"
fi

# [5] Content change → cache invalidates
sed -i 's/^ENABLE_OPENWEBUI=false$/ENABLE_OPENWEBUI=true/' "${TMP}/docker/.env"
sleep 1; touch -m "${TMP}/docker/.env"
fifth="$(resolve_active_services)"
if [[ "$fifth" != "$fourth" && "$fifth" == *open-webui* ]]; then
    _pass "[5] content change reflected (open-webui appears)"
else
    _fail "[5] content change not reflected: fifth=[$fifth]"
fi

# [6] Cache key shape
inspect_key="$(
  resolve_active_services >/dev/null
  echo "${_AGMIND_SVC_CACHE_KEY}"
)"
expected_prefix="${TMP}/docker/.env:"
if [[ "$inspect_key" == "${expected_prefix}"* ]]; then
    _pass "[6] cache_key shape (\"<env_file>:<mtime>\")"
else
    _fail "[6] cache_key shape unexpected: $inspect_key"
fi

# [7] Cache hit timing — measured within one subshell so cache survives.
# D-04 contract: cached <100ms per call. Observed on dev box: ~2ms/call.
t_ms="$(
  resolve_active_services >/dev/null  # warm
  t0=$(date +%s%N)
  for _ in $(seq 1 200); do resolve_active_services >/dev/null; done
  t1=$(date +%s%N)
  echo $(( (t1 - t0) / 1000000 ))
)"
avg_us=$(( (t_ms * 1000) / 200 ))
if (( avg_us < 100000 )); then  # 100ms = 100_000us per D-04
    _pass "[7] cache hit timing: 200 calls=${t_ms}ms, avg=${avg_us}us/call (< 100ms gate)"
else
    _fail "[7] cache hit timing: avg=${avg_us}us/call exceeds 100ms"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Summary: ${pass} passed, ${fail} failed"
echo "═══════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]]
