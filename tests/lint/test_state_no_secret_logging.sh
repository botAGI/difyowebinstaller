#!/usr/bin/env bash
# tests/lint/test_state_no_secret_logging.sh — Phase 11 R7 mitigation gate.
#
# Forbids accidental secret-value logging in state-store code paths. The pattern
#   log_(info|warn|error|success|debug) ... $value
# (or $val, $v with a word boundary) is dangerous — it would leak the actual
# secret bytes to stderr / log files / structured logs.
#
# Allowed (logs the KEY name only):
#   log_info "state: ${key} set"
#   log_info "state: secrets.env::${name} set"
# Forbidden (logs the VALUE bytes):
#   log_info "set $value"
#   log_info "set ${val}"
#   log_error "rejected v=${v}"
#
# Scope: lib/state.sh, lib/migrations.sh, lib/migrations/*.sh.
#
# Boundary handling: $value, ${value}, $val, ${val}, $v, ${v} match; $ver,
# $verbose, $variable, $vfd etc. do NOT match (word boundary after).
#
# Exit: 0 = clean, 1 = leak detected, 77 = no state/migrations files yet (SKIP).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_state_no_secret_logging"

# Collect files to scan (skip if absent — Phase 11 plans might land in waves)
files=()
for f in lib/state.sh lib/migrations.sh; do
    [[ -f "${REPO_ROOT}/${f}" ]] && files+=("${REPO_ROOT}/${f}")
done
if [[ -d "${REPO_ROOT}/lib/migrations" ]]; then
    while IFS= read -r m; do
        files+=("$m")
    done < <(find "${REPO_ROOT}/lib/migrations" -maxdepth 1 -name '*.sh' -type f | LC_ALL=C sort)
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "  SKIP: no state/migrations files to scan (Phase 11 not yet merged)"
    exit 77
fi

# Forbidden pattern:
#   log_(info|warn|error|success|debug)
#   ... any chars except '#' (so trailing # comments are ignored)
#   $ optionally { then value|val|v then } or word boundary
#
# Using POSIX ERE via grep -E. The trailing `\b` ensures $val/$v/$value with
# trailing word boundary (e.g. `$value `, `$v"`, `${val}`) match; while $ver,
# $verbose, $variable, $vfd do NOT.
forbidden_re='log_(info|warn|error|success|debug)[^#]*\$(\{(value|val|v)\}|(value|val|v)([^A-Za-z0-9_]|$))'

fail=0
for f in "${files[@]}"; do
    matches="$(grep -nE "$forbidden_re" "$f" 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
        echo "  FAIL: ${f#"${REPO_ROOT}/"} leaks value(s) in log_*:" >&2
        while IFS= read -r line; do
            echo "    ${line}" >&2
        done <<<"$matches"
        fail=1
    else
        echo "  ok: ${f#"${REPO_ROOT}/"} — no \$value/\$val/\$v in log_*"
    fi
done

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "=== test_state_no_secret_logging: PASS ==="
    exit 0
else
    echo "=== test_state_no_secret_logging: FAIL — see violations above ==="
    exit 1
fi
