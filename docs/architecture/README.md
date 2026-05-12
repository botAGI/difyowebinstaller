# Architecture

AGmind — установщик корпоративной RAG-платформы на DGX Spark (aarch64). Здесь собраны
архитектурные диаграммы, описывающие топологию сервисов, потоки данных и модель сетевой
безопасности. Диаграммы отображают текущее состояние стека (v3.1) и рендерятся
напрямую на GitHub.

> Эти диаграммы заменяют устаревший `branding/architecture.svg`, который не отражал
> dual-Spark-архитектуру и LAN-only-модель деплоя.

## Diagrams

- **[topology.md](topology.md)** — какие контейнеры работают, в каких профилях, master vs peer-узел; subgraph-группировка по deployment-профилям; peer-узел (spark-69a2) при `LLM_ON_PEER=true`
- **[data-flow.md](data-flow.md)** — Document → Docling → chunks → vector DB → Dify workflow → vLLM → пользователь; два потока: ingestion (загрузка документа) и query (RAG-запрос)
- **[security-zones.md](security-zones.md)** — сетевые/security-зоны, exposed vs internal-порты, docker-socket-proxy, airgapped-режим; отражает хардинг Phase 7

## Related

- [../compatibility-matrix.md](../compatibility-matrix.md) — матрица совместимости компонентов
- [../vector-db-decision-matrix.md](../vector-db-decision-matrix.md) — Weaviate vs Qdrant vs Milvus
- [../dify-vs-ragflow.md](../dify-vs-ragflow.md) — когда использовать Dify pipeline vs RAGFlow
- [../troubleshooting.md](../troubleshooting.md) — cookbook: симптом → причина → фикс
