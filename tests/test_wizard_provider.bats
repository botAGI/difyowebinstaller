#!/usr/bin/env bats

# test_wizard_provider.bats — Provider wizard selection validation tests

setup() {
    export ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# --- Syntax ---

@test "install.sh passes bash -n syntax check" {
    run bash -n "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "lib/models.sh passes bash -n syntax check" {
    run bash -n "${ROOT_DIR}/lib/models.sh"
    [ "$status" -eq 0 ]
}

@test "lib/config.sh passes bash -n syntax check" {
    run bash -n "${ROOT_DIR}/lib/config.sh"
    [ "$status" -eq 0 ]
}

# --- LLM Provider wizard (PROV-01) ---

@test "install.sh contains LLM provider selection menu" {
    run grep "Выберите LLM провайдер:" "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh has all 4 LLM provider options" {
    run grep -c 'LLM_PROVIDER="' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
    [ "$output" -ge 4 ]
}

@test "install.sh sets LLM_PROVIDER=ollama for choice 1" {
    run grep 'LLM_PROVIDER="ollama"' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh sets LLM_PROVIDER=vllm for choice 2" {
    run grep 'LLM_PROVIDER="vllm"' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh sets LLM_PROVIDER=external for choice 3" {
    run grep 'LLM_PROVIDER="external"' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh sets LLM_PROVIDER=skip for choice 4" {
    run grep 'LLM_PROVIDER="skip"' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh has GPU detection fallback for default provider" {
    run grep 'DETECTED_GPU.*nvidia' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh NON_INTERACTIVE guard exists for LLM provider" {
    # Verify that NON_INTERACTIVE pattern is used around LLM_PROVIDER selection
    run grep -A5 "LLM провайдер" "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
    # Verify NON_INTERACTIVE check exists nearby in the wizard
    run grep -c "NON_INTERACTIVE" "${ROOT_DIR}/install.sh"
    [ "$output" -ge 5 ]
}

# --- Embedding Provider wizard (PROV-02) ---

@test "install.sh contains Embedding provider selection menu" {
    run grep "Выберите Embedding провайдер:" "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh sets EMBED_PROVIDER=tei" {
    run grep 'EMBED_PROVIDER="tei"' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh sets EMBED_PROVIDER=external" {
    run grep 'EMBED_PROVIDER="external"' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh sets EMBED_PROVIDER=skip" {
    run grep 'EMBED_PROVIDER="skip"' "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh has Same as LLM mapping for embedding" {
    # Verify the "Same as LLM" dispatch exists
    run grep -A10 "Same as LLM\|Тот же, что LLM" "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ollama"* ]]
    [[ "$output" == *"tei"* ]]
}

# --- HuggingFace token ---

@test "install.sh prompts for HuggingFace token" {
    run grep "HuggingFace token" "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh HF_TOKEN prompt only for vllm or tei" {
    run grep -B5 "HuggingFace token" "${ROOT_DIR}/install.sh"
    [[ "$output" == *"vllm"* ]] || [[ "$output" == *"tei"* ]]
}

# --- vLLM model list ---

@test "install.sh has vLLM model selection" {
    run grep "Выберите модель для vLLM:" "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh default vLLM model is Qwen2.5-14B-Instruct" {
    run grep "Qwen/Qwen2.5-14B-Instruct" "${ROOT_DIR}/install.sh"
    [ "$status" -eq 0 ]
}

# --- models.sh provider dispatch (PROV-01/02) ---

@test "models.sh uses LLM_PROVIDER variable" {
    run grep "LLM_PROVIDER" "${ROOT_DIR}/lib/models.sh"
    [ "$status" -eq 0 ]
}

@test "models.sh uses EMBED_PROVIDER variable" {
    run grep "EMBED_PROVIDER" "${ROOT_DIR}/lib/models.sh"
    [ "$status" -eq 0 ]
}

@test "models.sh has need_ollama dispatch logic" {
    run grep "need_ollama" "${ROOT_DIR}/lib/models.sh"
    [ "$status" -eq 0 ]
}

@test "models.sh skips download for vLLM provider" {
    run grep "vLLM.*загружается при старте" "${ROOT_DIR}/lib/models.sh"
    [ "$status" -eq 0 ]
}

@test "models.sh skips download for TEI provider" {
    run grep "TEI.*загружается при старте" "${ROOT_DIR}/lib/models.sh"
    [ "$status" -eq 0 ]
}

# --- config.sh provider env generation ---

@test "config.sh replaces __LLM_PROVIDER__ placeholder" {
    run grep "__LLM_PROVIDER__" "${ROOT_DIR}/lib/config.sh"
    [ "$status" -eq 0 ]
}

@test "config.sh replaces __EMBED_PROVIDER__ placeholder" {
    run grep "__EMBED_PROVIDER__" "${ROOT_DIR}/lib/config.sh"
    [ "$status" -eq 0 ]
}

@test "config.sh replaces __VLLM_MODEL__ placeholder" {
    run grep "__VLLM_MODEL__" "${ROOT_DIR}/lib/config.sh"
    [ "$status" -eq 0 ]
}

@test "config.sh replaces __HF_TOKEN__ placeholder" {
    run grep "__HF_TOKEN__" "${ROOT_DIR}/lib/config.sh"
    [ "$status" -eq 0 ]
}

@test "config.sh generates OLLAMA_BASE_URL for ollama provider" {
    run grep 'OLLAMA_BASE_URL=http://ollama:11434' "${ROOT_DIR}/lib/config.sh"
    [ "$status" -eq 0 ]
}

@test "config.sh generates OPENAI_API_BASE_URL for vllm provider" {
    run grep 'OPENAI_API_BASE_URL=http://vllm:8000/v1' "${ROOT_DIR}/lib/config.sh"
    [ "$status" -eq 0 ]
}
