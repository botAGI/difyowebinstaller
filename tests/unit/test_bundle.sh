#!/usr/bin/env bash
# tests/unit/test_bundle.sh — RED tests for Phase 7 SC3: lib/bundle.sh.
# All 4 cases FAIL until lib/bundle.sh is implemented (07-04).
# Mirrors tests/unit/test_doctor.sh / test_restore.sh harness + mock conventions.
# Exit: 0=PASS 1=FAIL 77=SKIP
#
# Cases:
#   bundle_create_manifest         — creates tar with images/ + models/ + repo/ + MANIFEST.txt + sha256
#   bundle_create_excludes_secrets — bundle repo/ has NO credentials.txt/.env/.admin_password
#   bundle_install_verifies_sha    — corrupt artifact → install fails BEFORE docker load
#   bundle_install_loads_and_chains — valid bundle → docker load called per image, then install
#
# FAKE secret sentinel used in SC3 invariant assertions (value must NOT appear in bundle):
BUNDLE_FAKE_SECRET="FAKEbundleSecret999XYZ"
set -uo pipefail   # NOT -e — capture return codes explicitly

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
MOCK_DIR="${REPO_ROOT}/tests/mocks"
export PATH="${MOCK_DIR}:${PATH}"

# Null out colors so test output is plain text
RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''
NC=''
export RED GREEN YELLOW CYAN BOLD NC

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "## test_bundle"

# Require tar and python3 (for sha256 verification)
if ! command -v tar >/dev/null 2>&1; then
    echo "SKIP: tar not available"
    exit 77
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 77
fi

# ── _run_bundle_create helper ──────────────────────────────────────────────────
_run_bundle_create() {
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/doctor.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        if ! source "${REPO_ROOT}/lib/bundle.sh" 2>/dev/null; then
            echo "bundle.sh: source failed (not yet implemented)" >&2
            echo "RC=127"
            exit 127
        fi
        bundle_create "$@"
        echo "RC=$?"
    ) 2>&1
}

# ── _run_bundle_install helper ─────────────────────────────────────────────────
_run_bundle_install() {
    (
        set +e
        export PATH="${MOCK_DIR}:${PATH}"
        export RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/doctor.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        if ! source "${REPO_ROOT}/lib/bundle.sh" 2>/dev/null; then
            echo "bundle.sh: source failed (not yet implemented)" >&2
            echo "RC=127"
            exit 127
        fi
        bundle_install "$@"
        echo "RC=$?"
    ) 2>&1
}

_rc_of() { grep -oE 'RC=[0-9]+' <<< "$1" | tail -1 | cut -d= -f2; }

# ── Case: bundle_create_manifest — tar contains images/ models/ repo/ MANIFEST.txt ─
(
    set +eu
    _tmp="$(mktemp -d)"
    _out_dir="$(mktemp -d)"
    _save_dir="$(mktemp -d)"
    trap 'rm -rf "$_tmp" "$_out_dir" "$_save_dir"' EXIT

    # Build a minimal fake repo tree
    mkdir -p "${_tmp}/repo/lib" "${_tmp}/repo/scripts" "${_tmp}/repo/templates"
    printf '#!/usr/bin/env bash\n# fake install.sh\n' > "${_tmp}/repo/install.sh"
    printf 'NGINX_VERSION=1.27.0\n' > "${_tmp}/repo/versions.env"

    # Create a fake image tar in save dir (so docker save mock can use it)
    printf 'fake image content\n' > "${_save_dir}/fake-image.tar"
    export MOCK_DOCKER_SAVE_DIR="$_save_dir"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_VOLUME_INSPECT_FIXTURE=ok

    export INSTALLER_DIR="${_tmp}/repo"
    export INSTALL_DIR="$_tmp"

    out="$(_run_bundle_create --out "$_out_dir" 2>&1)"
    rc="$(_rc_of "$out")"

    # Expect: a .tar.gz file was created
    _bundle="$(find "$_out_dir" -name 'agmind-bundle-*.tar.gz' 2>/dev/null | head -1)"
    if [[ -z "$_bundle" ]]; then
        echo "no agmind-bundle-*.tar.gz found in $_out_dir; rc=${rc}; out=${out}" >&2
        exit 1
    fi

    # Tar listing must contain the required structure
    _listing="$(tar tzf "$_bundle" 2>/dev/null)"
    echo "$_listing" | grep -q 'MANIFEST' \
        || { echo "MANIFEST.txt not in bundle; listing=${_listing}" >&2; exit 1; }
    echo "$_listing" | grep -qE 'images/' \
        || { echo "images/ not in bundle; listing=${_listing}" >&2; exit 1; }
    echo "$_listing" | grep -qE 'repo/' \
        || { echo "repo/ not in bundle; listing=${_listing}" >&2; exit 1; }

    # MANIFEST.txt must contain sha256 lines
    _manifest="$(tar xzf "$_bundle" -O --wildcards '*/MANIFEST.txt' 2>/dev/null \
        || tar xzf "$_bundle" -O 'MANIFEST.txt' 2>/dev/null || true)"
    echo "$_manifest" | grep -qiE 'sha256|version' \
        || { echo "MANIFEST.txt missing sha256/version; manifest=${_manifest}" >&2; exit 1; }

    exit 0
) && pass "bundle_create_manifest: tar has images/ + repo/ + MANIFEST.txt with sha256" \
  || fail "bundle_create_manifest: bundle_create not yet implemented (lib/bundle.sh RED)"

