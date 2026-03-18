---
status: complete
phase: 03-provider-architecture
source: 03-01-SUMMARY.md, 03-02-SUMMARY.md, 03-03-SUMMARY.md
started: 2026-03-18T12:20:00Z
updated: 2026-03-18T12:25:00Z
---

## Current Test

[testing complete]

## Tests

### 1. vLLM service в docker-compose
expected: agmind-vllm контейнер с profiles, ipc: host, start_period 900s, volume vllm_cache.
result: pass

### 2. TEI service в docker-compose
expected: agmind-tei контейнер с profiles, BAAI/bge-m3, start_period 600s.
result: pass

### 3. Ollama за profile
expected: Ollama-сервис имеет profiles: [ollama], не стартует по умолчанию.
result: pass

### 4. versions.env с пинами
expected: VLLM_VERSION=v0.8.4 и TEI_VERSION=cuda-1.9.2 в templates/versions.env.
result: pass

### 5. Provider переменные в env templates
expected: LLM_PROVIDER и EMBED_PROVIDER присутствуют во всех 4 env templates.
result: pass

### 6. Provider wizard в install.sh
expected: install.sh содержит LLM_PROVIDER и EMBED_PROVIDER (wizard + config).
result: pass

### 7. config.sh генерация provider env vars
expected: lib/config.sh заменяет __LLM_PROVIDER__ и дописывает provider-specific WebUI vars.
result: pass

## Summary

total: 7
passed: 7
issues: 0
pending: 0
skipped: 0

## Gaps

[none]
