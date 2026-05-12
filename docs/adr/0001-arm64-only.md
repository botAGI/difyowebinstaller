# 0001. AGmind Targets aarch64 (DGX Spark) Only

**Date:** 2026-04-25
**Status:** Accepted

## Context and Problem Statement

AGmind is deployed exclusively on DGX Spark (Grace Blackwell GB10, aarch64 / SM_121).
Starting from 2026-04-25, x86_64/amd64 support was removed from `install.sh`: the installer
exits with an error on non-aarch64 hardware. The key upstream dependencies — NGC vLLM
(`vllm/vllm-openai:gemma4-cu130`) and Docling-serve cu130 — publish only arm64 manifests;
there are no official amd64 builds of these images.

## Decision Outcome

**Chosen option:** "arm64-only; `install.sh` exits 1 on non-aarch64 unless `AGMIND_ALLOW_AMD64=true` is set"

**Reason:** All images in `templates/versions.env` must have a verified arm64 manifest
(`docker manifest inspect ... | grep -c arm64` >= 1). Running the stack on x86_64 would
require rebuilding core GPU-inference images from scratch and is outside the project's
support scope. The escape hatch (`AGMIND_ALLOW_AMD64=true`) exists for CI/testing
environments where GPU workloads are mocked out.

## Consequences

**Good:**
- Focused testing and qualification on a single hardware target.
- No multi-arch image drift; every image version is tested on GB10.
- `tests/compose/test_image_tags_exist.sh` enforces arm64 manifest presence for every image in compose.

**Bad:**
- No x86_64 / amd64 deployments without manual image substitution.
- Community amd64 builds are best-effort only and not covered by AGmind QA.
- DGX Spark unified memory (121 GiB shared CPU+GPU) requires specific tuning for
  `gpu_memory_utilization`, `mem_limit` values that differ from discrete-GPU hardware.

## References

- [NVIDIA DGX Spark Playbooks](https://github.com/NVIDIA/dgx-spark-playbooks/tree/main/nvidia/vllm)
- `docs/installation/requirements.md`
- `docs/compatibility-matrix.md`
- `templates/versions.env` (authoritative image:tag source)
