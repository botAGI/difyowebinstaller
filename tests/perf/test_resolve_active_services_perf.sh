#!/usr/bin/env bash
# ============================================================================
# tests/perf/test_resolve_active_services_perf.sh
#
# Plan 14-02 Task 2 / D-04 perf gate for resolve_active_services.
#
# Asserts:
#   - cached hit  mean  < 100ms per call  (D-04 cached threshold)
#   - uncached    mean  < 1500ms per call (D-04 uncached threshold;
#                                          intentionally slower because
#                                          _resolve_active_services_uncached
#                                          still uses legacy grep|cut reads
#                                          pre-Plans 14-03..06 migration)
#
# Hermetic — uses mktemp -d for INSTALL_DIR; never reads /opt/agmind.
#
# Subshell semantics note (Pitfall 4 caveat, from 14-01 SUMMARY):
# Bash `$(...)` forks a subshell — cache vars set inside cannot escape
# to the parent. Therefore timing measurements live inside ONE subshell
# block per phase (cached / uncached). The cache is warm-and-measure
# within the same subshell scope where the loop runs.
#
# Mean-of-N rather than max-of-N to be robust against CI runner jitter.
#
# rc convention:
#   0   — both gates pass
#   1   — at least one gate failed (informational ms values still printed)
#   77  — SKIP (Plan 14-01 missing OR bash < 5 where EPOCHREALTIME unavailable)
# ============================================================================
set -uo pipefail

# CRITICAL: force C locale so EPOCHREALTIME uses '.' as decimal separator
# (otherwise ru_RU.UTF-8 emits comma — awk parses it as field separator and
# silently returns 0 for elapsed time, defeating the perf gate).
export LC_ALL=C LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# rc=77 SKIP — Plan 14-01 prerequisite check
if [[ ! -f "${REPO_ROOT}/lib/health.sh" ]] \
   || [[ ! -f "${REPO_ROOT}/lib/service-map.sh" ]] \
   || ! grep -q "^resolve_active_services()" "${REPO_ROOT}/lib/health.sh" 2>/dev/null; then
    echo "SKIP: Plan 14-01 deliverables missing"
    exit 77
fi

# rc=77 SKIP — EPOCHREALTIME requires bash 5+. AGmind targets bash 5+ per
# CLAUDE.md §6 so this should never SKIP on a real host; defensive only.
if [[ -z "${EPOCHREALTIME:-}" ]]; then
    echo "SKIP: bash < 5 — EPOCHREALTIME unavailable"
    exit 77
fi

# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/service-map.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/lib/health.sh"
set +e

# ----------------------------------------------------------------------------
# Hermetic fixture
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/docker"
cat > "${TMP}/docker/.env" <<'EOF'
VECTOR_STORE=weaviate
LLM_PROVIDER=vllm
EMBED_PROVIDER=tei
LLM_ON_PEER=false
ENABLE_RERANKER=false
RERANKER_PROVIDER=tei
MONITORING_MODE=none
ETL_TYPE=dify
ENABLE_LITELLM=false
ENABLE_NOTEBOOK=false
ENABLE_DBGPT=false
ENABLE_OPENWEBUI=false
ENABLE_RAGFLOW=false
ENABLE_MINIO=false
ENABLE_SEARXNG=false
ENABLE_CRAWL4AI=false
ENABLE_N8N=false
EOF

export INSTALL_DIR="$TMP"

# Thresholds per D-04
CACHED_GATE_MS=100
UNCACHED_GATE_MS=1500

# ----------------------------------------------------------------------------
# Cached path measurement — single subshell so cache survives the loop.
# Iteration count N=100 amortizes EPOCHREALTIME granularity (1 µs).
# ----------------------------------------------------------------------------
N_CACHED=100
cached_payload="$(
    _AGMIND_SVC_CACHE_KEY=""
    _AGMIND_SVC_CACHE_VAL=""

    # Warm-up call populates cache + sanity-check cache was actually written.
    resolve_active_services >/dev/null
    if [[ -z "${_AGMIND_SVC_CACHE_KEY:-}" ]]; then
        echo "CACHE_NOT_WARMED|0|0"
        exit
    fi

    t0="$EPOCHREALTIME"
    for ((i = 0; i < N_CACHED; i++)); do
        resolve_active_services >/dev/null
    done
    t1="$EPOCHREALTIME"

    elapsed_ms="$(awk -v s="$t0" -v e="$t1" 'BEGIN { printf "%.3f", (e - s) * 1000.0 }')"
    mean_ms="$(awk -v s="$t0" -v e="$t1" -v n="$N_CACHED" 'BEGIN { printf "%.3f", (e - s) * 1000.0 / n }')"
    echo "OK|${elapsed_ms}|${mean_ms}"
)"

