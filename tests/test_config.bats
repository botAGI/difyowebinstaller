#!/usr/bin/env bats

# Test config.sh functions

setup() {
    export INSTALL_DIR="$(mktemp -d)"
    mkdir -p "${INSTALL_DIR}/docker"
    source "$(dirname "$BATS_TEST_FILENAME")/../lib/config.sh" 2>/dev/null || true
}

teardown() {
    rm -rf "$INSTALL_DIR"
}

@test "generate_random produces correct length" {
    result=$(generate_random 16)
    [ ${#result} -eq 16 ]
}

@test "generate_random produces alphanumeric only" {
    result=$(generate_random 64)
    [[ "$result" =~ ^[a-zA-Z0-9]+$ ]]
}

@test "generate_random produces unique values" {
    val1=$(generate_random 32)
    val2=$(generate_random 32)
    [ "$val1" != "$val2" ]
}

@test "escape_sed handles special characters" {
    result=$(escape_sed "test&value/with|backslash\\")
    [[ "$result" == *'\&'* ]] && [[ "$result" == *'\/'* ]]
}

@test "validate_no_default_secrets rejects 'changeme'" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_PASSWORD=changeme" > "$env_file"
    run validate_no_default_secrets "$env_file"
    [ "$status" -ne 0 ]
}

@test "validate_no_default_secrets rejects 'difyai123456'" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "SECRET_KEY=difyai123456" > "$env_file"
    run validate_no_default_secrets "$env_file"
    [ "$status" -ne 0 ]
}

@test "validate_no_default_secrets accepts random passwords" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "DB_PASSWORD=$(generate_random 32)" > "$env_file"
    echo "SECRET_KEY=$(generate_random 64)" >> "$env_file"
    run validate_no_default_secrets "$env_file"
    [ "$status" -eq 0 ]
}

@test "validate_no_default_secrets rejects unresolved placeholders" {
    local env_file="${INSTALL_DIR}/docker/.env"
    echo "SECRET_KEY=__SECRET_KEY__" > "$env_file"
    run validate_no_default_secrets "$env_file"
    [ "$status" -ne 0 ]
}

@test "versions.env has no 'latest' tags" {
    local versions_file="$(dirname "$BATS_TEST_FILENAME")/../templates/versions.env"
    run grep -i "latest" "$versions_file"
    [ "$status" -ne 0 ]
}

@test "env templates have no _VERSION variables" {
    for template in $(dirname "$BATS_TEST_FILENAME")/../templates/env.*.template; do
        count=$(grep -c "_VERSION=" "$template" || true)
        [ "$count" -eq 0 ]
    done
}

@test "nginx template has no __ADMIN_TOKEN__" {
    local nginx_template="$(dirname "$BATS_TEST_FILENAME")/../templates/nginx.conf.template"
    run grep "__ADMIN_TOKEN__" "$nginx_template"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml is valid YAML" {
    local compose="$(dirname "$BATS_TEST_FILENAME")/../templates/docker-compose.yml"
    run python3 -c "import yaml; yaml.safe_load(open('$compose'))"
    [ "$status" -eq 0 ]
}

@test "all services have security-defaults" {
    local compose="$(dirname "$BATS_TEST_FILENAME")/../templates/docker-compose.yml"
    local service_count=$(grep -c "<<: \*security-defaults" "$compose")
    [ "$service_count" -ge 20 ]
}

@test "backup and restore use same DB dump filename" {
    local base="$(dirname "$BATS_TEST_FILENAME")/.."
    local backup_file="$base/scripts/backup.sh"
    local restore_file="$base/scripts/restore.sh"
    local runbook_file="$base/scripts/restore-runbook.sh"

    # backup.sh creates dify_db.sql — extract the canonical name
    grep -q 'dify_db\.sql' "$backup_file"
    grep -q 'dify_db\.sql' "$restore_file"
    grep -q 'dify_db\.sql' "$runbook_file"

    # plugin DB name must also match
    grep -q 'dify_plugin_db\.sql' "$backup_file"
    grep -q 'dify_plugin_db\.sql' "$restore_file"
}
