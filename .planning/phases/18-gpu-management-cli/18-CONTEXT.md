# Phase 18: GPU Management CLI - Context

**Gathered:** 2026-03-23
**Status:** Ready for planning

<domain>
## Phase Boundary

New `agmind gpu` subcommand (status + assign) and docker-compose env var substitution for CUDA_VISIBLE_DEVICES.

</domain>

<decisions>
## Implementation Decisions

### GPUM-01: agmind gpu status
- Show per-GPU: name, total VRAM, used, free via nvidia-smi
- Show containers assigned to each GPU (match CUDA_VISIBLE_DEVICES from docker inspect)
- Show GPU processes via nvidia-smi --query-compute-apps
- Requires root (_require_root)
- If nvidia-smi not found: print error and return 1

### GPUM-02: agmind gpu assign
- `agmind gpu assign <service> <gpu_id>` — service: vllm, tei, xinference
- Maps service to env var: vllm→VLLM_CUDA_DEVICE, tei→TEI_CUDA_DEVICE, xinference→XINFERENCE_CUDA_DEVICE
- Updates .env file (sed if exists, append if not)
- Prints "Restart required: agmind restart <service>"
- `agmind gpu assign --auto` — multi-GPU: vLLM on biggest GPU, TEI on smallest
- Single GPU: "Single GPU detected, all services on GPU 0"

### GPUM-03: docker-compose.yml env vars
- vLLM: replace `CUDA_VISIBLE_DEVICES: "0"` with `CUDA_VISIBLE_DEVICES: "${VLLM_CUDA_DEVICE:-0}"`
- TEI: replace `CUDA_VISIBLE_DEVICES: "0"` with `CUDA_VISIBLE_DEVICES: "${TEI_CUDA_DEVICE:-0}"`
- These are in templates/docker-compose.yml (source of truth for new installs)
- Existing installs: `agmind gpu assign` updates .env, compose reads from there

### Integration
- Add `gpu) shift; cmd_gpu "$@" ;;` to main case in agmind.sh
- Add gpu lines to usage/help text
- cmd_gpu dispatches to _gpu_status / _gpu_assign based on subcommand

### Claude's Discretion
- Exact formatting of gpu status output (box drawing, colors)
- Whether _gpu_status needs root (nvidia-smi usually works without root, docker inspect needs root)
- Error handling for invalid GPU IDs

</decisions>

<code_context>
## Existing Code Insights

### Key Files
- scripts/agmind.sh — main CLI dispatcher (case statement at bottom)
- templates/docker-compose.yml — vLLM at line ~320, TEI at line ~352
- lib/config.sh — env var substitution during install

### Established Patterns
- agmind.sh: `cmd_*` functions for each subcommand
- _require_root check at function start
- Color vars: RED, GREEN, YELLOW, CYAN, BOLD, NC
- ENV_FILE="${COMPOSE_DIR}/.env" for reading/writing

### Integration Points
- agmind.sh bottom: main case statement dispatching commands
- agmind.sh: usage/help text block
- templates/docker-compose.yml: CUDA_VISIBLE_DEVICES lines

</code_context>

<specifics>
## Specific Ideas

From task doc: detailed implementations of _gpu_status and _gpu_assign with nvidia-smi queries and docker inspect for container-GPU mapping.

</specifics>

<deferred>
## Deferred Ideas

- GPU memory limits per container (NVIDIA MPS)
- GPU temperature monitoring in status
- ROCm (AMD) support for gpu status

</deferred>
