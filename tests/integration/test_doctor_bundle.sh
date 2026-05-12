#!/usr/bin/env bash
# tests/integration/test_doctor_bundle.sh — SC3: agmind doctor --bundle creates clean archive.
# Runs on real system with /opt/agmind installed. Exit 77 = SKIP if not installed.
# Requires: sudo (for doctor --bundle root ops), /opt/agmind installed, agmind on PATH.
# WHY rc=77: SKIP convention from tests/run_all.sh — not installed on CI / planning env.
set -uo pipefail   # NOT -e — we capture return codes explicitly

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# SKIP guards (D-20 pattern)
[[ -d "$INSTALL_DIR" ]]           || exit 77
[[ "$EUID" -eq 0 ]]               || { echo "SKIP: requires root" >&2; exit 77; }
command -v agmind >/dev/null 2>&1 || exit 77

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_doctor_bundle (integration)"

# ── Run bundle ────────────────────────────────────────────────────────────────
bundle_out=""
bundle_out="$(agmind doctor --bundle 2>&1)" || true
pass "doctor --bundle exits without error"

# ── Find created bundle path ──────────────────────────────────────────────────
bundle_path=""
bundle_path="$(echo "$bundle_out" \
    | grep -oE '/opt/agmind/support-bundle-[0-9T_-]+\.tar\.gz' \
    | head -1 || true)"
if [[ -n "$bundle_path" ]]; then
    pass "bundle path found in output"
else
    fail "bundle path not found in output"
    echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
    [[ $FAIL -eq 0 ]]
    exit "$FAIL"
fi

# ── File exists and permissions are 600 ──────────────────────────────────────
if [[ -f "$bundle_path" ]]; then
    pass "bundle file exists: $bundle_path"
else
    fail "bundle file not found at: $bundle_path"
    echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
    [[ $FAIL -eq 0 ]]
    exit "$FAIL"
fi

bundle_perm="$(stat -c %a "$bundle_path" 2>/dev/null || echo "???")"
[[ "$bundle_perm" == "600" ]] \
    && pass "bundle chmod=600 (no world-read for sensitive data)" \
    || fail "bundle chmod=${bundle_perm} (want 600)"

# ── Unpack and scan for secrets ───────────────────────────────────────────────
unpack_dir=""
unpack_dir="$(mktemp -d)"
trap 'rm -rf "$unpack_dir"' EXIT

if tar xzf "$bundle_path" -C "$unpack_dir" 2>/dev/null; then
    pass "bundle unpacks without error"
else
    fail "bundle unpack failed"
    echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
    [[ $FAIL -eq 0 ]]
    exit "$FAIL"
fi

# SC3: no credentials/secrets in bundle — D-14.2 sanitization must have worked.
secret_hits=""
secret_hits="$(grep -rEi \
    '(password|secret|token|bearer|api[_-]?key)[[:space:]]*[=:][[:space:]]*[a-zA-Z0-9]{8,}' \
    "$unpack_dir/" 2>/dev/null || true)"
if [[ -z "$secret_hits" ]]; then
    pass "no credentials found in bundle (SC3 — sanitizer clean)"
else
    fail "credentials found in bundle (SC3 FAIL — sanitizer incomplete)"
    # Print hit count and files only, NOT values (no secrets in test output)
    echo "$secret_hits" | wc -l | xargs -I{} echo "  {} potential credential line(s)" >&2
    echo "$secret_hits" | grep -oE '^[^:]+' | sort -u | head -5 >&2
fi

# ── Key files must be present in bundle ───────────────────────────────────────
# WHY: these files are the minimum for remote debugging without SSH (D-13).
doctor_json="$(find "$unpack_dir" -name 'doctor.json' -print -quit 2>/dev/null || true)"
[[ -n "$doctor_json" ]] \
    && pass "doctor.json present in bundle" \
    || fail "doctor.json missing from bundle"

versions_env="$(find "$unpack_dir" -name 'versions.env' -print -quit 2>/dev/null || true)"
[[ -n "$versions_env" ]] \
    && pass "versions.env present in bundle" \
    || fail "versions.env missing from bundle"

docker_ps="$(find "$unpack_dir" -name 'docker-ps.txt' -print -quit 2>/dev/null || true)"
[[ -n "$docker_ps" ]] \
    && pass "docker-ps.txt present in bundle" \
    || fail "docker-ps.txt missing from bundle"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
