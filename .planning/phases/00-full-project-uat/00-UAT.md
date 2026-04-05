---
status: complete
phase: 00-full-project-uat
source: All SUMMARY.md files (phases 01-33)
started: 2026-04-01T12:55:00Z
updated: 2026-04-01T13:12:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Cold Start — sudo bash install.sh
expected: Запуск `sudo bash install.sh` на чистой системе. Баннер с версией, 9 фаз с таймстампами, preflight-проверки, wizard, credentials.txt (chmod 600) и install.log создаются.
result: pass

### 2. Checkpoint Resume после сбоя
expected: Установка прерывается на фазе 5 → повторный `sudo bash install.sh` → появляется промпт "Resume from phase 5? (yes/no/restart)" → "yes" пропускает фазы 1-4, продолжает с 5-й.
result: pass

### 3. Wizard — выбор профиля (LAN / VDS)
expected: Wizard предлагает "Выберите профиль развертывания" → 2 варианта: 1) LAN (default), 2) VDS/VPS → Выбор VDS/VPS выполняет git fetch + checkout agmind-caddy + exec install.sh --vds.
result: pass

### 4. Wizard — выбор LLM-провайдера
expected: Wizard спрашивает "Выберите поставщика LLM" → 3 варианта: Ollama, vLLM, External API → Выбор устанавливает LLM_PROVIDER в .env и определяет какие контейнеры поднимутся.
result: pass

### 5. VRAM Guard — предупреждение при нехватке памяти
expected: В меню vLLM-моделей каждая строка показывает [N GB VRAM]. Выбор модели, требующей больше доступной VRAM → жёлтое предупреждение "требует X GB, доступно Y GB. Возможен OOM." → y/N → "N" возвращает в меню.
result: pass

### 6. Wizard — Embedding провайдер + TEI VRAM offset
expected: Wizard спрашивает embedding провайдер → выбор TEI → в VRAM-сводке отображается "-2 GB TEI embedding overhead" → рекомендуемая модель учитывает вычтенный VRAM.
result: pass

### 7. Wizard — Reranker + Docling GPU
expected: Wizard спрашивает "Включить переранжировщик?" и "Включить Docling?" → при наличии NVIDIA runtime: Docling предлагает 3 варианта (None/CPU/GPU CUDA) → GPU устанавливает DOCLING_IMAGE=CUDA и NVIDIA_VISIBLE_DEVICES=all.
result: pass

### 8. Wizard — Optional Services (SearXNG, DB-GPT, Open Notebook, Crawl4AI)
expected: Wizard предлагает включить дополнительные сервисы → включение SearXNG/DB-GPT → compose запускается с --profile searxng --profile dbgpt → DB-GPT роутит через LiteLLM → docker compose ps показывает оба сервиса.
result: pass

### 9. Wizard — LiteLLM toggle
expected: Wizard спрашивает "Включить LiteLLM AI Gateway?" → "да" → ENABLE_LITELLM=true в .env → litellm-контейнер стартует → Dashboard доступен на порту 4001.
result: pass

### 10. --dry-run Preflight
expected: `sudo bash install.sh --dry-run` → выполняет preflight (Docker version, DNS hub.docker.com/ghcr.io, порты 80/443/5432, диск, RAM) → "Dry-run complete" → exit 0 или 1 → контейнеры НЕ запускаются.
result: pass

### 11. Security — Rate Limiting
expected: 4+ быстрых запроса на логин Dify → первые 3 проходят (burst=3) → 4-й получает 429 Too Many Requests → через 10с логин снова работает.
result: pass

### 12. Security — Credentials Protection
expected: credentials.txt имеет chmod 600. Пароли НЕ выводятся в stdout/install.log. grep -r "password\|DIFY_API" install.log возвращает пустоту.
result: pass

### 13. Health Checks — Post-Install Verification
expected: После установки verify_services() делает curl-проверки: Open WebUI (/), Dify (/console/api/setup), vLLM (/v1/models), TEI (/info), Weaviate (/v1/.well-known/ready) → каждый показывает [OK] зелёным или [FAIL] красным с подсказкой "agmind logs <service>".
result: pass

### 14. Dify Init Retry (60s)
expected: Фаза инициализации Dify → если контейнер не готов → retry каждые 60 секунд с [dify-init] в логах → после max retries — warn с указанием проверить agmind logs dify-api.
result: pass

### 15. agmind status — Dashboard
expected: `agmind status` → цветной dashboard: Services (контейнеры + health %), GPU (VRAM usage), Models (Ollama список), Endpoints (URLs), Backup status, Credentials location → зелёный=OK, красный=FAIL.
result: pass

### 16. agmind doctor — Диагностика
expected: `agmind doctor` → 4 категории: Docker/Compose, DNS/Network, GPU driver, Ports/disk/RAM → [OK]/[WARN]/[FAIL] бейджи → `agmind doctor --json` выводит JSON.
result: pass

### 17. agmind gpu — Multi-GPU Assignment
expected: `agmind gpu status` → таблица GPU (ID, Name, VRAM, Utilization) + assignment (vLLM→GPU0, TEI→GPU1) → `sudo agmind gpu assign vllm 1` → обновляет VLLM_CUDA_DEVICE, рестартит vLLM → status показывает новое назначение.
result: pass

### 18. Update System — agmind update
expected: `agmind update --check` → таблица версий (Current vs Available, 28 компонентов) → `agmind update` → загружает versions.env с release branch → показывает diff → подтверждение → обновляет .env → рестартит контейнеры → rollback доступен.
result: pass

### 19. Non-Interactive Install (CI/CD)
expected: Установка env vars (LLM_PROVIDER, EMBED_PROVIDER, DEPLOY_PROFILE и т.д.) + `sudo bash install.sh --non-interactive` → никаких промптов wizard → все значения из env vars → установка завершается автоматически → install.log записан.
result: pass

### 20. Credentials File — API Endpoints
expected: credentials.txt содержит секцию "Model API Endpoints" с условными блоками: Ollama URL (если ollama), vLLM URL (если vllm), TEI URL (если tei), Reranker URL (если reranker), LiteLLM proxy URL → порты корректны (TEI=80, не 8080).
result: pass

## Summary

total: 20
passed: 20
issues: 0
pending: 0
skipped: 0

## Gaps

[none yet]
