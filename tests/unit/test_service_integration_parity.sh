#!/usr/bin/env bash
# test_service_integration_parity.sh — Static cross-layer wiring parity for
# optional ENABLE_X services. Catches the 260513-5ep class: service added to
# wizard + compose but forgotten in nginx vhost / avahi alias / final summary.
#
# Pure static parse against repo source. <2s. No docker, no env generation.
#
# Exit: 0 = all PASS, 1 = any FAIL, 77 = SKIP (required source missing).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ============================================================================
# SKIP PROBE — required source files
# ============================================================================
for _f in \
    "${REPO_ROOT}/templates/env.lan.template" \
    "${REPO_ROOT}/lib/wizard.sh" \
    "${REPO_ROOT}/lib/config.sh" \
    "${REPO_ROOT}/lib/compose.sh" \
    "${REPO_ROOT}/lib/health.sh" \
    "${REPO_ROOT}/templates/nginx.conf.template" \
    "${REPO_ROOT}/install.sh" \
    "${REPO_ROOT}/templates/docker-compose.yml"
do
    if [[ ! -f "$_f" ]]; then
        echo "SKIP: required source missing: ${_f}"
        exit 77
    fi
done

echo "## test_service_integration_parity.sh"

PASS=0; FAIL=0

# ============================================================================
# HELPERS
# ============================================================================

_assert_present_in_file() {
    # label, regex (ERE), file
    local label="$1" regex="$2" file="$3"
    if grep -qE "$regex" "$file" 2>/dev/null; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        regex:  ${regex}"
        echo "        file:   ${file#"${REPO_ROOT}/"}"
        FAIL=$((FAIL + 1))
    fi
}

_assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        actual:   $(printf '%q' "$actual")"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================================
# HARDCODED SKIP-LIST (document rationale per entry)
# ============================================================================
declare -A SKIP_SERVICES
SKIP_SERVICES["ENABLE_DIFY_PREMIUM"]="feature flag, not a container/UI — no vhost or avahi needed"
SKIP_SERVICES["ENABLE_UFW"]="security toggle, not a service — no compose profile"
SKIP_SERVICES["ENABLE_FAIL2BAN"]="security toggle, not a service — no compose profile"
SKIP_SERVICES["ENABLE_RERANKER"]="GPU sub-service of vLLM/TEI, no nginx vhost"
SKIP_SERVICES["ENABLE_AUTHELIA"]="reverse-proxy auth layer — has #__AUTHELIA__ but no dedicated vhost/avahi"
SKIP_SERVICES["ENABLE_DOCLING"]="ETL mode flag — activated via ETL_TYPE=unstructured_api, no __ENABLE_DOCLING__ placeholder in env template by design"

# Services that have compose profile + avahi but NO explicit health.sh service-list entry
# (managed by docker-compose healthcheck, not agmind health.sh service list)
declare -A SKIP_D_LAYER
SKIP_D_LAYER["ENABLE_MINIO"]="MinIO health is managed via compose healthcheck, not tracked in health.sh get_service_list by design"

# ============================================================================
# DISCOVER WIZARD-MANAGED ENABLE_X TOKENS
# Intersection of:
#   (a) names appearing inside _init_wizard_defaults() in lib/wizard.sh
#   (b) tokens on line-start in templates/env.lan.template
# This filters out non-wizard flags (ENABLE_SIGNUP, ENABLE_LOKI, etc.).
# ============================================================================
mapfile -t _WIZARD_ENABLES < <(
    awk '/^_init_wizard_defaults\(\) \{/,/^\}/' "${REPO_ROOT}/lib/wizard.sh" \
        | grep -oE 'ENABLE_[A-Z0-9_]+' \
        | sort -u
)
mapfile -t _ENV_ENABLES < <(
    grep -oE '^ENABLE_[A-Z0-9_]+' "${REPO_ROOT}/templates/env.lan.template" | sort -u
)
mapfile -t SERVICES < <(
    comm -12 \
        <(printf '%s\n' "${_WIZARD_ENABLES[@]}" | sort -u) \
        <(printf '%s\n' "${_ENV_ENABLES[@]}" | sort -u)
)

echo "  Discovered ${#SERVICES[@]} wizard-managed ENABLE_X tokens"

# ============================================================================
# PER-SERVICE LAYER PARITY: A (wizard defaults) + B (env template + config.sh sed)
#                          + C (compose dispatch) + D (health dispatch)
# ============================================================================
echo ""
echo "--- Per-service layer parity ---"

