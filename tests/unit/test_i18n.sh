#!/usr/bin/env bash
# test_i18n.sh — Unit tests for lib/i18n.sh: t() lookup, AGMIND_LANG resolution,
# autodetect from locale, env-override priority, invalid-lang fallback.
# Exit: 0 = all PASS, 1 = any FAIL, 77 = SKIP (lib/i18n.sh not found).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
I18N_SH="${REPO_ROOT}/lib/i18n.sh"

if [[ ! -f "$I18N_SH" ]]; then
    echo "SKIP: ${I18N_SH} not found"
    exit 77
fi

echo "## test_i18n.sh"

PASS=0; FAIL=0

_assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: ${label}"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        actual:   $(printf '%q' "$actual")"
        FAIL=$(( FAIL + 1 ))
    fi
}

_assert_ne() {
    local label="$1" unexpected="$2" actual="$3"
    if [[ "$unexpected" != "$actual" ]]; then
        echo "  PASS: ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: ${label} — got unexpected value: $(printf '%q' "$actual")"
        FAIL=$(( FAIL + 1 ))
    fi
}

_assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: ${label}"
        echo "        expected to contain: $(printf '%q' "$needle")"
        echo "        actual:              $(printf '%q' "$haystack")"
        FAIL=$(( FAIL + 1 ))
    fi
}

# TC1: AGMIND_LANG=en → t() returns English string (not the key, not the RU string)
result=$(env -i AGMIND_LANG=en HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    t wizard.llm_provider.title
")
_assert_eq "TC1: AGMIND_LANG=en gives English title" \
    "LLM Provider" "$result"

# TC2: AGMIND_LANG=ru → t() returns Russian string
result=$(env -i AGMIND_LANG=ru HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    t wizard.llm_provider.title
")
_assert_eq "TC2: AGMIND_LANG=ru gives Russian title" \
    "LLM-провайдер" "$result"

# TC3: EN and RU strings differ (sanity — not the same value)
en_val=$(env -i AGMIND_LANG=en HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}; t wizard.llm_provider.title")
ru_val=$(env -i AGMIND_LANG=ru HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}; t wizard.llm_provider.title")
_assert_ne "TC3: EN != RU for wizard.llm_provider.title" "$en_val" "$ru_val"

# TC4: missing key → t() prints the key itself (key fallback)
result=$(env -i AGMIND_LANG=en HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    t zzz.nonexistent.key
")
_assert_eq "TC4: missing key falls back to key string" \
    "zzz.nonexistent.key" "$result"

# TC5: autodetect — LANG=ru_RU.UTF-8, no AGMIND_LANG → AGMIND_LANG=ru
result=$(env -i LANG=ru_RU.UTF-8 HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    echo \$AGMIND_LANG
")
_assert_eq "TC5: autodetect LANG=ru_RU.UTF-8 → AGMIND_LANG=ru" \
    "ru" "$result"

# TC6: autodetect — LANG=C → AGMIND_LANG=en
result=$(env -i LANG=C HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    echo \$AGMIND_LANG
")
_assert_eq "TC6: autodetect LANG=C → AGMIND_LANG=en" \
    "en" "$result"

# TC7: autodetect — LANG=en_US.UTF-8 → AGMIND_LANG=en
result=$(env -i LANG=en_US.UTF-8 HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    echo \$AGMIND_LANG
")
_assert_eq "TC7: autodetect LANG=en_US.UTF-8 → AGMIND_LANG=en" \
    "en" "$result"

# TC8: explicit AGMIND_LANG=ru wins over LANG=en_US.UTF-8
result=$(env -i LANG=en_US.UTF-8 AGMIND_LANG=ru HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    echo \$AGMIND_LANG
")
_assert_eq "TC8: explicit AGMIND_LANG=ru wins over LANG=en_US.UTF-8" \
    "ru" "$result"

# TC9: invalid AGMIND_LANG=de → normalises to en
result=$(env -i AGMIND_LANG=de HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    echo \$AGMIND_LANG
")
_assert_eq "TC9: invalid AGMIND_LANG=de → normalised to en" \
    "en" "$result"

# TC10: LC_ALL=ru_RU.UTF-8 wins over unset LANG
result=$(env -i LC_ALL=ru_RU.UTF-8 HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    echo \$AGMIND_LANG
")
_assert_eq "TC10: LC_ALL=ru_RU.UTF-8 (no LANG) → AGMIND_LANG=ru" \
    "ru" "$result"

# TC11: t() EN opt_vllm contains expected English text
result=$(env -i AGMIND_LANG=en HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    t wizard.llm_provider.opt_vllm
")
_assert_contains "TC11: EN opt_vllm contains 'DGX Spark'" "DGX Spark" "$result"

# TC12: t() RU opt_vllm contains expected Russian text
result=$(env -i AGMIND_LANG=ru HOME="${HOME}" bash --noprofile --norc -c "
    source ${I18N_SH}
    t wizard.llm_provider.opt_vllm
")
_assert_contains "TC12: RU opt_vllm contains 'DGX Spark'" "DGX Spark" "$result"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
