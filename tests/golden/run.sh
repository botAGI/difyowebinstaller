#!/usr/bin/env bash
# tests/golden/run.sh — AGmind config-rendering equivalence harness.
# Re-uses lib/config.sh::generate_config (production code path) with PATH-mock
# isolation + AGMIND_TEST_SEED for deterministic secrets/clock/hostname.
#
# Usage:
#   tests/golden/run.sh <scenario>            # render + diff one scenario
#   tests/golden/run.sh --all                 # all scenarios from scenarios.list
#   tests/golden/run.sh --check-determinism <scenario>   # double-render only
#   tests/golden/run.sh --update <scenario>   # render + update expected/ (LOCAL ONLY,
#                                              requires AGMIND_GOLDEN_ACCEPT=1)
#   tests/golden/run.sh --update --update-all # update all scenarios in scenarios.list
#
# Exit codes: 0 = clean, 1 = drift OR non-determinism, 77 = SKIP missing dep.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Colors (own palette — harness must NOT source common.sh at top level because
# that triggers production guard. We source it inside a subshell per scenario
# with AGMIND_ALLOW_TEST_SEED=true.)
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

GOLDEN_DIR="${REPO_ROOT}/tests/golden"
INPUTS_DIR="${GOLDEN_DIR}/inputs"
EXPECTED_DIR="${GOLDEN_DIR}/expected"
SCENARIOS_LIST="${GOLDEN_DIR}/scenarios.list"

# CI-only block on auto-accept (D-14)
if [[ -n "${CI:-}" && "${AGMIND_GOLDEN_ACCEPT:-}" == "1" ]]; then
    echo "FATAL: AGMIND_GOLDEN_ACCEPT=1 forbidden in CI environment" >&2
    exit 1
fi

# ── Prerequisites — graceful SKIP if env can't run hermetic golden ─────────────
_log_warn() { echo "${YELLOW}$*${NC}" >&2; }
_log_err()  { echo "${RED}$*${NC}"   >&2; }

