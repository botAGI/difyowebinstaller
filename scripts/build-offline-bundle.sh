#!/usr/bin/env bash
# ============================================================================
# AGMind Offline Bundle Builder
# Creates a self-contained archive for air-gapped installation
#
# Usage: ./build-offline-bundle.sh [--output DIR] [--include-models MODEL1,MODEL2]
#        [--platform linux/amd64|linux/arm64] [--skip-images]
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/dist"
INCLUDE_MODELS=""
PLATFORM="linux/amd64"
SKIP_IMAGES=false
BUNDLE_NAME="agmind-offline"
INCLUDE_DOCLING_CUDA="${INCLUDE_DOCLING_CUDA:-false}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_DIR="$2"; shift 2 ;;
        --include-models)
            INCLUDE_MODELS="$2"; shift 2 ;;
        --platform)
            PLATFORM="$2"; shift 2 ;;
        --skip-images)
            SKIP_IMAGES=true; shift ;;
        --name)
            BUNDLE_NAME="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --output DIR           Output directory (default: ./dist)"
            echo "  --include-models M1,M2 Include Ollama models (e.g., llama3.2,nomic-embed-text)"
            echo "  --platform PLAT        Target platform (default: linux/amd64)"
            echo "  --skip-images          Skip Docker image export (for testing)"
            echo "  --name NAME            Bundle name prefix (default: agmind-offline)"
            echo ""
            echo "Environment variables:"
            echo "  INCLUDE_DOCLING_CUDA=true  Include Docling CUDA image in bundle (+5-8 GB)"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  AGMind Offline Bundle Builder${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo ""

# ──────────────────────────────────────────
# Pre-checks
# ──────────────────────────────────────────
echo -e "${BOLD}Pre-flight checks${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${RED}Docker is required${NC}"
    exit 1
fi

if ! docker info &>/dev/null; then
    echo -e "${RED}Docker daemon not running${NC}"
    exit 1
fi

# Check disk space (need ~10GB for images)
free_gb=$(df -BG "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2{gsub(/G/,"");print $4}' || echo "0")
if [[ "${free_gb:-0}" -lt 10 ]] 2>/dev/null; then
    echo -e "${YELLOW}Warning: Only ${free_gb}GB free (10GB+ recommended)${NC}"
fi

# Source versions
VERSIONS_FILE="${SCRIPT_DIR}/versions.env"
if [[ -f "$VERSIONS_FILE" ]]; then
    # Safe parsing — allow VERSION vars and DOCLING_IMAGE_* vars
    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*_VERSION$ ]] || \
           [[ "$key" =~ ^DOCLING_IMAGE_(CPU|CUDA)$ ]]; then
            export "$key=$value"
        fi
    done < <(grep -E '^[A-Za-z_].*(=)' "$VERSIONS_FILE" | grep -v '^#')
    echo -e "${GREEN}✓ Loaded versions from versions.env${NC}"
else
    echo -e "${RED}versions.env not found!${NC}"
    exit 1
fi

# ──────────────────────────────────────────
# Stage 1: Prepare staging directory
# ──────────────────────────────────────────
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo ""
echo -e "${BOLD}Stage 1: Preparing installer files${NC}"

# Copy installer (exclude .git, docs, tests, dist)
rsync -a \
    --exclude='.git' \
    --exclude='docs/' \
    --exclude='tests/' \
    --exclude='dist/' \
    --exclude='*.tar.gz' \
    --exclude='node_modules/' \
    "${SCRIPT_DIR}/" "${STAGING}/agmind-installer/"

echo -e "${GREEN}✓ Installer files staged${NC}"