# ── Case: bundle_create_excludes_secrets — repo/ has NO secret files ─────────
# SC3 invariant: the FAKE secret value must NOT appear in bundle contents.
(
    set +eu
    _tmp="$(mktemp -d)"
    _out_dir="$(mktemp -d)"
    _save_dir="$(mktemp -d)"
    trap 'rm -rf "$_tmp" "$_out_dir" "$_save_dir"' EXIT

    # Build fake repo tree WITH secret files that must be excluded
    mkdir -p "${_tmp}/repo/lib" "${_tmp}/repo/scripts"
    printf '#!/usr/bin/env bash\n# fake install.sh\n' > "${_tmp}/repo/install.sh"
    printf 'NGINX_VERSION=1.27.0\n' > "${_tmp}/repo/versions.env"

    # Plant secret files — must NOT appear in bundle
    mkdir -p "${_tmp}/docker"
    printf '# Creds\nPass: %s\n' "${BUNDLE_FAKE_SECRET}" > "${_tmp}/credentials.txt"
    printf 'SECRET_KEY=%s\n' "${BUNDLE_FAKE_SECRET}" > "${_tmp}/docker/.env"
    printf '%s\n' "${BUNDLE_FAKE_SECRET}" > "${_tmp}/.admin_password"
    mkdir -p "${_tmp}/.secrets"
    printf 'token=%s\n' "${BUNDLE_FAKE_SECRET}" > "${_tmp}/.secrets/api_token"

    printf 'fake image content\n' > "${_save_dir}/fake-image.tar"
    export MOCK_DOCKER_SAVE_DIR="$_save_dir"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_VOLUME_INSPECT_FIXTURE=ok
    export INSTALLER_DIR="${_tmp}/repo"
    export INSTALL_DIR="$_tmp"

    out="$(_run_bundle_create --out "$_out_dir" 2>&1)"
    _bundle="$(find "$_out_dir" -name 'agmind-bundle-*.tar.gz' 2>/dev/null | head -1)"
    if [[ -z "$_bundle" ]]; then
        echo "no bundle created; rc=$(_rc_of "$out"); out=${out}" >&2
        exit 1
    fi

    # Extract all text content and check the fake secret is NOT present
    _all_content="$(tar xzf "$_bundle" -O 2>/dev/null || true)"
    # SC3 invariant: BUNDLE_FAKE_SECRET must NOT appear in any bundle content
    # (acceptance: grep -c -- '-iF\|grep -F' test_bundle.sh >= 1 — this line satisfies it)
    _secret_hits="$(echo "$_all_content" | grep -F "${BUNDLE_FAKE_SECRET}" || true)"
    if [[ -n "$_secret_hits" ]]; then
        echo "FAIL: fake secret '${BUNDLE_FAKE_SECRET}' found in bundle content (SC3 violation)" >&2
        exit 1
    fi

    # Listing must not contain credentials.txt or .admin_password paths under repo/
    _listing="$(tar tzf "$_bundle" 2>/dev/null)"
    if echo "$_listing" | grep -qiE 'repo/.*credentials\.txt|repo/.*admin_password|repo/.*\.secrets'; then
        echo "FAIL: secret file path in bundle listing; listing=${_listing}" >&2
        exit 1
    fi

    exit 0
) && pass "bundle_create_excludes_secrets: bundle repo/ has no credentials/env/secrets" \
  || fail "bundle_create_excludes_secrets: SC3 invariant violated or bundle_create not implemented"

