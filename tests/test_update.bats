#!/usr/bin/env bats
# =============================================================================
# test_update.bats — Structural tests for scripts/update.sh
# No Docker runtime required. Validates script structure, CLI parsing,
# component mapping, and function existence.
# Run: bats tests/test_update.bats
# =============================================================================

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="${PROJECT_ROOT}/scripts/update.sh"
}

# --- File basics ---

@test "update.sh exists" {
    [[ -f "$SCRIPT" ]]
}

@test "update.sh has bash shebang" {
    head -1 "$SCRIPT" | grep -q '#!/usr/bin/env bash'
}

@test "update.sh uses strict mode" {
    grep -q 'set -euo pipefail' "$SCRIPT"
}

@test "update.sh passes bash syntax check" {
    bash -n "$SCRIPT"
}

# --- Remote version fetching (UPDT-02 / BUG-V3-024 fix) ---

@test "update.sh fetches versions from GitHub raw URL" {
    grep -q 'REMOTE_VERSIONS_URL=.*raw.githubusercontent.com.*versions.env' "$SCRIPT"
}

@test "update.sh defines fetch_remote_versions function" {
    grep -q 'fetch_remote_versions()' "$SCRIPT"
}

@test "update.sh does NOT contain old load_new_versions function" {
    ! grep -q 'load_new_versions()' "$SCRIPT"
}

@test "update.sh uses curl for remote fetch" {
    grep -q 'curl.*REMOTE_VERSIONS_URL\|curl.*REMOTE_FETCH_TIMEOUT' "$SCRIPT"
}

@test "update.sh handles offline gracefully" {
    grep -q 'Cannot reach GitHub' "$SCRIPT"
}

# --- Component mapping (UPDT-01) ---

@test "update.sh defines NAME_TO_VERSION_KEY mapping" {
    grep -q 'declare -A NAME_TO_VERSION_KEY=' "$SCRIPT"
}

@test "update.sh defines NAME_TO_SERVICES mapping" {
    grep -q 'declare -A NAME_TO_SERVICES=' "$SCRIPT"
}

@test "update.sh maps dify-api to DIFY_VERSION" {
    grep -q '\[dify-api\]=DIFY_VERSION' "$SCRIPT"
}

@test "update.sh maps ollama to OLLAMA_VERSION" {
    grep -q '\[ollama\]=OLLAMA_VERSION' "$SCRIPT"
}

@test "update.sh maps vllm to VLLM_VERSION" {
    grep -q '\[vllm\]=VLLM_VERSION' "$SCRIPT"
}

@test "update.sh maps openwebui to OPENWEBUI_VERSION" {
    grep -q '\[openwebui\]=OPENWEBUI_VERSION' "$SCRIPT"
}

@test "update.sh maps tei to TEI_VERSION" {
    grep -q '\[tei\]=TEI_VERSION' "$SCRIPT"
}

@test "update.sh maps postgres to POSTGRES_VERSION" {
    grep -q '\[postgres\]=POSTGRES_VERSION' "$SCRIPT"
}

@test "update.sh maps grafana to GRAFANA_VERSION" {
    grep -q '\[grafana\]=GRAFANA_VERSION' "$SCRIPT"
}

@test "update.sh maps nginx to NGINX_VERSION" {
    grep -q '\[nginx\]=NGINX_VERSION' "$SCRIPT"
}

# --- Service groups ---

@test "update.sh dify-api maps to multiple services (api worker web sandbox plugin_daemon)" {
    grep '\[dify-api\]=' "$SCRIPT" | grep -q 'api worker web sandbox plugin_daemon'
}

@test "update.sh openwebui maps to single service" {
    grep '\[openwebui\]=' "$SCRIPT" | grep -q '"open-webui"'
}

# --- CLI argument parsing ---

@test "update.sh parses --check flag" {
    grep -q '\-\-check)' "$SCRIPT"
}

@test "update.sh parses --component flag" {
    grep -q '\-\-component)' "$SCRIPT"
}

@test "update.sh parses --version flag" {
    grep -q '\-\-version)' "$SCRIPT"
}

@test "update.sh parses --auto flag" {
    grep -q '\-\-auto)' "$SCRIPT"
}

@test "update.sh parses --rollback flag" {
    grep -q '\-\-rollback)' "$SCRIPT"
}

@test "update.sh maintains backward compat --check-only" {
    grep -q '\-\-check-only)' "$SCRIPT"
}

# --- Core functions ---

@test "update.sh defines update_component function" {
    grep -q 'update_component()' "$SCRIPT"
}

@test "update.sh defines resolve_component function" {
    grep -q 'resolve_component()' "$SCRIPT"
}

@test "update.sh defines rollback_component function" {
    grep -q 'rollback_component()' "$SCRIPT"
}

@test "update.sh defines update_service function" {
    grep -q 'update_service()' "$SCRIPT"
}

@test "update.sh defines rollback_service function" {
    grep -q 'rollback_service()' "$SCRIPT"
}

@test "update.sh defines check_preflight function" {
    grep -q 'check_preflight()' "$SCRIPT"
}

@test "update.sh defines send_notification function" {
    grep -q 'send_notification()' "$SCRIPT"
}

@test "update.sh defines save_rollback_state function" {
    grep -q 'save_rollback_state()' "$SCRIPT"
}

@test "update.sh defines display_version_diff function" {
    grep -q 'display_version_diff()' "$SCRIPT"
}

@test "update.sh defines log_update function" {
    grep -q 'log_update()' "$SCRIPT"
}

# --- Rollback (UPDT-03) ---

@test "update.sh rollback logs to update_history.log" {
    grep -q 'log_update.*ROLLBACK' "$SCRIPT"
}

@test "update.sh manual rollback logs MANUAL_ROLLBACK" {
    grep -q 'MANUAL_ROLLBACK' "$SCRIPT"
}

@test "update.sh rollback sends notification" {
    grep -q 'send_notification.*roll' "$SCRIPT"
}

@test "update.sh saves rollback state to .rollback directory" {
    grep -q 'ROLLBACK_DIR.*\.rollback' "$SCRIPT"
}

# --- Security ---

@test "update.sh uses flock for exclusive access" {
    grep -q 'flock -n' "$SCRIPT"
}

@test "update.sh requires root" {
    grep -q 'EUID.*ne.*0' "$SCRIPT"
}

@test "update.sh sets .env permissions to 600" {
    grep -q 'chmod 600.*ENV_FILE' "$SCRIPT"
}

# --- Logging ---

@test "update.sh logs SUCCESS on update completion" {
    grep -q 'log_update "SUCCESS"' "$SCRIPT"
}

@test "update.sh logs SKIP when no updates available" {
    grep -q 'log_update "SKIP"' "$SCRIPT"
}

@test "update.sh logs PARTIAL_FAILURE on rolling update errors" {
    grep -q 'log_update "PARTIAL_FAILURE"' "$SCRIPT"
}
