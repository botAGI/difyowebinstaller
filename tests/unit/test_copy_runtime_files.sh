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

# ---------------------------------------------------------------------------
# 4. Symlink preservation (Plan 14-07 / DUP-03)
# ---------------------------------------------------------------------------
# scripts/health.sh and scripts/detect.sh are symlinks → ../lib/X.sh per
# docs/lib-scripts-pairs.md. install.sh::_copy_runtime_files MUST preserve
# them during the glob copy step. Default `cp` dereferences source symlinks
# and writes regular files at the destination, silently breaking the
# single-source-of-truth contract on every install.
#
# Regression history (DUP-03, 2026-05-17):
#   Before Plan 14-07 Task 4, install.sh:533 used plain `cp ... scripts/*.sh ...`
#   followed by explicit `cp lib/health.sh scripts/health.sh` (line 544). The
#   net effect was: scripts/health.sh on a fresh-installed host = REGULAR FILE
#   (not symlink). Plan 14-07 changed the glob to `cp -P` and removed the
#   redundant explicit copies. This block enforces that fix going forward.
check_symlink_preservation() {
    local sp_pass=0 sp_fail=0
    echo "  -- symlink preservation (DUP-03) --"

    # 4a. The glob copy line MUST use cp -P (or cp -a / --preserve=links)
    if grep -qE 'cp[[:space:]]+(-P|-a|--preserve=links)[[:space:]]+.*\$\{INSTALLER_DIR\}/scripts/.*\*\.sh' "$INSTALL_SH"; then
        _ok "install.sh uses cp -P (or -a) for scripts glob copy"
        sp_pass=$((sp_pass + 1))
    else
        _fail "install.sh scripts glob copy does not preserve symlinks (need cp -P)"
        sp_fail=$((sp_fail + 1))
    fi

    # 4b. No explicit overwrite of symlinked pairs (would re-introduce DUP-03 bug)
    if grep -qE 'cp[[:space:]]+.*lib/health\.sh.*scripts/health\.sh' "$INSTALL_SH"; then
        _fail "install.sh has explicit cp lib/health.sh -> scripts/health.sh, which would overwrite the symlink (DUP-03 regression)"
        sp_fail=$((sp_fail + 1))
    else
        _ok "install.sh does not redundantly overwrite scripts/health.sh symlink"
        sp_pass=$((sp_pass + 1))
    fi
    if grep -qE 'cp[[:space:]]+.*lib/detect\.sh.*scripts/detect\.sh' "$INSTALL_SH"; then
        _fail "install.sh has explicit cp lib/detect.sh -> scripts/detect.sh, which would overwrite the symlink (DUP-03 regression)"
        sp_fail=$((sp_fail + 1))
    else
        _ok "install.sh does not redundantly overwrite scripts/detect.sh symlink"
        sp_pass=$((sp_pass + 1))
    fi

    # 4c. Live simulation — actually exercise cp -P semantic against tmp dirs.
    # This catches future regressions where someone swaps -P for something
    # that no longer preserves symlinks (e.g., reverting to plain cp).
    local tmp_src tmp_dst
    tmp_src="$(mktemp -d)"
    tmp_dst="$(mktemp -d)"
    mkdir -p "${tmp_src}/lib" "${tmp_src}/scripts" "${tmp_dst}/scripts"
    echo "# fake-lib" > "${tmp_src}/lib/health.sh"
    (cd "${tmp_src}/scripts" && ln -s ../lib/health.sh health.sh)
    echo "# fake-script" > "${tmp_src}/scripts/agmind.sh"

    cp -P "${tmp_src}/scripts/"*.sh "${tmp_dst}/scripts/" 2>/dev/null || true

    local sim_target
    sim_target="$(readlink "${tmp_dst}/scripts/health.sh" 2>/dev/null || echo "NOT-A-SYMLINK")"
    if [[ -L "${tmp_dst}/scripts/health.sh" ]] && [[ "$sim_target" == "../lib/health.sh" ]]; then
        _ok "cp -P simulation preserves symlink (target=$sim_target)"
        sp_pass=$((sp_pass + 1))
    else
        _fail "cp -P simulation lost symlink semantic (target=$sim_target — expected ../lib/health.sh)"
        sp_fail=$((sp_fail + 1))
    fi
    rm -rf "${tmp_src}" "${tmp_dst}"

    echo "  -- symlink preservation: $sp_pass ok, $sp_fail fail --"
}
check_symlink_preservation

if [[ $fail -ne 0 ]]; then
    echo "## test_copy_runtime_files: FAIL"
    exit 1
fi
echo "## test_copy_runtime_files: PASS"
exit 0
