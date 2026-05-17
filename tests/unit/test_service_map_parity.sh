#!/usr/bin/env bash
# tests/unit/test_service_map_parity.sh — REG-04/05/06 coverage.
#
# Asserts lib/service-map.sh public API surface stays stable after refactor:
# all 8 public symbols defined with correct types + sane counts + spot-check
# values + backward-compat aliases + newly-visible services.
#
# Two categories of assertions:
#
#   (A) STABLE — passes both pre-refactor (188-line hand-edited file) and
#       post-refactor (thin shim over _registry.indexed.sh). Tests symbol
#       presence, >=counts, named-profile expansion verbatim.
#
#   (B) EXPANSION — passes ONLY post-refactor. Tests:
#         - 8 backward-compat aliases in NAME_TO_VERSION_KEY (Blocker #1)
#         - 5 newly-visible services in SERVICE_GROUPS (Warning #3):
#             redis-lock-cleaner, ragflow_es_exporter, docker-socket-proxy,
#             milvus-init, k6
#
# Behaviour:
#   Pre-refactor: test FAILS on EXPANSION block (B2 — newly-visible services)
#                 — this is expected TDD red.
#   Post-refactor (Task 2): test PASSES on both blocks — TDD green.
#
# See docs/adr/0012-service-registry-codegen.md for design rationale.
# Exit: 0 = pass, 1 = fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_service_map_parity"

pass=0
fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# Source service-map.sh in same shell (assoc arrays must persist).
# shellcheck source=../../lib/service-map.sh
source "$REPO_ROOT/lib/service-map.sh"

# ============================================================================
# (A) STABLE assertions — pre/post refactor agnostic
# ============================================================================

# === A1-A6: All 6 assoc-array public symbols defined ===
for sym in NAME_TO_VERSION_KEY NAME_TO_SERVICES SERVICE_GROUPS NAMED_PROFILE_EXPANSION NAMED_PROFILE_DESC NAMED_PROFILE_IMPLIED; do
    if declare -p "$sym" 2>/dev/null | grep -q '^declare -A'; then
        _ok "symbol $sym is declare -A"
    else
        _fail "symbol $sym not defined as assoc array"
    fi
done

# === A7-A8: 2 scalar public symbols defined and non-empty ===
for sym in SERVICE_GROUP_ORDER ALL_COMPOSE_PROFILES; do
    if [[ -n "${!sym:-}" ]]; then
        _ok "symbol $sym is non-empty scalar"
    else
        _fail "symbol $sym not defined or empty"
    fi
done