for svc in "${SERVICES[@]}"; do
    if [[ -n "${SKIP_SERVICES["$svc"]:-}" ]]; then
        echo "  [${svc}] SKIP — ${SKIP_SERVICES["$svc"]}"
        continue
    fi

    # A. wizard defaults — must contain ENABLE_X="${ENABLE_X:-...}
    _assert_present_in_file \
        "[${svc}] A:wizard_defaults" \
        "[[:space:]]+${svc}=\"\\\$\{${svc}:-" \
        "${REPO_ROOT}/lib/wizard.sh"

    # B. env-template placeholder — __ENABLE_X__ must appear in template
    _assert_present_in_file \
        "[${svc}] B:env_template_placeholder" \
        "__${svc}__" \
        "${REPO_ROOT}/templates/env.lan.template"

    # B. config.sh sed substitution — must have s|__ENABLE_X__| line
    _assert_present_in_file \
        "[${svc}] B:config_sh_sed_substitution" \
        "s\|__${svc}__\|" \
        "${REPO_ROOT}/lib/config.sh"

    # C. compose profile dispatch — ENABLE_X referenced in lib/compose.sh
    _assert_present_in_file \
        "[${svc}] C:compose_dispatch" \
        "${svc}" \
        "${REPO_ROOT}/lib/compose.sh"

    # D. health-check coverage — ENABLE_X referenced in lib/health.sh
    # Some services (e.g. ENABLE_MINIO) are managed via compose healthcheck
    # rather than the agmind health.sh service list — those are in SKIP_D_LAYER.
    if [[ -n "${SKIP_D_LAYER["$svc"]:-}" ]]; then
        echo "  [${svc}] D:health_dispatch SKIP-D — ${SKIP_D_LAYER["$svc"]}"
    else
        _assert_present_in_file \
            "[${svc}] D:health_dispatch" \
            "${svc}" \
            "${REPO_ROOT}/lib/health.sh"
    fi
done

# ============================================================================
# AVAHI ALIAS → NGINX VHOST PARITY
# Parse agmind-<name> patterns from _register_local_dns() in lib/config.sh.
# For each alias, nginx.conf.template must have a matching server_name line.
# Core aliases (agmind-dify, agmind-grafana, agmind-portainer, agmind-vllm)
# are hardcoded and always present — they still pass the server_name check.
# ============================================================================
echo ""
echo "--- Avahi alias → nginx server_name parity ---"

mapfile -t AVAHI_NAMES < <(
    # Only look at lines that add to the names array (names+=("agmind-xxx"))
    # to avoid false positives from comments and variable names like agmind-mdns-publish.
    # Use [a-z][a-z0-9-]* to capture names with digits (e.g. agmind-n8n).
    awk '/^_register_local_dns\(\) \{/,/^\}/' "${REPO_ROOT}/lib/config.sh" \
        | grep 'names+=(' \
        | grep -oE 'agmind-[a-z][a-z0-9-]*' \
        | sort -u
)

echo "  Discovered ${#AVAHI_NAMES[@]} avahi aliases in _register_local_dns"

for name in "${AVAHI_NAMES[@]}"; do
    _assert_present_in_file \
        "[${name}] F:nginx_server_name" \
        "server_name[[:space:]]+${name}\.local" \
        "${REPO_ROOT}/templates/nginx.conf.template"
done

# ============================================================================
# NGINX #__MARKER__ ROUND-TRIP
# Every #__MARKER__ token in nginx.conf.template must have at least one
# matching _atomic_sed line in generate_nginx_config in lib/config.sh.
#
# Note: [A-Z0-9_] is intentional — N8N and CRAWL4AI contain digits.
# Using only [A-Z_] would silently miss these two markers (confirmed bug).
# ============================================================================
echo ""
echo "--- nginx #__MARKER__ round-trip ---"

mapfile -t MARKERS < <(
    grep -oE '#__[A-Z0-9_]+__' "${REPO_ROOT}/templates/nginx.conf.template" \
        | sed 's/#__\(.*\)__/\1/' \
        | sort -u
)

echo "  Discovered ${#MARKERS[@]} #__MARKER__ tokens in nginx.conf.template"

for m in "${MARKERS[@]}"; do
    # Must have at least one _atomic_sed call touching this marker (enable OR disable path)
    _assert_present_in_file \
        "[#__${m}__] G:has_atomic_sed_in_config_sh" \
        "_atomic_sed[[:space:]].*#__${m}__" \
        "${REPO_ROOT}/lib/config.sh"
done

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