_check_docker_compose_version() {
    # rc=0 OK; rc=77 SKIP с понятным message; rc=1 hard fail (impossible here)
    if ! command -v docker >/dev/null 2>&1; then
        _log_warn "SKIP: docker CLI недоступен — golden тестам нужен docker compose v2.20+; rc=77"
        return 77
    fi
    local ver
    ver="$(docker compose version --short 2>/dev/null || echo "0.0.0")"
    # Tolerate optional 'v' prefix and trailing notes
    ver="${ver#v}"; ver="${ver%% *}"
    local major minor
    major="${ver%%.*}"
    if [[ "$ver" == *.* ]]; then
        minor="${ver#*.}"; minor="${minor%%.*}"
    else
        minor=0
    fi
    # Numeric coerce
    [[ "$major" =~ ^[0-9]+$ ]] || major=0
    [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
    if [[ "$major" -lt 2 || ( "$major" -eq 2 && "$minor" -lt 20 ) ]]; then
        _log_warn "SKIP: docker compose $ver < v2.20 — golden output не byte-stable между версиями; rc=77"
        return 77
    fi
    return 0
}

# Run check ONCE up front; cache result via env var so subshells inherit.
if [[ -z "${_GOLDEN_PREREQ_OK:-}" ]]; then
    _check_docker_compose_version
    _GOLDEN_PREREQ_RC=$?
    if [[ "$_GOLDEN_PREREQ_RC" -ne 0 ]]; then
        exit "$_GOLDEN_PREREQ_RC"
    fi
    export _GOLDEN_PREREQ_OK=1
fi

SCENARIO_NAME=""
SCENARIO_PROFILE=""
SCENARIO_SEED=""
SCENARIO_DESC=""

_load_scenario() {
    local scenario="$1"
    local line
    line="$(awk -F'\t' -v s="$scenario" '$1==s {print; exit}' "$SCENARIOS_LIST")"
    if [[ -z "$line" ]]; then
        _log_err "ERROR: scenario '$scenario' отсутствует в $SCENARIOS_LIST"
        return 1
    fi
    SCENARIO_NAME="$(echo "$line"     | awk -F'\t' '{print $1}')"
    SCENARIO_PROFILE="$(echo "$line"  | awk -F'\t' '{print $2}')"
    SCENARIO_SEED="$(echo "$line"     | awk -F'\t' '{print $3}')"
    SCENARIO_DESC="$(echo "$line"     | awk -F'\t' '{print $4}')"
    # Silence "unused var" lint — we keep the description for diagnostics callers
    : "$SCENARIO_NAME" "$SCENARIO_DESC"
}

# Render scenario into out_dir. Hermetic: PATH-mock isolation, AGMIND_TEST_SEED active,
# AGMIND_ALLOW_TEST_SEED=true (bypass production guard for test runs).
_render_scenario() {
    local scenario="$1" out_dir="$2"
    _load_scenario "$scenario" || return 1

    local tmpdir; tmpdir="$(mktemp -d -t "agmind-golden-${scenario}.XXXXXX")"
    local mock_path="${REPO_ROOT}/tests/mocks:${PATH}"
    local inputs_file="${INPUTS_DIR}/${scenario}.env"

    if [[ ! -f "$inputs_file" ]]; then
        _log_err "ERROR: inputs file отсутствует: $inputs_file"
        rm -rf "$tmpdir"
        return 1
    fi

    # Save real PATH before any subshell — needed for `docker compose config`
    # which must run against the real CLI (mock docker doesn't parse `-f X -p Y
    # --env-file Z config` argv shape — and `compose config` is intentionally
    # hermetic at the daemon level, so calling the real binary is safe).
    local real_path="$PATH"

    (
        export PATH="$mock_path"
        export INSTALL_DIR="$tmpdir/install"
        mkdir -p "$INSTALL_DIR/docker"
        local template_dir="${REPO_ROOT}/templates"
        export AGMIND_TEST_SEED="$SCENARIO_SEED"
        export AGMIND_ALLOW_TEST_SEED=true
        # Isolate from host state — `*.preserved` files in /var/lib/agmind/state/
        # from prior real installs would otherwise leak into the snapshot
        # (e.g. dev box has n8n_encryption_key.preserved → empty cat by non-root
        # user → empty key in expected/, while CI runners have no preserved
        # files → generate_random_named fills the key, byte-drift). Per-scenario
        # tmp state dir gives generate_random_named ownership over the key.
        export AGMIND_STATE_DIR="${INSTALL_DIR}/state"
        # Neutralize host docker.sock GID drift — dev box ≠ CI runner.
        # lib/config.sh:619 detects DOCKER_GID via `stat -c %g /var/run/docker.sock`;
        # mock returns fixed value so snapshot is host-agnostic.
        export MOCK_STAT_GID_FIXTURE=988

        # Load scenario .env (self-contained per D-03)
        set -a
        # shellcheck disable=SC1090
        source "$inputs_file"
        set +a

        # Source library code — same as install.sh path.
        # We DO NOT propagate `set -euo pipefail` from lib/common.sh into our
        # subshell context to keep diagnostics readable when generate_config
        # warns (non-fatal warnings would otherwise abort). Production install
        # gets the strict mode via install.sh itself.
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/common.sh"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/config.sh"

        # Run the real rendering pipeline. set +e так как config.sh может
        # бросать non-fatal warnings (например mkdir на /var/lib/agmind/state
        # без root) — это не должно валить весь рендер. Главный сигнал успеха —
        # наличие .env и docker-compose.yml после возврата.
        set +e
        generate_config "$SCENARIO_PROFILE" "$template_dir" >/dev/null 2>&1
        if [[ ! -s "$INSTALL_DIR/docker/.env" ]] || [[ ! -s "$INSTALL_DIR/docker/docker-compose.yml" ]]; then
            echo "${RED}ERROR: generate_config не создал .env или docker-compose.yml для scenario=$scenario${NC}" >&2
            exit 1
        fi

        # Capture fully-interpolated compose (Pitfall 7: pass -p agmind to fix `name:`).
        # Use REAL docker binary (not mock) — mock argv parser doesn't handle the
        # full `-f ... -p ... --env-file ... config` shape, and `compose config`
        # is hermetic by design (parser-only, no daemon).
        if ! PATH="$real_path" docker compose -f "$INSTALL_DIR/docker/docker-compose.yml" \
                -p agmind \
                --env-file "$INSTALL_DIR/docker/.env" \
                config 2>/dev/null > "$INSTALL_DIR/docker/docker-compose.rendered.yml"; then
            echo "${RED}ERROR: docker compose config упал для scenario=$scenario${NC}" >&2
            exit 1
        fi
        if [[ ! -s "$INSTALL_DIR/docker/docker-compose.rendered.yml" ]]; then
            echo "${RED}ERROR: docker compose config дал пустой output для scenario=$scenario${NC}" >&2
            exit 1
        fi

        # Normalize tmpdir path в bind-mount `source:` строках → __INSTALL_DIR__.
        # Docker Compose резолвит относительные пути в абсолютные используя
        # текущий INSTALL_DIR, что вносит non-determinism (mktemp suffix). После
        # этой замены rendered YAML стабилен между запусками. Удаление этого
        # шага = double-render guard будет ловить tmpdir-leak (verified).
        local _esc_install_dir
        _esc_install_dir="$(printf '%s\n' "$INSTALL_DIR" | sed 's|[][\\/.*^$]|\\&|g')"
        sed -i "s|${_esc_install_dir}|__INSTALL_DIR__|g" \
            "$INSTALL_DIR/docker/docker-compose.rendered.yml"

        # Cross-version normalization: docker compose v2 emits implicit defaults
        # explicitly в новых патчах ("bind:\n  create_host_path: true"), старые
        # эмитят compact form ("bind: {}"). Семантика identical (create_host_path
        # default = true). Collapse explicit form → compact чтобы snapshot был
        # cross-version stable (CI runner ≠ dev box compose version).
        python3 - "$INSTALL_DIR/docker/docker-compose.rendered.yml" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()
# "bind:\n  create_host_path: true" → "bind: {}"
content = re.sub(
    r'^([ \t]+)bind:\n[ \t]+create_host_path: true$',
    r'\1bind: {}',
    content,
    flags=re.MULTILINE,
)
with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
PY

        mkdir -p "$out_dir"
        cp "$INSTALL_DIR/docker/.env" "$out_dir/.env.rendered"
        cp "$INSTALL_DIR/docker/docker-compose.rendered.yml" "$out_dir/"
        if [[ -f "$INSTALL_DIR/docker/nginx/nginx.conf" ]]; then
            cp "$INSTALL_DIR/docker/nginx/nginx.conf" "$out_dir/"
        fi

        if [[ "${MONITORING_MODE:-none}" == "local" && -d "$INSTALL_DIR/docker/monitoring" ]]; then
            mkdir -p "$out_dir/monitoring"
            # Copy only the .yml/.yaml/.river config files, preserving relative paths
            while IFS= read -r -d '' f; do
                local rel="${f#"$INSTALL_DIR/docker/monitoring/"}"
                local dest="$out_dir/monitoring/$rel"
                mkdir -p "$(dirname "$dest")"
                cp "$f" "$dest"
            done < <(find "$INSTALL_DIR/docker/monitoring" -type f \
                \( -name '*.yml' -o -name '*.yaml' -o -name '*.river' -o -name '*.json' \) -print0)
        fi
        if [[ "${ENABLE_RAGFLOW:-false}" == "true" && -d "$INSTALL_DIR/docker/ragflow" ]]; then
            mkdir -p "$out_dir/ragflow"
            while IFS= read -r -d '' f; do
                local rel="${f#"$INSTALL_DIR/docker/ragflow/"}"
                local dest="$out_dir/ragflow/$rel"
                mkdir -p "$(dirname "$dest")"
                cp "$f" "$dest"
            done < <(find "$INSTALL_DIR/docker/ragflow" -type f \
                \( -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name 'service_conf*' \) -print0)
        fi
    )
    local subrc=$?
    rm -rf "$tmpdir"
    if [[ "$subrc" -ne 0 ]]; then return "$subrc"; fi

    # Generate checksums (sorted for stable ordering) — relative paths, LC_ALL=C
    # для byte-stable sort вне зависимости от локали хоста.
    ( cd "$out_dir" && LC_ALL=C find . -type f ! -name 'checksums.sha256' -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum > checksums.sha256 )
}

# Double-render guard (D-23). Renders same scenario twice into separate tmpdirs;
# any byte-difference = entropy leak (missed callsite, $(date)/$(hostname)/$RANDOM).
_double_render_guard() {
    local scenario="$1"
    local r1 r2
    r1="$(mktemp -d -t "agmind-golden-dr1-${scenario}.XXXXXX")"
    r2="$(mktemp -d -t "agmind-golden-dr2-${scenario}.XXXXXX")"
    _render_scenario "$scenario" "$r1" || { rm -rf "$r1" "$r2"; return 1; }
    _render_scenario "$scenario" "$r2" || { rm -rf "$r1" "$r2"; return 1; }
    if ! diff -r -q "$r1" "$r2" >/dev/null 2>&1; then
        {
            echo "${RED}✗ Non-deterministic render для scenario=${scenario} (seed=${SCENARIO_SEED}).${NC}"
            echo "${YELLOW}Это НЕ snapshot drift — один и тот же scenario, отрендеренный дважды,${NC}"
            echo "${YELLOW}дал разный output. Root cause: незащищённый callsite generate_random${NC}"
            echo "${YELLOW}(не _named), \$(date), \$(hostname) или \$RANDOM в template-rendering path.${NC}"
            echo "Audit commands:"
            echo "  grep -nE '\\\$\\(generate_random ' lib/config.sh lib/openwebui.sh lib/authelia.sh"
            echo "  grep -nE '\\\$\\(date|\\\$\\(hostname|\\\$RANDOM' lib/config.sh lib/peer.sh lib/security.sh"
            echo ""
            echo "Первые расхождения:"
            diff -r "$r1" "$r2" 2>&1 | head -30
        } >&2
        rm -rf "$r1" "$r2"
        return 1
    fi
    rm -rf "$r1" "$r2"
    return 0
}

_diff_scenario() {
    local scenario="$1"
    local expected="${EXPECTED_DIR}/${scenario}"
    local actual
    actual="$(mktemp -d -t "agmind-golden-actual-${scenario}.XXXXXX")"

    if [[ ! -d "$expected" ]]; then
        _log_err "ERROR: expected/ отсутствует для '$scenario' — запусти с --update для bootstrap"
        rm -rf "$actual"
        return 1
    fi

    _render_scenario "$scenario" "$actual" || { rm -rf "$actual"; return 1; }

    local rc=0
    if ! diff -ur "$expected" "$actual" > "${GOLDEN_DIR}/.last-update.diff" 2>&1; then
        echo "${RED}✗ ${scenario}: byte-level drift${NC}" >&2
        head -120 "${GOLDEN_DIR}/.last-update.diff" >&2
        echo "" >&2
        echo "${YELLOW}Полный diff: ${GOLDEN_DIR}/.last-update.diff${NC}" >&2
        rc=1
    else
        echo "${GREEN}✓ ${scenario}: clean${NC}"
        # Remove empty diff file
        rm -f "${GOLDEN_DIR}/.last-update.diff"
    fi
    rm -rf "$actual"
    return "$rc"
}

_update_scenario() {
    local scenario="$1"
    if [[ "${AGMIND_GOLDEN_ACCEPT:-0}" != "1" ]]; then
        _log_err "ERROR: --update требует AGMIND_GOLDEN_ACCEPT=1 (сначала прочитай tests/golden/UPDATE.md)"
        return 1
    fi
    _double_render_guard "$scenario" || return 1
    local target="${EXPECTED_DIR}/${scenario}"
    rm -rf "$target"
    mkdir -p "$target"
    _render_scenario "$scenario" "$target" || return 1
    echo "${GREEN}✓ ${scenario}: expected/ обновлён${NC}"
}

_run_one() {
    local scenario="$1"
    _load_scenario "$scenario" || return 1
    echo "${BOLD}== scenario: $scenario (profile=$SCENARIO_PROFILE seed=$SCENARIO_SEED)${NC}"
    _double_render_guard "$scenario" || return 1
    _diff_scenario "$scenario" || return 1
}

# Main dispatcher
case "${1:-}" in
    --all)
        rc=0
        while IFS=$'\t' read -r name _ _ _; do
            [[ -z "$name" ]] && continue
            [[ "${name#\#}" != "$name" ]] && continue
            _run_one "$name" || rc=1
        done < "$SCENARIOS_LIST"
        exit "$rc"
        ;;
    --check-determinism)
        scenario="${2:?scenario required}"
        _double_render_guard "$scenario"
        ;;
    --update)
        scenario="${2:?scenario required (or use --update --update-all)}"
        if [[ "$scenario" == "--update-all" ]]; then
            rc=0
            while IFS=$'\t' read -r name _ _ _; do
                [[ -z "$name" ]] && continue
                [[ "${name#\#}" != "$name" ]] && continue
                _update_scenario "$name" || rc=1
            done < "$SCENARIOS_LIST"
            exit "$rc"
        else
            _update_scenario "$scenario"
        fi
        ;;
    "")
        echo "Usage: $0 <scenario>|--all|--check-determinism <scenario>|--update <scenario>" >&2
        exit 2
        ;;
    *)
        _run_one "$1"
        ;;
esac
