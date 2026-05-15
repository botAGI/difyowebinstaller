#!/usr/bin/env bash
# i18n.sh — Minimal bilingual layer for AGmind installer (EN/RU).
#
# Usage:
#   source lib/i18n.sh          # resolves AGMIND_LANG at source time
#   t "wizard.llm_provider.title"  # prints localised string
#
# AGMIND_LANG resolution order (on source):
#   1. AGMIND_LANG already set and non-empty → validate (en|ru, lowercase);
#      anything else normalises to "en".
#   2. Else autodetect from $LC_ALL, $LC_MESSAGES, $LANG in that order;
#      if any matches ^ru → "ru", else → "en".
# After resolution: AGMIND_LANG is exported (visible to child processes).
#
# Scope (MVP — 260513-2me):
#   Wizard-facing strings: LLM provider menu, LLM profile menu, context sub-menu,
#   _wizard_language prompt, _wizard_summary labels.
#   Out of scope (BACKLOG 999.9): long-tail log_info/log_warn across lib/*.sh.
set -uo pipefail

# ============================================================================
# STRING TABLES
# ============================================================================

# Keys without an entry in I18N_RU will fall back to I18N_EN (see t()).
declare -gA I18N_EN I18N_RU 2>/dev/null || true  # ignore if already declared

# --- Language prompt ---
I18N_EN["wizard.language.prompt"]="Language / Язык (en|ru)"
I18N_RU["wizard.language.prompt"]="Язык / Language (en|ru)"

# --- LLM provider menu ---
I18N_EN["wizard.llm_provider.title"]="LLM Provider"
I18N_RU["wizard.llm_provider.title"]="LLM-провайдер"

I18N_EN["wizard.llm_provider.prompt"]="Choose LLM provider:"
I18N_RU["wizard.llm_provider.prompt"]="Выберите LLM-провайдер:"

I18N_EN["wizard.llm_provider.opt_vllm"]="vLLM (recommended for DGX Spark)"
I18N_RU["wizard.llm_provider.opt_vllm"]="vLLM (рекомендуется для DGX Spark)"

I18N_EN["wizard.llm_provider.opt_external"]="External API"
I18N_RU["wizard.llm_provider.opt_external"]="Внешний API"

I18N_EN["wizard.llm_provider.opt_skip"]="Skip"
I18N_RU["wizard.llm_provider.opt_skip"]="Пропустить"

# --- LLM profile menu (DGX Spark) ---
I18N_EN["wizard.llm_profile.title"]="LLM Profile (DGX Spark)"
I18N_RU["wizard.llm_profile.title"]="Профиль LLM (DGX Spark)"

I18N_EN["wizard.llm_profile.prompt"]="Choose LLM profile. Option 1 is the validated default."
I18N_RU["wizard.llm_profile.prompt"]="Выберите профиль LLM. Вариант 1 — проверенный по умолчанию."

I18N_EN["wizard.llm_profile.opt_gemma"]="Gemma 4 26B-A4B (default — validated, fp8 kv-cache, 64K ctx)"
I18N_RU["wizard.llm_profile.opt_gemma"]="Gemma 4 26B-A4B (по умолчанию — проверен, fp8 kv-cache, 64K ctx)"

I18N_EN["wizard.llm_profile.opt_qwen36_fp8"]="Qwen3.6-35B-A3B FP8 + DFlash speculative (opt-in, ~35 GB HF pull)"
I18N_RU["wizard.llm_profile.opt_qwen36_fp8"]="Qwen3.6-35B-A3B FP8 + DFlash спекулятив (opt-in, ~35 ГБ HF pull)"

I18N_EN["wizard.llm_profile.opt_qwen36_heretic"]="Qwen3.6-35B heretic NVFP4 + DFlash — UNCENSORED, tool-calling BROKEN"
I18N_RU["wizard.llm_profile.opt_qwen36_heretic"]="Qwen3.6-35B heretic NVFP4 + DFlash — БЕЗ ЦЕНЗУРЫ, tool-calling СЛОМАН"

I18N_EN["wizard.llm_profile.heretic_warning"]="WARNING: Uncensored model — no content filtering. Tool-calling is BROKEN (finish_reason=length) — do NOT pick this profile if you need agentic/tool workflows."
I18N_RU["wizard.llm_profile.heretic_warning"]="ВНИМАНИЕ: Модель без цензуры — контентной фильтрации нет. Tool-calling СЛОМАН (finish_reason=length) — НЕ выбирайте если нужны агентные/tool-вызовы."

I18N_EN["wizard.llm_profile.log_gemma"]="DGX Spark -> Gemma 4 26B-A4B (validated default)"
I18N_RU["wizard.llm_profile.log_gemma"]="DGX Spark -> Gemma 4 26B-A4B (проверенный по умолчанию)"

I18N_EN["wizard.llm_profile.log_qwen36_fp8"]="DGX Spark -> Qwen3.6-35B FP8 + DFlash (opt-in; ~35 GB pull on first start)"
I18N_RU["wizard.llm_profile.log_qwen36_fp8"]="DGX Spark -> Qwen3.6-35B FP8 + DFlash (opt-in; ~35 ГБ при первом старте)"

