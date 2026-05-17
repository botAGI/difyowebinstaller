#!/usr/bin/env bash
# tests/unit/test_registry_api.sh — REG-02 coverage.
#
# Asserts lib/registry.sh public API:
#   1. Smoke: reg_list_services returns sorted 50 entries
#   2. Output is sorted
#   3. Known service: reg_get_profiles vllm == "vllm"
#   4. Always-on: reg_get_profiles api == ""
#   5. Distroless: reg_get_healthcheck loki == "distroless-no-health"
#   6. Group lookup: reg_get_group vllm == "llm"
#   7. Unknown service: reg_get_profiles bogus_xyz exits 1
#   8. Empty arg: reg_get_profiles "" exits 1
#   9. Double-source guard: source twice, succeeds
#  10. Backend cache: REG_BACKEND populated after first call
#  11. PyYAML fallback via clean PATH: hide yq, auto-detect falls back to python
#  11b. PyYAML branch via explicit REG_BACKEND=python override (Warning #5):
#       proves Python heredoc path is executable independent of host yq state
#
# Exit: 0 = all pass, 1 = any fail, 77 = SKIP (neither backend present).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

echo "## test_registry_api"

if ! python3 -c "import yaml" 2>/dev/null && ! command -v yq >/dev/null 2>&1; then
    echo "  SKIP: neither yq nor python3+PyYAML available"
    exit 77
fi

pass=0
fail=0
_ok()   { echo "  ok: $*"; pass=$((pass+1)); }
_fail() { echo "  FAIL: $*"; fail=$((fail+1)); }

# Sanity: required files exist
[[ -f "$REPO_ROOT/lib/registry.sh" ]] || { _fail "lib/registry.sh missing"; exit 1; }
[[ -f "$REPO_ROOT/templates/services/registry.yaml" ]] || { _fail "templates/services/registry.yaml missing"; exit 1; }

# Test 1-10: with whatever backend is available
# shellcheck source=../../lib/registry.sh
source "$REPO_ROOT/lib/registry.sh"

# Test 1: Smoke — reg_list_services emits 50 lines
n=$(reg_list_services | wc -l | tr -d ' ')
if [[ "$n" == "50" ]]; then
    _ok "reg_list_services emits 50 lines"
else
    _fail "reg_list_services emits $n lines (expected 50)"
fi

# Test 2: Output is sorted
sorted_check=$(reg_list_services | sort -c 2>&1)
if [[ -z "$sorted_check" ]]; then
    _ok "reg_list_services output is sorted"
else
    _fail "reg_list_services output not sorted: $sorted_check"
fi

# Test 3: Known service profile
p=$(reg_get_profiles vllm)
if [[ "$p" == "vllm" ]]; then
    _ok "reg_get_profiles vllm == 'vllm'"
else
    _fail "reg_get_profiles vllm == '$p' (expected 'vllm')"
fi

# Test 4: Always-on (empty profile list)
p=$(reg_get_profiles api)
if [[ -z "$p" ]]; then
    _ok "reg_get_profiles api is empty (always-on)"
else
    _fail "reg_get_profiles api == '$p' (expected empty)"
fi

# Test 5: Distroless healthcheck enum
hc=$(reg_get_healthcheck loki)
if [[ "$hc" == "distroless-no-health" ]]; then
    _ok "reg_get_healthcheck loki == 'distroless-no-health'"
else
    _fail "reg_get_healthcheck loki == '$hc' (expected 'distroless-no-health')"
fi

# Test 6: Group lookup
g=$(reg_get_group vllm)
if [[ "$g" == "llm" ]]; then
    _ok "reg_get_group vllm == 'llm'"
else
    _fail "reg_get_group vllm == '$g' (expected 'llm')"
fi

# Test 7: Unknown service returns 1
set +e
reg_get_profiles bogus_xyz 2>/dev/null
rc=$?
set -e
if [[ "$rc" == "1" ]]; then
    _ok "reg_get_profiles bogus_xyz exits 1"
else
    _fail "reg_get_profiles bogus_xyz exit code $rc (expected 1)"
fi

# Test 8: Empty arg returns 1
set +e
reg_get_profiles "" 2>/dev/null
rc=$?
set -e
if [[ "$rc" == "1" ]]; then
    _ok "reg_get_profiles '' exits 1"
else
    _fail "reg_get_profiles '' exit code $rc (expected 1)"
fi

# Test 9: Double-source guard (no error on second source)
if (source "$REPO_ROOT/lib/registry.sh") 2>&1 | grep -q ERROR; then
    _fail "double-source emits ERROR"
else
    _ok "double-source guard works"
fi

# Test 10: Backend cache populated
if [[ -n "$REG_BACKEND" ]]; then
    _ok "REG_BACKEND is set: $REG_BACKEND"
else
    _fail "REG_BACKEND should be populated after API call"
fi

# Test 11: PyYAML fallback via clean PATH — hides yq from auto-detection.
# This proves _reg_load's yq-absent code path falls through to python.
# Caveat: on hosts where yq isn't installed anywhere, this trivially executes
# the python branch without actually exercising the "yq is rejected" logic.
# Test 11b below covers the explicit-override path independent of host state.
if python3 -c "import yaml" 2>/dev/null; then
    out=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" bash -c "
        cd '$REPO_ROOT'
        unset REG_BACKEND _REGISTRY_LOADED
        source lib/registry.sh
        reg_get_profiles vllm
        reg_get_healthcheck loki
        echo \"BACKEND=\$REG_BACKEND\"
    " 2>&1)
    if echo "$out" | grep -q 'BACKEND=python' && echo "$out" | grep -q '^vllm$' && echo "$out" | grep -q 'distroless-no-health'; then
        _ok "PyYAML fallback works (forced via clean PATH)"
    else
        _fail "PyYAML fallback failed. Output: $out"
    fi
else
    echo "  skip: PyYAML fallback test (PyYAML missing — but should never happen on AGmind hosts)"
fi

# Test 11b: Explicit PyYAML backend via REG_BACKEND override (Warning #5).
# Proves Python branch executes correctly REGARDLESS of yq presence on the
# host. Test 11 only proves "if yq is absent, python is chosen"; 11b proves
# "the python heredoc actually produces the right output". On dev boxes with
# no yq installed, Test 11 trivially exercises python; on CI runners that
# do install mikefarah yq, Test 11 may never hit the python branch — 11b is
# the deterministic guarantee.
if python3 -c "import yaml" 2>/dev/null; then
    out=$(bash -c "
        cd '$REPO_ROOT'
        unset _REGISTRY_LOADED
        export REG_BACKEND=python
        source lib/registry.sh
        echo \"BACKEND=\$REG_BACKEND\"
        reg_get_profiles vllm
        reg_get_healthcheck loki
        reg_get_group vllm
    " 2>&1)
    if echo "$out" | grep -q 'BACKEND=python' \
        && echo "$out" | grep -q '^vllm$' \
        && echo "$out" | grep -q 'distroless-no-health' \
        && echo "$out" | grep -q '^llm$'; then
        _ok "PyYAML backend produces correct output via explicit REG_BACKEND=python override"
    else
        _fail "PyYAML backend override failed. Output: $out"
    fi
else
    echo "  skip: PyYAML explicit override test (PyYAML missing)"
fi

echo ""
echo "=== Summary: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]
