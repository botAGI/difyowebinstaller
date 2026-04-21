#!/usr/bin/env bash
# tests/run_all.sh — one-shot local regression runner for AGmind Phase 1 mDNS fixes.
# Exit 0 = all tests PASS (SKIP is OK); exit 1 = any FAIL.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
cd "$REPO_ROOT"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

fail=0; pass=0; skip=0

_run() {
    local label="$1"; shift
    echo -e "${BOLD}==> ${label}${NC}"
    local rc=0
    "$@" || rc=$?
    case $rc in
        0)  echo -e "${GREEN}    PASS${NC}"; pass=$((pass+1)) ;;
        77) echo -e "${YELLOW}    SKIP (rc=77)${NC}"; skip=$((skip+1)) ;;
        *)  echo -e "${RED}    FAIL (rc=$rc)${NC}"; fail=$((fail+1)) ;;
    esac
    echo ""
}

# ── shellcheck gates ──────────────────────────────────────────────────────────
_run "shellcheck lib/*.sh scripts/*.sh install.sh" \
    shellcheck -S warning lib/*.sh scripts/*.sh install.sh

_run "shellcheck tests/unit/*.sh tests/integration/*.sh tests/mocks/* tests/run_all.sh" \
    bash -c 'shellcheck -S warning tests/unit/*.sh tests/integration/*.sh tests/mocks/* tests/run_all.sh'

# ── unit tests ────────────────────────────────────────────────────────────────
for t in tests/unit/*.sh; do
    [[ -x "$t" ]] || continue
    _run "unit: $t" bash "$t"
done

# ── integration tests ─────────────────────────────────────────────────────────
for t in tests/integration/*.sh; do
    [[ -x "$t" ]] || continue
    _run "integration: $t" bash "$t"
done

# ── summary ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}================================${NC}"
echo -e "  PASS: ${pass}   SKIP: ${skip}   FAIL: ${fail}"
echo -e "${BOLD}================================${NC}"
[[ $fail -eq 0 ]]
