#!/usr/bin/env bash
# ============================================================================
# scripts/gsd/apply/HEALTH-01.sh
# Fix HEALTH-01: `grep -qi "up\|healthy"` matches "Up X (unhealthy)" as OK.
# Spec: §3.1 HEALTH-01. Track: A.
#
# Locations (byte-identical duplicate in lib/ and scripts/):
#   lib/health.sh + scripts/health.sh — three sites each:
#     - check_container         (grep -qi "up\|healthy")
#     - wait_healthy Phase 1    (! grep -qi "up\|healthy")
#     - wait_healthy Phase 2    (grep -qi "up\|starting")
#
# Replacement: switch from string-match on `docker ps` Status column to
# `docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}
# {{.State.Status}}{{end}}'` which yields disambiguated healthy/unhealthy/
# starting/running etc. and treat each enum value distinctly.
#
# Exit: 0 ok, 1 pre-condition fail, 2 apply fail (rolled back).
# ============================================================================
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
AUDIT_LOG="${AUDIT_LOG:-${REPO_ROOT}/.gsd/audit.jsonl}"
mkdir -p "$(dirname "$AUDIT_LOG")"
_audit() {
    local a="$1"; shift
    printf '{"ts":"%s","finding":"HEALTH-01","action":"%s",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$a" "$*" >> "$AUDIT_LOG"
}

LIB="${REPO_ROOT}/lib/health.sh"
SCR="${REPO_ROOT}/scripts/health.sh"

# ---------------------------------------------------------------------------
# 1. PRE-CONDITION
# ---------------------------------------------------------------------------
echo "→ Pre-condition: lib/scripts byte-identical + 3 occurrences each..." >&2
if ! diff -q "$LIB" "$SCR" >/dev/null; then
    _audit "precondition_fail" "\"reason\":\"lib_scripts_differ\""
    echo "FAIL: lib/health.sh and scripts/health.sh diverged — manual reconciliation needed." >&2
    exit 1
fi
lib_count=$(grep -cE 'grep -qi "up\\\|healthy"' "$LIB" || true)
scr_count=$(grep -cE 'grep -qi "up\\\|healthy"' "$SCR" || true)
if [[ "$lib_count" -ne 2 || "$scr_count" -ne 2 ]]; then
    _audit "precondition_fail" "\"reason\":\"count_mismatch\",\"lib\":${lib_count},\"scr\":${scr_count}"
    echo "FAIL: expected 2 'up|healthy' occurrences each, got lib=${lib_count} scr=${scr_count}." >&2
    exit 1
fi
phase2_count=$(grep -cE 'grep -qi "up\\\|starting"' "$LIB" || true)
if [[ "$phase2_count" -ne 1 ]]; then
    _audit "precondition_fail" "\"reason\":\"phase2_count\",\"count\":${phase2_count}"
    echo "FAIL: expected 1 'up|starting' occurrence in lib/health.sh, got ${phase2_count}." >&2
    exit 1
fi
_audit "precondition_ok" "\"identical\":true,\"sites\":3"

# ---------------------------------------------------------------------------
# 2. APPLY
# ---------------------------------------------------------------------------
echo "→ Applying replacement to lib/health.sh + scripts/health.sh..." >&2

BACKUPS=("${LIB}.gsd-bak" "${SCR}.gsd-bak")
cp "$LIB" "${LIB}.gsd-bak"
cp "$SCR" "${SCR}.gsd-bak"

_rollback() {
    local r="${1:-unspecified}"
    echo "✗ Rollback (${r})." >&2
    for b in "${BACKUPS[@]}"; do
        [[ -f "$b" ]] && mv "$b" "${b%.gsd-bak}"
    done
    _audit "rollback" "\"reason\":\"${r}\""
}
trap '_rollback apply_error; exit 2' ERR

