#!/usr/bin/env bash
# ============================================================================
# scripts/gsd/apply/GEN-01.sh
# Apply the GEN-01 fix: replace generate_random with length-guaranteed impl.
# Spec: docs/AGmind-Autofix-Architecture-Spec-v1.0.2.md §3.1 GEN-01
# Track: A (mechanical replacement of one function)
#
# The current `head -c 256 /dev/urandom | tr -dc | head -c $length` yields
# fewer than $length chars ~59% of the time for length=64. Replacement uses
# python3 if present, falls back to bash dd+tr loop with 100-attempt retry.
#
# Exit codes:
#   0  — fix applied; ready for verify
#   1  — pre-condition not met (function already replaced or absent)
#   2  — apply failed; backup restored
# ============================================================================
set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
AUDIT_LOG="${AUDIT_LOG:-${REPO_ROOT}/.gsd/audit.jsonl}"
mkdir -p "$(dirname "$AUDIT_LOG")"

_audit() {
    local action="$1"; shift
    printf '{"ts":"%s","finding":"GEN-01","action":"%s",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action" "$*" >> "$AUDIT_LOG"
}

TARGET="${REPO_ROOT}/lib/common.sh"
OPENWEBUI="${REPO_ROOT}/lib/openwebui.sh"

# ---------------------------------------------------------------------------
# 1. PRE-CONDITION: confirm broken signature present (function + inline dup)
# ---------------------------------------------------------------------------
echo "→ Pre-condition: confirming old broken generate_random signature..." >&2
OLD_MARKER='head -c 256 /dev/urandom | LC_ALL=C tr -dc'
if ! grep -qF "$OLD_MARKER" "$TARGET"; then
    _audit "precondition_fail" "\"reason\":\"old_marker_absent\",\"file\":\"common.sh\""
    echo "FAIL: old marker not found in lib/common.sh — function may already be replaced." >&2
    exit 1
fi
# openwebui.sh has an inline duplicate of the broken pipeline that must
# also be flipped to call generate_random — otherwise its admin_password
# remains short-length-prone after the function fix.
if ! grep -qF "$OLD_MARKER" "$OPENWEBUI"; then
    echo "→ Note: lib/openwebui.sh has no inline duplicate (already fixed or absent)." >&2
fi
_audit "precondition_ok" "\"old_marker\":true"

# ---------------------------------------------------------------------------
# 2. APPLY: replace function body via awk (multi-line)
# ---------------------------------------------------------------------------
echo "→ Applying replacement..." >&2
BACKUP="${TARGET}.gsd-bak"
BACKUP_OPENWEBUI="${OPENWEBUI}.gsd-bak"
cp "$TARGET" "$BACKUP"
cp "$OPENWEBUI" "$BACKUP_OPENWEBUI"

_rollback() {
    local reason="${1:-unspecified}"
    echo "✗ Rollback (${reason}). Restoring backups..." >&2
    [[ -f "$BACKUP" ]] && mv "$BACKUP" "$TARGET"
    [[ -f "$BACKUP_OPENWEBUI" ]] && mv "$BACKUP_OPENWEBUI" "$OPENWEBUI"
    _audit "rollback" "\"reason\":\"${reason}\""
}
trap '_rollback apply_error; exit 2' ERR

NEW_FUNC=$(cat <<'EOF'
generate_random() {
    local length="${1:-32}"
    if [[ ! "$length" =~ ^[1-9][0-9]*$ ]]; then
        log_error "generate_random: invalid length: ${length}"
        return 1
    fi

    # Prefer python3 — uses secrets module (CSPRNG, exact-length output).
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$length" <<'PY'
import secrets, string, sys
n = int(sys.argv[1])
print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n)), end='')
PY
        return $?
    fi

    # Bash-only fallback. dd reads fixed blocks; tr filters from regular file
    # (no pipe — SIGPIPE-safe under `set -o pipefail`). Retry up to 100 times
    # so `generate_random 1` doesn't false-abort on an unlucky block.
    local out="" block tmpf attempts=0
    local block_size=$(( length * 8 ))
    [[ $block_size -lt 64 ]] && block_size=64
    tmpf="$(mktemp)"
    trap 'rm -f "$tmpf"' RETURN
    while [[ ${#out} -lt $length ]]; do
        attempts=$((attempts + 1))
        if [[ $attempts -gt 100 ]]; then
            log_error "generate_random: failed to produce ${length} chars in 100 attempts"
            return 1
        fi
        dd if=/dev/urandom of="$tmpf" bs="$block_size" count=1 2>/dev/null
        block="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < "$tmpf")"
        out+="$block"
    done
    printf '%s' "${out:0:length}"
}
EOF
)

# Use awk to find function start and replace until matching closing brace.
# State machine: in_func toggled on detection, emit only outside replacement region.
awk -v new_body="$NEW_FUNC" '
    BEGIN { skip = 0 }
    /^generate_random\(\) \{/ {
        print new_body
        skip = 1
        next
    }
    skip == 1 {
        if ($0 == "}") {
            skip = 0
        }
        next
    }
    { print }
' "$BACKUP" > "$TARGET"

# Replace the inline duplicate in lib/openwebui.sh with a call to the (now
# fixed) generate_random helper. Length 16 preserves original behavior.
perl -i -pe \
    's{admin_password="\$\(head -c 256 /dev/urandom \| LC_ALL=C tr -dc '\''a-zA-Z0-9'\'' \| head -c 16\)"}{admin_password="\$(generate_random 16)"}g' \
    "$OPENWEBUI"

trap - ERR

# ---------------------------------------------------------------------------
# 3. POST-CONDITION: new function present, old marker gone, single definition
# ---------------------------------------------------------------------------
echo "→ Post-condition: verifying replacement..." >&2

if grep -qF "$OLD_MARKER" "$TARGET"; then
    _audit "postcondition_fail" "\"reason\":\"old_marker_in_common\""
    _rollback postcondition_old_in_common
    exit 2
fi
if grep -qF "$OLD_MARKER" "$OPENWEBUI"; then
    _audit "postcondition_fail" "\"reason\":\"old_marker_in_openwebui\""
    _rollback postcondition_old_in_openwebui
    exit 2
fi

if ! grep -qF 'import secrets, string, sys' "$TARGET"; then
    _audit "postcondition_fail" "\"reason\":\"new_python_marker_absent\""
    _rollback postcondition_new_absent
    exit 2
fi

DEFS="$(grep -cE '^generate_random\(\) \{' "$TARGET")"
if [[ "$DEFS" -ne 1 ]]; then
    _audit "postcondition_fail" "\"reason\":\"def_count\",\"count\":${DEFS}"
    _rollback postcondition_def_count
    exit 2
fi

# Bash syntax check
if ! bash -n "$TARGET"; then
    _audit "postcondition_fail" "\"reason\":\"bash_syntax\""
    _rollback postcondition_bash_syntax
    exit 2
fi

rm -f "$BACKUP" "$BACKUP_OPENWEBUI"
_audit "postcondition_ok" "\"def_count\":1,\"openwebui_inline_fixed\":true"
echo "✓ GEN-01 applied: generate_random replaced (python3 primary, bash dd-retry fallback)." >&2
echo "  Next: scripts/gsd/verify/GEN-01.sh" >&2
exit 0
