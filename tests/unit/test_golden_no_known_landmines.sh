#!/usr/bin/env bash
# tests/unit/test_golden_no_known_landmines.sh
# Phase 13 D-12 enforcer: parse tests/lint/LANDMINES.tsv, grep -E each pattern
# against tests/golden/expected/<scenario>/<file>; severity=critical → exit 1;
# severity=warning → log_warn + continue.
#
# Special-case L08 (NVIDIA caps): match `runtime: nvidia` THEN verify
# NVIDIA_DRIVER_CAPABILITIES присутствует в [N..N+30] context window;
# if missing → flag warning.
#
# Distroless healthcheck rule NOT enforced here — delegated to existing
# tests/unit/test_distroless_no_healthcheck.sh (multi-line AST parsing).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to $REPO_ROOT" >&2; exit 1; }

TSV="tests/lint/LANDMINES.tsv"
EXPECTED_ROOT="tests/golden/expected"

# Graceful SKIP if Plan 13-02 expected/ not bootstrapped yet
if [[ ! -d "$EXPECTED_ROOT" ]] || [[ -z "$(ls -A "$EXPECTED_ROOT" 2>/dev/null)" ]]; then
    echo "SKIP: $EXPECTED_ROOT empty or missing (Plan 13-02 prerequisite)"
    exit 77
fi
if [[ ! -f "$TSV" ]]; then
    echo "SKIP: $TSV missing (Plan 13-03 Task 1 prerequisite)"
    exit 77
fi

# Colors only when stdout is a TTY (CI logs stay clean)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; NC=''
fi

fail=0
warnings=0
scanned=0
matched=0

# L08 post-match context check.
# For each `runtime: nvidia` line N в файле — проверить, что в окне [N..N+30]
# присутствует `NVIDIA_DRIVER_CAPABILITIES`. Если нет — emit `LINE` (warning).
_check_l08_context() {
    local file="$1"
    grep -nE 'runtime:[[:space:]]+nvidia' "$file" 2>/dev/null | while IFS=: read -r line_num _; do
        local end=$((line_num + 30))
        if ! awk -v s="$line_num" -v e="$end" 'NR>=s && NR<=e' "$file" \
             | grep -q 'NVIDIA_DRIVER_CAPABILITIES'; then
            echo "L08-MISS:$file:$line_num"
        fi
    done
}

# Pre-collect rendered file paths grouped by basename for fast glob match.
mapfile -t ALL_RENDERED < <(find "$EXPECTED_ROOT" -type f \
    \( -name '*.rendered.yml' -o -name '*.rendered' -o -name 'nginx.conf' \
       -o -name '*.yml' -o -name '*.yaml' -o -name '*.river' \
       -o -name '*.conf' -o -name '.env.rendered' \))

# Iterate TSV (skip header + empty lines).
# `introduced` is unpacked for documentation / future use even if currently unused.
# shellcheck disable=SC2034
while IFS=$'\t' read -r id pattern file_glob severity anchor rationale introduced; do
    [[ -z "${id:-}" ]] && continue
    [[ "${id,,}" == "id" ]] && continue
    [[ "${id:0:1}" == "#" ]] && continue

    # Resolve candidate files for this landmine.
    if [[ "$file_glob" == "*" ]]; then
        targets=("${ALL_RENDERED[@]}")
    else
        targets=()
        for f in "${ALL_RENDERED[@]}"; do
            if [[ "$(basename "$f")" == "$file_glob" ]]; then
                targets+=("$f")
            fi
        done
    fi

    for rendered in "${targets[@]}"; do
        scanned=$((scanned + 1))

        if [[ "$id" == "L08" ]]; then
            # post-match context check
            misses="$(_check_l08_context "$rendered")"
            if [[ -n "$misses" ]]; then
                matched=$((matched + 1))
                printf '%s' "$YELLOW" >&2
                echo "⚠ LANDMINE L08 (warning): $rendered" >&2
                printf '%s' "$NC" >&2
                echo "  anchor: $anchor" >&2
                echo "  rationale: $rationale" >&2
                echo "  context misses:" >&2
                echo "$misses" | sed 's/^/    /' >&2
                warnings=$((warnings + 1))
            fi
            continue
        fi

        if grep -qE "$pattern" "$rendered" 2>/dev/null; then
            matched=$((matched + 1))
            hits="$(grep -nE "$pattern" "$rendered" | head -3)"
            case "$severity" in
                critical)
                    printf '%s' "$RED" >&2
                    echo "✗ LANDMINE ${id} (critical): $rendered" >&2
                    printf '%s' "$NC" >&2
                    echo "  anchor: $anchor" >&2
                    echo "  rationale: $rationale" >&2
                    echo "  hits:" >&2
                    echo "$hits" | sed 's/^/    /' >&2
                    fail=$((fail + 1))
                    ;;
                warning)
                    printf '%s' "$YELLOW" >&2
                    echo "⚠ LANDMINE ${id} (warning): $rendered — $rationale" >&2
                    printf '%s' "$NC" >&2
                    warnings=$((warnings + 1))
                    ;;
                *)
                    printf '%s' "$YELLOW" >&2
                    echo "LANDMINE ${id}: unknown severity '$severity' — treated as warning" >&2
                    printf '%s' "$NC" >&2
                    warnings=$((warnings + 1))
                    ;;
            esac
        fi
    done
done < "$TSV"

echo ""
echo "Scanned ${scanned} (rendered_file × pattern) combinations, ${matched} matches: critical=${fail}, warning=${warnings}"

if [[ "$fail" -gt 0 ]]; then
    printf '%s' "$RED" >&2
    echo "FAIL: ${fail} critical landmine(s) found" >&2
    printf '%s' "$NC" >&2
    exit 1
fi
printf '%s' "$GREEN"
echo "PASS: no critical landmines in tests/golden/expected/"
printf '%s' "$NC"
exit 0