I18N_EN["wizard.llm_profile.log_qwen36_heretic"]="DGX Spark -> Qwen3.6-35B heretic NVFP4 + DFlash (opt-in, uncensored)"
I18N_RU["wizard.llm_profile.log_qwen36_heretic"]="DGX Spark -> Qwen3.6-35B heretic NVFP4 + DFlash (opt-in, без цензуры)"

I18N_EN["wizard.llm_profile.aeon_unavailable"]="AEON image unreachable — falling back to Gemma 4 26B (validated default)"
I18N_RU["wizard.llm_profile.aeon_unavailable"]="AEON образ недоступен — откат на Gemma 4 26B (проверенный по умолчанию)"

# --- LLM context sub-menu ---
I18N_EN["wizard.llm_ctx.title"]="Context Length"
I18N_RU["wizard.llm_ctx.title"]="Длина контекста"

I18N_EN["wizard.llm_ctx.prompt"]="Choose context window size:"
I18N_RU["wizard.llm_ctx.prompt"]="Выберите размер контекстного окна:"

I18N_EN["wizard.llm_ctx.gemma_64k"]="64K — default (recommended)"
I18N_RU["wizard.llm_ctx.gemma_64k"]="64K — по умолчанию (рекомендуется)"

I18N_EN["wizard.llm_ctx.gemma_128k"]="128K — not for single-node deployments"
I18N_RU["wizard.llm_ctx.gemma_128k"]="128K — не для single-node установок"

I18N_EN["wizard.llm_ctx.gemma_256k"]="256K — full native Gemma 4 context (peer-node only)"
I18N_RU["wizard.llm_ctx.gemma_256k"]="256K — полный нативный контекст Gemma 4 (только на peer-ноде)"

I18N_EN["wizard.llm_ctx.qwen36_128k"]="128K — balanced (default for qwen36)"
I18N_RU["wizard.llm_ctx.qwen36_128k"]="128K — баланс (по умолчанию для qwen36)"

I18N_EN["wizard.llm_ctx.qwen36_256k"]="256K — full native context"
I18N_RU["wizard.llm_ctx.qwen36_256k"]="256K — полный нативный контекст"

I18N_EN["wizard.llm_ctx.qwen36_1m"]="1M YaRN — experimental (quality degrades on long tail)"
I18N_RU["wizard.llm_ctx.qwen36_1m"]="1M YaRN — экспериментально (деградация качества на хвосте)"

I18N_EN["wizard.llm_ctx.yarn_warn"]="1M YaRN context: quality degrades significantly on the long tail; experimental."
I18N_RU["wizard.llm_ctx.yarn_warn"]="1M YaRN контекст: качество деградирует на хвосте; экспериментально."

# --- Wizard summary labels ---
I18N_EN["wizard.summary.profile"]="Profile:"
I18N_RU["wizard.summary.profile"]="Профиль:"

I18N_EN["wizard.summary.domain"]="Domain:"
I18N_RU["wizard.summary.domain"]="Домен:"

I18N_EN["wizard.summary.vector_db"]="Vector DB:"
I18N_RU["wizard.summary.vector_db"]="Вектор. БД:"

I18N_EN["wizard.summary.etl"]="ETL:"
I18N_RU["wizard.summary.etl"]="ETL:"

I18N_EN["wizard.summary.llm"]="LLM:"
I18N_RU["wizard.summary.llm"]="LLM:"

I18N_EN["wizard.summary.embeddings"]="Embeddings:"
I18N_RU["wizard.summary.embeddings"]="Эмбеддинги:"

I18N_EN["wizard.summary.reranker"]="Reranker:"
I18N_RU["wizard.summary.reranker"]="Реранкер:"

I18N_EN["wizard.summary.tls"]="TLS:"
I18N_RU["wizard.summary.tls"]="TLS:"

I18N_EN["wizard.summary.monitoring"]="Monitoring:"
I18N_RU["wizard.summary.monitoring"]="Мониторинг:"

I18N_EN["wizard.summary.alerts"]="Alerts:"
I18N_RU["wizard.summary.alerts"]="Уведомления:"

I18N_EN["wizard.summary.storage"]="Storage:"
I18N_RU["wizard.summary.storage"]="Хранилище:"

I18N_EN["wizard.summary.storage_minio"]="MinIO (S3) agmind-storage.local:9001"
I18N_RU["wizard.summary.storage_minio"]="MinIO (S3) agmind-storage.local:9001"

I18N_EN["wizard.summary.storage_local"]="Local (./volumes/app/storage)"
I18N_RU["wizard.summary.storage_local"]="Локальное (./volumes/app/storage)"

I18N_EN["wizard.summary.ufw"]="UFW:"
I18N_RU["wizard.summary.ufw"]="UFW:"

I18N_EN["wizard.summary.enabled"]="enabled"
I18N_RU["wizard.summary.enabled"]="включён"

