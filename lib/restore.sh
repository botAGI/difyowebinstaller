#!/usr/bin/env bash
# restore.sh — Restore plan, verify, and apply helpers for AGmind DR ergonomics.
# Dependencies: none (standalone-safe; fallback log_* shims if common.sh absent).
# Functions: restore_artifact_map(), restore_verify(RESTORE_DIR [--json]),
#            restore_plan(RESTORE_DIR [--service <name>] [--dry-run]),
#            restore_apply(RESTORE_DIR [--service <name>] [--auto-confirm]),
#            restore_list(), _resolve_backup_dir(arg)
# Expects: INSTALL_DIR (default /opt/agmind), BACKUP_BASE (default /var/backups/agmind)
# Exports: RESTORE_REGISTRY (array), RESTORE_ERRORS, RESTORE_WARNINGS
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"
BACKUP_BASE="${BACKUP_BASE:-${BACKUP_DIR:-/var/backups/agmind}}"
COMPOSE_FILE="${COMPOSE_FILE:-${INSTALL_DIR}/docker/docker-compose.yml}"

# ============================================================================
# FALLBACK SHIMS (only active when sourced without common.sh / health.sh)
# ============================================================================

# Fallback log functions when sourced without common.sh (mirror lib/health.sh:11-14)
command -v log_info    >/dev/null 2>&1 || log_info()    { echo -e "  -> $*"; }
command -v log_success >/dev/null 2>&1 || log_success() { echo -e "  ✓ $*"; }
command -v log_warn    >/dev/null 2>&1 || log_warn()    { echo -e "  ⚠ $*"; }
command -v log_error   >/dev/null 2>&1 || log_error()   { echo -e "  ✗ $*"; }

# Fallback colors when sourced without common.sh
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
NC="${NC:-\033[0m}"

# ============================================================================
# REGISTRY HELPERS (copied from lib/doctor.sh, namespaced RESTORE_*)
# WHY: lib/restore.sh is sourced standalone from scripts/restore.sh which does NOT
#      source lib/doctor.sh; copying the helpers avoids a cross-module dependency.
# Record format (7 fields, \x1f-delimited):
#   id | category | severity | message | fix_hint | fixable | fix_cmd
# ============================================================================

# WHY \x1f: ASCII Unit Separator — not present in normal diagnostic messages.
SEP=$'\x1f'
# shellcheck disable=SC2034
RESTORE_REGISTRY=()
RESTORE_ERRORS=0
RESTORE_WARNINGS=0

# Category display labels for _registry_render_human output
declare -A CATEGORY_LABELS=(
    [dir_exists]="Backup directory"
    [checksums]="Checksums"
    [archive_integrity]="Archive integrity"
    [sql_sanity]="SQL sanity"
    [encryption]="Encryption"
    [completeness]="Completeness"
)

_registry_reset() {
    RESTORE_REGISTRY=()
    RESTORE_ERRORS=0
    RESTORE_WARNINGS=0
}

# _registry_add id category severity message [fix_hint] [fixable] [fix_cmd]
_registry_add() {
    local id="$1" category="$2" severity="$3" message="$4" \
          fix_hint="${5:-}" fixable="${6:-false}" fix_cmd="${7:-}"
    RESTORE_REGISTRY+=("${id}${SEP}${category}${SEP}${severity}${SEP}${message}${SEP}${fix_hint}${SEP}${fixable}${SEP}${fix_cmd}")
}

# _registry_count — tallies RESTORE_ERRORS and RESTORE_WARNINGS from registry
_registry_count() {
    RESTORE_ERRORS=0
    RESTORE_WARNINGS=0
    local entry id category sev msg fix_hint fixable _fix_cmd
    for entry in "${RESTORE_REGISTRY[@]+"${RESTORE_REGISTRY[@]}"}"; do
        IFS=$'\x1f' read -r id category sev msg fix_hint fixable _fix_cmd <<< "$entry"
        case "$sev" in
            FAIL) RESTORE_ERRORS=$((RESTORE_ERRORS+1)) ;;
            WARN) RESTORE_WARNINGS=$((RESTORE_WARNINGS+1)) ;;
        esac
    done
}

