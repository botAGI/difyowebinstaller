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
    bash -c '
        # tests/mocks/ may contain non-bash artifacts (README.md inventory doc per
        # Phase 13 TEST-08). Glob only files that look like bash sources: those
        # carrying a shebang line OR with .sh extension.
        mock_targets=()
        for f in tests/mocks/*; do
            [[ -f "$f" ]] || continue
            case "$f" in
                *.md) continue ;;
            esac
            if [[ "$f" == *.sh ]] || head -n1 "$f" 2>/dev/null | grep -q "^#!.*\(bash\|sh\)\b"; then
                mock_targets+=("$f")
            fi
        done
        shellcheck -S warning tests/unit/*.sh tests/integration/*.sh "${mock_targets[@]}" tests/run_all.sh
    '

# ── unit tests ────────────────────────────────────────────────────────────────
for t in tests/unit/*.sh; do
    [[ -x "$t" ]] || continue
    _run "unit: $t" bash "$t"
done

# ── lint tests ────────────────────────────────────────────────────────────────
for t in tests/lint/*.sh; do
    [[ -x "$t" ]] || continue
    _run "lint: $t" bash "$t"
done

# ── compose tests (hermetic — pure YAML, no docker daemon) ────────────────────
for t in tests/compose/*.sh; do
    [[ -x "$t" ]] || continue
    _run "compose: $t" bash "$t"
done

# ── integration tests ─────────────────────────────────────────────────────────
for t in tests/integration/*.sh; do
    [[ -x "$t" ]] || continue
    _run "integration: $t" bash "$t"
done

# ── golden tests (smoke только — full --all лежит в CI matrix; локально не таймаутим) ──
if [[ -x tests/golden/run.sh ]]; then
    _run "golden: minimal_lan smoke" bash tests/golden/run.sh minimal_lan
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}================================${NC}"
echo -e "  PASS: ${pass}   SKIP: ${skip}   FAIL: ${fail}"
echo -e "${BOLD}================================${NC}"
[[ $fail -eq 0 ]]