_patch_one() {
    local f="$1"
    # Replace check_container body — the status block is line-uniform across
    # both files (validated byte-identical above), so a perl slurp on the
    # exact 3-line conditional swap is safe.
    perl -i -0777 -pe '
        s{
            \n    \# Exact name match to avoid confusion with init-containers \(BUG-V3-039\)\n
            .*?
            \n    local status\n
            \s*status=\"\$\(docker ps -a --filter \"name=\^agmind-\$\{cname\}\$\" --format \x27\{\{\.Status\}\}\x27 2>/dev/null \| head -1\)\"\n
            \s*if \[\[ -z \"\$status\" \]\]; then status=\"not found\"; fi\n
            \n
            \s*if echo \"\$status\" \| grep -qi \"up\\\\\|healthy\"; then\n
            \s*echo -e \"  \$\{GREEN\}\[OK\]\$\{NC\}  \$\{name\}\"\n
            \s*return 0\n
            \s*elif echo \"\$status\" \| grep -qi \"starting\"; then\n
            \s*echo -e \"  \$\{YELLOW\}\[\.\.\]\$\{NC\}  \$\{name\} \(starting\)\"\n
            \s*return 1\n
            \s*else\n
            \s*echo -e \"  \$\{RED\}\[!!\]\$\{NC\}  \$\{name\} \(\$\{status\}\)\"\n
            \s*return 1\n
            \s*fi\n
        }
        {
\n    # HEALTH-01: distinguish healthy from unhealthy via docker inspect.
    # The Status column of `docker ps` ("Up 5 minutes (unhealthy)") matches
    # `grep -qi "up\\|healthy"` and gives false-OK for unhealthy containers.
    local state
    state=\"\$(docker inspect -f \x27{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}\x27 \"agmind-\$\{cname\}\" 2>/dev/null || echo not-found)\"
    case \"\$state\" in
        healthy|running)
            echo -e \"  \$\{GREEN\}[OK]\$\{NC\}  \$\{name\}\"; return 0 ;;
        starting|created|restarting)
            echo -e \"  \$\{YELLOW\}[..]\$\{NC\}  \$\{name\} (\$\{state\})\"; return 1 ;;
        unhealthy|exited|dead|paused|removing|not-found)
            echo -e \"  \$\{RED\}[!!]\$\{NC\}  \$\{name\} (\$\{state\})\"; return 1 ;;
        *)
            echo -e \"  \$\{RED\}[!!]\$\{NC\}  \$\{name\} (unknown:\$\{state\})\"; return 1 ;;
    esac
}xms;
    ' "$f"

    # Replace Phase-1 negated guard inside wait_healthy.
    perl -i -pe '
        s{
            if \! echo \"\$status\" \| grep -qi \"up\\\\\|healthy\"; then
        }{
            # HEALTH-01: check via inspect, distinguishing unhealthy from running.
            local _state
            _state=\"\$(docker inspect -f \x27{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}\x27 \"\$(docker compose -f \"\$compose_file\" ps -q \"\$svc\" 2>/dev/null | head -1)\" 2>/dev/null || echo not-found)\"
            if [[ \"\$_state\" != \"healthy\" \&\& \"\$_state\" != \"running\" ]]; then
        }gx;
    ' "$f"

    # Replace Phase-2 still-loading guard inside wait_healthy.
    perl -i -pe '
        s{
            if echo \"\$status\" \| grep -qi \"up\\\\\|starting\"; then
        }{
            # HEALTH-01: GPU still-loading check via inspect (running/starting/healthy = still alive).
            local _gstate
            _gstate=\"\$(docker inspect -f \x27{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}\x27 \"\$(docker compose -f \"\$compose_file\" ps -q \"\$svc\" 2>/dev/null | head -1)\" 2>/dev/null || echo not-found)\"
            if [[ \"\$_gstate\" == \"running\" || \"\$_gstate\" == \"starting\" || \"\$_gstate\" == \"healthy\" ]]; then
        }gx;
    ' "$f"
}

_patch_one "$LIB"
_patch_one "$SCR"

trap - ERR

# ---------------------------------------------------------------------------
# 3. POST-CONDITION
# ---------------------------------------------------------------------------
echo "→ Post-condition: stale grep gone, files still byte-identical, bash -n OK..." >&2

# Stale pattern gone
if grep -rE 'grep -qi "up\\\|healthy"' "$LIB" "$SCR" >/dev/null 2>&1; then
    _audit "postcondition_fail" "\"reason\":\"stale_up_healthy\""
    _rollback postcondition_stale_up_healthy
    exit 2
fi
if grep -rE 'grep -qi "up\\\|starting"' "$LIB" "$SCR" >/dev/null 2>&1; then
    _audit "postcondition_fail" "\"reason\":\"stale_up_starting\""
    _rollback postcondition_stale_up_starting
    exit 2
fi

# New marker present
if ! grep -qF 'HEALTH-01: distinguish' "$LIB"; then
    _audit "postcondition_fail" "\"reason\":\"new_marker_absent_lib\""
    _rollback postcondition_no_marker_lib
    exit 2
fi
if ! grep -qF 'HEALTH-01: distinguish' "$SCR"; then
    _audit "postcondition_fail" "\"reason\":\"new_marker_absent_scr\""
    _rollback postcondition_no_marker_scr
    exit 2
fi

# Byte-identical preserved
if ! diff -q "$LIB" "$SCR" >/dev/null; then
    _audit "postcondition_fail" "\"reason\":\"divergence\""
    _rollback postcondition_divergence
    exit 2
fi

# Bash syntax
if ! bash -n "$LIB" || ! bash -n "$SCR"; then
    _audit "postcondition_fail" "\"reason\":\"bash_syntax\""
    _rollback postcondition_bash_syntax
    exit 2
fi

rm -f "${LIB}.gsd-bak" "${SCR}.gsd-bak"
_audit "postcondition_ok" "\"files\":2"
echo "✓ HEALTH-01 applied: lib/scripts health.sh both updated, byte-identical." >&2
echo "  Next: scripts/gsd/verify/HEALTH-01.sh" >&2
exit 0
