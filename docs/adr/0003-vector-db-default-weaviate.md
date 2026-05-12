# 0003. Weaviate as Default Vector Store

**Date:** 2026-04-25
**Status:** Accepted

## Context and Problem Statement

AGmind supports three vector databases: Weaviate (default), Qdrant (lightweight alternative),
and Milvus (experimental, huge-scale). A deployment can activate only one at a time via
the compose profile selector. The installer wizard must pick a sensible default for new
deployments, and this choice affects backup/restore coverage and unified-memory budgeting
on DGX Spark.

## Decision Outcome

**Chosen option:** "Weaviate as the default vector store; Qdrant as the lightweight alternative; Milvus as experimental (not active by default)"

**Reason:** Weaviate is the general-purpose, well-tested choice in the AGmind stack: it
integrates with Dify's native KB pipeline, has proven backup/restore procedures, and its
GraphQL API is used by existing retrieval workflows. Qdrant is available as an alternative
for resource-constrained deployments. Milvus targets use cases with > 50 M vectors and
is kept EXPERIMENTAL until full integration is validated.

## Consequences

**Good:**
- Predictable deployment: one well-tested path for most users.
- Backup/restore covered for Weaviate in `lib/backup.sh` and `lib/restore.sh`.
- Dify KB pipelines work out of the box without additional connector configuration.

**Bad:**
- Weaviate heap (~15 GiB) counts against the 121 GiB unified-memory budget on DGX Spark.
  With vLLM, Postgres, and Docling running, memory planning is required (see `agmind estimate`).
- Milvus users must opt in explicitly and are responsible for testing the integration.

## References

- `docs/vector-db-decision-matrix.md`
- `docs/dify-vs-ragflow.md`
- `docs/compatibility-matrix.md`
- `lib/service-map.sh` — `SERVICE_GROUPS` and compose profile definitions
