#!/usr/bin/env bash
# tests/compose/test_lib_scripts_parity.sh — DUP-04/05 CI gate.
#
# Parses docs/lib-scripts-pairs.md markdown table (DUP-02 inventory) and
# enforces per-row contract:
#   - type=symlink:            [[ -L scripts/X.sh ]] AND readlink == ../lib/X.sh
#   - type=byte-identical-copy: diff -q lib/X.sh scripts/X.sh exits 0
#   - type=justified-divergence: both files exist (no content check)
#
# Auto-discovered by tests/run_all.sh `compose:` lane (Phase 12 wired
# the `for t in tests/compose/*.sh; do ...` glob).
#
# Exit: 0 = parity holds, 1 = drift detected, 77 = SKIP (inventory missing).
#
# Adversarial validation (run during Plan 14-07 Task 3, verified passing):
#   1. Convert scripts/health.sh to regular file:
#        cp -L scripts/health.sh /tmp/h.sh && mv /tmp/h.sh scripts/health.sh
#      -> test rc=1 with "FAIL: scripts/health.sh expected symlink"
#   2. Restore: rm scripts/health.sh && ln -s ../lib/health.sh scripts/health.sh
#      -> test rc=0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INVENTORY="${REPO_ROOT}/docs/lib-scripts-pairs.md"

echo "## test_lib_scripts_parity"

if [[ ! -f "$INVENTORY" ]]; then
    echo "  SKIP: $INVENTORY missing — DUP-02 inventory not authored yet"
    exit 77
fi

fail=0
ok_count=0
_fail() { echo "  FAIL: $*"; fail=1; }
_ok()   { echo "  ok: $*"; ok_count=$((ok_count + 1)); }

# Trim leading/trailing whitespace from a string.
_trim() {
    local v="$1"
    # shellcheck disable=SC2001
    v="$(echo "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    echo "$v"
}

# Parse markdown table. Strategy: find lines starting with `|`, skip the header
# and separator rows, parse remaining as data rows. Columns are:
#   1: lib path (e.g., "lib/health.sh")
#   2: scripts path (e.g., "scripts/health.sh")
#   3: type (symlink / byte-identical-copy / justified-divergence)
#   4: rationale (free text — not validated)
#   5: enforced_by_test (free text — not validated)

rows_seen=0
data_rows=0

while IFS= read -r line; do
    rows_seen=$((rows_seen + 1))

    # Skip header (contains "lib" + "scripts" as words, no path prefix)
    if [[ "$line" == *"| lib |"* ]] || [[ "$line" == *"| lib|"* ]]; then
        continue
    fi
    # Skip separator row (pipes + dashes only)
    if [[ "$line" =~ ^\|[[:space:]\|-]+\|[[:space:]]*$ ]]; then
        continue
    fi

    # Split into fields. Strip leading/trailing |.
    stripped="${line#|}"
    stripped="${stripped%|}"

    # Use IFS='|' to split (each field is separated by literal `|` chars)
    IFS='|' read -r -a fields <<<"$stripped"

    if [[ ${#fields[@]} -lt 3 ]]; then
        # Not a data row (probably text or malformed)
        continue
    fi

    lib_path="$(_trim "${fields[0]}")"
    scripts_path="$(_trim "${fields[1]}")"
    pair_type="$(_trim "${fields[2]}")"

    # Must be a lib/X.sh row (filters out any non-inventory pipes)
    if [[ "$lib_path" != lib/*.sh ]]; then
        continue
    fi
    if [[ "$scripts_path" != scripts/*.sh ]]; then
        _fail "row has lib_path=$lib_path but scripts_path=$scripts_path does not look like scripts/X.sh"
        continue
    fi

    data_rows=$((data_rows + 1))

    abs_lib="${REPO_ROOT}/${lib_path}"
    abs_scripts="${REPO_ROOT}/${scripts_path}"

    if [[ ! -f "$abs_lib" ]]; then
        _fail "row $lib_path ↔ $scripts_path: lib file does not exist ($abs_lib)"
        continue
    fi
    # For symlink rows we must NOT call -f on scripts_path before symlink check
    # (-f follows the symlink — would still pass for a valid symlink, but order
    # matters for the error message). Check existence in a way that works for
    # both symlinks and regular files.
    if [[ ! -e "$abs_scripts" ]] && [[ ! -L "$abs_scripts" ]]; then
        _fail "row $lib_path ↔ $scripts_path: scripts file does not exist ($abs_scripts)"
        continue
    fi

    case "$pair_type" in
        symlink)
            if [[ ! -L "$abs_scripts" ]]; then
                _fail "$scripts_path expected symlink (type=$pair_type) but is a regular file"
                continue
            fi
            target="$(readlink "$abs_scripts")"
            expected_basename="$(basename "$lib_path")"
            expected_target="../lib/${expected_basename}"
            if [[ "$target" != "$expected_target" ]]; then
                _fail "$scripts_path symlink target=$target, expected $expected_target"
                continue
            fi
            _ok "$lib_path ↔ $scripts_path (symlink → $target)"
            ;;
        byte-identical-copy)
            if [[ -L "$abs_scripts" ]]; then
                _fail "$scripts_path expected byte-identical-copy (type=$pair_type) but is a symlink"
                continue
            fi
            if ! diff -q "$abs_lib" "$abs_scripts" >/dev/null 2>&1; then
                _fail "$lib_path ↔ $scripts_path: byte-identical-copy contract violated (diff -q non-zero)"
                continue
            fi
            _ok "$lib_path ↔ $scripts_path (byte-identical-copy)"
            ;;
        justified-divergence)
            # Both files must exist (already verified above); no content check.
            _ok "$lib_path ↔ $scripts_path (justified-divergence — both exist)"
            ;;
        *)
            _fail "$lib_path ↔ $scripts_path: unknown pair_type='$pair_type' (expected: symlink | byte-identical-copy | justified-divergence)"
            ;;
    esac
done < <(grep -E '^\|' "$INVENTORY" || true)

if [[ $data_rows -eq 0 ]]; then
    _fail "no data rows parsed from $INVENTORY — inventory format may be broken or empty"
fi

echo
if [[ $fail -ne 0 ]]; then
    echo "## test_lib_scripts_parity: FAIL ($data_rows rows, $ok_count ok, drift detected)"
    exit 1
fi
echo "## test_lib_scripts_parity: PASS ($data_rows rows, all consistent with on-disk state)"
exit 0
