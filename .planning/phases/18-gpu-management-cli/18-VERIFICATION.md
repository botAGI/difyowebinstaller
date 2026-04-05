---
phase: 18-gpu-management-cli
verified: 2026-03-23T00:13:57Z
status: human_needed
score: 4/4 must-haves verified
re_verification: false
human_verification:
  - test: "Run agmind gpu assign vllm 1 then verify agmind gpu status reflects GPU 1 for vLLM"
    expected: "VLLM_CUDA_DEVICE=1 written to docker/.env; agmind gpu status shows 'vLLM -> GPU 1'; after sudo agmind restart, container uses GPU 1"
    why_human: "Requires live NVIDIA GPU server with vLLM running; cannot verify container GPU binding without nvidia-smi and actual docker containers"
  - test: "Run agmind gpu assign --auto on a 2-GPU server"
    expected: "vLLM assigned to GPU with largest free VRAM, TEI to GPU with smallest; both VLLM_CUDA_DEVICE and TEI_CUDA_DEVICE written to .env; restart instruction printed"
    why_human: "Requires multi-GPU server; cannot simulate nvidia-smi output in static analysis"
  - test: "Run agmind gpu assign --auto on a single-GPU server"
    expected: "Both VLLM_CUDA_DEVICE=0 and TEI_CUDA_DEVICE=0 written to .env; message 'Single GPU detected, all services on GPU 0' displayed; restart instruction printed"
    why_human: "Requires physical server with exactly one GPU"
  - test: "Verify ROADMAP SC-2 auto-restart intent: does 'gpu assign' need to auto-restart the affected container?"
    expected: "ROADMAP SC-2 says 'перезапускает vLLM контейнер' but PLAN must_haves say 'prints restart instruction'. Confirm with operator which behavior is correct."
    why_human: "Policy decision — PLAN explicitly chose manual restart (prints instruction). ROADMAP wording may be aspirational. Human must confirm intent."
---

# Phase 18: GPU Management CLI Verification Report

**Phase Goal:** Оператор управляет распределением GPU между контейнерами через CLI — agmind gpu status показывает текущее состояние, agmind gpu assign назначает GPU сервису через .env, docker-compose использует env-переменные вместо hardcoded "0".
**Verified:** 2026-03-23T00:13:57Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (from PLAN must_haves)

| #  | Truth                                                                                                    | Status     | Evidence                                                                                                          |
|----|----------------------------------------------------------------------------------------------------------|------------|-------------------------------------------------------------------------------------------------------------------|
| 1  | agmind gpu status shows per-GPU name, total VRAM, free VRAM, utilization %, and assigned containers     | VERIFIED   | `_gpu_status()` at line 410: nvidia-smi query for name/total/used/free/utilization; reads VLLM_CUDA_DEVICE / TEI_CUDA_DEVICE from .env and shows container assignments |
| 2  | agmind gpu assign vllm 1 writes VLLM_CUDA_DEVICE=1 to .env and prints restart instruction               | VERIFIED   | `_gpu_assign()` at line 535: validates service, maps to env var, calls `_set_env_var`, echoes "Restart required: sudo agmind restart" (line 585) |
| 3  | agmind gpu assign --auto distributes vLLM to biggest GPU, TEI to smallest on multi-GPU; single GPU sets both to 0 | VERIFIED   | `_gpu_auto_assign()` at line 480: single-GPU path sets both to "0" (lines 496-497); multi-GPU path computes biggest/smallest free VRAM (lines 504-527); tie-break 0/1 when equal |
| 4  | docker-compose.yml uses env var substitution for CUDA_VISIBLE_DEVICES on vLLM and TEI services          | VERIFIED   | Line 320: `CUDA_VISIBLE_DEVICES=${VLLM_CUDA_DEVICE:-0}`; line 352: `CUDA_VISIBLE_DEVICES=${TEI_CUDA_DEVICE:-0}`; zero hardcoded "=0" values remain (confirmed by grep count) |