# ──────────────────────────────────────────
# Stage 2: Pull and export Docker images
# ──────────────────────────────────────────
if [[ "$SKIP_IMAGES" != "true" ]]; then
    echo ""
    echo -e "${BOLD}Stage 2: Pulling Docker images (platform: ${PLATFORM})${NC}"

    cd "${SCRIPT_DIR}"

    # Get list of images from docker-compose
    COMPOSE_FILE="${SCRIPT_DIR}/templates/docker-compose.yml"
    if [[ -f "$COMPOSE_FILE" ]]; then
        # Pull all images for target platform
        echo -e "${CYAN}→ Pulling images...${NC}"
        DOCKER_DEFAULT_PLATFORM="$PLATFORM" docker compose -f "$COMPOSE_FILE" pull 2>&1 | tail -5

        # Get image list
        images=$(docker compose -f "$COMPOSE_FILE" config --images 2>/dev/null | sort -u)

        echo ""
        echo -e "${BOLD}Exporting images:${NC}"
        echo "$images" | while read -r img; do
            echo "  → $img"
        done

        # Ensure Docling CPU image is included (always in bundle)
        DOCLING_IMAGE_CPU="${DOCLING_IMAGE_CPU:-ghcr.io/docling-project/docling-serve:v1.14.3}"
        if ! echo "$images" | grep -qF "docling"; then
            echo -e "${CYAN}→ Pulling Docling CPU image: ${DOCLING_IMAGE_CPU}${NC}"
            DOCKER_DEFAULT_PLATFORM="$PLATFORM" docker pull "${DOCLING_IMAGE_CPU}" 2>&1 | tail -3
            images="${images}"$'\n'"${DOCLING_IMAGE_CPU}"
        fi

        # Docling CUDA image (optional, +5-8 GB)
        if [[ "${INCLUDE_DOCLING_CUDA}" == "true" ]]; then
            DOCLING_IMAGE_CUDA="${DOCLING_IMAGE_CUDA:-quay.io/docling-project/docling-serve-cu128:v1.14.3}"
            echo ""
            echo -e "${CYAN}→ Including Docling CUDA image: ${DOCLING_IMAGE_CUDA}${NC}"
            DOCKER_DEFAULT_PLATFORM="$PLATFORM" docker pull "${DOCLING_IMAGE_CUDA}" 2>&1 | tail -3
            images="${images}"$'\n'"${DOCLING_IMAGE_CUDA}"
        fi

        # Save all images to a single tar
        echo ""
        echo -e "${CYAN}→ Saving images to tar (this may take a while)...${NC}"
        # shellcheck disable=SC2086
        docker save $images | gzip > "${STAGING}/agmind-images.tar.gz"
        image_size=$(du -sh "${STAGING}/agmind-images.tar.gz" | cut -f1)
        echo -e "${GREEN}✓ Images exported: ${image_size}${NC}"
    else
        echo -e "${RED}docker-compose.yml not found!${NC}"
        exit 1
    fi
else
    echo ""
    echo -e "${YELLOW}⚠ Skipping Docker image export (--skip-images)${NC}"
fi

# ──────────────────────────────────────────
# Stage 3: Pull Ollama models (optional)
# ──────────────────────────────────────────
if [[ -n "$INCLUDE_MODELS" ]]; then
    echo ""
    echo -e "${BOLD}Stage 3: Pulling Ollama models${NC}"

    OLLAMA_VERSION="${OLLAMA_VERSION:-0.6.2}"
    MODEL_VOLUME="agmind-bundle-models-$$"

    # Create temporary volume
    docker volume create "$MODEL_VOLUME" >/dev/null

    IFS=',' read -ra models <<< "$INCLUDE_MODELS"
    for model in "${models[@]}"; do
        model=$(echo "$model" | tr -d ' ')
        echo -e "  ${CYAN}→ Pulling model: ${model}${NC}"
        docker run --rm -v "${MODEL_VOLUME}:/root/.ollama" \
            "ollama/ollama:${OLLAMA_VERSION}" pull "$model" 2>&1 | tail -3
    done

    # Export models volume
    echo -e "${CYAN}→ Exporting models...${NC}"
    docker run --rm -v "${MODEL_VOLUME}:/data:ro" -v "${STAGING}:/output" \
        alpine tar czf /output/ollama-models.tar.gz -C /data .

    model_size=$(du -sh "${STAGING}/ollama-models.tar.gz" | cut -f1)
    echo -e "${GREEN}✓ Models exported: ${model_size}${NC}"

    # Cleanup
    docker volume rm "$MODEL_VOLUME" >/dev/null 2>&1 || true
