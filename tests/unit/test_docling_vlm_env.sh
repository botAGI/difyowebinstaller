#!/usr/bin/env bash
# test_docling_vlm_env.sh — Docling-serve standalone env из CLAUDE.md §8.
#
# Прецеденты:
#
# 1. DOCLING_SERVE_ENABLE_REMOTE_SERVICES=true — обязательно для VLM picture
#    description (без него docling не зовёт vLLM, картинки остаются placeholder).
#
# 2. DOCLING_DEVICE=cuda (не cpu) — иначе ML на CPU = 10× медленнее.
#    Симптом в логах: "CUDA is not available. Fall back to 'CPU'".
#
# 3. Shared GPU conservative defaults (vLLM + docling на одном GB10):
#    UVICORN_WORKERS=1, ENG_LOC_NUM_WORKERS=1, LAYOUT_BATCH≤64, OCR_BATCH≤64.
#    Прецедент: WORKERS=2 + LAYOUT_BATCH=64 + 2 parallel PDF → 83+40 > 124 GiB
#    → torch.AcceleratorError: CUDA out of memory, docling падает, swap 100%.
#    Baseline 32, max 64 — больше только на dedicated GPU без vLLM рядом.
#
# 4. DOCLING_SERVE_ALLOW_CUSTOM_OCR_CONFIG=true — нужно для ocr_custom_config
#    JSON-поля (русская кириллица через easyocr cyrillic_g2.pth).
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_docling_vlm_env"

fail=0
pass=0

COMPOSE="${REPO_ROOT}/templates/docker-compose.yml"
if [[ ! -f "$COMPOSE" ]]; then
    echo "SKIP: ${COMPOSE} not found"
    exit 77
fi

# Extract docling service environment as key=value pairs
docling_env="$(python3 - "$COMPOSE" <<'PY'
import sys, yaml, re
d = yaml.safe_load(open(sys.argv[1])) or {}
svc = d.get('services', {}).get('docling', {})
env = svc.get('environment', [])
out = {}
if isinstance(env, list):
    for item in env:
        if isinstance(item, str) and '=' in item:
            k, v = item.split('=', 1)
            out[k.strip()] = v.strip()
elif isinstance(env, dict):
    out = {k: str(v) for k, v in env.items()}
# Also dump mem_limit
out['__mem_limit__'] = str(svc.get('mem_limit', ''))
for k, v in out.items():
    print(f"{k}={v}")
PY
)"

if [[ -z "$docling_env" ]]; then
    echo "SKIP: docling service not found in compose (ETL profile?)"
    exit 77
fi

_get() {
    echo "$docling_env" | grep "^${1}=" | head -1 | cut -d'=' -f2-
}
_num() {
    # extract numeric value from "32" or "${VAR:-32}"
    echo "$1" | grep -oE ':-[0-9]+' | grep -oE '[0-9]+' || echo "$1" | grep -oE '^[0-9]+'
}

# 1. ENABLE_REMOTE_SERVICES = true
val="$(_get DOCLING_SERVE_ENABLE_REMOTE_SERVICES)"
if [[ "$val" == "true" ]]; then
    echo "  PASS: DOCLING_SERVE_ENABLE_REMOTE_SERVICES=true (VLM picture description enabled §8)"
    pass=$((pass+1))
else
    echo "  FAIL: DOCLING_SERVE_ENABLE_REMOTE_SERVICES=${val:-unset} (must be 'true' for VLM §8)"
    fail=$((fail+1))
fi

# 2. DEVICE = cuda
val="$(_get DOCLING_DEVICE)"
case "$val" in
    *cuda*)
        echo "  PASS: DOCLING_DEVICE=${val} (GPU inference §8)"
        pass=$((pass+1))
        ;;
    "")
        echo "  WARN: DOCLING_DEVICE not set (image default may be cpu — 10× slower §8)"
        pass=$((pass+1))
        ;;
    *)
        echo "  FAIL: DOCLING_DEVICE=${val} (expected cuda — cpu fallback is 10× slower §8)"
        fail=$((fail+1))
        ;;
esac

# 3. UVICORN_WORKERS ≤ 1 (shared GPU)
val="$(_get UVICORN_WORKERS)"
n="$(_num "$val")"
if [[ -z "$val" ]] || [[ "${n:-1}" -le 1 ]]; then
    echo "  PASS: UVICORN_WORKERS=${val:-1} (≤1 for shared GPU §8)"
    pass=$((pass+1))
else
    echo "  FAIL: UVICORN_WORKERS=${val} (>1 → CUDA OOM on shared GPU §8)"
    fail=$((fail+1))
fi

# 4. ENG_LOC_NUM_WORKERS ≤ 1 (shared GPU)
val="$(_get DOCLING_SERVE_ENG_LOC_NUM_WORKERS)"
n="$(_num "$val")"
if [[ -z "$val" ]] || [[ "${n:-1}" -le 1 ]]; then
    echo "  PASS: DOCLING_SERVE_ENG_LOC_NUM_WORKERS=${val:-1} (≤1 for shared GPU §8)"
    pass=$((pass+1))
else
    echo "  FAIL: DOCLING_SERVE_ENG_LOC_NUM_WORKERS=${val} (>1 → CUDA OOM §8)"
    fail=$((fail+1))
fi

# 5. LAYOUT_BATCH ≤ 64 (baseline 32)
val="$(_get DOCLING_SERVE_LAYOUT_BATCH_SIZE)"
n="$(_num "$val")"
if [[ -z "$val" ]] || [[ "${n:-32}" -le 64 ]]; then
    echo "  PASS: DOCLING_SERVE_LAYOUT_BATCH_SIZE=${val:-32} (≤64 for shared GPU §8)"
    pass=$((pass+1))
else
    echo "  FAIL: DOCLING_SERVE_LAYOUT_BATCH_SIZE=${val} (>64 → OOM on shared GPU §8)"
    fail=$((fail+1))
fi

# 6. OCR_BATCH ≤ 64
val="$(_get DOCLING_SERVE_OCR_BATCH_SIZE)"
n="$(_num "$val")"
if [[ -z "$val" ]] || [[ "${n:-32}" -le 64 ]]; then
    echo "  PASS: DOCLING_SERVE_OCR_BATCH_SIZE=${val:-32} (≤64 for shared GPU §8)"
    pass=$((pass+1))
else
    echo "  FAIL: DOCLING_SERVE_OCR_BATCH_SIZE=${val} (>64 → OOM §8)"
    fail=$((fail+1))
fi

# 7. ALLOW_CUSTOM_OCR_CONFIG = true (для русской кириллицы через easyocr)
val="$(_get DOCLING_SERVE_ALLOW_CUSTOM_OCR_CONFIG)"
if [[ "$val" == "true" ]]; then
    echo "  PASS: DOCLING_SERVE_ALLOW_CUSTOM_OCR_CONFIG=true (cyrillic OCR via ocr_custom_config §8)"
    pass=$((pass+1))
else
    echo "  WARN: DOCLING_SERVE_ALLOW_CUSTOM_OCR_CONFIG=${val:-unset} (cyrillic ocr_custom_config won't work §8)"
    pass=$((pass+1))  # warn — может не быть critical если cyrillic не нужен
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
