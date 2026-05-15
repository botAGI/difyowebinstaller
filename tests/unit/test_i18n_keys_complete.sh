#!/usr/bin/env bash
# test_i18n_keys_complete.sh — Static check that every t <key> invocation
# resolves to an I18N_EN entry; EN/RU parity is reported; dead keys WARN.
#
# Pure static parse against repo source. <2s. No docker, no env gen.
#
# Notes on scope:
#   Only matches the $(t key.with.dots) command-substitution form currently
#   used throughout lib/wizard.sh, install.sh, scripts/agmind.sh, lib/config.sh.
#   If bare `t key` calls outside $(...) are added in future, extend the grep
#   pattern accordingly — out of scope for this test version.
#
# Exit: 0 = all PASS (warns OK), 1 = any missing key, 77 = SKIP (i18n.sh missing).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
I18N="${REPO_ROOT}/lib/i18n.sh"

if [[ ! -f "$I18N" ]]; then
    echo "SKIP: ${I18N} not found"
    exit 77
fi

echo "## test_i18n_keys_complete.sh"

PASS=0; FAIL=0; WARN=0

# ============================================================================
# DISCOVER DEFINED KEYS
# Parse I18N_EN["key"]= and I18N_RU["key"]= lines in lib/i18n.sh.
# ============================================================================
mapfile -t EN_KEYS < <(
    grep -oE 'I18N_EN\["[^"]+"\]=' "$I18N" \
        | sed 's/I18N_EN\["\(.*\)"\]=/\1/' \
        | sort -u
)
mapfile -t RU_KEYS < <(
    grep -oE 'I18N_RU\["[^"]+"\]=' "$I18N" \
        | sed 's/I18N_RU\["\(.*\)"\]=/\1/' \
        | sort -u
)

echo "  Discovered: ${#EN_KEYS[@]} EN keys, ${#RU_KEYS[@]} RU keys"

# ============================================================================
# DISCOVER t() INVOCATIONS
# Pattern: $(t key.with.dots) — the explicit command-substitution form.
# [a-z][a-z0-9._]+ ensures we only match real dotted keys (not shell builtins).
# ============================================================================
SOURCES=(
    "${REPO_ROOT}/lib/wizard.sh"
    "${REPO_ROOT}/install.sh"
    "${REPO_ROOT}/scripts/agmind.sh"
    "${REPO_ROOT}/lib/config.sh"
)

# Only scan files that exist (defensive for partial checkouts)
EXISTING_SOURCES=()
for _s in "${SOURCES[@]}"; do
    [[ -f "$_s" ]] && EXISTING_SOURCES+=("$_s")
done

mapfile -t USED_KEYS < <(
    grep -hoE '\$\(t [a-z][a-z0-9._]+\)' "${EXISTING_SOURCES[@]}" 2>/dev/null \
        | sed 's/^\$(t //;s/)$//' \
        | sort -u
)

echo "  Discovered: ${#USED_KEYS[@]} unique t() invocations in source"

# ============================================================================
# A. Every t() invocation key must be in I18N_EN
# (t() falls back to EN → EN is the mandatory table)
# ============================================================================
echo ""
echo "--- A: every t() invocation resolves to I18N_EN ---"

missing_in_en=0
for k in "${USED_KEYS[@]}"; do
    if printf '%s\n' "${EN_KEYS[@]}" | grep -qxF "$k"; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: key '${k}' used in source but missing in I18N_EN"
        FAIL=$((FAIL + 1))
        missing_in_en=$((missing_in_en + 1))
    fi
done
if [[ $missing_in_en -eq 0 ]]; then
    echo "  PASS: all ${#USED_KEYS[@]} t() invocations resolve to I18N_EN"
fi

# ============================================================================
# B. EN/RU parity
# Keys in I18N_EN without a RU entry → WARN (user falls back to EN, OK).
# Keys in I18N_RU without an EN entry → FAIL (orphan; t() can never return it).
# ============================================================================
echo ""
echo "--- B: EN/RU parity ---"

en_only=0; ru_only=0
for k in "${EN_KEYS[@]}"; do
    if ! printf '%s\n' "${RU_KEYS[@]}" | grep -qxF "$k"; then
        echo "  WARN: key '${k}' in I18N_EN but not in I18N_RU (RU users fall back to EN)"
        WARN=$((WARN + 1))
        en_only=$((en_only + 1))
    fi
done
for k in "${RU_KEYS[@]}"; do
    if ! printf '%s\n' "${EN_KEYS[@]}" | grep -qxF "$k"; then
        echo "  FAIL: key '${k}' in I18N_RU but not in I18N_EN (orphan; EN fallback impossible)"
        FAIL=$((FAIL + 1))
        ru_only=$((ru_only + 1))
    fi
done
if [[ $en_only -eq 0 && $ru_only -eq 0 ]]; then
    echo "  PASS: EN/RU parity perfect (${#EN_KEYS[@]} EN <-> ${#RU_KEYS[@]} RU)"
    PASS=$((PASS + 1))
fi

# ============================================================================
# C. Dead-key check (WARN only — pre-added/future keys are legitimate)
# Reports EN keys that are defined but never referenced via t() in source.
# ============================================================================
echo ""
echo "--- C: unreferenced I18N_EN keys (informational dead-key check) ---"

dead=0
for k in "${EN_KEYS[@]}"; do
    if ! printf '%s\n' "${USED_KEYS[@]}" | grep -qxF "$k"; then
        echo "  WARN: key '${k}' defined in I18N_EN but never referenced via t()"
        WARN=$((WARN + 1))
        dead=$((dead + 1))
    fi
done
if [[ $dead -eq 0 ]]; then
    echo "  PASS: every I18N_EN key is referenced at least once"
    PASS=$((PASS + 1))
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "=== Summary: ${PASS} passed, ${WARN} warned, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
