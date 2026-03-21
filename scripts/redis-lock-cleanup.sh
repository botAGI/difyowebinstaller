#!/usr/bin/env bash
# Redis stale lock cleanup — runs as init-container before plugin-daemon
# Deletes all plugin_daemon lock keys unconditionally (any lock present at
# startup is guaranteed stale since the daemon hasn't started yet)
set -euo pipefail

REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

AUTH_ARGS=()
if [[ -n "$REDIS_PASSWORD" ]]; then
    AUTH_ARGS=(-a "$REDIS_PASSWORD" --no-auth-warning)
fi

echo "Scanning for stale plugin_daemon locks..."
cursor=0
deleted=0
while true; do
    result=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "${AUTH_ARGS[@]}" \
        SCAN "$cursor" MATCH 'plugin_daemon:*lock*' COUNT 100)
    cursor=$(echo "$result" | head -1)
    keys=$(echo "$result" | tail -n +2)
    for key in $keys; do
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "${AUTH_ARGS[@]}" DEL "$key" >/dev/null
        echo "  Deleted stale lock: $key"
        deleted=$((deleted + 1))
    done
    [[ "$cursor" == "0" ]] && break
done

if [[ $deleted -gt 0 ]]; then
    echo "Cleaned $deleted stale lock(s)"
else
    echo "No stale locks found"
fi
echo "Lock cleanup complete"
