#!/usr/bin/env bats

# Tests for agmind CLI (scripts/agmind.sh) and health-gen.sh
# Run: bats tests/test_agmind_cli.bats

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# === Syntax Validation ===

@test "agmind.sh has no syntax errors" {
    run bash -n "${PROJECT_ROOT}/scripts/agmind.sh"
    [ "$status" -eq 0 ]
}

@test "health-gen.sh has no syntax errors" {
    run bash -n "${PROJECT_ROOT}/scripts/health-gen.sh"
    [ "$status" -eq 0 ]
}

# === agmind.sh structure ===

@test "agmind.sh contains cmd_status function" {
    grep -q 'cmd_status()' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh contains cmd_doctor function" {
    grep -q 'cmd_doctor()' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh contains cmd_help function" {
    grep -q 'cmd_help()' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh contains _require_root function" {
    grep -q '_require_root()' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh contains _status_json function" {
    grep -q '_status_json()' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh sources health.sh with INSTALL_DIR set first" {
    # INSTALL_DIR or export INSTALL_DIR must appear before source health.sh
    local install_line health_line
    install_line=$(grep -n 'INSTALL_DIR=' "${PROJECT_ROOT}/scripts/agmind.sh" | head -1 | cut -d: -f1)
    health_line=$(grep -n 'source.*health\.sh' "${PROJECT_ROOT}/scripts/agmind.sh" | head -1 | cut -d: -f1)
    [ "$install_line" -lt "$health_line" ]
}

@test "agmind.sh uses AGMIND_DIR not hardcoded /opt/agmind for paths" {
    # Main logic should reference AGMIND_DIR, not /opt/agmind (except default value)
    local hardcoded_count
    hardcoded_count=$(grep -c '/opt/agmind' "${PROJECT_ROOT}/scripts/agmind.sh" || true)
    # Allow up to 3 references: the default assignment and help text
    [ "$hardcoded_count" -le 3 ]
}

# === Case dispatch ===

@test "agmind.sh dispatches backup to scripts/backup.sh" {
    grep -q 'backup\.sh' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh dispatches restore to scripts/restore.sh" {
    grep -q 'restore\.sh' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh dispatches update to scripts/update.sh" {
    grep -q 'update\.sh' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh dispatches uninstall to scripts/uninstall.sh" {
    grep -q 'uninstall\.sh' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh dispatches rotate-secrets to scripts/rotate_secrets.sh" {
    grep -q 'rotate_secrets\.sh' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "agmind.sh dispatches logs to docker compose logs" {
    grep -q 'docker compose.*logs' "${PROJECT_ROOT}/scripts/agmind.sh"
}

# === Doctor structure ===

@test "doctor checks Docker version" {
    grep -q 'docker version' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "doctor checks Docker Compose version" {
    grep -q 'docker compose version' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "doctor checks DNS resolution" {
    grep -q 'registry.ollama.ai' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "doctor checks disk space with df" {
    grep -q 'df -BG' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "doctor checks RAM with free" {
    grep -q 'free -g' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "doctor has exit code 2 for failures" {
    grep -q 'return 2' "${PROJECT_ROOT}/scripts/agmind.sh"
}

@test "doctor skips GPU when providers are external" {
    grep -q 'external.*external\|external.*&&.*external' "${PROJECT_ROOT}/scripts/agmind.sh"
}

# === Status JSON schema ===

@test "status --json contains required top-level fields" {
    grep -q '"status"' "${PROJECT_ROOT}/scripts/agmind.sh"
    grep -q '"timestamp"' "${PROJECT_ROOT}/scripts/agmind.sh"
    grep -q '"services"' "${PROJECT_ROOT}/scripts/agmind.sh"
    grep -q '"gpu"' "${PROJECT_ROOT}/scripts/agmind.sh"
}

# === health-gen.sh structure ===

@test "health-gen.sh uses atomic write pattern (mktemp + mv)" {
    grep -q 'mktemp' "${PROJECT_ROOT}/scripts/health-gen.sh"
    grep -q 'mv.*TMPFILE.*health\.json\|mv.*TMPFILE.*HEALTH_JSON' "${PROJECT_ROOT}/scripts/health-gen.sh"
}

@test "health-gen.sh delegates to agmind status --json" {
    grep -q 'agmind\.sh.*status.*--json' "${PROJECT_ROOT}/scripts/health-gen.sh"
}

@test "health-gen.sh has fallback on failure" {
    grep -q '"status": "unhealthy"' "${PROJECT_ROOT}/scripts/health-gen.sh"
}

@test "health-gen.sh sets chmod 644 on health.json" {
    grep -q 'chmod 644' "${PROJECT_ROOT}/scripts/health-gen.sh"
}

@test "health-gen.sh has trap for TMPFILE cleanup" {
    grep -q "trap.*rm.*TMPFILE.*EXIT" "${PROJECT_ROOT}/scripts/health-gen.sh"
}

# === nginx template ===

@test "nginx template has /health location block" {
    grep -q 'location = /health' "${PROJECT_ROOT}/templates/nginx.conf.template"
}

@test "nginx template has health rate limit zone" {
    grep -q 'zone=health' "${PROJECT_ROOT}/templates/nginx.conf.template"
}

@test "nginx template /health serves application/json" {
    grep -q 'default_type application/json' "${PROJECT_ROOT}/templates/nginx.conf.template"
}

@test "nginx template /health has Authelia bypass (auth_request off)" {
    grep -q 'auth_request off' "${PROJECT_ROOT}/templates/nginx.conf.template"
}

@test "nginx template /health uses alias for health.json" {
    grep -q 'alias /etc/nginx/health/health.json' "${PROJECT_ROOT}/templates/nginx.conf.template"
}

@test "nginx template has /health rate limit at 1r/s" {
    grep -q 'zone=health:1m rate=1r/s' "${PROJECT_ROOT}/templates/nginx.conf.template"
}

# === install.sh integration ===

@test "install.sh copies agmind.sh in _copy_runtime_files" {
    grep -q 'agmind\.sh' "${PROJECT_ROOT}/install.sh"
}

@test "install.sh copies health-gen.sh in phase_config" {
    grep -q 'health-gen\.sh' "${PROJECT_ROOT}/install.sh"
}

@test "install.sh copies detect.sh to scripts" {
    grep -q 'detect\.sh.*scripts/detect\.sh\|scripts/detect\.sh' "${PROJECT_ROOT}/install.sh"
}

@test "install.sh creates agmind symlink in phase_complete" {
    grep -q 'ln -sf.*agmind' "${PROJECT_ROOT}/install.sh"
}

@test "install.sh creates cron entry for health-gen" {
    grep -q 'cron\.d/agmind-health' "${PROJECT_ROOT}/install.sh"
}

@test "install.sh creates initial health.json placeholder" {
    grep -q '"status": "starting"' "${PROJECT_ROOT}/install.sh"
}

@test "install.sh cron entry runs health-gen.sh as root" {
    grep -q 'root.*health-gen\.sh' "${PROJECT_ROOT}/install.sh"
}

@test "docker-compose template mounts health.json into nginx" {
    grep -q 'health\.json:/etc/nginx/health/health\.json:ro' "${PROJECT_ROOT}/templates/docker-compose.yml"
}