**Score:** 4/4 truths verified

### Required Artifacts

| Artifact                        | Expected                                               | Status      | Details                                                                                                     |
|---------------------------------|--------------------------------------------------------|-------------|-------------------------------------------------------------------------------------------------------------|
| `templates/docker-compose.yml`  | Env var substitution for CUDA_VISIBLE_DEVICES          | VERIFIED    | Lines 320, 352 use `${VLLM_CUDA_DEVICE:-0}` / `${TEI_CUDA_DEVICE:-0}`; total 2 CUDA_VISIBLE_DEVICES occurrences, 0 hardcoded "=0" |
| `scripts/agmind.sh`             | cmd_gpu dispatcher, _gpu_status, _gpu_assign, _gpu_auto_assign, _set_env_var | VERIFIED | All 5 functions present and substantive; syntax check passes (`bash -n`); 212 lines added in commit 0963f63 |

### Key Link Verification

| From                                   | To                       | Via                                      | Status  | Details                                                                                      |
|----------------------------------------|--------------------------|------------------------------------------|---------|----------------------------------------------------------------------------------------------|
| `scripts/agmind.sh _gpu_assign`        | `docker/.env`            | `_set_env_var` (sed/echo)                | WIRED   | `_set_env_var "$env_var" "$gpu_id"` at line 582; `_set_env_var` uses `LC_ALL=C sed -i` or `echo >>` |
| `templates/docker-compose.yml`         | `docker/.env`            | Docker Compose env var substitution      | WIRED   | `${VLLM_CUDA_DEVICE:-0}` / `${TEI_CUDA_DEVICE:-0}` syntax correctly references .env vars; default "0" is backward-compatible |
| `scripts/agmind.sh dispatch`           | `cmd_gpu`                | `case` statement `gpu)` branch           | WIRED   | Line 654: `gpu) shift; cmd_gpu "$@" ;;` — confirmed in main dispatch case block |
| `scripts/agmind.sh cmd_gpu`            | `_gpu_status / _gpu_assign` | `case` statement in `cmd_gpu()`       | WIRED   | Lines 591-596: `status) _gpu_status ;;` and `assign) _gpu_assign "$@" ;;`                  |
| `scripts/agmind.sh _gpu_assign`        | `_gpu_auto_assign`       | `[[ "$service" == "--auto" ]]` branch    | WIRED   | Lines 541-544: `--auto` branch calls `_gpu_auto_assign; return $?`                          |

### Requirements Coverage

| Requirement | Source Plan  | Description                                                                                                          | Status    | Evidence                                                                                             |
|-------------|--------------|----------------------------------------------------------------------------------------------------------------------|-----------|------------------------------------------------------------------------------------------------------|
| GPUM-01     | 18-01-PLAN   | `agmind gpu status` показывает per-GPU name/VRAM/free, привязанные контейнеры, GPU processes                        | SATISFIED | `_gpu_status()`: nvidia-smi query (name/total/used/free/utilization), container assignments via `_read_env`, GPU compute processes via `--query-compute-apps` |
| GPUM-02     | 18-01-PLAN   | `agmind gpu assign <service> <gpu_id>` назначает GPU через .env + `--auto` для multi-GPU auto-distribute            | SATISFIED | `_gpu_assign()` + `_gpu_auto_assign()`: manual assign with validation + auto-distribution logic; `_set_env_var()` writes to .env |
| GPUM-03     | 18-01-PLAN   | docker-compose.yml использует `${VLLM_CUDA_DEVICE:-0}` / `${TEI_CUDA_DEVICE:-0}` вместо hardcoded "0"             | SATISFIED | Task 1 acceptance criteria fully pass: vllm=1 tei=1 hardcoded=0 total=2                             |

No orphaned requirements — all three GPUM-01..03 are covered by 18-01-PLAN.

### Anti-Patterns Found

| File                   | Line | Pattern | Severity | Impact                          |
|------------------------|------|---------|----------|---------------------------------|
| No anti-patterns found |  —   |  —      |  —       | No stubs, TODOs, or empty impls |

