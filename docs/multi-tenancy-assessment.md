# Multi-tenancy assessment for AGmind v4.0 (Phase 49)

**Decision: do NOT add true multi-tenancy in v4.0. Stay single-tenant (dedicated stack per customer). Focus v4.0 on workspace-isolation hardening within a single stack.**

Research done 2026-04-18 via Dify 1.13.3 codebase review + ecosystem scan. This document is a decision artifact, not an implementation spec.

---

## TL;DR

| Question | Answer |
|---|---|
| Can AGmind become a multi-tenant SaaS on Dify OSS? | **No** — license forbids commercial MT without written permission from LangGenius ([issue #4685](https://github.com/langgenius/dify/issues/4685)) |
| Does Dify 1.13 provide real tenant isolation in OSS? | **No** — "soft" isolation via `WHERE tenant_id=` ORM filters; no Postgres RLS; shared Redis/Weaviate/MinIO/plugins |
| What do RU enterprise customers actually want? | **On-prem per customer**. SaaS multi-tenant is a weak value prop for the target segment |
| Is there a real technical path if we ignored the license? | Yes — Option 2 or 3 below — but 15-25 days of engineering and Dify fork maintenance |
| What SHOULD v4.0 do? | Phase A: audit workspace leak vectors + wire Weaviate native MT; Phase B/C deferred to demand |

---

## Current isolation state (Dify 1.13.3)

- `tenants` table = workspaces. Sentinel: App, Dataset, InstalledApp, ApiToken, Message, Conversation have `tenant_id` column with index.
- Enforcement is **in application code** (ORM-level WHERE clauses). No Postgres Row Level Security, no schema-per-tenant.
- Any missed WHERE clause = cross-tenant data leak. Fork tax = per-release re-audit.
- Shared between tenants: Redis instance, Weaviate schema (class per dataset, no `tenant=` parameter), MinIO bucket, Model providers (incl. credentials), Plugin daemon, Prometheus metrics.

Reference: https://github.com/langgenius/dify/tree/main/api/models

---

## Known leak vectors (single-stack multi-workspace today)

| Severity | Vector | Issue |
|---|---|---|
| **H** | Redis keys without tenant prefix (partial; some are already scoped, but not all) | [#13604](https://github.com/langgenius/dify/issues/13604), [#24783](https://github.com/langgenius/dify/issues/24783) |
| **H** | Weaviate: class-per-dataset instead of native multi-tenancy (`tenant=`) — `schema.get()` returns all classes across tenants | Dify `api/core/rag/datasource/vdb/weaviate/weaviate_vector.py` |
| **M** | MinIO single bucket, paths don't include tenant_id — direct S3 access bypasses Dify ACL | Dify storage layer |
| **M** | Model providers shared — no per-tenant rate limits, no cost attribution in OSS | Enterprise-gated feature |
| **M** | Plugin daemon: plugins run in shared process, cache keys are scoped but runtime access isn't | Requires plugin-side audit |
| **L** | Worker race "tenant not found" on membership delete | [#31369](https://github.com/langgenius/dify/issues/31369) |
| **L** | Prometheus has no tenant labels — per-tenant dashboards need Mimir + cortex-tenant proxy | — |

---

## Architectural options considered

| # | Approach | Effort | Risk | License | Fit |
|---|---|---|---|---|---|
| **1** | **Dify workspaces as-is, sold as multi-tenant SaaS** | 0 d | H (license + leak) | ❌ violates OSS license | No |
| **2** | **Fork Dify — schema-per-tenant PG, Weaviate native MT, MinIO per-bucket, Redis prefix** | 15-25 d | M (fork maint) | ❌ still commercial MT | No |
| **3** | **Stack-per-tenant via Swarm/k3s orchestrator** ("AGmind Hub") | 10-15 d + orchestrator learn | L (iso) / M (ops) | ✅ each tenant = single-workspace OSS | Maybe (reseller segment) |
| **4** | **Dedicated hardware per customer** (current AGmind model) | 0 d | L | ✅ | **Best for RU enterprise** |

---

## Russian market reality check

- RU enterprise under LLM/RAG procurement want **on-prem per customer**:
  - Data stays within perimeter (152-ФЗ, КИИ)
  - Integrations into their AD / 1C / СЭД
  - Customer-held keys and audit
- Multi-tenant SaaS would fight GigaChat / YandexGPT / Cloud-Dify on price where AGmind (on-prem, specialized) cannot win.
- SMB segment (10-50 users) is price-sensitive — not the target buyer persona for dedicated GPU boxes.

Conclusion: single-tenant on-prem is **not a limitation, it's the product**.

---

## v4.0 recommended scope (what we WILL do)

### Phase A — workspace-isolation hardening (3-5 days, priority HIGH)

Goal: close leak vectors inside a single stack so multi-department customers ("legal + marketing, isolate documents") get real separation.

1. Grep Dify fork for `get_or_create_redis_client()` / Redis cache paths without tenant_id in key → patch with prefix.
2. Patch `weaviate_vector.py` to use native Weaviate MT: create one class per dataset-type with `multi_tenancy_config: {enabled: true}`, store tenant_id as Weaviate tenant parameter instead of per-dataset class.
3. MinIO: migrate object paths from `upload_files/{uuid}` → `upload_files/{tenant_id}/{uuid}`; add bucket policy per tenant.
4. Document the audit + patches in AGmind fork, pin Dify version.

Output: hardened single-stack deploy. Customers with multi-department needs get reliable separation.

### Phase B — AGmind Hub (deferred, 10-15 days)

Build only when first reseller/MSP customer signs. Orchestrator (Docker Swarm or k3s) spawns per-tenant stacks from a single control plane. Each tenant = independent Dify single-workspace install, which is OSS license compliant.

### Phase C — Dify Enterprise license integration (deferred)

If a customer is willing to pay the Dify Enterprise uplift directly, document how to point our installer at their licensed Dify image. Do not subsidize the Enterprise license ourselves.

---

## Explicit non-goals for v4.0

- SaaS multi-tenant product ("agmind.cloud") — license blocker + market blocker
- Generic row-level tenant isolation inside Dify OSS — fork cost too high for minority use case
- Per-tenant Prometheus/Grafana split — only at Phase B

---

## Unknowns requiring future spikes

| Unknown | Action |
|---|---|
| Full list of Redis keys without tenant prefix | Grep Dify API codebase in Phase A |
| Baseline RAM of one empty AGmind stack (for Hub sizing) | Measure when Phase B triggers |
| Dify Enterprise license cost in 2026 | Only contact business@dify.ai if Phase C triggers |
| MinIO IAM policy path for per-tenant bucket access | Phase A step 3 prototype |

---

## Sources

- https://github.com/langgenius/dify/discussions/32254 — license discussion
- https://github.com/langgenius/dify/issues/4685 — commercial multi-tenant guidance
- https://github.com/langgenius/dify/blob/main/api/core/rag/datasource/vdb/weaviate/weaviate_vector.py
- https://docs.weaviate.io/weaviate/concepts/data — multi-tenancy model
- https://grafana.com/docs/mimir/latest/manage/secure/authentication-and-authorization/
- https://dify.ai/enterprise