else
    echo ""
    echo -e "${YELLOW}⚠ No Ollama models included (use --include-models to add)${NC}"
fi

# ──────────────────────────────────────────
# Stage 4: Create install wrapper
# ──────────────────────────────────────────
echo ""
echo -e "${BOLD}Stage 4: Creating install wrapper${NC}"

cat > "${STAGING}/install-offline.sh" << 'WRAPPER'
#!/usr/bin/env bash
# AGMind Offline Installer Wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo "═══════════════════════════════════════"
echo "  AGMind Offline Installation"
echo "═══════════════════════════════════════"
echo ""

# Root check
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root: sudo bash $0${NC}"
    exit 1
fi

# Load Docker images
if [[ -f "${SCRIPT_DIR}/agmind-images.tar.gz" ]]; then
    echo -e "${YELLOW}Loading Docker images (this may take a while)...${NC}"
    docker load < "${SCRIPT_DIR}/agmind-images.tar.gz"
    echo -e "${GREEN}✓ Docker images loaded${NC}"
else
    echo -e "${RED}agmind-images.tar.gz not found!${NC}"
    exit 1
fi

# Load Ollama models if present
if [[ -f "${SCRIPT_DIR}/ollama-models.tar.gz" ]]; then
    echo -e "${YELLOW}Loading Ollama models...${NC}"
    docker volume create agmind_ollama_data 2>/dev/null || true
    docker run --rm \
        -v agmind_ollama_data:/data \
        -v "${SCRIPT_DIR}:/input:ro" \
        alpine sh -c "tar xzf /input/ollama-models.tar.gz -C /data"
    echo -e "${GREEN}✓ Ollama models loaded${NC}"
fi

# Run installer
echo ""
echo -e "${YELLOW}Starting AGMind installer...${NC}"
export DEPLOY_PROFILE="${DEPLOY_PROFILE:-offline}"
cd "${SCRIPT_DIR}/agmind-installer"
exec bash install.sh "$@"
WRAPPER

chmod +x "${STAGING}/install-offline.sh"
echo -e "${GREEN}✓ Install wrapper created${NC}"

# ──────────────────────────────────────────
# Stage 5: Create final bundle
# ──────────────────────────────────────────
echo ""
echo -e "${BOLD}Stage 5: Creating final bundle${NC}"

mkdir -p "$OUTPUT_DIR"
BUNDLE_FILE="${OUTPUT_DIR}/${BUNDLE_NAME}-$(date +%Y%m%d).tar.gz"

cd "$(dirname "$STAGING")"
tar czf "$BUNDLE_FILE" -C "$STAGING" .

bundle_size=$(du -sh "$BUNDLE_FILE" | cut -f1)

# ──────────────────────────────────────────
# Stage 6: Bundle Verification
# ──────────────────────────────────────────
echo ""
echo -e "${BOLD}Stage 6: Bundle Verification${NC}"

# Get expected images from compose (default services)
COMPOSE_FILE="${SCRIPT_DIR}/templates/docker-compose.yml"
expected_images="$(docker compose -f "$COMPOSE_FILE" config --images 2>/dev/null | sort -u)"

# Also collect images from named profiles (tei, reranker, docling)
for profile in tei reranker docling; do
    _profile_imgs="$(COMPOSE_PROFILES="$profile" docker compose -f "$COMPOSE_FILE" config --images 2>/dev/null | sort -u)" || true
    if [[ -n "$_profile_imgs" ]]; then
        expected_images="$(printf '%s\n%s' "$expected_images" "$_profile_imgs" | sort -u)"
    fi
done

# Add Docling CPU image (always expected in bundle)
DOCLING_IMAGE_CPU="${DOCLING_IMAGE_CPU:-ghcr.io/docling-project/docling-serve:v1.14.3}"
expected_images="$(printf '%s\n%s' "$expected_images" "$DOCLING_IMAGE_CPU" | sort -u)"

