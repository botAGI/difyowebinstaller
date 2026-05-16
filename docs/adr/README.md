# Architecture Decision Records

These ADRs are the public projection of key architectural decisions in AGmind.
Format: MADR-lite (Title / Status / Context / Decision / Consequences / References).
When code comments need to point at a decision rationale, they reference
`docs/adr/NNNN-...` (a tracked, public file).

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-arm64-only.md) | AGmind Targets aarch64 (DGX Spark) Only | Accepted |
| [0002](0002-vps-profile-removed.md) | VPS/VDS Deployment Profile Removed | Accepted |
| [0003](0003-vector-db-default-weaviate.md) | Weaviate as Default Vector Store | Accepted |
| [0004](0004-plugin-daemon-pin-0.5.3-local.md) | Dify Plugin Daemon Pinned at 0.5.3-local | Accepted |
| [0005](0005-driver-580-hold.md) | NVIDIA Driver 580 Hold on DGX Spark | Accepted |
| [0006](0006-docling-standalone-not-plugin.md) | Docling Runs as Standalone Container, Not Dify Plugin | Accepted |
| [0007](0007-force-recreate-trap.md) | Never force-recreate Dify Worker/API During Active Indexing | Accepted |
| [0008](0008-nginx-variable-proxy.md) | nginx proxy_pass Must Use Variable Form with resolver | Accepted |
| [0009](0009-cadvisor-minio-arm64-holds.md) | cAdvisor and MinIO Version Holds for arm64 | Accepted |
| [0011](0011-state-store-architecture.md) | State Store Substrate (Versioned + Atomic + Migration-Driven) | Accepted |

> More decisions are recorded as inline `# WHY:` comments at the relevant code site
> or in `../troubleshooting.md`; not every operational note warrants a dedicated ADR.
