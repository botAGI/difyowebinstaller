#!/usr/bin/env bash
# lib/migrations/001-initial.sh — bootstrap schema 0 -> 1.
#
# Copies legacy secrets into state-store WITHOUT removing legacy:
#   - 3 .preserved files in ${STATE_DIR}: surrealdb_password, n8n_encryption_key,
#     portainer_agent_secret -> state_set_secret <UPPERCASE_NAME> <bytes>
#   - Known KEYS from ${INSTALL_DIR}/docker/.env via _env_get_raw -> state_set_secret
#
# Idempotent: re-running on already-migrated state is a no-op (schema check + upsert).
# Atomicity: migrations_apply tar-backups STATE_DIR BEFORE sourcing this; on failure,
# operator runs `agmind upgrade --rollback 0` (NO auto-rollback).
#
# Phase 11 contract: this migration COPIES bytes. It does NOT delete legacy files
# or .env entries. Phase 14 STATE-11 ships migration 002-cleanup-preserved.sh that
# removes legacy AFTER consumers are flipped to state_get_secret API.

# Sourced by lib/migrations.sh::migrations_apply in a subshell with set -euo pipefail
# and these globals/functions in scope: STATE_DIR, INSTALL_DIR, state_set_secret,
# state_schema_version, _env_get_raw, log_*.

migration_1_up() {
    # Defense-in-depth — migrations_apply already filters via migrations_pending,
    # but if operator manually reset schema_version=0 with stale secrets.env still
    # populated, this prevents silent secret rotation.
    local current
    current="$(state_schema_version)"
    if [[ "$current" -ge 1 ]]; then
        log_info "migration 001: already applied (schema=${current}), no-op"
        return 0
    fi

    local secrets_file="${STATE_DIR}/secrets.env"
    local docker_env="${INSTALL_DIR}/docker/.env"

    log_info "migration 001: bootstrap state-store from v3.1.x legacy"

    # 1. Ensure secrets.env exists with schema marker (state_init_dir should have done this,
    #    but be safe — migration may be run before state_init_dir on edge paths).
    if [[ ! -f "$secrets_file" ]]; then
        install -m 0600 /dev/null "$secrets_file" || return 1
        printf '# schema=0\n' > "$secrets_file"
    fi

    # 2. Copy 3 known .preserved files (bytes verbatim, no shell interpretation).
    local pair pname kname src val
    for pair in \
        "surrealdb_password.preserved:SURREALDB_PASSWORD" \
        "n8n_encryption_key.preserved:N8N_ENCRYPTION_KEY" \
        "portainer_agent_secret.preserved:PORTAINER_AGENT_SECRET"
    do
        pname="${pair%%:*}"
        kname="${pair##*:}"
        src="${STATE_DIR}/${pname}"
        if [[ -s "$src" ]]; then
            # `cat` returns byte-exact contents; trailing newline (if any) consumed
            # by $() command-substitution — matches what _generate_secrets wrote.
            val="$(cat "$src")"
            if [[ -n "$val" ]]; then
                state_set_secret "$kname" "$val" || return 1
                log_info "migration 001: copied ${pname} -> secrets.env::${kname}"
            else
                log_warn "migration 001: ${pname} is empty — skip"
            fi
        fi
    done

    # 3. Copy known secrets from docker/.env via _env_get_raw (byte-exact, $-safe).
    #    Placeholder values like `__VLLM_MODEL__` are sed-targets, not real secrets — skip them.
    if [[ -r "$docker_env" ]]; then
        local key
        for key in \
            DB_PASSWORD REDIS_PASSWORD SECRET_KEY \
            SANDBOX_API_KEY PLUGIN_DAEMON_KEY PLUGIN_INNER_API_KEY \
            WEAVIATE_API_KEY QDRANT_API_KEY \
            GRAFANA_ADMIN_PASSWORD \
            AUTHELIA_JWT_SECRET AUTHELIA_SESSION_SECRET AUTHELIA_STORAGE_KEY \
            LITELLM_MASTER_KEY SEARXNG_SECRET_KEY \
            MINIO_ROOT_USER MINIO_ROOT_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY \
            RAGFLOW_MYSQL_PASSWORD RAGFLOW_ES_PASSWORD RAGFLOW_MINIO_PASSWORD \
            NOTEBOOK_ENCRYPTION_KEY
        do
            if val="$(_env_get_raw "$key" "$docker_env" 2>/dev/null)"; then
                # Skip empty values and placeholder tokens (e.g. __VLLM_MODEL__)
                [[ -n "$val" ]] || continue
                [[ "$val" == "__"*"__" ]] && continue
                state_set_secret "$key" "$val" || return 1
            fi
        done
    else
        log_warn "migration 001: ${docker_env} not readable — skipping .env copy (fresh install path)"
    fi

    # 4. NB: legacy .preserved files NOT removed (rollback safety, Phase 14 territory).
    # 5. NB: ${INSTALL_DIR}/docker/.env entries NOT removed (live consumers still grep them).

    log_info "migration 001: complete"
    return 0
}

migration_1_down() {
    # Rollback hint: real rollback path is `agmind upgrade --rollback 0` which restores
    # the pre-migration tarball via tar. This function is a fallback — wipes secrets.env
    # to the schema=0 marker only.
    local secrets_file="${STATE_DIR}/secrets.env"
    if [[ -f "$secrets_file" ]]; then
        local tmp
        tmp="$(mktemp "${STATE_DIR}/secrets.env.tmp.XXXXXX")" || return 1
        chmod 0600 "$tmp" 2>/dev/null || true
        printf '# schema=0\n' > "$tmp"
        mv "$tmp" "$secrets_file" || { rm -f "$tmp"; return 1; }
    fi
    return 0
}