# _registry_render_human — print colored check output grouped by category
_registry_render_human() {
    local entry id category sev msg fix_hint fixable _fix_cmd
    local cur_cat=""
    for entry in "${RESTORE_REGISTRY[@]+"${RESTORE_REGISTRY[@]}"}"; do
        IFS=$'\x1f' read -r id category sev msg fix_hint fixable _fix_cmd <<< "$entry"
        if [[ "$category" != "$cur_cat" ]]; then
            echo -e "\n${BOLD}${CATEGORY_LABELS[$category]:-$category}:${NC}"
            cur_cat="$category"
        fi
        case "$sev" in
            OK)   echo -e "  ${GREEN}[OK]${NC}   ${msg}" ;;
            WARN) echo -e "  ${YELLOW}[WARN]${NC} ${msg}"
                  [[ -n "$fix_hint" ]] && echo -e "         ${CYAN}-> ${fix_hint}${NC}" ;;
            FAIL) echo -e "  ${RED}[FAIL]${NC} ${msg}"
                  [[ -n "$fix_hint" ]] && echo -e "         ${CYAN}-> ${fix_hint}${NC}" ;;
            SKIP) echo -e "  ${CYAN}[SKIP]${NC} ${msg}" ;;
        esac
    done
}

# _registry_render_json — emit a JSON summary object
# WHY python3: shell string concat breaks on quotes/newlines in messages (Edge Case 7).
_registry_render_json() {
    local entry id category sev msg fix_hint fixable fix_cmd
    local checks_json="" first=1
    _registry_count
    for entry in "${RESTORE_REGISTRY[@]+"${RESTORE_REGISTRY[@]}"}"; do
        IFS=$'\x1f' read -r id category sev msg fix_hint fixable fix_cmd <<< "$entry"
        local rec
        rec="$(python3 -c "
import json, sys
rec = {
    'id': sys.argv[1],
    'category': sys.argv[2],
    'severity': sys.argv[3],
    'message': sys.argv[4],
    'fix_hint': sys.argv[5],
    'fixable': sys.argv[6] == 'true',
    'fix_cmd': sys.argv[7],
}
print(json.dumps(rec))
" "$id" "$category" "$sev" "$msg" "$fix_hint" "$fixable" "$fix_cmd")"
        if [[ "$first" -eq 1 ]]; then
            checks_json="$rec"
            first=0
        else
            checks_json="${checks_json},${rec}"
        fi
    done
    local status="ok"
    [[ "$RESTORE_WARNINGS" -gt 0 ]] && status="warn"
    [[ "$RESTORE_ERRORS"   -gt 0 ]] && status="fail"
    printf '{"status":"%s","errors":%d,"warnings":%d,"checks":[%s]}\n' \
        "$status" "$RESTORE_ERRORS" "$RESTORE_WARNINGS" "$checks_json"
}

# ============================================================================
# ARTIFACT MAP
# WHY: single source of truth — backup.sh §artifacts and restore performers +
#      verify completeness all derive from this; mirrors the inventory in
#      05-RESEARCH.md; avoids drift between «what we backup» and «what we restore».
# Format: filename|type|target|service|optional
#   type: pgdump | volume-path | volume-docker | sqldump-mysql | config-file | config-tar | meta
#   service: dify | rag | ragflow | openwebui | ollama | optional | config | skip
#   optional: true | false  (false = core artifact, must be present)
# ============================================================================