# Add Docling CUDA image if flag set
if [[ "${INCLUDE_DOCLING_CUDA}" == "true" ]]; then
    DOCLING_IMAGE_CUDA="${DOCLING_IMAGE_CUDA:-quay.io/docling-project/docling-serve-cu128:v1.14.3}"
    expected_images="$(printf '%s\n%s' "$expected_images" "$DOCLING_IMAGE_CUDA" | sort -u)"
fi

# Remove blank lines from expected_images
expected_images="$(echo "$expected_images" | sed '/^[[:space:]]*$/d')"

# Get actual images saved in bundle from tar manifest
actual_images=""
if [[ -f "${STAGING}/agmind-images.tar.gz" ]]; then
    actual_images="$(tar -xzf "${STAGING}/agmind-images.tar.gz" manifest.json -O 2>/dev/null \
        | grep -oP '"RepoTags":\["[^"]*"' \
        | grep -oP '[^"[]*:[^"[]*$' \
        | sort -u)" || true
fi

# Fallback: check locally available images (they were pulled in Stage 2)
if [[ -z "$actual_images" ]]; then
    actual_images=""
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        if docker image inspect "$img" >/dev/null 2>&1; then
            actual_images="$(printf '%s\n%s' "$actual_images" "$img")"
        fi
    done <<< "$expected_images"
    actual_images="$(echo "$actual_images" | sort -u | sed '/^[[:space:]]*$/d')"
fi

# Compare expected vs actual
missing=0
extra=0
echo ""
echo -e "  ${BOLD}Expected vs Bundle:${NC}"

while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    if echo "$actual_images" | grep -qF "$img"; then
        echo -e "  ${GREEN}[OK]${NC}      ${img}"
    else
        echo -e "  ${RED}[MISSING]${NC} ${img}"
        missing=$((missing + 1))
    fi
done <<< "$expected_images"

# Check for extra images (in bundle but not expected)
while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    if ! echo "$expected_images" | grep -qF "$img"; then
        echo -e "  ${YELLOW}[EXTRA]${NC}   ${img}"
        extra=$((extra + 1))
    fi
done <<< "$actual_images"

# Image manifest with sizes
echo ""
echo -e "  ${BOLD}Image Manifest:${NC}"
echo ""
printf "  %-60s %s\n" "IMAGE" "SIZE"
printf "  %-60s %s\n" "$(printf '%.0s─' {1..60})" "──────"
while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    img_size="$(docker image inspect "$img" --format='{{.Size}}' 2>/dev/null || echo "0")"
    if [[ "$img_size" -gt 1073741824 ]] 2>/dev/null; then
        img_size="$(echo "scale=1; $img_size / 1073741824" | bc 2>/dev/null || echo "?")GB"
    elif [[ "$img_size" -gt 1048576 ]] 2>/dev/null; then
        img_size="$(echo "scale=0; $img_size / 1048576" | bc 2>/dev/null || echo "?")MB"
    else
        img_size="${img_size}B"
    fi
    printf "  %-60s %s\n" "$img" "$img_size"
done <<< "$expected_images"

# Summary
echo ""
if [[ $missing -gt 0 ]]; then
    echo -e "  ${RED}FAIL: ${missing} image(s) missing from bundle!${NC}"
    echo -e "  ${RED}This bundle will fail on air-gapped installation.${NC}"
    exit 1
elif [[ $extra -gt 0 ]]; then
    echo -e "  ${YELLOW}WARN: ${extra} extra image(s) in bundle (not required by compose)${NC}"
    echo -e "  ${GREEN}All required images present.${NC}"
else
    echo -e "  ${GREEN}All required images present. Bundle is complete.${NC}"
fi

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  Offline bundle created!${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo ""
echo "  File:     ${BUNDLE_FILE}"
echo "  Size:     ${bundle_size}"
echo "  Platform: ${PLATFORM}"
if [[ -n "$INCLUDE_MODELS" ]]; then
    echo "  Models:   ${INCLUDE_MODELS}"
fi
echo ""
echo "  To install on air-gapped host:"
echo "    1. Transfer ${BUNDLE_FILE} to target"
echo "    2. tar xzf $(basename "$BUNDLE_FILE")"
echo "    3. sudo bash install-offline.sh"
echo ""
