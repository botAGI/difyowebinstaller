#!/usr/bin/env bash
# gpu-metrics.sh — Export GPU metrics for node-exporter textfile collector.
# Runs via cron every 15s or as a systemd timer.
# Writes Prometheus-format metrics to a .prom file that node-exporter reads.
set -euo pipefail

TEXTFILE_DIR="${1:-/opt/agmind/docker/monitoring/textfile}"
PROM_FILE="${TEXTFILE_DIR}/gpu_metrics.prom"
TMP_FILE="${PROM_FILE}.tmp"

mkdir -p "$TEXTFILE_DIR"

# Query nvidia-smi (works on DGX Spark and discrete GPUs)
if ! command -v nvidia-smi &>/dev/null; then
    exit 0
fi

data=$(nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,power.draw,clocks.current.graphics,memory.used,memory.total,name \
    --format=csv,noheader,nounits 2>/dev/null || true)

if [[ -z "$data" ]]; then
    exit 0
fi

{
    echo "# HELP agmind_gpu_temperature_celsius GPU temperature in Celsius."
    echo "# TYPE agmind_gpu_temperature_celsius gauge"
    echo "# HELP agmind_gpu_utilization_percent GPU utilization percentage."
    echo "# TYPE agmind_gpu_utilization_percent gauge"
    echo "# HELP agmind_gpu_power_watts GPU power draw in watts."
    echo "# TYPE agmind_gpu_power_watts gauge"
    echo "# HELP agmind_gpu_clock_mhz GPU clock speed in MHz."
    echo "# TYPE agmind_gpu_clock_mhz gauge"
    echo "# HELP agmind_gpu_memory_used_bytes GPU memory used in bytes."
    echo "# TYPE agmind_gpu_memory_used_bytes gauge"
    echo "# HELP agmind_gpu_memory_total_bytes GPU memory total in bytes."
    echo "# TYPE agmind_gpu_memory_total_bytes gauge"

    while IFS=', ' read -r idx temp util power clock mem_used mem_total name; do
        # Clean up values: remove [N/A], extra spaces
        temp="${temp//\[N\/A\]/0}"; temp="${temp// /}"
        util="${util//\[N\/A\]/0}"; util="${util// /}"
        power="${power//\[N\/A\]/0}"; power="${power// /}"
        clock="${clock//\[N\/A\]/0}"; clock="${clock// /}"
        mem_used="${mem_used//\[N\/A\]/0}"; mem_used="${mem_used// /}"
        mem_total="${mem_total//\[N\/A\]/0}"; mem_total="${mem_total// /}"
        name="${name// /_}"; name="${name//,/}"

        labels="gpu=\"${idx}\",name=\"${name}\""
        echo "agmind_gpu_temperature_celsius{${labels}} ${temp}"
        echo "agmind_gpu_utilization_percent{${labels}} ${util}"
        echo "agmind_gpu_power_watts{${labels}} ${power}"
        echo "agmind_gpu_clock_mhz{${labels}} ${clock}"
        # Memory in bytes (nvidia-smi reports MiB)
        if [[ "$mem_used" != "0" ]]; then
            echo "agmind_gpu_memory_used_bytes{${labels}} $((mem_used * 1048576))"
        fi
        if [[ "$mem_total" != "0" ]]; then
            echo "agmind_gpu_memory_total_bytes{${labels}} $((mem_total * 1048576))"
        fi
    done <<< "$data"
} > "$TMP_FILE"

# Content-replace, NOT mv-rename — preserves the inode of $PROM_FILE.
#
# Why this matters: peer node-exporter bind-mounts the textfile directory
# from the host. When this script `mv`'d the tmp file over the final one,
# the destination inode changed every cycle. Docker's bind-mount tracking
# on the container side keeps the original inode mapping cached and never
# observes the new file — node_textfile_scrape_error stayed at 1 forever,
# Grafana peer GPU panels stayed blank, and the only fix was
# `docker restart agmind-node-exporter` (which re-attached the bind).
#
# The trade-off: writing in-place is not strictly atomic — a concurrent
# scrape can read a half-written file. But:
#  (1) the file is <1 KB (6 metrics × ~6 GPUs max) → typically one write()
#      syscall, so partial-read windows are nanoseconds wide;
#  (2) node-exporter retries every 15s — a single corrupted scrape blips
#      `node_textfile_scrape_error 1` for one tick, then recovers;
#  (3) gauges (not counters) — even fully missed samples don't break math
#      since the next sample overrides.
#
# Net result: bind-mount stays valid forever; node-exporter sees every
# update on first scrape; no per-restart maintenance needed.
# Regression caught 2026-05-19 — see CLAUDE.md §8 "Docker bind-mount
# rename invalidation".
if [[ -f "$PROM_FILE" ]]; then
    # Preserve existing inode — overwrite contents in place.
    cat "$TMP_FILE" > "$PROM_FILE"
    rm -f "$TMP_FILE"
else
    # First run — file doesn't exist yet. mv creates it with a fresh inode.
    # Subsequent runs hit the branch above and preserve the inode.
    mv "$TMP_FILE" "$PROM_FILE"
fi
