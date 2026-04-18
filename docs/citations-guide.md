# Citations in AGmind (Phase 45)

Dify уже умеет показывать ссылки на источники из KB. **Ничего писать не надо** — нужно правильно включить в конфиге app.

## Для каких клиентов работает что

| Клиент | Native footnote-чипы | Inline-цитаты в тексте |
|---|---|---|
| **Dify Console chat** (http://agmind-dify.local) | ✅ автоматом из `metadata.retriever_resources` | ✅ если prompt просит модель их писать |
| **Dify public chat** (shared app link) | ✅ | ✅ |
| **Open WebUI** (http://agmind-chat.local) | ❌ теряется в OpenAI-compat pipe | ✅ |
| **Raw API** (`/v1/chat-messages` blocking) | ✅ в ответе есть `metadata.retriever_resources` | ✅ |
| **Raw API streaming** | ✅ events `message_end` содержат resources | ✅ |

**Вывод:** если твои клиенты разнородные (Dify + Open WebUI + API)—включи **и** footnote toggle, **и** inline-citation prompt. Оба работают параллельно, не конфликтуют.

---

## Часть 1 — Advanced-chat / Workflow app (advanced-chat, workflow)

### 1.1 Knowledge Retrieval node

В графе workflow должен быть узел **Knowledge Retrieval**, подключён к нужным datasets.

### 1.2 Answer node — Show Citation

Открой Answer node → правая панель → секция **Citations** → переключи **Show Citation: ON**.

Это включит footnote-чипы в Dify UI.

### 1.3 LLM node — prompt c inline-цитатами

В системном промпте LLM node добавь в конце:

```
Отвечай строго на русском. Используй только информацию из контекста ниже.

Контекст:
{{#context#}}

Правила цитирования:
- После каждого утверждения, взятого из контекста, ставь источник
  в квадратных скобках: [Источник: {название документа}, стр. {номер если есть}]
- Не выдумывай названия документов — только из контекста.
- Если ответ не следует из контекста, скажи: "Не нашёл в базе знаний".
```

Pro-tip: если chunks имеют стабильный `document_name` — можно требовать формат
`[doc.pdf, p.42]`. Если метадата слабая — используй `[Source: {doc_name}]`.

### 1.4 Проверить

Создай тестовое сообщение через UI или API:
```bash
curl -sf -X POST http://localhost/v1/chat-messages \
    -H "Authorization: Bearer app-<TOKEN>" \
    -H 'Content-Type: application/json' \
    -d '{"query":"test","inputs":{},"response_mode":"blocking","user":"test"}' | \
  jq '.metadata.retriever_resources[] | {doc: .document_name, score, page}'
```

Ожидаемо: список retrieved chunks с названиями документов.

---

## Часть 2 — Classic chatbot app (chat, agent-chat)

Правый sidebar → **Context** → **Citations and Attributions: ON**. Всё. Остальное идентично §1.3.

---

## Часть 3 — Проверить state по SQL

```sql
-- для advanced-chat/workflow — scan workflow graph
SELECT
  a.name,
  (w.graph::jsonb -> 'nodes' @> '[{"data": {"title": "Answer"}}]'::jsonb) AS has_answer_node,
  CASE WHEN w.graph::text ILIKE '%"citations_config"%' THEN 'configured' ELSE 'missing' END AS citations
FROM apps a
LEFT JOIN workflows w ON w.app_id = a.id
WHERE a.mode IN ('advanced-chat', 'workflow');

-- для classic chatbot
SELECT a.name, ac.retriever_resource
FROM apps a
LEFT JOIN app_model_configs ac ON ac.id = a.app_model_config_id
WHERE a.mode IN ('chat', 'agent-chat');
```

Подключиться:
```bash
sudo docker exec -it agmind-db psql -U postgres -d dify
```

Или через Grafana: dashboard **AGMind Audit Trail** → panel "Recent messages" покажет `retrieved_docs` колонку (Phase 44).

---

## Частая ошибка

**Citation chips не появляются в UI даже при включённом toggle.**

Обычно два повода:
1. App использует workflow, но в Answer node **Show Citation = OFF**. Починить в п.1.2.
2. Retrieval node ничего не вернул (пустой KB, или слишком высокий `score_threshold`). Проверь через Grafana Audit Trail → panel "KB retrieval hit count" — если пусто, KB молчит.

**Inline-цитаты в тексте отсутствуют, хотя prompt их требует.**

Обычно — модель сократила prompt из-за `max_tokens`. Увеличь `max_tokens` в LLM node минимум до 800-1000 для chat-QA.
