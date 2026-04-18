#!/usr/bin/env bash
# docling-bench.sh — benchmark docling-serve conversion on a real PDF.
# Runs N iterations with current config; reports cold/warm/avg.
# Phase 42: data-driven tuning tool for DOCLING_SERVE_*_BATCH_SIZE.
#
# Usage: agmind docling bench <pdf> [--iter 3] [--format md]
# Env: DOCLING_URL (default http://localhost:8765)
set -euo pipefail
# Force C locale so printf %f parses "1.23" (not "1,23" from ru_RU)
export LC_ALL=C LC_NUMERIC=C

PDF="${1:-}"
ITER=3
FORMAT="md"
PRESET="balanced"

shift || true
while (( $# > 0 )); do
    case "$1" in
        --iter)    ITER="$2"; shift 2 ;;
        --format)  FORMAT="$2"; shift 2 ;;
        --preset)  PRESET="$2"; shift 2 ;;
        *)         echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Build extra curl args per preset (Phase 43 presets; see docs/docling-presets.md)
declare -a PRESET_ARGS
case "$PRESET" in
    fast)
        PRESET_ARGS=(-F 'do_ocr=false' -F 'do_table_structure=false' -F 'table_mode=fast')
        ;;
    balanced)
        PRESET_ARGS=()
        ;;
    scan)
        # OCR-heavy preset without VLM picture description.
        # VLM requires a full picture_description_api JSON; set that up in
        # Dify workflow where the vLLM URL is known — see docs/docling-presets.md.
        PRESET_ARGS=(
            -F 'do_ocr=true'
            -F 'ocr_custom_config={"kind":"easyocr","lang":["ru","en"],"use_gpu":true}'
            -F 'do_table_structure=true'
            -F 'table_mode=accurate'
        )
        ;;
    *)
        echo "Unknown preset: $PRESET (use fast|balanced|scan)" >&2; exit 1
        ;;
esac

if [[ -z "$PDF" || ! -f "$PDF" ]]; then
    cat >&2 <<USAGE
Usage: agmind docling bench <pdf> [--iter N] [--format md|json|html]

Reports docling-serve conversion time (cold + warm runs) for the given PDF.
Use to compare effects of DOCLING_SERVE_LAYOUT_BATCH_SIZE,
DOCLING_SERVE_OCR_BATCH_SIZE, DOCLING_NUM_THREADS on YOUR documents.

Suggested workflow:
  1. agmind docling bench your.pdf            # baseline
  2. Edit /opt/agmind/docker/.env:
       DOCLING_SERVE_LAYOUT_BATCH_SIZE=128
  3. cd /opt/agmind/docker && docker compose up -d docling
  4. agmind docling bench your.pdf            # new config
  5. Compare; revert .env if worse.
USAGE
    exit 1
fi

URL="${DOCLING_URL:-http://localhost:8765}/v1/convert/file"
pages=$(strings "$PDF" | grep -c '/Type /Page' || true)

printf 'PDF:     %s\n' "$PDF"
printf 'Size:    %s bytes\n' "$(stat -c%s "$PDF" 2>/dev/null || wc -c < "$PDF")"
printf 'Pages:   %s\n' "$pages"
printf 'URL:     %s\n' "$URL"
printf 'Iter:    %s\n' "$ITER"
printf 'Preset:  %s\n' "$PRESET"
echo

# Show current docling env so results are reproducible
if command -v docker >/dev/null 2>&1; then
    echo "Current docling env:"
    docker exec agmind-docling sh -c 'env | grep -E "DOCLING_(SERVE|NUM|DEVICE)" | sort' 2>/dev/null | sed 's/^/  /'
    echo
fi

declare -a times
for i in $(seq 1 "$ITER"); do
    start=$(date +%s.%N)
    http_code=$(curl -s -o "/tmp/docling-bench-$i.out" -w '%{http_code}' \
        -X POST \
        -F "files=@${PDF}" \
        -F "to_formats=${FORMAT}" \
        -F 'image_export_mode=placeholder' \
        "${PRESET_ARGS[@]}" \
        --max-time 600 \
        "$URL")
    end=$(date +%s.%N)
    elapsed=$(echo "$end - $start" | bc)
    size=$(wc -c < "/tmp/docling-bench-$i.out")
    printf '  run %d: %6.2fs  http=%s  out=%s bytes\n' "$i" "$elapsed" "$http_code" "$size"
    times+=("$elapsed")
done

# Stats: min, max, mean (skip first as cold)
python3 <<PY
import statistics
t = [float(x) for x in "${times[@]}".split()]
if not t:
    print("no runs")
    raise SystemExit(1)
print()
print(f"  cold:  {t[0]:.2f}s")
if len(t) > 1:
    warm = t[1:]
    print(f"  warm:  {statistics.mean(warm):.2f}s (mean of {len(warm)})")
    print(f"  min:   {min(warm):.2f}s")
    print(f"  max:   {max(warm):.2f}s")
    if len(warm) > 1:
        print(f"  stdev: {statistics.stdev(warm):.2f}s")
if "$pages".isdigit() and int("$pages") > 0:
    per_page = t[-1] / int("$pages")
    print(f"  per-page (last run): {per_page:.2f}s/page")
PY

# Peak memory during runs (from docker stats)
if command -v docker >/dev/null 2>&1; then
    echo
    echo "Post-bench docling mem:"
    docker stats --no-stream --format '  {{.Name}} {{.MemUsage}} ({{.MemPerc}})' agmind-docling 2>/dev/null || true
fi
