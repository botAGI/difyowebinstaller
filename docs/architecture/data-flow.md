# Data Flow

Два основных потока данных в AGmind:

- **Flow A — Ingestion:** оператор загружает документ → документ преобразуется в чанки с эмбеддингами → попадает в векторную БД.
- **Flow B — Query:** пользователь задаёт вопрос → RAG-поиск по чанкам → LLM-генерация ответа.

Оба потока оркестрируются через Dify (Universal Auto-Router DSL, `templates/dify-workflows/`).
RAGFlow — альтернативный парсинг-тяжёлый путь ingestion при `ENABLE_RAGFLOW=true`;
подробнее: [`../dify-vs-ragflow.md`](../dify-vs-ragflow.md).

---

## Flow A — Ingestion (Document Upload)

```mermaid
sequenceDiagram
    actor Operator as Operator
    participant UI as Dify UI<br/>(agmind-dify.local)
    participant nginx as nginx :80
    participant api as agmind-api :5001
    participant worker as agmind-worker
    participant docling as Docling-serve :8765<br/>POST /v1/convert/file
    participant embed as agmind-vllm-embed :8001<br/>(deepvk/USER-bge-m3)
    participant vdb as Vector DB (Weaviate :8080)

    Operator->>UI: Upload document (PDF/DOCX/etc.)
    UI->>nginx: HTTP POST /console/api/files/upload
    nginx->>api: proxy_pass $u_dify_api
    api->>worker: Queue indexing task (Celery/Redis)
    worker->>docling: POST /v1/convert/file<br/>(multipart, image_export_mode=placeholder)
    docling-->>worker: Markdown + chunk candidates
    Note over worker,docling: Universal Auto-Router DSL selects<br/>fast_text (pypdfium2) or docling+OCR path
    worker->>embed: POST /v1/embeddings<br/>(chunk texts batch)
    embed-->>worker: float32 vectors
    worker->>vdb: Store chunks + vectors<br/>(Weaviate HTTP API, WEAVIATE_API_KEY)
    vdb-->>worker: OK — indexed
    worker-->>api: Task complete
    api-->>UI: Knowledge base updated
```

> **Docling VLM picture description** (optional): при `do_picture_description=true`
> Docling-serve вызывает `DOCLING_VLM_URL` → vLLM `/v1/chat/completions` (peer-узел при `LLM_ON_PEER=true`)
> для аннотации изображений из документа (concurrency=8).

---

## Flow B — Query (RAG Question Answering)

```mermaid
sequenceDiagram
    actor User as User
    participant UI as Dify UI / Chat API
    participant nginx as nginx :80
    participant api as agmind-api :5001
    participant worker as agmind-worker
    participant embed as agmind-vllm-embed :8001<br/>(deepvk/USER-bge-m3)
    participant vdb as Vector DB (Weaviate :8080)
    participant vllm as agmind-vllm :8000<br/>(gemma-4-26B-A4B)<br/>peer node

    User->>UI: Ask question
    UI->>nginx: POST /v1/chat-messages
    nginx->>api: proxy_pass $u_dify_api
    api->>worker: Dispatch workflow
    worker->>embed: POST /v1/embeddings (query)
    embed-->>worker: Query vector
    worker->>vdb: Similarity search (top-k chunks)
    vdb-->>worker: Relevant chunks + metadata
    Note over worker,vdb: Reranking optional:<br/>agmind-vllm-rerank (--runner pooling)
    worker->>vllm: POST /v1/chat/completions<br/>(system: retrieved chunks + user question)
    Note over worker,vllm: LLM_ON_PEER=true:<br/>http://${PEER_IP}:8000/v1/chat/completions
    vllm-->>worker: Generated answer (stream)
    worker-->>api: Answer + source citations
    api-->>UI: Response with citations
    UI-->>User: Answer displayed
```

> **LiteLLM gateway** (при `ENABLE_LITELLM=true`): между worker и vLLM может стоять
> `agmind-litellm :4000` как OpenAI-compatible proxy — позволяет подключать
> несколько LLM-бэкендов через единый endpoint.

---

See also: [topology.md](topology.md), [../dify-vs-ragflow.md](../dify-vs-ragflow.md), [../troubleshooting.md](../troubleshooting.md).
