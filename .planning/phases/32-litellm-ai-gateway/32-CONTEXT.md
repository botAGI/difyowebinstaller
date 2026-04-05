# Phase 32: LiteLLM — AI Gateway - Context

**Gathered:** 2026-03-30
**Status:** Ready for planning

<domain>
## Phase Boundary

LiteLLM как core-сервис: единый OpenAI-совместимый прокси ко всем LLM в стеке. Wizard генерирует конфиг из выбранного провайдера. Dify и Open WebUI переключаются на LiteLLM endpoint. PostgreSQL reuse для cost tracking.

</domain>

<decisions>
## Implementation Decisions

### Конфиг и провайдеры
- `litellm-config.yaml` генерируется автоматически в `phase_config()` из выбранного LLM_PROVIDER + LLM_MODEL (Ollama → ollama/model, vLLM → openai/model)
- Fallback: из коробки только выбранный провайдер; если оператор вручную добавит второй в YAML — fallback заработает автоматически
- Один LITELLM_MASTER_KEY генерируется при установке; virtual keys — оператор добавляет потом через LiteLLM UI
- Пост-установка: оператор редактирует `litellm-config.yaml` на хосте + `docker compose restart agmind-litellm`

### Переключение Dify/OWUI
- Полное переключение: Dify получает `OPENAI_API_BASE_URL=http://agmind-litellm:4000/v1` — все LLM-запросы через gateway
- Open WebUI: сохраняет прямое подключение к Ollama для model management (pull/list/delete), LLM-запросы через LiteLLM endpoint
- Dify Model Provider: оператор вручную добавляет «OpenAI-compatible» с LiteLLM URL и ключом. Инструкция в credentials.txt
- LiteLLM UI доступен через Nginx: проксируем /litellm → agmind-litellm:4000

### PostgreSQL и хранение
- Reuse основного agmind-postgres с отдельной БД `litellm`
- LiteLLM создаёт таблицы автоматически при первом запуске
- Один бэкап PostgreSQL покрывает всё

### Docker и networking
- Core-сервис: НЕТ profiles: тега — запускается всегда, как Dify/OWUI/PG
- Container name: `agmind-litellm`, порт 4000 (внутренний)
- Bind mount: `./docker/litellm-config.yaml:/app/config.yaml`
- Версия: LITELLM_VERSION=X.X.X в versions.env, пинится как все образы
- Healthcheck: `curl -f http://localhost:4000/health`
- depends_on: agmind-postgres (healthy)

### Claude's Discretion
- Точная структура litellm-config.yaml (model_list, litellm_settings, general_settings)
- Nginx location block для /litellm проксирования
- Init SQL для создания БД litellm (если нужна отдельная от PGDATABASE)
- Формат инструкций в credentials.txt

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### LLM provider config
- `lib/wizard.sh` §_wizard_llm_provider, §_wizard_ollama_model, §_wizard_vllm_model — текущая логика выбора провайдера и модели
- `lib/config.sh` §generate_config — генерация .env из шаблона, точка вставки для litellm-config.yaml

### Docker Compose
- `templates/docker-compose.yml` — все сервисы, паттерн для нового контейнера (healthcheck, depends_on, networks, volumes)
- `templates/versions.env` — все образы с версиями, добавить LITELLM_VERSION

### .env templates
- `templates/env.lan.template` — OLLAMA_BASE_URL, OPENAI_API_BASE_URL (сейчас прямые, будут через LiteLLM)
- `templates/env.vps.template` — то же

### Credentials
- `install.sh` §_show_credentials — генерация credentials.txt, добавить LiteLLM URL + master key

### Nginx
- `templates/nginx.conf` — текущий конфиг, добавить location /litellm

### Health & Doctor
- `lib/health.sh` §wait_healthy — паттерн health wait для новых сервисов
- `scripts/agmind.sh` §cmd_doctor — добавить проверку LiteLLM health

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `generate_config()` в lib/config.sh: sed-замена плейсхолдеров из .env шаблона — паттерн для litellm-config.yaml генерации
- `_generate_password()` в lib/common.sh: генерация LITELLM_MASTER_KEY
- `wait_healthy()` в lib/health.sh: паттерн ожидания healthcheck для нового контейнера
- `cmd_doctor()` в scripts/agmind.sh: паттерн добавления endpoint-проверки

### Established Patterns
- Все образы пинятся через versions.env: `IMAGE=${LITELLM_VERSION}` в docker-compose.yml
- .env шаблон: плейсхолдеры `__VAR__` заменяются sed'ом в config.sh
- Healthcheck: `curl -sf --max-time 5 http://localhost:PORT/health` (lib/health.sh)
- Core services: без profiles: тега, запускаются всегда

### Integration Points
- `phase_config()` в install.sh → вызывает generate_config() → здесь генерировать litellm-config.yaml
- `_show_credentials()` → добавить LiteLLM URL + master key
- `templates/nginx.conf` → location /litellm
- `cmd_doctor()` → проверка http://agmind-litellm:4000/health

</code_context>

<specifics>
## Specific Ideas

- LiteLLM UI через Nginx позволяет оператору видеть cost tracking и управлять ключами без SSH
- Open WebUI сохраняет OLLAMA_BASE_URL для model management — не ломаем существующий UX

</specifics>

<deferred>
## Deferred Ideas

- `agmind litellm add` CLI команда для добавления моделей без ручного YAML — v3.0
- Автоматическая настройка Dify Model Provider через API — ранее отвергнуто (Phase 1: три-layer boundary)

</deferred>

---

*Phase: 32-litellm-ai-gateway*
*Context gathered: 2026-03-30*