Scanned: `scripts/agmind.sh`, `templates/docker-compose.yml` — no TODO/FIXME/PLACEHOLDER/XXX, no empty return stubs.

### Human Verification Required

#### 1. Live nvidia-smi Output (agmind gpu status)

**Test:** On a server with at least one NVIDIA GPU, run `agmind gpu status`
**Expected:** Table shows GPU index, name (e.g., "NVIDIA RTX 4090"), total VRAM (e.g., 24576 MiB), free VRAM, and utilization %. Container Assignments section shows VLLM_CUDA_DEVICE and TEI_CUDA_DEVICE values from .env. GPU Processes section lists any running CUDA processes.
**Why human:** Requires live nvidia-smi; cannot mock GPU hardware in static analysis.

#### 2. agmind gpu assign vllm 1 on a 2-GPU server

**Test:** On a 2-GPU server with an installed AGMind stack (docker/.env exists), run `sudo agmind gpu assign vllm 1`
**Expected:** `VLLM_CUDA_DEVICE=1` appears in `docker/.env`; message "Set VLLM_CUDA_DEVICE=1 in /opt/agmind/docker/.env" printed in green; "Restart required: sudo agmind restart" printed in yellow. After running `sudo agmind restart`, `nvidia-smi` shows the vLLM process on GPU 1.
**Why human:** Requires physical multi-GPU server, running vLLM container, and docker/.env present.

#### 3. agmind gpu assign --auto (multi-GPU)

**Test:** On a server with 2+ GPUs, run `sudo agmind gpu assign --auto`
**Expected:** Both VLLM_CUDA_DEVICE and TEI_CUDA_DEVICE written to .env. vLLM assigned to GPU with most free VRAM, TEI to GPU with least. Output shows "Auto-assigned: vLLM -> GPU N (X MiB free), TEI -> GPU M (Y MiB free)".
**Why human:** Requires multi-GPU hardware.

#### 4. Confirm ROADMAP SC-2 auto-restart intent

**Test:** Manually review whether `agmind gpu assign` should auto-restart the affected container or just print a restart instruction.
**Expected:** ROADMAP SC-2 says "перезапускает vLLM контейнер" (restarts the container). The PLAN must_haves deliberately chose "prints restart instruction" instead (operator decides when to restart to avoid disrupting ongoing inference). Confirm which behavior is acceptable.
**Why human:** This is a deliberate design decision documented in PLAN must_haves. The ROADMAP text may be aspirational/imprecise. A human must decide if the "print instruction" approach fully satisfies the requirement, or if auto-restart is needed.

### Gaps Summary

No automated gaps found. All four must-have truths are verified:

- `_gpu_status()` is fully implemented with all required fields (name, VRAM total/used/free, utilization %, container assignments from .env, GPU processes).
- `_gpu_assign()` correctly validates service names (vllm/tei/xinference), validates GPU ID as a number, validates GPU ID against actual GPU count (via nvidia-smi), and writes to .env via `_set_env_var`.
- `_gpu_auto_assign()` handles the single-GPU path (both to 0) and multi-GPU path (biggest/smallest free VRAM) with a tie-break for equal VRAM.
- `templates/docker-compose.yml` uses `${VLLM_CUDA_DEVICE:-0}` and `${TEI_CUDA_DEVICE:-0}` with zero hardcoded values remaining.
- The `gpu)` dispatch branch is correctly placed in the main case statement at line 654.
- Help text is present at lines 615-618.
- `bash -n` passes — no syntax errors.
- Both commits (27295ee, 0963f63) exist in git history and match what was planned.

The one open question is behavioral policy (ROADMAP SC-2 says "restarts container" but PLAN chose "print instruction"). This cannot be resolved by static analysis — it requires human confirmation.

---

_Verified: 2026-03-23T00:13:57Z_
_Verifier: Claude (gsd-verifier)_
