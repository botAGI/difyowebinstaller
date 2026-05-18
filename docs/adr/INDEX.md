# Architecture Decision Records — Catalogue

Canonical machine-friendly index of all ADRs in this repository.

> Phase 15 (v3.2.0) ships this as a **hand-written** index. Phase 16 (DOCS-03) will wire
> a `make adr-index` target + pre-commit hook to auto-regenerate this file when new ADRs
> land. Until then, contributors must update this table manually when adding an ADR.

Format spec, MADR-lite conventions, and how to write a new ADR: [README.md](README.md).

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001](0001-arm64-only.md) | AGmind Targets aarch64 (DGX Spark) Only | Accepted | 2026-04-25 |
| [0002](0002-vps-profile-removed.md) | VPS/VDS Deployment Profile Removed | Accepted | 2026-04-25 |
| [0003](0003-vector-db-default-weaviate.md) | Weaviate as Default Vector Store | Accepted | 2026-04-25 |
| [0004](0004-plugin-daemon-pin-0.5.3-local.md) | Dify Plugin Daemon Pinned at 0.5.3-local | Accepted | 2026-04-25 |
| [0005](0005-driver-580-hold.md) | NVIDIA Driver 580 Hold on DGX Spark | Accepted | 2026-04-25 |
| [0006](0006-docling-standalone-not-plugin.md) | Docling Runs as Standalone Container, Not Dify Plugin | Accepted | 2026-04-25 |
| [0007](0007-force-recreate-trap.md) | Never force-recreate Dify Worker/API During Active Indexing | Accepted | 2026-04-25 |
| [0008](0008-nginx-variable-proxy.md) | nginx proxy_pass Must Use Variable Form with resolver | Accepted | 2026-04-25 |
| [0009](0009-cadvisor-minio-arm64-holds.md) | cAdvisor and MinIO Version Holds for arm64 | Accepted | 2026-04-25 |
| [0010](0010-go-migration-staged-port.md) | Go Migration — Staged Port After Equivalence Proof | Accepted | 2026-05-18 |
| [0011](0011-state-store-architecture.md) | State Store Substrate (Versioned + Atomic + Migration-Driven) | Accepted | 2026-05-16 |
| [0012](0012-service-registry-codegen.md) | Service Registry as Single Source of Truth (YAML + Build-Time Codegen) | Accepted | 2026-05-17 |
| [0013](0013-go-single-binary-internal-packages.md) | Go CLI as Single Binary with internal/ Packages (Q-07) | Accepted | 2026-05-18 |

**Total: 13 ADRs.**

## Cross-cutting ADR groups

- **Platform/architecture (parent decisions):** [0001](0001-arm64-only.md), [0002](0002-vps-profile-removed.md), [0003](0003-vector-db-default-weaviate.md)
- **Operations / hold-rules:** [0004](0004-plugin-daemon-pin-0.5.3-local.md), [0005](0005-driver-580-hold.md), [0007](0007-force-recreate-trap.md), [0009](0009-cadvisor-minio-arm64-holds.md)
- **Infrastructure (nginx / containers):** [0006](0006-docling-standalone-not-plugin.md), [0008](0008-nginx-variable-proxy.md)
- **v3.2.0 architecture release:** [0011](0011-state-store-architecture.md), [0012](0012-service-registry-codegen.md)
- **v4.0 Go migration:** [0010](0010-go-migration-staged-port.md), [0013](0013-go-single-binary-internal-packages.md) → also see [docs/ROADMAP-GO.md](../ROADMAP-GO.md)
