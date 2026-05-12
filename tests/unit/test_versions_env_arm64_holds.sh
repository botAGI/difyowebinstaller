#!/usr/bin/env bash
# test_versions_env_arm64_holds.sh — Regression gate for arm64-manifest hold rules.
# Каждое правило ниже было выработано через реальный факап в проде. Если кто-то
# (включая будущего меня) bumpит версию мимо hold'а — этот тест должен падать
# красным в CI ДО того как изменение долетит до prod.
#
# Sources: docs/adr/0009-cadvisor-minio-arm64-holds.md + project institutional rules.
#
# Exit: 0 = all PASS, 1 = any FAIL, 77 = skip (env file missing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERSIONS="${REPO_ROOT}/templates/versions.env"
ENV_LAN="${REPO_ROOT}/templates/env.lan.template"

if [[ ! -f "$VERSIONS" ]]; then
    echo "SKIP: ${VERSIONS} not found"
    exit 77
fi

echo "## test_versions_env_arm64_holds"

fail=0
pass=0

_assert() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: ${label}"
        pass=$((pass+1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        fail=$((fail+1))
    fi
}

_get_version() {
    grep -E "^${1}=" "$VERSIONS" | head -1 | cut -d'=' -f2-
}

# Rule 1: cAdvisor — MUST stay ≤ v0.55.1 (verified arm64).
# §8: «v0.53.0, v0.54.0, v0.55.0, v0.56.x — arm64 manifest broken».
# Re-verified 2026-05-11: v0.56.2 GCR manifest вернул platforms=[].
cadv="$(_get_version CADVISOR_VERSION)"
_assert "cAdvisor pinned to v0.55.1 (arm64 hold)" "v0.55.1" "$cadv"

# Rule 2: MinIO — MUST stay ≤ RELEASE.2025-09-07T16-13-09Z (verified arm64).
# §8: «RELEASE.2025-09-30, 2025-10-08, 2025-10-15 — arm64 dropped из manifest».
# Verified 2026-05-11.
minio="$(_get_version MINIO_VERSION)"
_assert "MinIO pinned to last arm64 release" "RELEASE.2025-09-07T16-13-09Z" "$minio"

# Rule 3: Plugin daemon — golden stable 0.5.3-local until 0.5.7 ships.
# §8: «0.5.4 #640 null-content; 0.5.5 #640 still; 0.5.6 #672 broken auto-migrate».
# 0.6.0 release notes минимальные — deep-dive нужен ДО bump (memory project_dify_version_status).
pd="$(_get_version PLUGIN_DAEMON_VERSION)"
_assert "Plugin daemon pinned to 0.5.3-local (golden stable)" "0.5.3-local" "$pd"

# Rule 4: vLLM Spark image — HARD HOLD per §8.
# DGX Spark driver 580 + sm_121 + 580 UMA leak + 595 TMA bug — НЕ обновлять
# VLLM_SPARK_IMAGE без testing on Spark hardware.
vllm_spark="$(_get_version VLLM_SPARK_IMAGE)"
_assert "vLLM Spark image pinned to gemma4-cu130 (driver 580 hold)" \
    "vllm/vllm-openai:gemma4-cu130" "$vllm_spark"
ngc="$(_get_version VLLM_NGC_VERSION)"
_assert "VLLM NGC version pinned to 26.02-py3 (driver 580 hold)" \
    "26.02-py3" "$ngc"

# Rule 5: Docling — STAY на v1.16.1 пока v1.17 RapidOCR regression / v1.18 not verified.
# §8: «Docling 1.17 has RapidOcr regression: container ищет PP-OCRv4 ONNX model».
docling_cuda="$(_get_version DOCLING_IMAGE_CUDA)"
case "$docling_cuda" in
    *":v1.16.1"|*":v1.16."[0-9]*)
        echo "  PASS: Docling pinned to v1.16.x (RapidOCR regression hold)"
        pass=$((pass+1))
        ;;
    *)
        echo "  FAIL: Docling pinned to v1.16.x (RapidOCR regression hold)"
        echo "        expected: *:v1.16.x"
        echo "        actual:   ${docling_cuda}"
        fail=$((fail+1))
        ;;
esac

# Rule 6: Portainer master ↔ agent versions MUST match (TLS handshake protocol).
# §8: «Portainer master ↔ peer Agent version mismatch = TLS handshake EOF».
if [[ -f "$ENV_LAN" ]]; then
    portainer_master="$(_get_version PORTAINER_VERSION)"
    portainer_agent="$(grep -E '^PORTAINER_AGENT_VERSION=' "$ENV_LAN" | head -1 | cut -d'=' -f2-)"
    _assert "Portainer master == agent version (TLS protocol sync)" \
        "$portainer_master" "$portainer_agent"
else
    echo "  SKIP: ${ENV_LAN} not found — Portainer alignment check skipped"
fi

# Rule 7: SOPS hashes — must be 64-char hex (SHA256 length).
# Lib/security.sh refuses install on mismatch — bad format = silent fail.
sops_arm64="$(_get_version SOPS_SHA256_ARM64)"
sops_amd64="$(_get_version SOPS_SHA256_AMD64)"
if [[ "$sops_arm64" =~ ^[a-f0-9]{64}$ ]]; then
    echo "  PASS: SOPS_SHA256_ARM64 valid 64-char hex"
    pass=$((pass+1))
else
    echo "  FAIL: SOPS_SHA256_ARM64 not valid 64-char hex"
    echo "        actual: ${sops_arm64}"
    fail=$((fail+1))
fi
if [[ "$sops_amd64" =~ ^[a-f0-9]{64}$ ]]; then
    echo "  PASS: SOPS_SHA256_AMD64 valid 64-char hex"
    pass=$((pass+1))
else
    echo "  FAIL: SOPS_SHA256_AMD64 not valid 64-char hex"
    echo "        actual: ${sops_amd64}"
    fail=$((fail+1))
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
