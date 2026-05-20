#!/usr/bin/env bash
# AGmind vLLM entrypoint wrapper.
#
# Purpose
# -------
# Build the `vllm serve` argv vector as a bash ARRAY before exec, so any
# argument that contains shell metacharacters (single quotes, JSON braces,
# whitespace) survives intact instead of being mangled by docker compose's
# shlex-style word-splitting on a folded YAML `command:` scalar.
#
# Why this exists
# ---------------
# The previous attempt put DFlash JSON into `--speculative-config` as either
# inline JSON or a path-to-file. Both failed:
#
#   1. Inline JSON via `command: >- ...` was shlex-split by docker compose
#      after `${VLLM_EXTRA_ARGS}` env substitution, stripping the inner
#      double-quotes and leaving `{method:dflash}` (invalid).
#
#   2. Plain path `--speculative-config /etc/vllm/dflash.json` was rejected
#      by vLLM's argparse because `--speculative-config` has `type=json.loads`
#      — it parses the VALUE as JSON, not as a path. There's no fromfile
#      prefix opt-in. The path string itself was passed to json.loads and
#      failed with "Value /etc/vllm/dflash.json cannot be converted".
#
# Solution
# --------
# All vLLM arguments are now passed via environment variables and assembled
# into a bash array here. `exec vllm serve "${args[@]}"` preserves each
# array element as one argv slot — JSON, quotes, spaces all survive.
#
# Required env (set by wizard, passed to container via compose environment):
#   VLLM_MODEL                — model identifier (HF repo or local path)
#
# Optional env (with sane defaults):
#   VLLM_GPU_MEM_UTIL         — default 0.60 (shared-GPU safe on GB10)
#   VLLM_MAX_MODEL_LEN        — default 65536 (64K context)
#   VLLM_CMD_PREFIX           — bare positional args before flags (rare)
#   VLLM_EXTRA_ARGS           — additional flags, word-split (no JSON inside)
#   VLLM_SPECULATIVE_CONFIG   — inline JSON for DFlash/MTP speculative
#   VLLM_ROPE_SCALING_CONFIG  — inline JSON for YaRN rope scaling (1M ctx)
#   VLLM_RUNNER               — runner mode (e.g. "pooling" for embed/rerank)
#
# References
# ----------
# - docs/adr/0005-driver-580-hold.md (GB10 driver 580 constraint)
# - LANDMINES.md "vLLM CLI: --speculative-config is JSON, not path"

set -euo pipefail

args=()

# Optional prefix (rare — overrides vllm CMD; word-split intentional)
if [[ -n "${VLLM_CMD_PREFIX:-}" ]]; then
    # shellcheck disable=SC2206  # word-split intentional
    args+=( ${VLLM_CMD_PREFIX} )
fi

# Required model + host/port
args+=(
    --model "${VLLM_MODEL:?VLLM_MODEL must be set in env}"
    --host  0.0.0.0
    --port  8000
)

# Memory + context
args+=(
    --gpu-memory-utilization "${VLLM_GPU_MEM_UTIL:-0.60}"
    --max-model-len          "${VLLM_MAX_MODEL_LEN:-65536}"
)

# Always-on flags
args+=( --trust-remote-code )

# Extra args from .env — word-split intentional (caller responsibility:
# no embedded JSON or values with whitespace; that's what
# VLLM_SPECULATIVE_CONFIG is for).
if [[ -n "${VLLM_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    args+=( ${VLLM_EXTRA_ARGS} )
fi

# Speculative config — passed as ONE argv element (no shell-split, no shlex).
# JSON survives because it's a single bash array element, not a substring
# of a folded YAML scalar.
if [[ -n "${VLLM_SPECULATIVE_CONFIG:-}" ]]; then
    args+=( --speculative-config "${VLLM_SPECULATIVE_CONFIG}" )
fi

# Rope scaling config (YaRN for 1M context) — same JSON-via-env path as speculative.
if [[ -n "${VLLM_ROPE_SCALING_CONFIG:-}" ]]; then
    args+=( --rope-scaling "${VLLM_ROPE_SCALING_CONFIG}" )
fi

# Runner mode (embed/rerank pooling)
if [[ -n "${VLLM_RUNNER:-}" ]]; then
    args+=( --runner "${VLLM_RUNNER}" )
fi

exec vllm serve "${args[@]}"
