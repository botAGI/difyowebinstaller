#!/usr/bin/env bash
# import-dify-workflow.sh — import a Dify DSL YAML into running stack.
# Phase 46.
#
# Usage:
#   agmind dify import-workflow <path/to/dsl.yaml> [--name "App Name"]
#
# Needs a valid Dify console JWT. Pass via DIFY_CONSOLE_TOKEN env or let
# the script fetch via /console/api/login using INIT_PASSWORD from .env.
#
# Fallback if both fail: prints step-by-step UI instructions and exits 1.
set -euo pipefail
export LC_ALL=C

DSL="${1:-}"
NAME=""

shift || true
while (( $# > 0 )); do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$DSL" || ! -f "$DSL" ]]; then
    cat >&2 <<EOF
Usage: agmind dify import-workflow <path/to/dsl.yaml> [--name "App Name"]

Example:
  agmind dify import-workflow /opt/agmind/templates/dify-workflows/example-rag-qa.yaml
EOF
    exit 1
fi

DIFY_URL="${DIFY_URL:-http://localhost}"
ENV_FILE="${AGMIND_DIR:-/opt/agmind}/docker/.env"

# Prefer explicit DIFY_CONSOLE_TOKEN
TOKEN="${DIFY_CONSOLE_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
    # Try to login using .env credentials
    EMAIL="${DIFY_ADMIN_EMAIL:-admin@agmind.ai}"
    PASS=""
    if [[ -f "$ENV_FILE" ]]; then
        ENCODED="$(grep '^INIT_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)"
        if [[ -n "$ENCODED" ]]; then
            PASS="$(echo "$ENCODED" | base64 -d 2>/dev/null || echo "$ENCODED")"
        fi
    fi
    if [[ -n "$PASS" ]]; then
        LOGIN_RESP=$(curl -s -X POST "${DIFY_URL}/console/api/login" \
            -H 'Content-Type: application/json' \
            -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASS}\",\"language\":\"en-US\",\"remember_me\":true}")
        TOKEN="$(echo "$LOGIN_RESP" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("data") or {}).get("access_token",""))' 2>/dev/null || echo "")"
    fi
fi

if [[ -z "$TOKEN" ]]; then
    cat >&2 <<EOF
Error: no Dify console token.

Auto-login failed (SECRET_KEY may have rotated since install). Two options:

(a) Grab JWT from browser:
    1. Open http://agmind-dify.local in browser, sign in
    2. F12 → Application → Local Storage → http://agmind-dify.local
    3. Copy value of 'console_token'
    4. Run: DIFY_CONSOLE_TOKEN=<jwt> agmind dify import-workflow $DSL

(b) Import via UI:
    1. Dify Studio → + Create App → Import from DSL
    2. Choose file: $DSL
    3. Click Create
EOF
    exit 1
fi

# POST DSL content to /console/api/apps/imports
YAML_CONTENT="$(cat "$DSL")"
REQ_NAME="${NAME:-$(basename "$DSL" .yaml)}"

RESP="$(curl -s -X POST "${DIFY_URL}/console/api/apps/imports" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "import json,sys; print(json.dumps({'mode':'yaml-content','yaml_content':sys.stdin.read(),'name':'$REQ_NAME'}))" <<<"$YAML_CONTENT")")"

APP_ID="$(echo "$RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("app_id",""))' 2>/dev/null || echo "")"

if [[ -n "$APP_ID" ]]; then
    echo "OK — imported app_id=$APP_ID"
    echo "Open: ${DIFY_URL}/app/${APP_ID}/configuration"
else
    echo "Import failed:" >&2
    echo "$RESP" | python3 -m json.tool 2>&1 | head -20 >&2
    exit 1
fi
