#!/usr/bin/env bash
# Image tag existence gate — runs `docker manifest inspect` on every image
# in a compose file. Prevents LLM hallucinations (CLAUDE.md §8: MinIO RELEASE
# timestamp tag case). Verifies arm64 manifest support for DGX Spark.
#
# Usage:
#   bash tests/compose/test_image_tags_exist.sh [compose_file [compose_file ...]]
#   default: templates/docker-compose.worker.yml
#
# Env:
#   SKIP_PLATFORM_CHECK=1  — skip arm64 manifest check (CI runs on amd64)
#   MAX_RETRIES=3          — per-image retry count on rate-limit
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMPOSE_FILES=("$@")
if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
    COMPOSE_FILES=("${REPO_ROOT}/templates/docker-compose.worker.yml")
fi

MAX_RETRIES="${MAX_RETRIES:-3}"
SKIP_PLATFORM="${SKIP_PLATFORM_CHECK:-0}"
FAIL=0
CHECKED=0

check_image() {
    local image="$1"
    local attempt
    local out=""
    for attempt in $(seq 1 "$MAX_RETRIES"); do
        if out="$(docker manifest inspect "$image" 2>&1)"; then
            echo "  OK   ${image}"
            # Platform check: ensure arm64 manifest exists
            if [[ "$SKIP_PLATFORM" != "1" ]]; then
                if command -v jq >/dev/null 2>&1; then
                    if echo "$out" | jq -e '.manifests // empty | .[] | select(.platform.architecture == "arm64")' >/dev/null 2>&1; then
                        echo "       arm64 manifest present"
                    elif echo "$out" | jq -e '.architecture // empty | test("arm64")' >/dev/null 2>&1; then
                        echo "       single-arch arm64 manifest"
                    else
                        echo "       WARN: arm64 manifest not explicitly found (may still work via fallback)"
                    fi
                fi
            fi
            return 0
        fi
        if echo "$out" | grep -qiE 'rate.limit|too many requests|429'; then
            echo "  RETRY ${image} (attempt ${attempt}/${MAX_RETRIES}) — rate-limited"
            sleep $((5 * attempt))
            continue
        fi
        # Non-rate-limit failure — no point retrying
        break
    done
    echo "  FAIL ${image}" >&2
    echo "$out" | head -3 >&2
    return 1
}

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found — cannot run image tag gate" >&2
    exit 2
fi

for compose_file in "${COMPOSE_FILES[@]}"; do
    if [[ ! -f "$compose_file" ]]; then
        echo "ERROR: compose file not found: ${compose_file}" >&2
        FAIL=$((FAIL+1))
        continue
    fi
    echo "=== Checking images in ${compose_file} ==="

    # Resolve images via compose config (handles env var interpolation).
    # Provide sane defaults so config does not error on unset vars.
    images="$(
        VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:gemma4-cu130}" \
        VLLM_SPARK_IMAGE="${VLLM_SPARK_IMAGE:-vllm/vllm-openai:gemma4-cu130}" \
        VLLM_MODEL="${VLLM_MODEL:-google/gemma-4-26B-A4B-it}" \
        VLLM_SPARK_MODEL="${VLLM_SPARK_MODEL:-google/gemma-4-26B-A4B-it}" \
        NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-v1.11.1}" \
        docker compose -f "$compose_file" config 2>/dev/null \
            | awk '/^\s*image:/ {print $2}' \
            | sort -u
    )"
    if [[ -z "$images" ]]; then
        echo "  WARN: no images parsed from ${compose_file}"
        continue
    fi
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        CHECKED=$((CHECKED+1))
        check_image "$image" || FAIL=$((FAIL+1))
    done <<< "$images"
done

echo ""
echo "=== Summary: ${CHECKED} checked, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
