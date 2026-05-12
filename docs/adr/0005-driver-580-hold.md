# 0005. NVIDIA Driver 580 Hold on DGX Spark

**Date:** 2026-04-25
**Status:** Accepted

## Context and Problem Statement

DGX Spark (GB10 / SM_121) uses unified memory architecture where GPU and system RAM
share the same 121 GiB pool. NVIDIA driver 590+ and 595+ introduce three independent
regressions specific to GB10 unified memory that break AGmind production workloads.
NVIDIA staff have explicitly stated that drivers past 580.126.09 are not supported on
DGX Spark hardware.

## Decision Outcome

**Chosen option:** "Pin NVIDIA driver at 580.x and hold via `apt-mark hold nvidia-driver-580-open`"

**Reason:** Three confirmed GB10 unified-memory regressions on 590+/595+:

1. **CUDAGraph capture deadlock** — vLLM hangs on first inference after model load, or
   throws `RayChannelTimeoutError` after 300 seconds in tensor-parallel mode.
2. **UMA memory leak (590.48.01)** — approximately 80 GiB become unavailable after a
   clean CUDA process exit. The memory is not reflected in AnonPages/Slab/PageTables;
   `MemAvailable` drops permanently until reboot. Forum thread closed without a fix.
3. **Blackwell TMA bug (595.58.03)** — `cuTensorMapEncodeTiled` causes an illegal memory
   access on SM_121, breaking NVFP4 quantization on DGX Spark.

## Consequences

**Good:**
- vLLM runs stably with gemma-4 26B-A4B-it on GB10.
- No unattended-upgrade reboots breaking production unexpectedly.
- `apt-mark hold` prevents unattended-upgrades from pulling newer drivers.

**Bad:**
- NGC vLLM 26.03+ (requires driver ≥ 590.44) cannot be used until DGX OS ≥ 7.6
  where NVIDIA resolves the UMA leak and CUDAGraph deadlock.
- CUDAGraph cannot be used at all on the current driver series (not merely version-gated).
- `VLLM_ATTENTION_BACKEND=TRITON_ATTN` is required for FP8 workloads because FlashInfer
  FP8 backend is broken on SM_121.

## References

- NVIDIA Developer Forum thread 360181 (CUDAGraph capture deadlock)
- NVIDIA Developer Forum thread 359969 (UMA memory leak — closed without fix 2026-02-25)
- vLLM GitHub issue #35519 (Blackwell TMA bug / NVFP4 on SM_121)
- NVIDIA staff statement (`cyuen1`): "we do not support new drivers past version 580.126.09 on Spark"
- `docs/troubleshooting.md` section 1 (vLLM model not loading)
- `docs/compatibility-matrix.md` (NVIDIA Driver row)
