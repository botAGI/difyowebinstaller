#!/usr/bin/env bats
# test_common.bats — Tests for lib/common.sh
# Run: bats tests/test_common.bats

setup() {
    # Source common.sh in a subshell-friendly way
    export INSTALL_DIR="${BATS_TMPDIR}/agmind_test"
    mkdir -p "$INSTALL_DIR"
    # shellcheck source=../lib/common.sh
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
}

teardown() {
    rm -rf "${BATS_TMPDIR}/agmind_test"
}

# ============================================================================
# LOGGING
# ============================================================================

@test "log_info outputs to stderr with arrow prefix" {
    run log_info "test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"→ test message"* ]]
}

@test "log_warn outputs to stderr with warning prefix" {
    run log_warn "warning message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ warning message"* ]]
}

@test "log_error outputs to stderr with error prefix" {
    run log_error "error message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✗ error message"* ]]
}

@test "log_success outputs to stderr with check prefix" {
    run log_success "success message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✓ success message"* ]]
}

@test "log_info includes timestamp when LOG_FILE is set" {
    export LOG_FILE="/tmp/test.log"
    run log_info "timestamped"
    [ "$status" -eq 0 ]
    # Should contain date-like pattern YYYY-MM-DD
    [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]
    unset LOG_FILE
}

# ============================================================================
# VALIDATE MODEL NAME
# ============================================================================

@test "validate_model_name: valid names pass" {
    run validate_model_name "qwen2.5:14b"
    [ "$status" -eq 0 ]

    run validate_model_name "bge-m3"
    [ "$status" -eq 0 ]

    run validate_model_name "library/llama3:latest"
    [ "$status" -eq 0 ]

    run validate_model_name "my_model.v2"
    [ "$status" -eq 0 ]
}

@test "validate_model_name: empty name fails" {
    run validate_model_name ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot be empty"* ]]
}

@test "validate_model_name: invalid characters fail" {
    run validate_model_name "model name with spaces"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid model name"* ]]

    run validate_model_name 'model;rm -rf'
    [ "$status" -eq 1 ]
}

# ============================================================================
# VALIDATE DOMAIN
# ============================================================================

@test "validate_domain: valid domains pass" {
    run validate_domain "example.com"
    [ "$status" -eq 0 ]

    run validate_domain "sub.domain.org"
    [ "$status" -eq 0 ]

    run validate_domain "my-host"
    [ "$status" -eq 0 ]
}

@test "validate_domain: empty domain fails" {
    run validate_domain ""
    [ "$status" -eq 1 ]
}

@test "validate_domain: invalid domains fail" {
    run validate_domain "-startdash.com"
    [ "$status" -eq 1 ]

    run validate_domain "domain with space.com"
    [ "$status" -eq 1 ]
}

# ============================================================================
# VALIDATE EMAIL
# ============================================================================

@test "validate_email: valid emails pass" {
    run validate_email "user@example.com"
    [ "$status" -eq 0 ]

    run validate_email "first.last+tag@domain.org"
    [ "$status" -eq 0 ]
}

@test "validate_email: empty email fails" {
    run validate_email ""
    [ "$status" -eq 1 ]
}

@test "validate_email: invalid emails fail" {
    run validate_email "noatsign.com"
    [ "$status" -eq 1 ]

    run validate_email "@missing-local.com"
    [ "$status" -eq 1 ]

    run validate_email "user@"
    [ "$status" -eq 1 ]
}

# ============================================================================
# VALIDATE URL
# ============================================================================

@test "validate_url: valid URLs pass" {
    run validate_url "https://example.com"
    [ "$status" -eq 0 ]

    run validate_url "http://localhost:8080/path"
    [ "$status" -eq 0 ]

    run validate_url "https://10.0.0.1:9090/api/v1"
    [ "$status" -eq 0 ]
}

@test "validate_url: empty URL fails" {
    run validate_url ""
    [ "$status" -eq 1 ]
}

@test "validate_url: invalid URLs fail" {
    run validate_url "ftp://wrong-scheme.com"
    [ "$status" -eq 1 ]

    run validate_url "not-a-url"
    [ "$status" -eq 1 ]
}

# ============================================================================
# VALIDATE PORT
# ============================================================================

@test "validate_port: valid ports pass" {
    run validate_port "80"
    [ "$status" -eq 0 ]

    run validate_port "443"
    [ "$status" -eq 0 ]

    run validate_port "65535"
    [ "$status" -eq 0 ]

    run validate_port "1"
    [ "$status" -eq 0 ]
}

@test "validate_port: empty port fails" {
    run validate_port ""
    [ "$status" -eq 1 ]
}

@test "validate_port: invalid ports fail" {
    run validate_port "0"
    [ "$status" -eq 1 ]

    run validate_port "65536"
    [ "$status" -eq 1 ]

    run validate_port "abc"
    [ "$status" -eq 1 ]

    run validate_port "-1"
    [ "$status" -eq 1 ]
}

