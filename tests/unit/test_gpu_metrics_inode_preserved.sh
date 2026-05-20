#!/usr/bin/env bash
# ============================================================================
# tests/unit/test_gpu_metrics_inode_preserved.sh — bind-mount race regression
#
# Bug history
# -----------
# 2026-05-19 fresh-install: peer-node-exporter scraped /textfile/gpu_metrics.prom
# with node_textfile_scrape_error=1 forever. agmind_gpu_* metrics never reached
# Prometheus from spark-69a2. Grafana "AGMind GPU — worker" dashboard stayed
# blank. Only fix was `docker restart agmind-node-exporter` (which re-attached
# the bind-mount).
#
# Root cause: scripts/gpu-metrics.sh wrote .prom via `mv tmp final`. Atomic
# rename swapped the destination inode every cron tick. Docker bind-mount on
# the container side kept the original inode cached and never observed the
# new file. Race window = the second `mv` after node-exporter started.
#
# Architectural fix: `cat "$TMP_FILE" > "$PROM_FILE"` preserves the inode by
# in-place truncate+write. Trade-off documented in the script header.
#
# This test STATICALLY asserts the fix shape (no live nvidia-smi required —
# checks bash source in scripts/gpu-metrics.sh):
#
#   A. The script must NOT contain `mv "$TMP_FILE" "$PROM_FILE"` as the
#      unconditional final write. The legacy single-line `mv` was the bug.
#
#   B. The script must contain `cat "$TMP_FILE" > "$PROM_FILE"` (or
#      semantically equivalent inode-preserving overwrite) gated on
#      `$PROM_FILE` already existing.
#
#   C. The comment block must explain the bind-mount rationale so a future
#      reader doesn't "fix" it back to mv.
#
# Plus a functional smoke test:
#
#   D. Run the script twice against a tmp dir and verify the inode of the
#      output file is IDENTICAL between runs (the actual contract).
#
# Exit: 0 = PASS, 1 = FAIL. Auto-discovered by tests/run_all.sh.
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

SCRIPT="scripts/gpu-metrics.sh"

fail=0

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not found" >&2
    exit 1
fi

# --- (A) reject unconditional `mv "$TMP_FILE" "$PROM_FILE"` final write ---
# The legacy bug-line was literally `mv "$TMP_FILE" "$PROM_FILE"` as the only
# write path. Refactor must guard it (only mv on first-creation) or replace it
# entirely.
mv_lines=$(grep -nE 'mv[[:space:]]+"\$TMP_FILE"[[:space:]]+"\$PROM_FILE"' "$SCRIPT" || true)
if [[ -n "$mv_lines" ]]; then
    # Allowed only inside a conditional branch — verify it's not the sole write
    if ! grep -qE 'cat[[:space:]]+"\$TMP_FILE"[[:space:]]+>[[:space:]]+"\$PROM_FILE"' "$SCRIPT"; then
        echo "FAIL (A): $SCRIPT uses 'mv \$TMP_FILE \$PROM_FILE' as the only write — bind-mount inode swap regression" >&2
        echo "          legacy lines:" >&2
        sed 's/^/            /' <<<"$mv_lines" >&2
        fail=1
    fi
fi

# --- (B) require inode-preserving overwrite via `cat tmp > final` ---
if ! grep -qE 'cat[[:space:]]+"\$TMP_FILE"[[:space:]]+>[[:space:]]+"\$PROM_FILE"' "$SCRIPT"; then
    echo "FAIL (B): $SCRIPT does not use 'cat \"\$TMP_FILE\" > \"\$PROM_FILE\"' for inode-preserving overwrite" >&2
    fail=1
fi

# --- (C) preserve documentation ---
if ! grep -qiE 'bind-mount|inode' "$SCRIPT"; then
    echo "FAIL (C): $SCRIPT has no comment about bind-mount/inode rationale — risk of revert" >&2
    fail=1
fi

# --- (D) functional smoke: inode stability across 2 runs ---
# Stub nvidia-smi so the script produces deterministic output on hosts without
# a GPU. The script invokes `nvidia-smi --query-gpu=...` with `|| true`, so we
# can replace it with a fake on PATH.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/textfile"
cat >"$tmp_dir/bin/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
# Fake nvidia-smi for inode-stability test. Returns one fake GPU row.
case "$*" in
    *--query-gpu=*) echo "0, 47, 0, 10.94, 2411, 0, 122880, NVIDIA_GB10" ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$tmp_dir/bin/nvidia-smi"

export PATH="$tmp_dir/bin:$PATH"

# Run 1 — creates the file
bash "$SCRIPT" "$tmp_dir/textfile" >/dev/null 2>&1 || true
if [[ ! -f "$tmp_dir/textfile/gpu_metrics.prom" ]]; then
    echo "FAIL (D): $SCRIPT did not create gpu_metrics.prom on first run" >&2
    fail=1
else
    inode1=$(stat -c '%i' "$tmp_dir/textfile/gpu_metrics.prom")

    # Run 2 — must preserve inode (this is the regression-detection step)
    bash "$SCRIPT" "$tmp_dir/textfile" >/dev/null 2>&1 || true
    inode2=$(stat -c '%i' "$tmp_dir/textfile/gpu_metrics.prom")

    if [[ "$inode1" != "$inode2" ]]; then
        echo "FAIL (D): inode changed between runs ($inode1 → $inode2) — bind-mount race regression" >&2
        echo "          The script rewrites the file with a new inode, which invalidates" >&2
        echo "          Docker bind-mount in the node-exporter container — every container" >&2
        echo "          would need a restart to see fresh metrics." >&2
        fail=1
    fi

    # Run 3 — sanity, inode still identical
    bash "$SCRIPT" "$tmp_dir/textfile" >/dev/null 2>&1 || true
    inode3=$(stat -c '%i' "$tmp_dir/textfile/gpu_metrics.prom")
    if [[ "$inode2" != "$inode3" ]]; then
        echo "FAIL (D): inode changed between run 2 and run 3 ($inode2 → $inode3)" >&2
        fail=1
    fi

    # Sanity: file should still contain meaningful metrics after the rewrites
    if ! grep -q 'agmind_gpu_temperature_celsius' "$tmp_dir/textfile/gpu_metrics.prom"; then
        echo "FAIL (D): output file lacks agmind_gpu_temperature_celsius after rewrites" >&2
        fail=1
    fi
fi

if (( fail )); then
    echo "" >&2
    echo "test_gpu_metrics_inode_preserved.sh: FAIL — bind-mount race regression risk" >&2
    exit 1
fi

echo "test_gpu_metrics_inode_preserved.sh: PASS — inode stable across runs ($inode1)"
exit 0
