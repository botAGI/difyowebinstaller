# 0009. cAdvisor and MinIO Version Holds for arm64

**Date:** 2026-04-25
**Status:** Accepted

## Context and Problem Statement

Two monitoring/storage components — cAdvisor and MinIO — publish release tags where the
GitHub Releases page and Docker Hub show the tag as "available", but the container
image manifest does not include an arm64 architecture entry. Pulling these images on
DGX Spark (aarch64) silently falls back to amd64 emulation or fails with a manifest error.

## Decision Outcome

**Chosen option:** "Pin cAdvisor at `<= v0.55.1`; pin MinIO at `RELEASE.2025-09-07T16-13-09Z`; mandate `docker manifest inspect` verification before any image bump"

**Reason:**
- **cAdvisor:** v0.53.0, v0.54.0, v0.55.0, v0.56.0, v0.56.1, v0.56.2 — all have release
  tags on GitHub but their container manifests do not include arm64. Only v0.52.1 and
  v0.55.1 have confirmed arm64 manifest entries. The maintainers lost arm64 CI builds
  after v0.55.1.
- **MinIO:** releases after `RELEASE.2025-09-07T16-13-09Z` (2025-09-30, 2025-10-08,
  2025-10-15, and later) dropped arm64 from the multi-arch manifest. The upstream CI
  lost arm64 builds after September 7, 2025.

The verification command before any bump:
```bash
docker manifest inspect <image>:<tag> | grep -c '"arm64"'
# Must return >= 1
```

## Consequences

**Good:**
- Deployments never pull a non-arm64 image onto DGX Spark.
- `tests/compose/test_image_tags_exist.sh` (and `make manifest-check`) enforce arm64
  presence for every image in the compose file — this catches future regressions automatically.

**Bad:**
- Monitoring stack is stuck on older cAdvisor (v0.55.1); newer metrics or dashboards
  may not be available.
- MinIO is stuck on the September 2025 release; newer MinIO features unavailable until
  upstream restores arm64 builds.
- GitHub release pages and Docker Hub "available" indicators are not trustworthy for
  arm64 verification — always use `docker manifest inspect` directly.

## References

- `docs/compatibility-matrix.md` (cAdvisor and MinIO rows)
- `scripts/check-upstream.sh` — automated upstream version check with arm64 manifest validation
- `tests/compose/test_image_tags_exist.sh`
- `templates/versions.env` — `CADVISOR_VERSION` and `MINIO_VERSION` pins
