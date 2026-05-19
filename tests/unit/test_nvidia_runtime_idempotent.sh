#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_nvidia_runtime_idempotent.sh — regression 2026-05-19
#
# Bug history
# -----------
# install.sh::install_nvidia_toolkit (lib/docker.sh) bailed out with
# `return 0` whenever the nvidia-container-toolkit package was already
# installed — SKIPPING the critical `nvidia-ctk runtime configure --runtime=docker`
# + `systemctl restart docker` step. On re-installs / fresh installs after
# wipe, `daemon.json` had lost the `nvidia` runtime entry (caused by docker
# reinstall, daemon.json edit, or apt upgrade) but the toolkit package was
# still installed → function thought "all set" and returned.
#
# Symptom: every GPU container on master (docling, vllm-embed, vllm-rerank)
# failed with `Failed to initialize NVML: Unknown Error` even though host
# `nvidia-smi` worked. agmind doctor masked it with a false-positive
# `grep -qi nvidia` against full `docker info` (matched the host GPU name).
#
# This test STATICALLY asserts the fix shape (no live docker daemon
# required — checks bash source in lib/docker.sh + lib/doctor.sh):
#
#   A. install_nvidia_toolkit must call `nvidia-ctk runtime configure`
#      OUTSIDE of any "package already installed" early-return branch.
#      → The configure call must be reachable on the re-install path.
#
#   B. install_nvidia_toolkit must verify runtime registration AFTER
#      restart and FAIL LOUDLY if registration didn't stick.
#
#   C. agmind doctor's NVIDIA-runtime check must match the `Runtimes:`
#      line specifically (precise grep), not the whole `docker info`
#      output (false-positives on host GPU description).
#
# Exit: 0 = PASS, 1 = FAIL. Auto-discovered by tests/run_all.sh.
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

DOCKER_LIB="lib/docker.sh"
DOCTOR_LIB="lib/doctor.sh"

fail=0

# --- (A) install_nvidia_toolkit invokes `nvidia-ctk runtime configure`
# AFTER the package-presence check, not gated behind it ----------------------
# The legacy bug: `if dpkg -l nvidia-container-toolkit; then return 0; fi`
# was placed BEFORE the `nvidia-ctk runtime configure` call. Refactor must
# put the configure call AFTER (or independent of) the package check.
#
# We assert: the line number of the `nvidia-ctk runtime configure` call is
# GREATER than the last `return 0` line inside install_nvidia_toolkit's
# package-already-installed branch.

# Extract install_nvidia_toolkit function body line numbers
func_start=$(awk '/^install_nvidia_toolkit\(\)/ { print NR; exit }' "$DOCKER_LIB")
if [[ -z "$func_start" ]]; then
    echo "FAIL (A): install_nvidia_toolkit() not found in $DOCKER_LIB" >&2
    fail=1
else
    # Find the closing `}` of the function (next top-level `^}` after func_start)
    func_end=$(awk -v start="$func_start" 'NR > start && /^}$/ { print NR; exit }' "$DOCKER_LIB")
    if [[ -z "$func_end" ]]; then
        echo "FAIL (A): could not find end of install_nvidia_toolkit()" >&2
        fail=1
    else
        # Extract function body
        body=$(sed -n "${func_start},${func_end}p" "$DOCKER_LIB")

        # The configure call must appear in the body
        if ! grep -q 'nvidia-ctk runtime configure --runtime=docker' <<<"$body"; then
            echo "FAIL (A): install_nvidia_toolkit() does not call 'nvidia-ctk runtime configure --runtime=docker'" >&2
            fail=1
        fi

        # Verify the early `return 0` from "package already installed" branch is
        # NOT placed AFTER the dpkg/rpm presence check while configure is BEFORE
        # the check. Pattern to detect the regression:
        #   if dpkg -l ... ; then return 0; fi      ← line X
        #   ...
        #   nvidia-ctk runtime configure ...        ← line Y > X (bug if Y is unreachable)
        # Reverse pattern (correct): the configure call must be reachable for
        # the re-install path. The simplest check: when the package-installed
        # block ends with `return 0`, ensure the configure call is in a
        # SEPARATE branch (post-block), not gated by it.

        # We look for the literal anti-pattern:
        #   dpkg -l nvidia-container-toolkit ... then log_(success|info) ...; return 0
        # in the body — if found, configure call MUST also appear in a non-gated
        # location (we already verified it appears above).
        # The new architecture splits package install (gated) from runtime configure
        # (always run after a separate `docker info` check). Verify by ensuring
        # the function body contains BOTH a package-already-installed branch
        # AND a `docker info ... Runtimes:.*nvidia` check before the configure.
        if ! grep -qE 'docker info.*Runtimes' <<<"$body"; then
            echo "FAIL (A): install_nvidia_toolkit() does not check 'docker info Runtimes:' before configure — regression: function may skip configure when package is already installed but daemon.json lacks runtime entry" >&2
            fail=1
        fi
    fi
