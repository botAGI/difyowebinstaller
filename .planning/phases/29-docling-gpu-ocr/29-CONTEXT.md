# Phase 29: Docling GPU/OCR - Context

**Gathered:** 2026-03-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Расширение Docling-сервиса: wizard предлагает выбор GPU/CPU образа (ручной, не автодетект), persistent model cache через существующий volume, русский OCR по умолчанию через переменную окружения, offline bundle поддержка CUDA-образа через флаг.

</domain>

<decisions>
## Implementation Decisions

### Выбор образа в wizard
- Тройной выбор вместо текущего да/нет: 1) Нет, 2) Да — CPU, 3) Да — GPU (CUDA)
- Если GPU (nvidia container toolkit) НЕ обнаружен — GPU-пункт скрыт (показываются только Нет/CPU)
- Выбор записывает полный image:tag в переменную `DOCLING_IMAGE` в .env
- docker-compose использует `image: ${DOCLING_IMAGE}` — одна переменная, без сборки из частей
- Один сервис `docling` в docker-compose (без дубликата). GPU-доступ через `NVIDIA_VISIBLE_DEVICES` env var в .env; без GPU переменная пуста — контейнер работает на CPU

### OCR языки
- `OCR_LANG=rus,eng` по умолчанию в шаблонах .env — молча, без шага в wizard
- Пользователь может изменить языки редактированием .env + перезапуск контейнера
- Переменная OCR_LANG передаётся в контейнер через environment в docker-compose

### Model cache и preload
- Текущий volume `agmind_docling_cache` на `/home/docling/.cache` — достаточно, второй volume не нужен
- Предзагрузка моделей при установке НЕ выполняется — модели скачиваются при первом реальном запросе
- Volume переживает recreate — это уже работает

### Offline bundle
- По умолчанию offline bundle включает CPU-образ Docling
- Флаг `INCLUDE_DOCLING_CUDA=true` добавляет CUDA-образ в bundle (+5-8 GB)
- В `versions.env` два образа: `DOCLING_IMAGE_CPU=ghcr.io/...:version` и `DOCLING_IMAGE_CUDA=quay.io/...:version`
- Wizard копирует нужный в `DOCLING_IMAGE` в .env на основе выбора пользователя

### Claude's Discretion
- Точный формат GPU-детектирования (nvidia-smi, docker info, nvidia-ctk)
- Как передать `NVIDIA_VISIBLE_DEVICES` и `deploy.resources.reservations` в compose (если нужно)
- Формат OCR_LANG в docling-serve (env var vs command flag)
- Интеграция с build-offline-bundle.sh

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docling конфигурация
- `templates/docker-compose.yml` §docling — текущий сервис docling (image, volumes, command, profiles)
- `lib/wizard.sh` — шаг Docling (ENABLE_DOCLING), место для расширения на GPU/CPU выбор
- `lib/compose.sh` — build_compose_profiles() с docling профилем
- `templates/versions.env` — DOCLING_SERVE_VERSION, нужно добавить DOCLING_IMAGE_CPU/CUDA

### Env шаблоны
- `templates/env.lan.template` — ENABLE_DOCLING, нужно добавить DOCLING_IMAGE, OCR_LANG
- `templates/env.vpn.template` — аналогично
- `templates/env.vps.template` — аналогично
- `templates/env.offline.template` — аналогично

### Config и подстановка
- `lib/config.sh` — _generate_env_file() sed-замены для __DOCLING_IMAGE__, __OCR_LANG__

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/wizard.sh`: шаг Docling (строки ~198-210) — расширить с да/нет на тройной выбор
- `lib/compose.sh`: `build_compose_profiles()` — уже обрабатывает `ENABLE_DOCLING`
- `lib/config.sh`: `_generate_env_file()` — паттерн sed-замен __PLACEHOLDER__ уже используется
- `templates/versions.env`: паттерн для хранения версий образов

### Established Patterns
- Wizard: `case` блоки для нумерованного выбора (см. LLM/Embeddings wizard шаги)
- GPU-детект: можно использовать паттерн из существующего VRAM-расчёта в wizard
- Переменные образов: другие сервисы уже используют `${IMAGE_VAR}` в docker-compose

### Integration Points
- `lib/wizard.sh` → export DOCLING_IMAGE, OCR_LANG
- `lib/config.sh` → sed __DOCLING_IMAGE__, __OCR_LANG__ в .env
- `templates/docker-compose.yml` → `image: ${DOCLING_IMAGE}` вместо хардкода
- `scripts/build-offline-bundle.sh` → INCLUDE_DOCLING_CUDA для дополнительного docker save

</code_context>

<specifics>
## Specific Ideas

- GPU-пункт скрыт, а не серый — пользователь не должен видеть то, что не может выбрать
- DOCLING_IMAGE содержит полный image:tag — максимальная прозрачность в .env

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 29-docling-gpu-ocr*
*Context gathered: 2026-03-29*
