#!/usr/bin/env bash
# tests/mocks/rotate_secrets.sh — stub for agmind creds rotate dispatch tests.
# Records argv to MOCK_ROTATE_LOG; no side effects.
set -uo pipefail
printf '%s\n' "rotate_secrets.sh $*" >> "${MOCK_ROTATE_LOG:-/dev/null}"
exit "${MOCK_ROTATE_EXIT:-0}"
