# Vector DB — Decision Matrix

AGmind ships three vector store options behind the `VECTOR_STORE` environment variable and the `rag` compose profile. **The default is Weaviate.** The choice is made during `agmind wizard` and wired into the compose profile set by `lib/compose.sh::build_compose_profiles`. At most one vector store is active at a time (XOR logic in `build_compose_profiles`).

---

## Comparison

|  | **Weaviate** (default) | **Qdrant** | **Milvus** (EXPERIMENTAL) |
|---|---|---|---|
| **Set with** | `VECTOR_STORE=weaviate` (default) | `VECTOR_STORE=qdrant` | `VECTOR_STORE=milvus` |
| **Use when** | General-purpose RAG — the safe choice for most deployments | Lightweight footprint; fewer moving parts; smaller single-tenant installs | Very large corpora (> ~50 M chunks) **only** if you already know you need it |
| **Footprint** | Medium — Weaviate heap ~15 GiB counts against the 121 GiB unified-memory budget | Light — single container, modest RAM | Heavy — pulls extra services (MinIO bucket + etcd) similar to the RAGFlow profile |
| **Status in AGmind** | Fully supported; default in all named profiles (`rag`, `full`, `dev`) | Fully supported; opt-in via `VECTOR_STORE=qdrant` | **EXPERIMENTAL** — compose blocks present but not active by default; lib integration in backlog 999.5 |
| **Backup / restore** | Covered by `agmind backup create` / `agmind backup restore` | Covered | **Not yet covered** (experimental — backup integration deferred) |
| **RAGFlow compatible** | Yes | Yes | **No** — upstream PR #6367 closed, not merged. Use Weaviate or Qdrant when RAGFlow profile is active |
| **Notable features** | Hybrid dense+sparse search, Weaviate Modules ecosystem, multi-tenancy class isolation | ColBERT/ColPali multivector (v1.10+), BM25/IDF sparse, float16 vectors, ACORN-1 filtered search (v1.16) | Built-in BM25 + ICU/Lindera/Jieba tokenizers, Tiered Storage, Woodpecker WAL (S3-mode 750 MB/s), online schema updates |

---

## Recommendation

**Stick with Weaviate** unless you have a specific reason to switch. It is the only vector store tested end-to-end in all named profiles and covered by backup/restore. See [ADR-0003](adr/0003-vector-db-default-weaviate.md) for the rationale behind the default choice.

**Consider Qdrant** when:
- You are deploying without the full monitoring/storage stack (tight RAM budget)
- The lighter operational footprint matters more than Weaviate's module ecosystem

**Do not use Milvus in production** until backlog 999.5 is resolved. The compose blocks exist to let you experiment, but backup integration is absent and the profile is not validated in CI.

### Unified-memory budget note

DGX Spark has 121 GiB of unified memory shared by CPU and GPU workloads. Weaviate heap (~15 GiB) + PostgreSQL shared_buffers (~8 GiB) + RAGFlow Elasticsearch heap + Docling GPU batch peaks leave significantly less than 121 GiB for vLLM. Consult [compatibility-matrix.md](compatibility-matrix.md) for the full budget breakdown and `gpu_memory_utilization` guidance.

---

## See also

- [compatibility-matrix.md](compatibility-matrix.md) — tested versions + memory budget notes
- [dify-vs-ragflow.md](dify-vs-ragflow.md) — which component handles storage vs ingestion vs orchestration
- [adr/0003-vector-db-default-weaviate.md](adr/0003-vector-db-default-weaviate.md) — decision record for Weaviate as default