I18N_EN["wizard.summary.fail2ban"]="Fail2ban:"
I18N_RU["wizard.summary.fail2ban"]="Fail2ban:"

I18N_EN["wizard.summary.fail2ban_val"]="SSH jail"
I18N_RU["wizard.summary.fail2ban_val"]="SSH jail"

I18N_EN["wizard.summary.authelia"]="Authelia:"
I18N_RU["wizard.summary.authelia"]="Authelia:"

I18N_EN["wizard.summary.authelia_val"]="2FA enabled"
I18N_RU["wizard.summary.authelia_val"]="2FA включена"

I18N_EN["wizard.summary.litellm"]="LiteLLM:"
I18N_RU["wizard.summary.litellm"]="LiteLLM:"

I18N_EN["wizard.summary.litellm_val"]="enabled (AI Gateway)"
I18N_RU["wizard.summary.litellm_val"]="включён (AI Gateway)"

I18N_EN["wizard.summary.searxng"]="SearXNG:"
I18N_RU["wizard.summary.searxng"]="SearXNG:"

I18N_EN["wizard.summary.notebook"]="Open Notebook:"
I18N_RU["wizard.summary.notebook"]="Open Notebook:"

I18N_EN["wizard.summary.dbgpt"]="DB-GPT:"
I18N_RU["wizard.summary.dbgpt"]="DB-GPT:"

I18N_EN["wizard.summary.crawl4ai"]="Crawl4AI:"
I18N_RU["wizard.summary.crawl4ai"]="Crawl4AI:"

I18N_EN["wizard.summary.openwebui"]="Open WebUI:"
I18N_RU["wizard.summary.openwebui"]="Open WebUI:"

I18N_EN["wizard.summary.ragflow"]="RAGFlow:"
I18N_RU["wizard.summary.ragflow"]="RAGFlow:"

I18N_EN["wizard.summary.ragflow_val"]="internal (Dify plugin: witmeng/ragflow-api)"
I18N_RU["wizard.summary.ragflow_val"]="внутренний (Dify plugin: witmeng/ragflow-api)"

I18N_EN["wizard.summary.dify_premium"]="Dify Premium:"
I18N_RU["wizard.summary.dify_premium"]="Dify Premium:"

I18N_EN["wizard.summary.dify_premium_val"]="enabled (patch after start)"
I18N_RU["wizard.summary.dify_premium_val"]="включён (патч после запуска)"

I18N_EN["wizard.summary.backups"]="Backups:"
I18N_RU["wizard.summary.backups"]="Бэкапы:"

I18N_EN["wizard.summary.gpu_header"]="--- GPU memory ---"
I18N_RU["wizard.summary.gpu_header"]="--- GPU память ---"

I18N_EN["wizard.summary.gpu_vllm"]="vLLM:"
I18N_RU["wizard.summary.gpu_vllm"]="vLLM:"

I18N_EN["wizard.summary.gpu_total"]="Total:"
I18N_RU["wizard.summary.gpu_total"]="Итого:"

I18N_EN["wizard.summary.gpu_unknown"]="GPU memory not detected — check manually"
I18N_RU["wizard.summary.gpu_unknown"]="GPU память не определена -- проверьте вручную"

I18N_EN["wizard.summary.gpu_oom"]="GPU memory budget exceeded! OOM possible."
I18N_RU["wizard.summary.gpu_oom"]="GPU память бюджет превышен! Возможен OOM."

# ============================================================================
# AGMIND_LANG RESOLUTION (runs at source time)
# ============================================================================

_i18n_resolve_lang() {
    local lang="${AGMIND_LANG:-}"

    if [[ -n "$lang" ]]; then
        # Already set — validate and normalise
        lang="${lang,,}"  # lowercase
        case "$lang" in
            en|ru) : ;;  # valid
            *) lang="en" ;;
        esac
    else
        # Autodetect from locale vars
        local locale_val=""
        for _lv in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
            if [[ -n "$_lv" ]]; then
                locale_val="$_lv"
                break
            fi
        done
        if [[ "$locale_val" =~ ^ru ]]; then
            lang="ru"
        else
            lang="en"
        fi
    fi

    AGMIND_LANG="$lang"
    export AGMIND_LANG
}

_i18n_resolve_lang

# ============================================================================
# LOOKUP FUNCTION
# ============================================================================

# t <key> — print the localised string for <key>.
# Lookup order: I18N_<LANG>[key] → I18N_EN[key] → key itself (fallback).
# set -u safe: uses ${arr[$k]:-} to avoid unbound variable errors.
t() {
    local k="${1:-}"
    local lang="${AGMIND_LANG:-en}"
    local val=""

    # Try the requested language first (RU wins if lang=ru and key exists)
    if [[ "$lang" == "ru" ]]; then
        val="${I18N_RU[$k]:-}"
    fi

    # Fall back to EN
    if [[ -z "$val" ]]; then
        val="${I18N_EN[$k]:-}"
    fi

    # Final fallback: echo the key itself (safe for unknown keys)
    if [[ -z "$val" ]]; then
        val="$k"
    fi

    printf '%s' "$val"
}