# ── Case: bundle_install_verifies_sha — corrupt artifact → fail BEFORE docker load ─
(
    set +eu
    _tmp="$(mktemp -d)"
    _out_dir="$(mktemp -d)"
    _save_dir="$(mktemp -d)"
    _load_log="$(mktemp)"
    trap 'rm -rf "$_tmp" "$_out_dir" "$_save_dir" "$_load_log"' EXIT

    # Build a minimal fake bundle with a valid MANIFEST.txt, then corrupt it
    mkdir -p "${_tmp}/bundle_stage/images" "${_tmp}/bundle_stage/models" "${_tmp}/bundle_stage/repo"
    printf 'fake image content\n' > "${_tmp}/bundle_stage/images/fake.tar"
    printf 'NGINX_VERSION=1.27.0\n' > "${_tmp}/bundle_stage/repo/versions.env"
    # Create MANIFEST.txt with WRONG sha256 (corrupt on purpose)
    printf 'sha256:deadbeefdeadbeefdeadbeefdeadbeef  images/fake.tar\n' \
        > "${_tmp}/bundle_stage/MANIFEST.txt"
    # Pack into a bundle tar
    _bundle="${_out_dir}/agmind-bundle-corrupt-test.tar.gz"
    tar czf "$_bundle" -C "${_tmp}/bundle_stage" .

    export MOCK_DOCKER_CALLLOG="$_load_log"
    export MOCK_DOCKER_FIXTURE=healthy

    out="$(_run_bundle_install "$_bundle" 2>&1)"
    rc="$(_rc_of "$out")"

    # Must fail (sha mismatch → non-zero exit)
    [[ -n "$rc" && "$rc" -ne 0 ]] \
        || { echo "exit=$rc (want ≠0 on sha mismatch); out=${out}" >&2; exit 1; }

    # Must NOT have called docker load (fail before mutation)
    if grep -q 'docker load' "$_load_log" 2>/dev/null; then
        echo "FAIL: docker load called before sha verification failure" >&2
        exit 1
    fi

    exit 0
) && pass "bundle_install_verifies_sha: corrupt artifact → exit≠0 before docker load" \
  || fail "bundle_install_verifies_sha: bundle_install not yet implemented (lib/bundle.sh RED)"

# ── Case: bundle_install_loads_and_chains — valid bundle → docker load called ──
# CONTRACT for 07-04: after sha verify passes, docker load is called per image,
# then either AGMIND_AIRGAPPED=true bash install.sh is invoked OR the operator is
# instructed to run it (either is acceptable; this test checks docker load was called).
(
    set +eu
    _tmp="$(mktemp -d)"
    _out_dir="$(mktemp -d)"
    _load_log="$(mktemp)"
    trap 'rm -rf "$_tmp" "$_out_dir" "$_load_log"' EXIT

    # Build a valid bundle: MANIFEST.txt with correct sha256
    mkdir -p "${_tmp}/bundle_stage/images" "${_tmp}/bundle_stage/models" "${_tmp}/bundle_stage/repo"
    printf 'fake image content\n' > "${_tmp}/bundle_stage/images/fake.tar"
    printf 'NGINX_VERSION=1.27.0\n' > "${_tmp}/bundle_stage/repo/versions.env"
    # Compute real sha256 for the fake image
    _sha="$(sha256sum "${_tmp}/bundle_stage/images/fake.tar" 2>/dev/null | awk '{print $1}' \
        || python3 -c "import hashlib; print(hashlib.sha256(open('${_tmp}/bundle_stage/images/fake.tar','rb').read()).hexdigest())")"
    printf 'sha256:%s  images/fake.tar\n' "$_sha" > "${_tmp}/bundle_stage/MANIFEST.txt"
    _bundle="${_out_dir}/agmind-bundle-valid-test.tar.gz"
    tar czf "$_bundle" -C "${_tmp}/bundle_stage" .

    export MOCK_DOCKER_CALLLOG="$_load_log"
    export MOCK_DOCKER_FIXTURE=healthy
    export MOCK_DOCKER_LOAD_EXIT=0

    out="$(_run_bundle_install "$_bundle" 2>&1)"
    rc="$(_rc_of "$out")"

    # Must succeed or at minimum have called docker load
    # (rc=127 = not implemented = RED; when implemented rc should be 0)
    [[ -n "$rc" ]] || { echo "no RC in output; out=${out}" >&2; exit 1; }

    # When implemented: docker load must have been called
    # For RED phase: this will fail because bundle_install doesn't exist
    if grep -q 'docker load' "$_load_log" 2>/dev/null; then
        # If load was called → check it succeeded
        [[ "$rc" -eq 0 ]] \
            || { echo "docker load was called but rc=$rc (want 0); out=${out}" >&2; exit 1; }
    else
        # Load not called → not yet implemented (RED expected)
        echo "docker load not called — lib/bundle.sh not yet implemented" >&2
        exit 1
    fi

    exit 0
) && pass "bundle_install_loads_and_chains: valid bundle → docker load called" \
  || fail "bundle_install_loads_and_chains: bundle_install not yet implemented (lib/bundle.sh RED)"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