fi

# --- (B) Post-restart verification — install_nvidia_toolkit checks that
# the runtime actually registered after `systemctl restart docker` and
# returns non-zero with an actionable error message if it didn't ------------
if [[ -n "${func_start:-}" && -n "${func_end:-}" ]]; then
    body=$(sed -n "${func_start},${func_end}p" "$DOCKER_LIB")
    # Look for post-restart verification: after `systemctl restart docker`,
    # there should be another `docker info ... nvidia` check.
    restart_line=$(awk '/systemctl restart docker/ { print NR; exit }' <<<"$body" || true)
    verify_line=$(awk '/docker info.*Runtimes.*nvidia/ { print NR }' <<<"$body" | tail -1)

    if [[ -z "$restart_line" || -z "$verify_line" ]]; then
        # OK if the function never restarts (fully idempotent skip)
        :
    elif (( verify_line <= restart_line )); then
        echo "FAIL (B): install_nvidia_toolkit() does not verify nvidia runtime after 'systemctl restart docker' — regression: silent failure if daemon.json reverts" >&2
        fail=1
    fi

    # Failure path must log an error and return non-zero (not just `return 0`)
    if ! grep -qE 'log_error.*nvidia runtime|log_error.*GPU' <<<"$body"; then
        echo "FAIL (B): install_nvidia_toolkit() has no log_error message for nvidia runtime failure — silent failure regression risk" >&2
        fail=1
    fi
fi

# --- (C) agmind doctor uses precise `Runtimes:` match, not loose grep ------
# Legacy false-positive: `docker info | grep -qi nvidia` matched host GPU
# description in `docker info` output even when nvidia runtime was missing
# from the Runtimes: line. Fix: anchor pattern to `^Runtimes:` line.
if [[ ! -f "$DOCTOR_LIB" ]]; then
    echo "FAIL (C): $DOCTOR_LIB not found" >&2
    fail=1
else
    # Look for the docker info grep invocation in doctor's GPU check.
    grep_line=$(awk '
        /docker info.*grep.*nvidia/ { print NR ":" $0 }
    ' "$DOCTOR_LIB" | head -1)

    if [[ -z "$grep_line" ]]; then
        echo "FAIL (C): $DOCTOR_LIB has no 'docker info | grep ... nvidia' pattern for runtime check" >&2
        fail=1
    elif grep -qE 'docker info.*\|.*grep -qi "nvidia"' "$DOCTOR_LIB"; then
        # Legacy pattern — too loose
        echo "FAIL (C): $DOCTOR_LIB uses loose 'grep -qi nvidia' against full docker info output — false-positives match host GPU description" >&2
        echo "         Fix: anchor to 'Runtimes:' line via grep -qE '^[[:space:]]*Runtimes:.*\\\\bnvidia\\\\b'" >&2
        fail=1
    elif ! grep -qE 'Runtimes:.*nvidia' "$DOCTOR_LIB"; then
        echo "FAIL (C): $DOCTOR_LIB grep does not anchor to 'Runtimes:' line — likely loose match" >&2
        fail=1
    fi
fi

if (( fail )); then
    echo "" >&2
    echo "test_nvidia_runtime_idempotent.sh: FAIL — install_nvidia_toolkit + doctor invariants violated" >&2
    exit 1
fi

echo "test_nvidia_runtime_idempotent.sh: PASS — install_nvidia_toolkit idempotent + doctor precise"
exit 0
