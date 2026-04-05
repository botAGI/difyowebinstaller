---
status: complete
phase: 06-v3-bugfixes (Blackwell GPU support)
source: git diff (c19ea49..HEAD uncommitted)
started: 2026-03-19T18:00:00Z
updated: 2026-03-19T18:20:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Cold Start Smoke Test
expected: Kill stack, start fresh. All services healthy. vLLM image tag = v0.17.1.
result: skipped
reason: No Docker/server available locally

### 2. vLLM version updated to v0.17.1
expected: versions.env has VLLM_VERSION=v0.17.1 and VLLM_CUDA_SUFFIX= (empty default). docker-compose.yml references ${VLLM_VERSION}${VLLM_CUDA_SUFFIX:-} in vllm image tag.
result: pass

### 3. GPU compute capability detection
expected: detect.sh detect_gpu() sets DETECTED_GPU_COMPUTE for NVIDIA GPUs. FORCE_GPU_TYPE=nvidia + FORCE_GPU_COMPUTE=12.0 overrides compute. Format validated as X.Y or empty.
result: pass

### 4. Blackwell warning in wizard (non-interactive)
expected: NON_INTERACTIVE=true + LLM_PROVIDER=vllm + DETECTED_GPU_COMPUTE=12.0 => VLLM_CUDA_SUFFIX auto-set to "-cu130". Older GPU (8.9) => suffix stays empty.
result: pass

### 5. CUDA_VISIBLE_DEVICES in docker-compose
expected: vLLM service in docker-compose.yml has CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-all} in environment.
result: pass

### 6. GPU hint in _check_critical_services
expected: install.sh _check_critical_services checks agmind-vllm status when LLM_PROVIDER=vllm. If exited/restarting with "no kernel image" in logs, shows GPU compute hint.
result: pass

### 7. VLLM_CUDA_SUFFIX flows to .env
expected: config.sh _append_provider_vars writes VLLM_CUDA_SUFFIX to .env when LLM_PROVIDER=vllm and suffix is non-empty.
result: pass

### 8. All BATS tests pass
expected: Full CI suite (243 tests) passes. No regressions. Shellcheck clean (info-only).
result: pass

## Summary

total: 8
passed: 7
issues: 0
pending: 0
skipped: 1

## Gaps

[none]
