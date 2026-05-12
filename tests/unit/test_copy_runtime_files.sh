#!/usr/bin/env bash
# test_copy_runtime_files.sh — regression guard for INSTALL-COPY-RUNTIME.
#
# scripts/agmind.sh is a thin dispatcher: most commands `source "${SCRIPTS_DIR}/<x>.sh"`
# where SCRIPTS_DIR is the installed scripts/ dir. Those files are produced by
# install.sh::_copy_runtime_files — either glob-copied from the repo scripts/ dir
# (`cp scripts/*.sh ...`) or copied explicitly from lib/ (`cp lib/<y>.sh scripts/<x>.sh`).
#
# Bug history (v3.1 milestone audit, 2026-05-12): lib/{doctor,status,config,restore}.sh
# were NOT in _copy_runtime_files, so `agmind doctor|status|open|endpoints|config validate|
# backup verify|backup list` broke on a fresh install — the source path resolved to neither
# ${SCRIPTS_DIR}/<x>.sh (not produced) nor ${AGMIND_DIR}/lib/<x>.sh (lib/ never copied to
# INSTALL_DIR). This test asserts every ${SCRIPTS_DIR}/<x>.sh that agmind.sh sources is
# actually produced by _copy_runtime_files.
#
# Exit: 0 = pass, 1 = fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AGMIND_SH="${REPO_ROOT}/scripts/agmind.sh"
INSTALL_SH="${REPO_ROOT}/install.sh"

echo "## test_copy_runtime_files"

fail=0
_fail() { echo "  FAIL: $*"; fail=1; }
_ok()   { echo "  ok: $*"; }

[[ -f "$AGMIND_SH"  ]] || { _fail "scripts/agmind.sh not found"; exit 1; }
[[ -f "$INSTALL_SH" ]] || { _fail "install.sh not found";       exit 1; }

# 1. Extract every basename X from `source "${SCRIPTS_DIR}/X"` in agmind.sh.
mapfile -t sourced < <(grep -oE 'SCRIPTS_DIR\}/[A-Za-z0-9_.-]+\.sh' "$AGMIND_SH" \
    | sed 's#.*/##' | sort -u)

if [[ ${#sourced[@]} -eq 0 ]]; then
    _fail "no \${SCRIPTS_DIR}/*.sh source statements found in agmind.sh — grep pattern stale?"
    exit 1
fi
echo "  sourced from \${SCRIPTS_DIR}: ${sourced[*]}"

# 2. For each, it must be produced by _copy_runtime_files:
#    (a) a real repo file scripts/X (glob-copied via `cp scripts/*.sh`), OR
#    (b) an explicit `cp "${INSTALLER_DIR}/lib/...sh" "${INSTALL_DIR}/scripts/X"` line in install.sh.
for x in "${sourced[@]}"; do
    if [[ -e "${REPO_ROOT}/scripts/${x}" ]]; then
        _ok "${x} — present in repo scripts/ (glob-copied)"
        continue
    fi
    if grep -qF "/scripts/${x}\"" "$INSTALL_SH" && grep -q "INSTALL_DIR}/scripts/${x}\"" "$INSTALL_SH"; then
        _ok "${x} — explicit cp into INSTALL_DIR/scripts/ in install.sh"
        continue
    fi
    _fail "${x} is sourced from \${SCRIPTS_DIR} by agmind.sh but install.sh::_copy_runtime_files never produces scripts/${x} (not a repo scripts/ file, no explicit cp line)"
done

# 3. Cross-check: every explicit `cp "${INSTALLER_DIR}/lib/<y>.sh" "${INSTALL_DIR}/scripts/<x>.sh"`
#    target should be reachable — i.e. the lib source file exists.
while IFS= read -r line; do
    libpath="$(sed -E 's#.*INSTALLER_DIR\}/(lib/[A-Za-z0-9_.-]+\.sh)".*#\1#' <<<"$line")"
    [[ "$libpath" == lib/* ]] || continue
    if [[ -f "${REPO_ROOT}/${libpath}" ]]; then
        _ok "install.sh copies ${libpath} — source exists"
    else
        _fail "install.sh::_copy_runtime_files references ${libpath} but that file does not exist"
    fi
done < <(grep -E 'cp "\$\{INSTALLER_DIR\}/lib/[A-Za-z0-9_.-]+\.sh" *"\$\{INSTALL_DIR\}/scripts/' "$INSTALL_SH")

if [[ $fail -ne 0 ]]; then
    echo "## test_copy_runtime_files: FAIL"
    exit 1
fi
echo "## test_copy_runtime_files: PASS"
exit 0