# === A9-A10: Count assertions (lower bounds — pre + post both pass) ===
if [[ ${#NAME_TO_VERSION_KEY[@]} -ge 41 ]]; then
    _ok "NAME_TO_VERSION_KEY has ${#NAME_TO_VERSION_KEY[@]} entries (>=41)"
else
    _fail "NAME_TO_VERSION_KEY has ${#NAME_TO_VERSION_KEY[@]} entries (<41)"
fi
if [[ ${#NAME_TO_SERVICES[@]} -ge 41 ]]; then
    _ok "NAME_TO_SERVICES has ${#NAME_TO_SERVICES[@]} entries (>=41)"
else
    _fail "NAME_TO_SERVICES has ${#NAME_TO_SERVICES[@]} entries (<41)"
fi

# === A11: SERVICE_GROUPS must have exactly 7 keys ===
if [[ ${#SERVICE_GROUPS[@]} -eq 7 ]]; then
    _ok "SERVICE_GROUPS has 7 keys"
else
    _fail "SERVICE_GROUPS has ${#SERVICE_GROUPS[@]} keys (expected 7)"
fi

# === A12-A14: Named profile arrays must have 8 keys each ===
for kpvar in NAMED_PROFILE_EXPANSION NAMED_PROFILE_DESC NAMED_PROFILE_IMPLIED; do
    eval "n=\${#${kpvar}[@]}"
    if [[ "$n" -eq 8 ]]; then
        _ok "$kpvar has 8 keys"
    else
        _fail "$kpvar has $n keys (expected 8)"
    fi
done

# === A15: SERVICE_GROUP_ORDER has 7 space-separated tokens ===
n=$(echo "$SERVICE_GROUP_ORDER" | tr -s ' ' '\n' | grep -c .)
if [[ "$n" -eq 7 ]]; then
    _ok "SERVICE_GROUP_ORDER has 7 tokens: $SERVICE_GROUP_ORDER"
else
    _fail "SERVICE_GROUP_ORDER has $n tokens (expected 7)"
fi

# === A16: ALL_COMPOSE_PROFILES has >=20 comma-separated entries ===
n=$(echo "$ALL_COMPOSE_PROFILES" | tr ',' '\n' | grep -c .)
if [[ "$n" -ge 20 ]]; then
    _ok "ALL_COMPOSE_PROFILES has $n entries (>=20)"
else
    _fail "ALL_COMPOSE_PROFILES has $n entries (<20)"
fi

# === A17: NAMED_PROFILE_EXPANSION[core] spot-check ===
if [[ "${NAMED_PROFILE_EXPANSION[core]:-}" == "vllm,litellm" ]]; then
    _ok "NAMED_PROFILE_EXPANSION[core] == 'vllm,litellm'"
else
    _fail "NAMED_PROFILE_EXPANSION[core] == '${NAMED_PROFILE_EXPANSION[core]:-}' (expected 'vllm,litellm')"
fi

# === A18: NAMED_PROFILE_IMPLIED[core] verbatim match ===
if [[ "${NAMED_PROFILE_IMPLIED[core]:-}" == "LLM_PROVIDER=vllm ENABLE_LITELLM=true" ]]; then
    _ok "NAMED_PROFILE_IMPLIED[core] verbatim match"
else
    _fail "NAMED_PROFILE_IMPLIED[core] mismatch -- got '${NAMED_PROFILE_IMPLIED[core]:-}'"
fi

# === A19: SERVICE_GROUPS[dify] contains core Dify services ===
dify_svcs="${SERVICE_GROUPS[dify]:-}"
missing=()
for svc in api worker web sandbox; do
    if [[ "$dify_svcs" != *"$svc"* ]]; then
        missing+=("$svc")
    fi
done
if [[ "$dify_svcs" != *"plugin-daemon"* && "$dify_svcs" != *"plugin_daemon"* ]]; then
    missing+=("plugin-daemon|plugin_daemon")
fi
if [[ ${#missing[@]} -eq 0 ]]; then
    _ok "SERVICE_GROUPS[dify] contains all Dify services"
else
    _fail "SERVICE_GROUPS[dify] missing: ${missing[*]} -- actual: $dify_svcs"
fi

# === A20: NAMED_PROFILE_EXPANSION keys exact set ===
expected_keys="agents core dev full observability rag ragflow security"
actual_keys=$(echo "${!NAMED_PROFILE_EXPANSION[@]}" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
if [[ "$actual_keys" == "$expected_keys" ]]; then
    _ok "NAMED_PROFILE_EXPANSION keys exact match: $actual_keys"
else
    _fail "NAMED_PROFILE_EXPANSION keys mismatch -- expected '$expected_keys', got '$actual_keys'"
fi

# ============================================================================
# (B) EXPANSION assertions — pass ONLY post-refactor (Blocker #1 + Warning #3)
# ============================================================================

# === B1: Backward-compat CLI aliases — Blocker #1 ===
# All 8 must be present in NAME_TO_VERSION_KEY (preserves `agmind update <name>`).
EXPECTED_ALIASES=(dify-api dify-worker dify-web postgres squid plugin-daemon openwebui tei-embed)
alias_missing=()
for alias in "${EXPECTED_ALIASES[@]}"; do
    if [[ -z "${NAME_TO_VERSION_KEY[$alias]+_}" ]]; then
        alias_missing+=("$alias")
    fi
done
if [[ ${#alias_missing[@]} -eq 0 ]]; then
    _ok "all 8 backward-compat aliases present in NAME_TO_VERSION_KEY"
else
    _fail "missing aliases (agmind update CLI breakage): ${alias_missing[*]}"
fi

# === B1b: same 8 aliases in NAME_TO_SERVICES ===
alias_missing=()
for alias in "${EXPECTED_ALIASES[@]}"; do
    if [[ -z "${NAME_TO_SERVICES[$alias]+_}" ]]; then
        alias_missing+=("$alias")
    fi
done
if [[ ${#alias_missing[@]} -eq 0 ]]; then
    _ok "all 8 backward-compat aliases present in NAME_TO_SERVICES"
else
    _fail "aliases missing from NAME_TO_SERVICES: ${alias_missing[*]}"
fi

# === B2: SERVICE_GROUPS expansion — Warning #3 ===
# Five services previously hidden from SERVICE_GROUPS now surface
# (init-containers + distroless exporters); `agmind status` ~30 -> ~35 rows.
declare -A EXPECTED_GROUP_MEMBERS=(
    [core]="redis-lock-cleaner"
    [ragflow]="ragflow_es_exporter"
    [observability]="docker-socket-proxy"
    [rag]="milvus-init"
    [optional]="k6"
)
for grp in "${!EXPECTED_GROUP_MEMBERS[@]}"; do
    expected_svc="${EXPECTED_GROUP_MEMBERS[$grp]}"
    actual_members="${SERVICE_GROUPS[$grp]:-}"
    if [[ "$actual_members" == *"$expected_svc"* ]]; then
        _ok "SERVICE_GROUPS[$grp] contains newly-visible '$expected_svc'"
    else
        _fail "SERVICE_GROUPS[$grp] missing '$expected_svc' (Warning #3 expansion) -- actual: $actual_members"
    fi
done

echo ""
echo "=== Summary: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]
