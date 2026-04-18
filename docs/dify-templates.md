# Dify workflow templates (Phase 46)

## Что в репо

`templates/dify-workflows/` содержит **только generic examples** — минимальные шаблоны, которые показывают **как** импортировать DSL, не **что**. Конкретные бизнес-пайплайны (юристы, HR, финансы, scan-PDF, 1С) — **не в git**. Это sales asset.

Сейчас в `templates/dify-workflows/`:
- `example-rag-qa.yaml` — generic chat app с KB retrieval и citations промптом. Модель = placeholder `_REPLACE_WITH_YOUR_MODEL_`.

## Как импортировать

### Способ 1 — через UI (проще)

1. Открой Dify Studio: `http://agmind-dify.local/apps`
2. `+ Create App` → **Import from DSL**
3. Выбери файл `/opt/agmind/templates/dify-workflows/example-rag-qa.yaml`
4. При импорте Dify спросит какую модель использовать — выбирай vLLM (настроенный OpenAI-API-compatible провайдер)
5. В Orchestrate → Context → Add Dataset — привяжи одну или несколько своих KB

### Способ 2 — через CLI

```bash
# Автоматически тянет JWT из INIT_PASSWORD в .env, если login работает
sudo agmind dify import-workflow /opt/agmind/templates/dify-workflows/example-rag-qa.yaml

# Если login сломан (SECRET_KEY rotate):
# открой Dify UI → F12 → Application → Local Storage → console_token → скопируй
DIFY_CONSOLE_TOKEN=<jwt> sudo agmind dify import-workflow example-rag-qa.yaml
```

## Как создать свой DSL

Самый быстрый способ — настроить app через UI до рабочего состояния, затем **Export DSL** (кнопка в App settings). Получишь YAML — положи в приватный stash (см. ниже).

## Приватный stash

Для бизнес-ценных шаблонов используй локальную директорию:

```
.planning/private-stash/dify-workflows/
├── legal-contract-review.yaml
├── hr-onboarding-bot.yaml
├── finance-invoice-qa.yaml
├── scan-pdf-ingestion.yaml     # hybrid extractor flow (Phase 43 presets)
└── 1c-odata-connector.yaml
```

`.planning/` **уже в .gitignore** (см. корневой `.gitignore`). Положил туда YAML — он останется только на твоей машине, в репо не попадёт.

## Экспорт существующего app для backup/перенос

```bash
# CLI (требует console token)
DIFY_CONSOLE_TOKEN=<jwt> curl -sf \
    -H "Authorization: Bearer $DIFY_CONSOLE_TOKEN" \
    "http://agmind-dify.local/console/api/apps/<APP_UUID>/export?include_secret=false" \
    > my-app.yaml
```

Без `include_secret=true` система/API-ключи не экспортируются — безопасно делиться YAML между клиентами.

## Tips

- **Citations** (Phase 45) работают только если в DSL `retriever_resource.enabled: true` или в workflow Answer-ноде `citation.enable: true`.
- **Модель в DSL** (`model.name`) должна существовать у импортирующего стека. Если не существует — Dify при первом запуске попросит выбрать замену.
- **Shared по URL**: Import может работать и с URL-DSL, но требует чтобы URL был reachable из Dify-api контейнера; локально не надо.

## Roadmap

- Phase 46 (текущая): один generic example + import CLI
- Phase 46+ (по мере продаж): приватные бизнес-шаблоны в `.planning/private-stash/`
- v3.1+: автоматический импорт при `install.sh --with-examples` если пользователь укажет URL приватного git с templates