# ============================================================================
# VALIDATE CRON
# ============================================================================

@test "validate_cron: valid expressions pass" {
    run validate_cron "0 3 * * *"
    [ "$status" -eq 0 ]

    run validate_cron "*/15 * * * *"
    [ "$status" -eq 0 ]

    run validate_cron "0 0 1 * *"
    [ "$status" -eq 0 ]

    run validate_cron "30 2 1,15 * 0-6"
    [ "$status" -eq 0 ]
}

@test "validate_cron: empty expression fails" {
    run validate_cron ""
    [ "$status" -eq 1 ]
}

@test "validate_cron: invalid cron fails" {
    run validate_cron "not a cron"
    [ "$status" -eq 1 ]

    run validate_cron "0 3 * *"
    [ "$status" -eq 1 ]
}

# ============================================================================
# VALIDATE PATH
# ============================================================================

@test "validate_path: /tmp paths pass" {
    mkdir -p /tmp/agmind_test_path
    run validate_path "/tmp/agmind_test_path"
    [ "$status" -eq 0 ]
    [[ "$output" == "/tmp/agmind_test_path" ]]
    rmdir /tmp/agmind_test_path
}

@test "validate_path: empty path fails" {
    run validate_path ""
    [ "$status" -eq 1 ]
}

@test "validate_path: /var/backups passes" {
    if [[ -d "/var/backups" ]]; then
        run validate_path "/var/backups"
        [ "$status" -eq 0 ]
    else
        skip "/var/backups does not exist"
    fi
}

# ============================================================================
# VALIDATE HOSTNAME
# ============================================================================

@test "validate_hostname: valid hostnames pass" {
    run validate_hostname "my-server"
    [ "$status" -eq 0 ]

    run validate_hostname "host01.internal"
    [ "$status" -eq 0 ]
}

@test "validate_hostname: empty hostname fails" {
    run validate_hostname ""
    [ "$status" -eq 1 ]
}

@test "validate_hostname: invalid hostnames fail" {
    run validate_hostname "-bad"
    [ "$status" -eq 1 ]
}

# ============================================================================
# GENERATE RANDOM
# ============================================================================

@test "generate_random: default length is 32" {
    run generate_random
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ]
}

@test "generate_random: custom length works" {
    run generate_random 16
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 16 ]

    run generate_random 64
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 64 ]
}

@test "generate_random: output is alphanumeric only" {
    run generate_random 100
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[a-zA-Z0-9]+$ ]]
}

@test "generate_random: two calls produce different results" {
    local a b
    a="$(generate_random 32)"
    b="$(generate_random 32)"
    [ "$a" != "$b" ]
}

# ============================================================================
# ESCAPE SED
# ============================================================================

@test "escape_sed: escapes special characters" {
    run escape_sed "hello/world"
    [[ "$output" == 'hello\/world' ]]

    run escape_sed "a&b"
    [[ "$output" == 'a\&b' ]]

    run escape_sed 'back\slash'
    [[ "$output" == 'back\\slash' ]]
}

@test "escape_sed: plain string unchanged" {
    run escape_sed "hello"
    [[ "$output" == "hello" ]]
}

# ============================================================================
# ATOMIC SED
# ============================================================================

@test "_atomic_sed: replaces content atomically" {
    local testfile="${BATS_TMPDIR}/atomic_test.txt"
    echo "old content here" > "$testfile"
    _atomic_sed "$testfile" -e 's|old|new|g'
    run cat "$testfile"
    [[ "$output" == "new content here" ]]
    rm -f "$testfile"
}

@test "_atomic_sed: preserves file on sed failure" {
    local testfile="${BATS_TMPDIR}/atomic_fail.txt"
    echo "content" > "$testfile"
    # Invalid sed expression should fail
    run _atomic_sed "$testfile" -e 's|unclosed'
    [ "$status" -ne 0 ]
    # Original file should be intact
    run cat "$testfile"
    [[ "$output" == "content" ]]
    rm -f "$testfile"
}

@test "_atomic_sed: fails on missing file" {
    run _atomic_sed "/nonexistent/file.txt" -e 's|a|b|'
    [ "$status" -eq 1 ]
    [[ "$output" == *"file not found"* ]]
}

# ============================================================================
# SAFE WRITE FILE
# ============================================================================

@test "safe_write_file: creates parent directories" {
    local testpath="${INSTALL_DIR}/docker/deep/nested/file.conf"
    safe_write_file "$testpath"
    [ -d "$(dirname "$testpath")" ]
}

@test "safe_write_file: removes directory artifact" {
    local testpath="${INSTALL_DIR}/docker/nginx.conf"
    mkdir -p "$testpath"  # Docker creates dirs for missing bind mounts
    safe_write_file "$testpath"
    [ ! -d "$testpath" ]
    [ -d "$(dirname "$testpath")" ]
}

