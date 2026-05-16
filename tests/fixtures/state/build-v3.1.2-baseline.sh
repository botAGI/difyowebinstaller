#!/usr/bin/env bash
# tests/fixtures/state/build-v3.1.2-baseline.sh
# Reproducible builder for tests/fixtures/state/v3.1.2-baseline.tar.gz.
#
# Synthetic v3.1.x state-layout baseline used by:
#   tests/integration/test_upgrade_v3_1_2_to_v3_2_0.sh (STATE-10)
#
# Tricky values include $/#/quotes/spaces to prove _env_get_raw byte-exactness
# AND state_set_secret/state_get_secret round-trip integrity.
#
# All secret values are SYNTHETIC TEST-ONLY (recognizable markers); not derived
# from any production credential. See threat T-11-04-03 in plan frontmatter.
#
# Re-run is safe and deterministic: tar --mtime=@1767225600 + --sort=name +
# --owner=0 --group=0 --numeric-owner lock all non-deterministic inputs ->
# byte-identical archive each invocation (verifiable via sha256sum).
#
# Usage:
#   bash tests/fixtures/state/build-v3.1.2-baseline.sh
#
# Output: tests/fixtures/state/v3.1.2-baseline.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
OUT="${REPO_ROOT}/tests/fixtures/state/v3.1.2-baseline.tar.gz"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/state" "$T/docker"

# Three .preserved files — match exactly what lib/config.sh::_generate_secrets writes
# (mode 0600, byte-exact content via printf '%s'; no trailing newline beyond what
# printf produces).
printf '%s' 'surreal-pw-with-$dollar-and-#hash' > "$T/state/surrealdb_password.preserved"
# n8n encryption key: hex/base64 style, no newline (matches lib/config.sh::_generate_secrets output)
printf '%s' 'n8n-key-abc123-deadbeef-0123456789abcdef' > "$T/state/n8n_encryption_key.preserved"
printf '%s' 'portainer-shared-secret-xyz' > "$T/state/portainer_agent_secret.preserved"
chmod 0600 "$T/state"/*.preserved

# Synthetic docker/.env — secrets include $, #, quotes, spaces.
# Also include placeholders (__X__) and empty values to verify migration 001 skip logic.
# Comment lines verify _env_get_raw correctly ignores them.
cat > "$T/docker/.env" <<'ENV'
# Synthetic v3.1.2 docker/.env baseline — DO NOT EDIT, regenerate via build-v3.1.2-baseline.sh
DB_PASSWORD=postgresPw$with$special#chars
REDIS_PASSWORD=redisPw 123 with spaces
SECRET_KEY=dify-secret-64-char-string-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MINIO_ROOT_PASSWORD=minio "quoted" pw
SANDBOX_API_KEY=dify-sandbox-test-key
PLUGIN_DAEMON_KEY=plugin-daemon-key-aaa
PLUGIN_INNER_API_KEY=plugin-inner-key-bbb
WEAVIATE_API_KEY=weaviate-key-ccc
QDRANT_API_KEY=qdrant-key-ddd
GRAFANA_ADMIN_PASSWORD=__GRAFANA_ADMIN_PASSWORD__
AUTHELIA_JWT_SECRET=authelia-jwt-secret-64-chars-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
AUTHELIA_SESSION_SECRET=authelia-session-secret
AUTHELIA_STORAGE_KEY=authelia-storage-key
LITELLM_MASTER_KEY=sk-litellm-master-32-chars-aaaaaaaaa
SEARXNG_SECRET_KEY=searxng-secret-32
MINIO_ROOT_USER=agmind-admin
S3_ACCESS_KEY=s3-access-key-20
S3_SECRET_KEY=s3-secret-key-40-chars-aaaaaaaaaaaaaaa
RAGFLOW_MYSQL_PASSWORD=
RAGFLOW_ES_PASSWORD=ragflow-es-pw
RAGFLOW_MINIO_PASSWORD=ragflow-minio-pw
NOTEBOOK_ENCRYPTION_KEY=notebook-enc-key-32
ENV
chmod 0600 "$T/docker/.env"

# Deterministic tar — lock mtime/owner/sort so re-runs yield byte-identical archive.
# Format mtime 2026-01-01T00:00:00Z (= 1767225600).
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='@1767225600' \
    -czf "$OUT" -C "$T" state docker

echo "Built: $OUT"
ls -la "$OUT"
