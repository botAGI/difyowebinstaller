# Dify vs RAGFlow — Who Does What

AGmind includes several components whose names or descriptions sound overlapping. This document clarifies responsibilities so you don't double-build, duplicate configuration, or disable the wrong service when something breaks.

**The mental model: orchestration → ingestion → conversion → storage → serving.**

---

## Component responsibilities

| Component | Role | Use it for |
|-----------|------|-----------|
| **Dify** | **Orchestration / apps / agents / workflows** | Building chat applications, agents, and RAG pipelines. The Universal Auto-Router DSL (`templates/dify-workflows/`) wires together KB lookups, document ingestion, tool calls, and LLM completions. Primary operator UI. All user-facing products live here |
| **RAGFlow** | **Parsing-heavy ingestion** | Bulk document ingestion where deep layout analysis, table extraction, and OCR quality are the bottleneck. Use when the Dify + Docling ingestion path produces unsatisfactory chunking on complex PDFs, scanned documents, or multi-column layouts. Exposed to Dify via the `witmeng/ragflow-api` marketplace plugin |
| **Docling-serve** | **Document conversion** | PDF / DOCX / PPTX / XLSX / HTML / Markdown → structured Markdown + chunk candidates. Called by Dify KB pipelines via `POST http://docling:8765/v1/convert/file`. GPU batch inference on the master node. Standalone container since v3.0 — see [ADR-0006](adr/0006-docling-standalone-not-plugin.md) |
| **Vector DB** (Weaviate / Qdrant / Milvus) | **Embeddings storage** | The similarity-search index that backs Dify Knowledge Base and RAGFlow retrieval. Only one is active at a time (`VECTOR_STORE` env). See [vector-db-decision-matrix.md](vector-db-decision-matrix.md) for which to choose |
| **vLLM** | **Model serving** | The LLM (chat completions, `gemma-4-26B`) + embedding model (`deepvk/USER-bge-m3`) + rerank model (`BAAI/bge-reranker-v2-m3`). OpenAI-compatible API on the peer node (`LLM_ON_PEER=true`). Dify and RAGFlow call it via `openai_api_compatible` endpoint |
| **Open WebUI** | **Alternative chat UI** | Thin chat interface for ad-hoc LLM conversations. Not part of the RAG pipeline — just a frontend that hits the same vLLM endpoint. No pipeline/filter logic runs here (Pipelines extension removed in v3.0) |
| **LiteLLM** | **AI gateway / model proxy** | Optional unified proxy in front of vLLM (rate limiting, model aliases, multi-provider fallback). Enabled when `ENABLE_LITELLM=true` |

---

## When to use which ingestion path

### Dify + Docling (default)

- Fully integrated with Dify Knowledge Base, workflows, and the Universal Auto-Router DSL
- GPU-accelerated conversion via `docling-serve-cu130` (layout + OCR + VLM picture description)
- Best for: mixed-format corpora, ongoing ingestion via API, tight Dify workflow integration
- Limitation: single-pass pipeline; very complex scanned documents may produce noisy chunks

### RAGFlow (optional, `ragflow` profile)

- Deep parsing pipeline with its own OCR stack (Elasticsearch-backed full-text + vector hybrid)
- Multilingual OCR including Cyrillic (our custom image: `ragflow-local:arm64`)
- Best for: bulk ingestion of scan-heavy PDFs, books, technical manuals where table structure matters
- Note: pulls extra services (Elasticsearch, MySQL, MinIO) — heavier stack
- RAGFlow results are surfaced in Dify via the `witmeng/ragflow-api` plugin (5 operations: list datasets/documents/chunks, add chunks, retrieve data)
- The two paths **can coexist** on the same AGmind install (Dify KB for operational ingestion + RAGFlow for deep archive parsing)

---

## Common misconceptions

| Misconception | Reality |
|---------------|---------|
| "RAGFlow replaces Dify" | No. RAGFlow handles ingestion/parsing. Dify handles apps, agents, and workflows. They complement each other |
| "Docling is a Dify plugin" | Since v3.0 Docling runs as a **standalone container** (`agmind-docling`). The old `s20ss/docling` Dify plugin is removed — see [ADR-0006](adr/0006-docling-standalone-not-plugin.md) |
| "Vector DB is Weaviate-only" | AGmind supports Weaviate (default), Qdrant, or Milvus (experimental). Only one is active per install |
| "vLLM is only for chat" | vLLM also serves the embedding model (`USER-bge-m3`) via `--runner pooling` and the rerank model. All three use the same OpenAI-compatible API |
| "Open WebUI has RAG capabilities" | Open WebUI's built-in RAG features are not used. All RAG logic lives in Dify workflows + Docling/RAGFlow ingestion |

---

## See also

- [architecture/data-flow.md](architecture/data-flow.md) — end-to-end data flow: document → conversion → vector DB → Dify workflow → vLLM → user
- [architecture/topology.md](architecture/topology.md) — which containers run on master vs peer node
- [vector-db-decision-matrix.md](vector-db-decision-matrix.md) — Weaviate / Qdrant / Milvus comparison
- [compatibility-matrix.md](compatibility-matrix.md) — tested versions for all components
