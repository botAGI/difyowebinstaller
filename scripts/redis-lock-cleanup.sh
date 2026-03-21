#!/bin/sh
# Redis stale lock cleanup — runs as init-container before plugin-daemon
# Deletes all plugin_daemon lock keys unconditionally (any lock present at
# startup is guaranteed stale since the daemon hasn't started yet)
#
# POSIX sh compatible — redis:alpine uses ash, not bash
set -eu

REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

# Build auth arguments as a single string (no bash arrays)
AUTH_ARGS=""
if [ -n "$REDIS_PASSWORD" ]; then
    AUTH_ARGS="-a ${REDIS_PASSWORD} --no-auth-warning"
fi

# shellcheck disable=SC2086
redis_cmd() {
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARGS "$@"
}

echo "[redis-lock-cleaner] Scanning for stale plugin_daemon locks..."
cursor=0
deleted=0

while :; do
    result=$(redis_cmd SCAN "$cursor" MATCH 'plugin_daemon:*lock*' COUNT 100)
    cursor=$(echo "$result" | head -1)
    keys=$(echo "$result" | tail -n +2)

    for key in $keys; do
        [ -z "$key" ] && continue
        redis_cmd DEL "$key" >/dev/null
        echo "[redis-lock-cleaner] Deleted: $key"
        deleted=$((deleted + 1))
    done

    [ "$cursor" = "0" ] && break
done

if [ "$deleted" -gt 0 ]; then
    echo "[redis-lock-cleaner] Cleaned $deleted stale lock(s)"
else
    echo "[redis-lock-cleaner] No stale locks found"
fi
echo "[redis-lock-cleaner] Lock cleanup complete"