restore_artifact_map() {
    cat <<'MAP'
dify_db.sql.gz|pgdump|dify|dify|false
dify_plugin_db.sql.gz|pgdump|dify_plugin|dify|true
dify-storage.tar.gz|volume-path|docker/volumes/app/storage|dify|true
qdrant.tar.gz|volume-path|docker/volumes/qdrant|rag|true
weaviate.tar.gz|volume-path|docker/volumes/weaviate|rag|true
minio-data.tar.gz|volume-docker|minio_data|dify|true
openwebui.tar.gz|volume-docker|openwebui|openwebui|true
ollama.tar.gz|volume-docker|ollama_data|ollama|true
surrealdb.tar.gz|volume-docker|surrealdb|optional|true
ragflow_mysql.sql.gz|sqldump-mysql|rag_flow|ragflow|true
ragflow_es.live.tar.gz|volume-docker|ragflow_es_data|ragflow|true
ragflow_minio.tar.gz|config-tar|ragflow_minio|ragflow|true
env.backup|config-file|docker/.env|config|false
docker-compose.yml.backup|config-file|docker/docker-compose.yml|config|true
nginx.conf.backup|config-file|docker/nginx/nginx.conf|config|true
authelia.tar.gz|config-tar|docker/authelia|config|true
litellm-config.yaml|config-file|docker/litellm-config.yaml|config|true
searxng-settings.yml|config-file|docker/searxng-settings.yml|config|true
MAP
}

# ============================================================================
# RESOLVER
# ============================================================================

# _resolve_backup_dir <arg> — resolves 'latest', bare-dirname, or absolute path
# to a full absolute backup directory path. Returns path on stdout; exits 1
# with actionable message on stderr if unresolvable.
# WHY: shared by restore_verify / restore_plan / restore_apply — one definition,
#      no drift across callers.
_resolve_backup_dir() {
    local arg="${1:-latest}"
    local backup_base="${BACKUP_BASE:-/var/backups/agmind}"
    local resolved=""
    case "$arg" in
        latest)
            # ls -1d sorts lexicographically; YYYY-MM-DD_HHMM names = chronological
            resolved="$(ls -1d "${backup_base}"/*/ 2>/dev/null | sort | tail -1 || true)"
            resolved="${resolved%/}"
            ;;
        /*) resolved="$(realpath -m "$arg" 2>/dev/null || echo "$arg")" ;;
        *)  resolved="${backup_base}/${arg}" ;;
    esac
    if [[ -z "$resolved" || ! -d "$resolved" ]]; then
        echo "Нет бэкапов в ${backup_base} — запусти \`agmind backup create\`" >&2
        return 1
    fi
    [[ "$resolved" == "${backup_base}/"* ]] || {
        echo "Путь должен находиться под ${backup_base}" >&2
        return 1
    }
    printf '%s' "$resolved"
}

# ============================================================================
# PUBLIC API STUBS (Plan 02/03 implement bodies)
# ============================================================================

# restore_verify <RESTORE_DIR> [--json]
# Verifies backup integrity: checksums, archive integrity, SQL sanity, completeness.
# Exit 0 = no FAIL; exit 1 = ≥1 FAIL.
restore_verify() {
    # shellcheck disable=SC2034
    local restore_dir="${1:-}"
    echo "restore_verify: не реализовано (Wave 1)" >&2
    return 1
}

# restore_plan <RESTORE_DIR> [--service <name>] [--dry-run]
# Prints human-readable restore plan (what will be restored, what will be stopped).
# Read-only — zero mutations.
restore_plan() {
    echo "restore_plan: не реализовано (Wave 2)" >&2
    return 1
}

# restore_apply <RESTORE_DIR> [--service <name>] [--auto-confirm]
# Executes the restore: stops containers, restores artifacts, restarts containers.
# Requires root. Respects flock acquired by the caller (scripts/restore.sh).
restore_apply() {
    echo "restore_apply: не реализовано (Wave 2)" >&2
    return 1
}

# restore_list — prints table of available backups (DATE / SIZE / STATUS).
# Called by `agmind backup list`.
restore_list() {
    echo "restore_list: не реализовано (Wave 2)" >&2
    return 1
}