@test "safe_write_file: rejects paths outside INSTALL_DIR" {
    run safe_write_file "/etc/passwd"
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside INSTALL_DIR"* ]]
}

@test "safe_write_file: fails on empty path" {
    run safe_write_file ""
    [ "$status" -eq 1 ]
}

# ============================================================================
# VALIDATE NO DEFAULT SECRETS
# ============================================================================

@test "validate_no_default_secrets: clean env passes" {
    local envfile="${BATS_TMPDIR}/clean.env"
    cat > "$envfile" <<'EOF'
DB_PASSWORD=xK9mZ2pQ7rT4wY6n
SECRET_KEY=aB3cD5eF7gH9iJ1k
# comment with difyai123456 is fine
EOF
    run validate_no_default_secrets "$envfile"
    [ "$status" -eq 0 ]
    rm -f "$envfile"
}

@test "validate_no_default_secrets: detects weak passwords" {
    local envfile="${BATS_TMPDIR}/weak.env"
    cat > "$envfile" <<'EOF'
DB_PASSWORD=difyai123456
SECRET_KEY=realSecret42
EOF
    run validate_no_default_secrets "$envfile"
    [ "$status" -eq 1 ]
    [[ "$output" == *"weak default password"* ]]
    rm -f "$envfile"
}

@test "validate_no_default_secrets: detects unresolved placeholders" {
    local envfile="${BATS_TMPDIR}/placeholder.env"
    cat > "$envfile" <<'EOF'
DB_PASSWORD=__DB_PASSWORD__
SECRET_KEY=__SECRET_KEY__
EOF
    run validate_no_default_secrets "$envfile"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unresolved placeholders"* ]]
    rm -f "$envfile"
}

# ============================================================================
# INIT DETECTED DEFAULTS
# ============================================================================

@test "init_detected_defaults: sets all DETECTED_* variables" {
    # Unset everything first
    unset DETECTED_OS DETECTED_GPU DETECTED_RAM_TOTAL_MB
    unset DETECTED_DOCKER_INSTALLED DETECTED_NETWORK RECOMMENDED_MODEL

    init_detected_defaults

    [ "$DETECTED_OS" = "unknown" ]
    [ "$DETECTED_GPU" = "none" ]
    [ "$DETECTED_RAM_TOTAL_MB" = "0" ]
    [ "$DETECTED_DOCKER_INSTALLED" = "false" ]
    [ "$DETECTED_NETWORK" = "unknown" ]
    [ "$RECOMMENDED_MODEL" = "qwen2.5:7b" ]
}

@test "init_detected_defaults: preserves existing values" {
    export DETECTED_OS="ubuntu"
    export DETECTED_GPU="nvidia"
    export DETECTED_RAM_TOTAL_MB="16384"

    init_detected_defaults

    [ "$DETECTED_OS" = "ubuntu" ]
    [ "$DETECTED_GPU" = "nvidia" ]
    [ "$DETECTED_RAM_TOTAL_MB" = "16384" ]
}

# ============================================================================
# ENSURE BIND MOUNT FILES
# ============================================================================

@test "ensure_bind_mount_files: creates missing files" {
    local docker_dir="${INSTALL_DIR}/docker"
    mkdir -p "$docker_dir"

    ensure_bind_mount_files

    [ -f "${docker_dir}/nginx/nginx.conf" ]
    [ -f "${docker_dir}/volumes/redis/redis.conf" ]
    [ -f "${docker_dir}/volumes/ssrf_proxy/squid.conf" ]
    [ -f "${docker_dir}/volumes/sandbox/conf/config.yaml" ]
    [ -f "${docker_dir}/monitoring/prometheus.yml" ]
}

@test "ensure_bind_mount_files: fixes directory artifacts" {
    local docker_dir="${INSTALL_DIR}/docker"
    mkdir -p "${docker_dir}/nginx/nginx.conf"  # dir where file should be

    ensure_bind_mount_files

    [ -f "${docker_dir}/nginx/nginx.conf" ]
    [ ! -d "${docker_dir}/nginx/nginx.conf" ]
}

# ============================================================================
# PREFLIGHT BIND MOUNT CHECK
# ============================================================================

@test "preflight_bind_mount_check: passes with all files present" {
    local docker_dir="${INSTALL_DIR}/docker"
    ensure_bind_mount_files  # create all expected files

    run preflight_bind_mount_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"all bind mount files OK"* ]]
}

@test "preflight_bind_mount_check: fails on missing files" {
    local docker_dir="${INSTALL_DIR}/docker"
    mkdir -p "$docker_dir"
    # Don't create any files

    run preflight_bind_mount_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"PRE-FLIGHT FAILED"* ]]
}
