#!/usr/bin/env bash
# tests/integration/test_secrets_preserved_on_reinstall.sh
#
# STATE-11 BACKUP-01 contract: re-running install.sh on an existing host MUST
# preserve secrets (no rotation). The Phase 11 state-store substrate is the
# source of truth — once a slug has been written there, subsequent
# `_generate_secrets` invocations must read it back, NOT regenerate.
#
# Plan 14-08 / D-14. Pre-Plan-14-08 baseline (RED): `_generate_secrets` calls
# `generate_random_named` unconditionally, so a re-run without seed produces
# fresh bytes => regression. Post-Plan-14-08 (GREEN): `_state_get_or_generate`
# reads from ${STATE_DIR}/secrets.env first, only generating on miss.
#
# Hermetic: AGMIND_STATE_DIR + INSTALL_DIR override into mktemp tmp dirs;
# no host /var/lib/agmind/state mutation.
#
# Exit: 0 = all pass, 1 = any fail, 77 = SKIP (state/config layer missing).

set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to repo root: $REPO_ROOT"; exit 1; }

# SKIP if foundational layers missing (Phase 10/11/14 not yet merged on this checkout).
for f in lib/common.sh lib/state.sh lib/config.sh; do
    if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
        echo "SKIP: ${f} missing (Phase 11/14 layers incomplete)"
        exit 77
    fi
done

# Hermetic environment. AGMIND_TEST_SEED + AGMIND_ALLOW_TEST_SEED guard Phase 13
# RNG. INSTALL_DIR is required by lib/config.sh for .preserved-file paths.
# Both AGMIND_STATE_DIR (config.sh) and STATE_DIR (state.sh) are set — Phase 11
# state-store substrate honors STATE_DIR; lib/config.sh::_state_get_or_generate
# propagates AGMIND_STATE_DIR → STATE_DIR before each state_get_secret call,
# but here we set both up-front to keep the test deterministic regardless of
# which entry point is exercised first.
export AGMIND_TEST_SEED="state11:integration:v1"
export AGMIND_ALLOW_TEST_SEED=true
export AGMIND_STATE_DIR="${TMP}/state"
export STATE_DIR="${TMP}/state"
export INSTALL_DIR="${TMP}/agmind"
mkdir -p "${INSTALL_DIR}/docker" "${AGMIND_STATE_DIR}"

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/state.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/config.sh"

FAIL=0
PASS=0

# 11 STATE-11 slugs per Plan 13-01 inventory + CONTEXT D-11.
# SANDBOX_API_KEY is generated as "dify-sandbox-<random>" — wrapper prefix tested
# implicitly via Phase E (value byte-equality across invocations).
SLUGS=(
    SECRET_KEY
    DB_PASSWORD
    REDIS_PASSWORD
    SANDBOX_API_KEY
    PLUGIN_DAEMON_KEY
    PLUGIN_INNER_API_KEY
    WEAVIATE_API_KEY
    QDRANT_API_KEY
    MINIO_ROOT_PASSWORD
    S3_ACCESS_KEY
    S3_SECRET_KEY
)

# Internal slugs in _generate_secrets are named with a leading underscore.
# `eval` is the simplest portable way to read indirect var names in pre-Bash-5.0.
_slug_var() {
    eval "printf '%s' \"\${_${1}:-}\""
}

_assert_eq() {
    local label="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        echo "PASS: ${label}"
        PASS=$((PASS+1))
    else
        # Per CLAUDE.md §5 + Phase 11 lint, never log raw secret values. Compare
        # only via SHA-256 prefix (8 hex chars) — enough to diagnose drift, not
        # enough to reconstruct the secret.
        local want_h got_h
        want_h="$(printf '%s' "$want" | sha256sum | cut -c1-8)"
        got_h="$(printf '%s' "$got" | sha256sum | cut -c1-8)"
        echo "FAIL: ${label} (want sha8=${want_h}, got sha8=${got_h})"
        FAIL=$((FAIL+1))
    fi
}

# Phase A — first "install": generate secrets, snapshot bytes.
_generate_secrets >/dev/null 2>&1 || {
    echo "FAIL: _generate_secrets rc=$? on first invocation"
    exit 1
}
declare -A FIRST
for slug in "${SLUGS[@]}"; do
    val="$(_slug_var "$slug")"
    if [[ -z "$val" ]]; then
        echo "FAIL: _${slug} empty after first _generate_secrets"
        FAIL=$((FAIL+1))
    fi
    FIRST[$slug]="$val"
done

# Phase B — state-store populated with the same values.
for slug in "${SLUGS[@]}"; do
    state_val="$(state_get_secret "$slug" 2>/dev/null || true)"
    if [[ -z "$state_val" ]]; then
        echo "FAIL: state_get_secret ${slug} empty/missing (state store not wired)"
        FAIL=$((FAIL+1))
        continue
    fi
    # For SANDBOX_API_KEY, the wrapper prefix lives in _generate_secrets logic,
    # not in the state-stored slug — compare on the bare random suffix.
    if [[ "$slug" == "SANDBOX_API_KEY" ]]; then
        want="${FIRST[$slug]#dify-sandbox-}"
    else
        want="${FIRST[$slug]}"
    fi
    _assert_eq "state has ${slug} from first install" "$want" "$state_val"
done

# Phase C — second "install" WITHOUT AGMIND_TEST_SEED. Without the seed,
# generate_random_named falls back to CSPRNG (random each time). The only way
# for slugs to match Phase A is via state-store read.
unset AGMIND_TEST_SEED AGMIND_ALLOW_TEST_SEED
for slug in "${SLUGS[@]}"; do
    eval "unset _${slug}"
done

_generate_secrets >/dev/null 2>&1 || {
    echo "FAIL: _generate_secrets rc=$? on second invocation (no seed)"
    exit 1
}

# Phase D — BACKUP-01 contract: re-install preserves every slug byte-equal.
for slug in "${SLUGS[@]}"; do
    second="$(_slug_var "$slug")"
    _assert_eq "BACKUP-01 preserves ${slug} across re-install" "${FIRST[$slug]}" "$second"
done

# Phase E — adversarial: state IS source of truth. Mutate state directly,
# call _generate_secrets again, observe the new state value is honored.
# Skip SANDBOX_API_KEY because it has wrapper-prefix logic — covered above.
ADV_VALUE="ADVERSARIAL_VALUE_${RANDOM}_${$}"
state_set_secret DB_PASSWORD "$ADV_VALUE" >/dev/null
for slug in "${SLUGS[@]}"; do
    eval "unset _${slug}"
done
_generate_secrets >/dev/null 2>&1 || {
    echo "FAIL: _generate_secrets rc=$? on third invocation (adversarial)"
    exit 1
}
_assert_eq "adversarial: state value is authoritative for DB_PASSWORD" "$ADV_VALUE" "$(_slug_var DB_PASSWORD)"

echo ""
echo "Summary: PASS=${PASS} FAIL=${FAIL}"

if [[ "$FAIL" -eq 0 ]]; then
    echo "ALL PASS — STATE-11 BACKUP-01 contract holds."
    exit 0
fi

echo "SOME FAIL — STATE-11 migration incomplete or regressed."
exit 1
