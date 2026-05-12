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
# Read-only integrity checks (D-05). Exit 0 if no FAIL, 1 if ≥1 FAIL.
# Checks: dir_exists / checksums / archive_integrity / sql_sanity / encryption / completeness.
# WHY return not exit: lib is sourced under set -euo pipefail; exit would kill the caller.
restore_verify() {
    local restore_dir="" json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=1; shift ;;
            -*)     echo "restore_verify: unknown option: $1" >&2; return 2 ;;
            *)      restore_dir="$1"; shift ;;
        esac
    done
    [[ -n "$restore_dir" ]] || { echo "restore_verify: RESTORE_DIR required" >&2; return 2; }

    _registry_reset

    # ── Check 1: dir_exists ───────────────────────────────────────────────────
    # WHY: all other checks are meaningless if the directory is missing or empty.
    if [[ -d "$restore_dir" && -n "$(ls -A "$restore_dir" 2>/dev/null)" ]]; then
        _registry_add "dir_exists" "dir_exists" "OK" "Каталог бэкапа: ${restore_dir}" "" false ""
    else
        _registry_add "dir_exists" "dir_exists" "FAIL" "Каталог бэкапа не найден или пуст: ${restore_dir}" \
            "Проверь путь: \`agmind backup list\`" false ""
        if [[ "$json" -eq 1 ]]; then _registry_render_json; else _registry_render_human; echo; fi
        _registry_count
        [[ "$RESTORE_ERRORS" -eq 0 ]] && return 0 || return 1
    fi

    # ── Check 2: checksums ────────────────────────────────────────────────────
    # WHY set +e: sha256sum -c exits 1 on any mismatch; under set -euo pipefail that
    #     would kill the script before we can record the FAIL in the registry.
    if [[ ! -f "${restore_dir}/sha256sums.txt" ]]; then
        _registry_add "checksums" "checksums" "WARN" \
            "sha256sums.txt отсутствует (старый формат бэкапа) — целостность не гарантирована" \
            "Рассмотри более свежий бэкап: \`agmind backup list\`" false ""
    else
        local sums_out sums_rc
        set +e
        sums_out="$(cd "$restore_dir" && sha256sum -c sha256sums.txt 2>&1)"; sums_rc=$?
        set -e
        if [[ "$sums_rc" -eq 0 ]]; then
            _registry_add "checksums" "checksums" "OK" "Контрольные суммы совпадают" "" false ""
        else
            local bad
            bad="$(printf '%s\n' "$sums_out" | grep -E ': (FAILED|НЕ СОВПАЛО|ОШИБКА|FAILED open or read)' | head -3 | tr '\n' ' ')"
            _registry_add "checksums" "checksums" "FAIL" \
                "Контрольные суммы не совпадают: ${bad:-несоответствие}" \
                "Бэкап повреждён — используй предыдущий: \`agmind backup list\`" false ""
        fi
    fi

    # ── Check 3: archive_integrity ────────────────────────────────────────────
    # WHY both gzip -t and tar -tzf: gzip -t checks CRC of compressed stream;
    #     tar -tzf additionally validates TAR header structure.
    local arch_ok=1 f
    for f in "${restore_dir}"/*.tar.gz; do
        [[ -f "$f" ]] || continue
        if ! gzip -t "$f" 2>/dev/null; then
            _registry_add "archive_$(basename "$f")" "archive_integrity" "FAIL" \
                "Архив повреждён: $(basename "$f") (gzip -t)" \
                "Используй предыдущий бэкап: \`agmind backup list\`" false ""
            arch_ok=0
        elif ! tar -tzf "$f" >/dev/null 2>&1; then
            _registry_add "archive_$(basename "$f")" "archive_integrity" "FAIL" \
                "Архив повреждён: $(basename "$f") (tar листинг)" \
                "Используй предыдущий бэкап: \`agmind backup list\`" false ""
            arch_ok=0
        fi
    done
    for f in "${restore_dir}"/*.sql.gz; do
        [[ -f "$f" ]] || continue
        if ! gzip -t "$f" 2>/dev/null; then
            _registry_add "archive_$(basename "$f")" "archive_integrity" "FAIL" \
                "SQL-дамп повреждён: $(basename "$f")" \
                "Используй предыдущий бэкап: \`agmind backup list\`" false ""
            arch_ok=0
        fi
    done
    [[ "$arch_ok" -eq 1 ]] && \
        _registry_add "archive_ok" "archive_integrity" "OK" "Архивы целы (gzip -t / tar)" "" false ""

    # ── Check 4: sql_sanity ───────────────────────────────────────────────────
    # WHY pipe to head: reads only first 5 lines; no disk write; fully read-only.
    if [[ -f "${restore_dir}/dify_db.sql.gz" ]]; then
        local sql_head
        sql_head="$(gunzip -c "${restore_dir}/dify_db.sql.gz" 2>/dev/null | head -5 || true)"
        if [[ -z "$sql_head" ]]; then
            _registry_add "sql_sanity" "sql_sanity" "FAIL" \
                "dify_db.sql.gz пуст — дамп не был создан" \
                "Бэкап неполный — используй предыдущий: \`agmind backup list\`" false ""
        elif ! printf '%s\n' "$sql_head" | grep -qE '^-- PostgreSQL database dump|^SET statement_timeout'; then
            _registry_add "sql_sanity" "sql_sanity" "WARN" \
                "dify_db.sql.gz не содержит стандартного pg_dump-заголовка (непустой)" \
                "Дамп может быть нестандартного формата — проверь вручную" false ""
        else
            _registry_add "sql_sanity" "sql_sanity" "OK" \
                "dify_db.sql.gz: валидный pg_dump-заголовок" "" false ""
        fi
    fi

    # ── Check 5: encryption ───────────────────────────────────────────────────
    # WHY -o /dev/null: test-decode is fully read-only; the .age file is never modified.
    local age_files=() af
    for af in "${restore_dir}"/*.age; do [[ -f "$af" ]] && age_files+=("$af"); done
    if [[ "${#age_files[@]}" -eq 0 ]]; then
        _registry_add "encryption" "encryption" "SKIP" "Шифрование не используется" "" false ""
    else
        local age_key="${INSTALL_DIR}/.age/agmind.key"
        if [[ ! -f "$age_key" ]]; then
            _registry_add "encryption" "encryption" "FAIL" \
                "Ключ шифрования не найден: ${age_key}" \
                "Восстановление невозможно без ключа — найди резервную копию ключа" false ""
        elif ! command -v age >/dev/null 2>&1; then
            _registry_add "encryption" "encryption" "FAIL" \
                "age не установлен" \
                "Переустанови: \`sudo agmind update\`" false ""
        elif ! age -d -i "$age_key" -o /dev/null "${age_files[0]}" 2>/dev/null; then
            _registry_add "encryption" "encryption" "FAIL" \
                "Расшифровка не удалась — ключ может не подходить к этому бэкапу" \
                "Проверь, что ключ соответствует этому бэкапу" false ""
        else
            _registry_add "encryption" "encryption" "OK" \
                "Расшифровка проверена (тестовый decode в /dev/null)" "" false ""
        fi
    fi

    # ── Check 6: completeness ─────────────────────────────────────────────────
    # WHY MANIFEST.txt: avoids guessing which artifacts are expected based on profiles;
    #     old backups (no MANIFEST) fall back to core-minimum check with WARN.
    if [[ -f "${restore_dir}/MANIFEST.txt" ]]; then
        local artifact comp_ok=1
        while IFS= read -r artifact; do
            [[ -z "$artifact" || "$artifact" == \#* ]] && continue
            if [[ ! -f "${restore_dir}/${artifact}" ]]; then
                _registry_add "comp_${artifact}" "completeness" "FAIL" \
                    "Артефакт из MANIFEST отсутствует: ${artifact}" \
                    "Бэкап неполный — используй предыдущий: \`agmind backup list\`" false ""
                comp_ok=0
            fi
        done < "${restore_dir}/MANIFEST.txt"
        [[ "$comp_ok" -eq 1 ]] && \
            _registry_add "completeness" "completeness" "OK" \
                "Все артефакты из MANIFEST на месте" "" false ""
    else
        _registry_add "comp_no_manifest" "completeness" "WARN" \
            "MANIFEST.txt отсутствует (старый формат бэкапа) — проверка полноты ограничена" \
            "Обновлённые бэкапы создают MANIFEST автоматически" false ""
        local core
        for core in "dify_db.sql.gz" "env.backup"; do
            if [[ ! -f "${restore_dir}/${core}" && ! -f "${restore_dir}/${core}.age" ]]; then
                _registry_add "comp_${core}" "completeness" "FAIL" \
                    "Ключевой артефакт отсутствует: ${core}" \
                    "Бэкап повреждён или неполный — используй предыдущий: \`agmind backup list\`" false ""
            fi
        done
    fi

    # ── Render + exit ─────────────────────────────────────────────────────────
    if [[ "$json" -eq 1 ]]; then
        _registry_render_json
    else
        _registry_render_human
        echo
    fi
    _registry_count
    [[ "$RESTORE_ERRORS" -eq 0 ]] || return 1
    return 0
}

# ============================================================================
# RESTORE PLAN HELPERS
# ============================================================================

# _VALID_SERVICES — authoritative list of --service values; derived from
# restore_artifact_map's 4th field to avoid a second hardcoded list.
_VALID_SERVICES="dify rag ragflow openwebui ollama config"

# _plan_compose_names_for_service <svc>
# Returns the compose service names to stop/start for the given group.
# WHY hardcoded fallback: lib/restore.sh is standalone-safe; sources
# lib/service-map.sh if available, else uses the small static subset.
_plan_compose_names_for_service() {
    local svc="$1" restore_dir="${2:-}"
    case "$svc" in
        dify)      echo "api worker web sandbox plugin_daemon" ;;
        rag)
            # Only the vector store actually present in the backup
            if [[ -n "$restore_dir" && -f "${restore_dir}/qdrant.tar.gz" ]]; then
                echo "qdrant"
            else
                echo "weaviate"
            fi
            ;;
        ragflow)   echo "ragflow ragflow_mysql ragflow_es01" ;;
        openwebui) echo "open-webui" ;;
        ollama)    echo "ollama" ;;
        config)    echo "" ;;   # no containers — config applied on next agmind restart
        *)         echo "" ;;
    esac
}

# _plan_artifacts_for_service <svc|""> <restore_dir>
# Prints artifact-map rows (tab-delimited: filename|type|target|service|optional)
# filtered to the given service group. Empty svc = all rows.
# For "rag": only emits the vector store file actually present in restore_dir.
_plan_artifacts_for_service() {
    local svc="$1" restore_dir="$2"
    restore_artifact_map | while IFS='|' read -r fname atype atarget asvc aopt; do
        # Skip meta entries (sha256sums.txt etc.)
        [[ "$asvc" == "skip" ]] && continue
        # Filter by service group
        [[ -z "$svc" || "$asvc" == "$svc" ]] || continue
        # For rag: only emit the vector store actually present on disk
        if [[ "$asvc" == "rag" ]]; then
            [[ -f "${restore_dir}/${fname}" ]] || continue
        fi
        printf '%s|%s|%s|%s|%s\n' "$fname" "$atype" "$atarget" "$asvc" "$aopt"
    done
}

# restore_plan <RESTORE_DIR> [--service <name>] [--dry-run]
# Prints human-readable restore plan (what will be restored, what will be stopped).
# Read-only — zero mutations, no FS writes, no mutating docker calls.
# Exit 0 if restore_verify returns 0; exit 1 if restore_verify found FAIL
# (plan is printed either way, with a warning on verify FAIL).
restore_plan() {
    local restore_dir="" svc="" dry=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)        dry=1; shift ;;
            --service)
                shift
                [[ $# -gt 0 ]] || { echo "restore_plan: --service requires a value" >&2; return 1; }
                svc="$1"; shift
                ;;
            --service=*)      svc="${1#--service=}"; shift ;;
            -*)               echo "restore_plan: unknown option: $1" >&2; return 1 ;;
            *)                restore_dir="$1"; shift ;;
        esac
    done

    [[ -n "$restore_dir" ]] || { echo "restore_plan: RESTORE_DIR required" >&2; return 1; }

    # Validate --service value before anything else
    if [[ -n "$svc" ]]; then
        local ok=0 v
        for v in $_VALID_SERVICES; do
            [[ "$v" == "$svc" ]] && ok=1 && break
        done
        if [[ "$ok" -eq 0 ]]; then
            echo "Неизвестный сервис: ${svc}. Допустимые: ${_VALID_SERVICES}" >&2
            return 1
        fi
    fi

    [[ -d "$restore_dir" ]] || { echo "Каталог не найден: ${restore_dir}" >&2; return 1; }

    # ── 1. Run restore_verify first (read-only — no mutations) ───────────────
    local vrc=0
    restore_verify "$restore_dir" || vrc=$?
    echo

    # ── 2. Plan header ────────────────────────────────────────────────────────
    if [[ "$dry" -eq 1 ]]; then
        echo "=== План восстановления (dry-run) ==="
    else
        echo "=== План восстановления ==="
    fi
    [[ -n "$svc" ]] && echo "Область: --service ${svc}"

    # ── 3. PostgreSQL section ─────────────────────────────────────────────────
    echo
    echo "PostgreSQL:"
    local pg_found=0 afile atype atgt asvc aopt
    while IFS='|' read -r afile atype atgt asvc aopt; do
        [[ "$atype" == "pgdump" ]] || continue
        [[ -f "${restore_dir}/${afile}" ]] || continue
        echo "  ${atgt} ← ${afile}"
        pg_found=1
    done < <(_plan_artifacts_for_service "$svc" "$restore_dir")
    [[ "$pg_found" -eq 1 ]] || echo "  (нет SQL-дампов в области)"

    # ── 4. Volumes / каталоги section ────────────────────────────────────────
    echo
    echo "Volumes / каталоги:"
    local vol_found=0
    while IFS='|' read -r afile atype atgt asvc aopt; do
        case "$atype" in
            volume-path|volume-docker|volume-tar) : ;;
            *) continue ;;
        esac
        [[ -f "${restore_dir}/${afile}" ]] || continue
        echo "  $(basename "${atgt}") ← ${afile} → ${atgt}"
        vol_found=1
    done < <(_plan_artifacts_for_service "$svc" "$restore_dir")
    [[ "$vol_found" -eq 1 ]] || echo "  (нет томов в области)"

    # ── 5. Config section ─────────────────────────────────────────────────────
    echo
    echo "Config:"
    local cfg_found=0
    while IFS='|' read -r afile atype atgt asvc aopt; do
        case "$atype" in
            config-file|config-tar) : ;;
            *) continue ;;
        esac
        [[ -f "${restore_dir}/${afile}" ]] || continue
        echo "  ${atgt} ← ${afile}"
        cfg_found=1
    done < <(_plan_artifacts_for_service "$svc" "$restore_dir")
    [[ "$cfg_found" -eq 1 ]] || echo "  (нет конфигов в области)"

    # ── 6. Будет остановлено section ─────────────────────────────────────────
    echo
    echo "Будет остановлено:"
    if [[ -z "$svc" ]]; then
        echo "  весь стек (docker compose down), затем поднимется заново"
    else
        local names
        names="$(_plan_compose_names_for_service "$svc" "$restore_dir")"
        if [[ -n "$names" ]]; then
            echo "  только: ${names}"
            if [[ "$svc" == "dify" ]]; then
                echo "  (postgres НЕ останавливается — БД восстанавливается в живой контейнер)"
            fi
        else
            echo "  ничего (конфиг применится после: \`agmind restart\`)"
        fi
    fi

    # ── 7. Trailing line + exit code ─────────────────────────────────────────
    echo
    if [[ "$dry" -eq 1 ]]; then
        echo "Изменений не внесено (dry-run)."
    fi
    if [[ "$vrc" -ne 0 ]]; then
        echo "ВНИМАНИЕ: бэкап не прошёл verify — восстановление рискованно." >&2
        return 1
    fi
    return 0
}

# ============================================================================
# RESTORE APPLY — PERFORMER FUNCTIONS
# WHY split: each performer is independently testable; no-service path calls
#     all performers in sequence (same as scripts/restore.sh); selective path
#     calls only the relevant ones.
# NOTE: flock is already held by scripts/restore.sh (fd 9) — do NOT re-acquire.
# NOTE: use `return`, never `exit` — lib is sourced under `set -euo pipefail`.
# umask 077 — applied here for standalone-safe (scripts/restore.sh also sets it).
# ============================================================================

# shellcheck disable=SC2034
RESTORE_TMP=""

# _restore_cleanup — trap handler; removes RESTORE_TMP only (no compose-up-on-fail
# in the lib; the thin scripts/restore.sh wrapper keeps its own compose-up trap).
_restore_cleanup() {
    [[ -d "${RESTORE_TMP:-}" ]] && rm -rf "$RESTORE_TMP"
}

# _restore_decrypt <dir>
# Decrypts *.age files in-place using ${INSTALL_DIR}/.age/agmind.key.
# Returns 1 if encrypted files are present but cannot be decrypted.
_restore_decrypt() {
    local dir="$1"
    local has_age=false af
    for af in "${dir}"/*.age; do [[ -f "$af" ]] && has_age=true && break; done
    [[ "$has_age" == "true" ]] || return 0   # no .age files → nothing to do

    local age_key="${INSTALL_DIR}/.age/agmind.key"
    local key_to_use=""
    if [[ -f "$age_key" ]] && command -v age >/dev/null 2>&1; then
        key_to_use="$age_key"
    else
        log_warn "Ключ расшифровки не найден: ${age_key}"
        return 1
    fi

    log_info "Расшифровка бэкапа..."
    for af in "${dir}"/*.age; do
        [[ -f "$af" ]] || continue
        local out="${af%.age}"
        age -d -i "$key_to_use" -o "$out" "$af" && rm -f "$af"
    done
    log_success "Бэкап расшифрован"
    return 0
}

# _restore_pg_dify <dir>
# Restores the dify PostgreSQL database (drop + recreate + gunzip | psql).
# On selective path: `docker compose up -d db` is idempotent (safe for live db).
# On no-service path: `stop db` at end (start-all step re-starts it).
_restore_pg_dify() {
    local dir="$1" svc_mode="${2:-full}"   # full | selective
    [[ -f "${dir}/dify_db.sql.gz" ]] || return 0

    log_info "Восстановление PostgreSQL (dify)..."
    local compose_dir="${INSTALL_DIR}/docker"
    # up -d db is idempotent; never use recreate (stale Redis state — CLAUDE.md §8)
    ( cd "$compose_dir" && docker compose up -d db )

    # Wait up to 60s for pg_isready
    local _pg_try
    for _pg_try in $(seq 1 30); do
        if ( cd "$compose_dir" && docker compose exec -T db pg_isready -U postgres >/dev/null 2>&1 ); then
            break
        fi
        sleep 2
    done
    if ! ( cd "$compose_dir" && docker compose exec -T db pg_isready -U postgres >/dev/null 2>&1 ); then
        log_error "PostgreSQL не готов в отведённое время"
        return 1
    fi

    ( cd "$compose_dir" && docker compose exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS dify;" 2>/dev/null ) || true
    ( cd "$compose_dir" && docker compose exec -T db psql -U postgres -c "CREATE DATABASE dify;" 2>/dev/null ) || true

    if ! gunzip -c "${dir}/dify_db.sql.gz" | \
            ( cd "$compose_dir" && docker compose exec -T db psql -U postgres -d dify 2>/dev/null ); then
        log_error "PostgreSQL restore не удался (dify)"
        return 1
    fi

    # On full restore: stop db; start-all step will bring it back
    [[ "$svc_mode" == "full" ]] && ( cd "$compose_dir" && docker compose stop db )
    log_success "PostgreSQL (dify) восстановлен"
    return 0
}

# _restore_pg_dify_plugin <dir>
_restore_pg_dify_plugin() {
    local dir="$1" svc_mode="${2:-full}"
    [[ -f "${dir}/dify_plugin_db.sql.gz" ]] || return 0

    local compose_dir="${INSTALL_DIR}/docker"
    ( cd "$compose_dir" && docker compose exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS dify_plugin;" 2>/dev/null ) || true
    ( cd "$compose_dir" && docker compose exec -T db psql -U postgres -c "CREATE DATABASE dify_plugin;" 2>/dev/null ) || true

    if ! gunzip -c "${dir}/dify_plugin_db.sql.gz" | \
            ( cd "$compose_dir" && docker compose exec -T db psql -U postgres -d dify_plugin 2>/dev/null ); then
        log_error "PostgreSQL restore не удался (dify_plugin)"
        return 1
    fi
    log_success "PostgreSQL (dify_plugin) восстановлен"
    return 0
}

# _restore_volume_path_safe <dir> <archive_file> <target_path>
# Generic safe-rename restore for volume-path archives.
# Moves old data to RESTORE_TMP/.old before extracting; rolls back on failure.
_restore_volume_path_safe() {
    local dir="$1" archive="$2" target_path="$3"
    [[ -f "${dir}/${archive}" ]] || return 0

    local target="${INSTALL_DIR}/${target_path}"
    local tmp_old
    tmp_old="${RESTORE_TMP}/$(basename "$target").old"
    mkdir -p "$tmp_old"
    [[ -d "$target" ]] && mv "$target" "${tmp_old}/" 2>/dev/null || true
    mkdir -p "$target"
    if tar xzf "${dir}/${archive}" -C "${target}/"; then
        rm -rf "$tmp_old"
        log_success "${archive} восстановлен → ${target}"
    else
        rm -rf "$target"
        mv "${tmp_old}/$(basename "$target")" "$target" 2>/dev/null || true
        rm -rf "$tmp_old"
        log_error "${archive} restore не удался, старые данные сохранены"
        return 1
    fi
    return 0
}

# _restore_volume_vectorstore <dir>
# Restores qdrant OR weaviate volume-path (whichever archive is present).
_restore_volume_vectorstore() {
    local dir="$1"
    if [[ -f "${dir}/qdrant.tar.gz" ]]; then
        log_info "Восстановление Qdrant..."
        _restore_volume_path_safe "$dir" "qdrant.tar.gz" "docker/volumes/qdrant"
    elif [[ -f "${dir}/weaviate.tar.gz" ]]; then
        log_info "Восстановление Weaviate..."
        _restore_volume_path_safe "$dir" "weaviate.tar.gz" "docker/volumes/weaviate"
    fi
    return 0
}

# _restore_volume_dify_storage <dir>
_restore_volume_dify_storage() {
    local dir="$1"
    [[ -f "${dir}/dify-storage.tar.gz" ]] || return 0
    log_info "Восстановление Dify storage..."
    _restore_volume_path_safe "$dir" "dify-storage.tar.gz" "docker/volumes/app/storage"
}

# _restore_volume_docker_run <dir> <archive> <vol_pattern> <display_name>
# Generic restore for docker-named volumes using `docker run --rm alpine`.
_restore_volume_docker_run() {
    local dir="$1" archive="$2" vol_pattern="$3" display_name="$4"
    [[ -f "${dir}/${archive}" ]] || return 0

    local vol_name
    # shellcheck disable=SC2026,SC2046
    vol_name="$(docker volume ls -q 2>/dev/null | grep -m1 "$vol_pattern" || true)"
    if [[ -z "$vol_name" ]]; then
        log_warn "Volume ${vol_pattern} не найден, пропускаем ${display_name}"
        return 0
    fi
    docker run --rm -v "${vol_name}:/data" -v "${dir}:/backup" \
        alpine sh -c "rm -rf /data/* && tar xzf /backup/${archive} -C /data/"
    log_success "${display_name} восстановлен"
    return 0
}

# _restore_volume_openwebui <dir>
_restore_volume_openwebui() {
    local dir="$1"
    log_info "Восстановление Open WebUI..."
    _restore_volume_docker_run "$dir" "openwebui.tar.gz" "openwebui" "Open WebUI"
}

# _restore_volume_ollama <dir>
_restore_volume_ollama() {
    local dir="$1"
    log_info "Восстановление Ollama models..."
    _restore_volume_docker_run "$dir" "ollama.tar.gz" "ollama_data" "Ollama"
}

# _restore_ragflow <dir>
# RAGFlow restore is not automated (MySQL + ES + MinIO requires manual steps).
# Presence of ragflow artifacts is noted; user is directed to documentation.
_restore_ragflow() {
    local dir="$1"
    if [[ -f "${dir}/ragflow_mysql.sql.gz" || -f "${dir}/ragflow_es.live.tar.gz" ]]; then
        log_warn "RAGFlow артефакты есть в бэкапе, но автоматический restore не реализован"
        echo "       → см. backup.sh §6g для ручного восстановления RAGFlow"
    fi
    return 0
}

# _restore_config <dir> <auto:0|1>
# Restores .env, nginx.conf, authelia config (prompt or auto-confirm).
_restore_config() {
    local dir="$1" auto="${2:-0}"
    [[ -f "${dir}/env.backup" ]] || return 0

    local do_restore="no"
    if [[ "$auto" -eq 1 ]]; then
        do_restore="yes"
    else
        read -rp "Восстановить конфигурацию (.env, nginx)? (yes/no): " do_restore
    fi
    [[ "$do_restore" == "yes" ]] || return 0

    umask 077
    cp "${dir}/env.backup" "${INSTALL_DIR}/docker/.env"
    chmod 600 "${INSTALL_DIR}/docker/.env"
    cp "${dir}/nginx.conf.backup" "${INSTALL_DIR}/docker/nginx/nginx.conf" 2>/dev/null || true
    if [[ -f "${dir}/docker-compose.yml.backup" ]]; then
        cp "${dir}/docker-compose.yml.backup" "${INSTALL_DIR}/docker/docker-compose.yml" 2>/dev/null || true
    fi
    if [[ -f "${dir}/authelia.tar.gz" ]]; then
        log_info "Восстановление Authelia конфигурации..."
        mkdir -p "${INSTALL_DIR}/docker/authelia"
        tar xzf "${dir}/authelia.tar.gz" -C "${INSTALL_DIR}/docker/authelia/"
        log_success "Authelia конфигурация восстановлена"
    fi
    # Legacy: age_keys directory in backup root
    if [[ -d "${dir}/age_keys" ]]; then
        log_info "Восстановление ключей шифрования..."
        mkdir -p "${INSTALL_DIR}/.age"
        cp -r "${dir}/age_keys/"* "${INSTALL_DIR}/.age/"
        chmod 700 "${INSTALL_DIR}/.age"
        chmod 600 "${INSTALL_DIR}/.age/"* 2>/dev/null || true
        log_success "Ключи шифрования восстановлены"
    fi
    log_success "Конфигурация восстановлена"
    return 0
}

# ── _svc_match helper ─────────────────────────────────────────────────────────
# Returns 0 if svc is empty (all mode) or equals the given name.
_svc_match() {
    local check_svc="$1" cur_svc="$2"
    [[ -z "$cur_svc" || "$check_svc" == "$cur_svc" ]]
}

# ============================================================================
# restore_apply <RESTORE_DIR> [--service <name>] [--auto-confirm]
# Executes the actual restore. No-service path = full restore (same sequence as
# scripts/restore.sh steps 6-18, refactored into performers). Selective path
# stops ONLY affected containers — never `docker compose down`, never recreate containers.
# Requires root (checked by caller). flock already held by scripts/restore.sh.
# ============================================================================
restore_apply() {
    local restore_dir="" svc="" auto=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-confirm)  auto=1; shift ;;
            --service)
                shift
                [[ $# -gt 0 ]] || { echo "restore_apply: --service requires a value" >&2; return 1; }
                svc="$1"; shift
                ;;
            --service=*)     svc="${1#--service=}"; shift ;;
            -*)              echo "restore_apply: unknown option: $1" >&2; return 1 ;;
            *)               restore_dir="$1"; shift ;;
        esac
    done

    [[ -n "$restore_dir" ]] || { echo "restore_apply: RESTORE_DIR required" >&2; return 1; }

    # Validate --service
    if [[ -n "$svc" ]]; then
        local ok=0 v
        for v in $_VALID_SERVICES; do
            [[ "$v" == "$svc" ]] && ok=1 && break
        done
        if [[ "$ok" -eq 0 ]]; then
            echo "Неизвестный сервис: ${svc}. Допустимые: ${_VALID_SERVICES}" >&2
            return 1
        fi
    fi

    [[ -d "$restore_dir" ]] || { echo "Каталог не найден: ${restore_dir}" >&2; return 1; }

    # 0. Preview plan + confirmation
    local _vrc=0
    restore_plan "$restore_dir" ${svc:+--service "$svc"} || _vrc=$?
    if [[ "$auto" -ne 1 ]]; then
        local _c
        read -rp "Восстановить из этого бэкапа? Текущие данные будут перезаписаны. (yes/no): " _c
        [[ "$_c" == "yes" ]] || { echo "Отменено."; return 0; }
    fi

    # 1. Decrypt .age files in-place (only in apply — never in verify/plan)
    _restore_decrypt "$restore_dir" || return 1

    # 2. Verify checksums (warn + continue under auto-confirm; prompt otherwise)
    if [[ -f "${restore_dir}/sha256sums.txt" ]]; then
        local _sums_ok=0
        ( cd "$restore_dir" && sha256sum -c sha256sums.txt >/dev/null 2>&1 ) && _sums_ok=1 || true
        if [[ "$_sums_ok" -ne 1 ]]; then
            log_warn "Контрольные суммы НЕ совпадают!"
            if [[ "$auto" -ne 1 ]]; then
                local _fc
                read -rp "Продолжить восстановление? (yes/no): " _fc
                [[ "$_fc" == "yes" ]] || { echo "Отменено."; return 1; }
            fi
        fi
    fi

    # 3. RESTORE_TMP on same FS as data volumes (avoids cross-device mv)
    RESTORE_TMP="${INSTALL_DIR}/.restore_tmp"
    mkdir -p "$RESTORE_TMP"
    # shellcheck disable=SC2064
    trap '_restore_cleanup' RETURN INT TERM

    # 4. Stop containers
    local compose_dir="${INSTALL_DIR}/docker"
    if [[ -z "$svc" ]]; then
        ( cd "$compose_dir" && docker compose down )
    else
        local _names
        _names="$(_plan_compose_names_for_service "$svc" "$restore_dir")"
        # shellcheck disable=SC2086
        [[ -n "$_names" ]] && ( cd "$compose_dir" && docker compose stop $_names )
        # config-only: no containers stopped
    fi
    # NEVER recreate containers — use stop/up only (stale Redis trap — CLAUDE.md §8)

    # 5. Run performers gated by svc
    local _svc_mode="full"
    [[ -n "$svc" ]] && _svc_mode="selective"

    if _svc_match dify "$svc"; then
        _restore_pg_dify      "$restore_dir" "$_svc_mode"
        _restore_pg_dify_plugin "$restore_dir" "$_svc_mode"
        _restore_volume_dify_storage "$restore_dir"
    fi
    if _svc_match rag       "$svc"; then _restore_volume_vectorstore "$restore_dir"; fi
    if _svc_match openwebui "$svc"; then _restore_volume_openwebui  "$restore_dir"; fi
    if _svc_match ollama    "$svc"; then _restore_volume_ollama     "$restore_dir"; fi
    if _svc_match ragflow   "$svc"; then _restore_ragflow           "$restore_dir" || true; fi
    if _svc_match config    "$svc"; then _restore_config            "$restore_dir" "$auto"; fi

    # 6. Cleanup tmp
    rm -rf "$RESTORE_TMP" 2>/dev/null || true
    RESTORE_TMP=""

    # 7. Start containers
    if [[ -z "$svc" ]]; then
        local _profiles=""
        [[ -f "${compose_dir}/.env" ]] && \
            _profiles="$(grep '^COMPOSE_PROFILES=' "${compose_dir}/.env" 2>/dev/null | cut -d= -f2- || true)"
        if [[ -n "$_profiles" ]]; then
            ( cd "$compose_dir" && COMPOSE_PROFILES="$_profiles" docker compose up -d )
        else
            ( cd "$compose_dir" && docker compose up -d )
        fi
    else
        local _start_names
        _start_names="$(_plan_compose_names_for_service "$svc" "$restore_dir")"
        # shellcheck disable=SC2086
        [[ -n "$_start_names" ]] && ( cd "$compose_dir" && docker compose up -d $_start_names )
        [[ "$svc" == "config" ]] && echo "Конфигурация восстановлена. Применить: \`agmind restart\`"
    fi

    # 8. Stale-Redis hint after dify-DB restore (CLAUDE.md §8 — FLUSHDB blocked by ACL)
    if _svc_match dify "$svc" && [[ -f "${restore_dir}/dify_db.sql.gz" ]]; then
        echo
        echo "Если Celery-воркеры перезапускались, очисти stale Redis-ключи:"
        echo "  redis-cli -a \$REDIS_PASSWORD -n 0 --scan --pattern 'generate_task_belong:*' | xargs redis-cli -a \$REDIS_PASSWORD -n 0 DEL"
        echo "  redis-cli -a \$REDIS_PASSWORD -n 1 --scan --pattern 'celery-task-meta-*'   | xargs redis-cli -a \$REDIS_PASSWORD -n 1 DEL"
        echo "  (FLUSHDB заблокирован ACL — только DEL по ключам.)"
    fi
    echo
    echo "=== Восстановление завершено ==="
    return 0
}

# ============================================================================
# restore_list — prints DATE / SIZE / STATUS table of available backups.
# STATUS: ok if sha256sums.txt + core artifact present; suspect otherwise.
#         Appends ' [зашифрован]' marker if *.age files present.
# Called by `agmind backup list`.
# ============================================================================
restore_list() {
    local base="${BACKUP_BASE:-/var/backups/agmind}"
    [[ -d "$base" ]] || { echo "Нет каталога бэкапов: ${base}" >&2; return 1; }
    printf "%-20s %-8s %s\n" "ДАТА" "РАЗМЕР" "СТАТУС"
    printf "%-20s %-8s %s\n" "----" "------" "------"
    local found=0 dir name size status enc
    for dir in "${base}"/*/; do
        [[ -d "$dir" ]] || continue
        found=1
        name="$(basename "$dir")"
        size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
        enc=""
        ls "${dir}"/*.age >/dev/null 2>&1 && enc=" [зашифрован]"
        if [[ ! -f "${dir}/sha256sums.txt" ]]; then
            status="suspect"
        elif [[ ! -f "${dir}/dify_db.sql.gz" && ! -f "${dir}/dify_db.sql.gz.age" ]]; then
            status="suspect"
        else
            status="ok"
        fi
        printf "%-20s %-8s %s%s\n" "$name" "$size" "$status" "$enc"
    done
    [[ "$found" -eq 1 ]] || echo "(нет бэкапов)"
    return 0
}
