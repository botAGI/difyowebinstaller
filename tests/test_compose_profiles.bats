#!/usr/bin/env bats

# test_compose_profiles.bats — COMPOSE_PROFILES builder validation tests

setup() {
    export ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# --- COMPOSE_PROFILES builder (PROV-03) ---

@test "install.sh adds ollama to COMPOSE_PROFILES when LLM_PROVIDER=ollama" {
    run grep 'LLM_PROVIDER.*==.*"ollama".*profiles.*ollama\|LLM_PROVIDER.*ollama.*profiles' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh adds ollama to COMPOSE_PROFILES when EMBED_PROVIDER=ollama" {
    run grep 'EMBED_PROVIDER.*==.*"ollama".*profiles.*ollama\|EMBED_PROVIDER.*ollama.*profiles' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh adds vllm to COMPOSE_PROFILES when LLM_PROVIDER=vllm" {
    run grep 'LLM_PROVIDER.*==.*"vllm".*profiles.*vllm\|LLM_PROVIDER.*vllm.*profiles' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh adds tei to COMPOSE_PROFILES when EMBED_PROVIDER=tei" {
    run grep 'EMBED_PROVIDER.*==.*"tei".*profiles.*tei\|EMBED_PROVIDER.*tei.*profiles' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

# --- Nuclear cleanup includes new profiles ---

@test "install.sh nuclear cleanup includes ollama,vllm,tei profiles" {
    run grep "COMPOSE_PROFILES=.*ollama.*vllm.*tei" "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

# --- Docker Compose profiles (PROV-03) ---

@test "docker-compose.yml has ollama profile" {
    run grep -A20 "agmind-ollama" "${ROOT_DIR}/templates/docker-compose.yml"
    [[ "$output" == *"ollama"* ]]
}

@test "docker-compose.yml has vllm service with profile" {
    run grep "agmind-vllm" "${ROOT_DIR}/templates/docker-compose.yml"
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml has tei service with profile" {
    run grep "agmind-tei" "${ROOT_DIR}/templates/docker-compose.yml"
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml open-webui has no depends_on ollama" {
    # Get the open-webui service block and check no depends_on: ollama
    # Simple check: no line should have both "depends_on" near "ollama" for open-webui
    run bash -c "sed -n '/open-webui:/,/^  [a-z]/p' '${ROOT_DIR}/templates/docker-compose.yml' | grep -c 'ollama'"
    # ollama should not appear in open-webui block (was depends_on)
    [ "$output" -eq 0 ] || [ "$status" -ne 0 ]
}

@test "docker-compose.yml vllm has ipc: host" {
    run grep "ipc: host" "${ROOT_DIR}/templates/docker-compose.yml"
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml vllm has start_period 900s" {
    run grep "start_period: 900s" "${ROOT_DIR}/templates/docker-compose.yml"
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml tei has start_period 600s" {
    run grep "start_period: 600s" "${ROOT_DIR}/templates/docker-compose.yml"
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml has vllm_cache volume" {
    run grep "vllm_cache:" "${ROOT_DIR}/templates/docker-compose.yml"
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml has tei_cache volume" {
    run grep "tei_cache:" "${ROOT_DIR}/templates/docker-compose.yml"
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml vllm has GPU comment block" {
    run bash -c "sed -n '/agmind-vllm/,/networks:/p' '${ROOT_DIR}/templates/docker-compose.yml' | grep '#__GPU__'"
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml tei has GPU comment block" {
    run bash -c "sed -n '/agmind-tei/,/networks:/p' '${ROOT_DIR}/templates/docker-compose.yml' | grep '#__GPU__'"
    [ "$status" -eq 0 ]
}

# --- versions.env (PROV-03) ---

@test "versions.env has VLLM_VERSION" {
    run grep "VLLM_VERSION=" "${ROOT_DIR}/templates/versions.env"
    [ "$status" -eq 0 ]
    [[ "$output" == *"v0.8.4"* ]]
}

@test "versions.env has TEI_VERSION" {
    run grep "TEI_VERSION=" "${ROOT_DIR}/templates/versions.env"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cuda-1.9.2"* ]]
}

# --- Env templates (PROV-03) ---

@test "env.lan.template has LLM_PROVIDER placeholder" {
    run grep "LLM_PROVIDER=__LLM_PROVIDER__" "${ROOT_DIR}/templates/env.lan.template"
    [ "$status" -eq 0 ]
}

@test "env.lan.template has EMBED_PROVIDER placeholder" {
    run grep "EMBED_PROVIDER=__EMBED_PROVIDER__" "${ROOT_DIR}/templates/env.lan.template"
    [ "$status" -eq 0 ]
}

@test "env.lan.template has VLLM_MODEL placeholder" {
    run grep "VLLM_MODEL=__VLLM_MODEL__" "${ROOT_DIR}/templates/env.lan.template"
    [ "$status" -eq 0 ]
}

@test "env.lan.template has HF_TOKEN placeholder" {
    run grep "HF_TOKEN=__HF_TOKEN__" "${ROOT_DIR}/templates/env.lan.template"
    [ "$status" -eq 0 ]
}

# --- phase_models exports providers ---

@test "install.sh phase_models exports LLM_PROVIDER" {
    run grep -A5 "phase_models" "${ROOT_DIR}/install.sh"
    [[ "$output" == *"LLM_PROVIDER"* ]]
}

@test "install.sh phase_models exports EMBED_PROVIDER" {
    run grep -A5 "phase_models" "${ROOT_DIR}/install.sh"
    [[ "$output" == *"EMBED_PROVIDER"* ]]
}
