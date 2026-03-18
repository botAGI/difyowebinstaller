---
status: complete
phase: 01-surgery-remove-dify-api-automation
source: 01-01-SUMMARY.md, 01-02-SUMMARY.md
started: 2026-03-18T12:00:00Z
updated: 2026-03-18T12:15:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Cold Start Smoke Test
expected: install.sh проходит `bash -n` без ошибок. Скрипт содержит ровно 9 фаз — нет /11], /10], phase_workflow, phase_connectivity.
result: pass

### 2. Удаление Dify API automation файлов
expected: Файлы workflows/import.py, pipeline/Dockerfile, pipeline/dify_pipeline.py, pipeline/requirements.txt, lib/workflow.sh — не существуют в репозитории.
result: pass

### 3. INIT_PASSWORD auto-generation
expected: В lib/config.sh есть генерация INIT_PASSWORD (16 символов, random). Не запрашивается через wizard. grep 'ADMIN_PASSWORD' install.sh возвращает только GRAFANA_ADMIN_PASSWORD.
result: pass

### 4. Pipeline service удалён из docker-compose
expected: templates/docker-compose.yml не содержит сервис pipeline. Open WebUI не имеет depends_on pipeline.
result: pass

### 5. Open WebUI подключен к Ollama напрямую
expected: В docker-compose.yml Open WebUI имеет OLLAMA_BASE_URL указывающий на http://ollama:11434. ENABLE_OPENAI_API=false.
result: pass

### 6. Нет stale references к удалённому коду
expected: grep по install.sh, lib/, templates/ не находит: DIFY_API_KEY, ADMIN_EMAIL (как wizard-поле), COMPANY_NAME (кроме multi-instance), import.py, phase_workflow, phase_connectivity.
result: pass

### 7. WEBUI_NAME захардкожен как AGMind
expected: templates/docker-compose.yml содержит WEBUI_NAME=AGMind (не ${COMPANY_NAME:-AGMind}).
result: pass

### 8. workflows/README.md существует
expected: Файл workflows/README.md содержит инструкции по импорту DSL, список плагинов по провайдерам, и шаги post-import конфигурации.
result: pass

### 9. rag-assistant.json сохранён
expected: workflows/rag-assistant.json существует и является валидным JSON.
result: pass

## Summary

total: 9
passed: 9
issues: 0
pending: 0
skipped: 0

## Gaps

[none]