# shellcheck disable=SC2034   # cached_total_ms reserved for future "max-of-N" reporting
IFS='|' read -r cached_status cached_total_ms cached_mean_ms <<< "$cached_payload"

if [[ "$cached_status" != "OK" ]]; then
    echo "FAIL: cached path did not warm cache (status=$cached_status)"
    echo "PERF: cached=N/A uncached=N/A (D-04: cached<${CACHED_GATE_MS}ms, uncached<${UNCACHED_GATE_MS}ms)"
    exit 1
fi

# ----------------------------------------------------------------------------
# Uncached path measurement — reset cache before EACH call to force miss.
# N=20 — smaller because each miss is intentionally heavy (legacy grep|cut).
# ----------------------------------------------------------------------------
N_UNCACHED=20
uncached_payload="$(
    t0="$EPOCHREALTIME"
    for ((i = 0; i < N_UNCACHED; i++)); do
        _AGMIND_SVC_CACHE_KEY=""
        _AGMIND_SVC_CACHE_VAL=""
        resolve_active_services >/dev/null
    done
    t1="$EPOCHREALTIME"

    elapsed_ms="$(awk -v s="$t0" -v e="$t1" 'BEGIN { printf "%.3f", (e - s) * 1000.0 }')"
    mean_ms="$(awk -v s="$t0" -v e="$t1" -v n="$N_UNCACHED" 'BEGIN { printf "%.3f", (e - s) * 1000.0 / n }')"
    echo "OK|${elapsed_ms}|${mean_ms}"
)"

# shellcheck disable=SC2034   # uncached_status/total_ms reserved for parity with cached_payload schema
IFS='|' read -r uncached_status uncached_total_ms uncached_mean_ms <<< "$uncached_payload"

# ----------------------------------------------------------------------------
# Verdict
# ----------------------------------------------------------------------------
cached_ok="$(awk -v m="$cached_mean_ms" -v g="$CACHED_GATE_MS" 'BEGIN { print (m < g) ? "OK" : "FAIL" }')"
uncached_ok="$(awk -v m="$uncached_mean_ms" -v g="$UNCACHED_GATE_MS" 'BEGIN { print (m < g) ? "OK" : "FAIL" }')"

# Cache effectiveness ratio — cached path must be at least 5× faster than
# uncached, otherwise the cache is no-op (adversarial inversion guard).
# Without this, on fast tmpfs hosts cached + uncached can both be <100ms
# even when the cache is disabled — D-04 gate alone wouldn't catch regression.
# 5× is conservative; in practice we observe ~20× (1.7ms cached vs 33ms uncached).
ratio_ok="$(awk -v c="$cached_mean_ms" -v u="$uncached_mean_ms" \
    'BEGIN { print (c > 0 && u / c >= 5.0) ? "OK" : "FAIL" }')"
ratio="$(awk -v c="$cached_mean_ms" -v u="$uncached_mean_ms" \
    'BEGIN { if (c > 0) printf "%.1f", u / c; else printf "inf" }')"

echo "PERF: cached=${cached_mean_ms}ms uncached=${uncached_mean_ms}ms" \
     "ratio=${ratio}× (N_cached=${N_CACHED} N_uncached=${N_UNCACHED};" \
     "D-04 gates: cached<${CACHED_GATE_MS}ms, uncached<${UNCACHED_GATE_MS}ms, ratio>=5×)"

rc=0
if [[ "$cached_ok" != "OK" ]]; then
    echo "FAIL: cached threshold violated — mean=${cached_mean_ms}ms >= ${CACHED_GATE_MS}ms"
    rc=1
fi
if [[ "$uncached_ok" != "OK" ]]; then
    echo "FAIL: uncached threshold violated — mean=${uncached_mean_ms}ms >= ${UNCACHED_GATE_MS}ms"
    rc=1
fi
if [[ "$ratio_ok" != "OK" ]]; then
    echo "FAIL: cache effectiveness — uncached/cached ratio=${ratio} < 5× (cache appears disabled)"
    rc=1
fi

if [[ $rc -eq 0 ]]; then
    echo "PASS: both D-04 gates green + cache effective (ratio=${ratio}×)"
fi

exit "$rc"
