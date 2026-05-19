#!/usr/bin/env bash
# test_vllm_args_sanity.sh — sanity-чек args для vLLM на DGX Spark.
#
# §8 правила (Phase 13 baseline):
#   1. gpu_memory_utilization=0.60 (не 0.70) — на shared GPU c docling
#      0.70 валит CUBLAS, docling берёт 30-40 GiB при 2 parallel PDF →
#      83+40 > 124 → torch.AcceleratorError: out of memory.
#   2. FlashInfer FP8 backend сломан на SM121 — все vLLM workloads должны
#      использовать --attention-backend TRITON_ATTN или --enforce-eager.
#   3. max_model_len ≤ 131072 для дефолтного NGC vLLM (gemma-4-26B); AEON-7
#      разрешает больше.
#   4. mem_limit ≥ 96g (не дефолтные 16g которые crash через minute).
#
# Новые правила (2026-05-18 — vLLM JSON-args regression class):
#   5. JSON-typed vLLM args (--speculative-config, --rope-scaling) НЕ ДОЛЖНЫ
#      передаваться через `command:` в compose как inline JSON — docker
#      compose shlex-strips inner quotes на этапе env-substitution. Они
#      должны прокидываться через dedicated env vars (VLLM_SPECULATIVE_CONFIG,
#      VLLM_ROPE_SCALING_CONFIG) и собираться в argv массивом
#      bash-wrapper'ом templates/vllm-config/entrypoint.sh.
#   6. `--speculative-config <path>` запрещён в wizard.sh — argparse имеет
#      type=json.loads, путь не парсится как JSON. Регрессия от 9dcacb0
#      (2026-05-18) ловится этим чеком.
#   7. compose vllm service должен ссылаться на entrypoint wrapper
#      (agmind-vllm-entrypoint.sh) — без него argv-через-массив не работает.
#
# Тест: парсит compose worker.yml + main.yml + lib/wizard.sh + entrypoint.sh.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_vllm_args_sanity"

fail=0
pass=0

# ------------------------------------------------------------------
# Part 1: per-compose-file sanity (gpu-mem, max-model-len, mem_limit)
# ------------------------------------------------------------------
mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#"${REPO_ROOT}"/}"

    # GPU util limit зависит от топологии (single-node shared GPU ≤0.60, dedicated peer ≤0.70):
    #   worker.yml — peer Spark, dedicated GPU → ≤0.70 (CUBLAS hard limit GB10)
    #   docker-compose.yml — single-node, shared GPU w/ docling → ≤0.60
    if [[ "$relpath" == *"worker"* ]]; then
        GPU_UTIL_MAX="0.70"
    else
        GPU_UTIL_MAX="0.60"
    fi

    result="$(python3 - "$f" "$GPU_UTIL_MAX" <<'PY'
import sys, yaml, re

data = yaml.safe_load(open(sys.argv[1])) or {}
gpu_util_max = float(sys.argv[2])
services = data.get('services', {}) if isinstance(data, dict) else {}

violations = []
checked = 0

def _flatten_args(svc):
    """Collect every arg-bearing source: command (str/list), environment
    (list/dict). Returns one concatenated string for regex scanning."""
    parts = []
    cmd = svc.get('command', '')
    if isinstance(cmd, list):
        parts.append(' '.join(str(c) for c in cmd))
    else:
        parts.append(str(cmd))
    env = svc.get('environment', [])
    if isinstance(env, list):
        parts.extend(str(e) for e in env)
    elif isinstance(env, dict):
        parts.extend(f"{k}={v}" for k, v in env.items())
    return ' '.join(parts)

for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    # vLLM LLM services: name содержит 'vllm' но НЕ embedding/reranker
    is_vllm_llm = ('vllm' in name and 'embed' not in name and 'rerank' not in name)
    if not is_vllm_llm:
        continue
    checked += 1

    args_blob = _flatten_args(svc)

    # Check 1: gpu_memory_utilization ≤ topology limit. Look in both
    # --gpu-memory-utilization (legacy command:) and VLLM_GPU_MEM_UTIL=
    # (entrypoint-wrapper architecture).
    util_patterns = [
        r'--gpu-memory-utilization\s+(\S+)',
        r'VLLM_GPU_MEM_UTIL=(\S+)',
    ]
    util_found = None
    for pat in util_patterns:
        m = re.search(pat, args_blob)
        if m:
            util_found = m.group(1)
            break
    if util_found is not None:
        fb = re.search(r':-([\d.]+)', util_found)
        actual = fb.group(1) if fb else util_found
        try:
            if float(actual) > gpu_util_max:
                violations.append(
                    f"{name}: gpu_memory_utilization={actual} > {gpu_util_max} "
                    f"({'dedicated peer GPU CUBLAS limit' if gpu_util_max > 0.6 else 'shared GPU + docling OOM'} §8)"
                )
        except ValueError:
            pass

    # Check 2: max_model_len ≤ 131072 unless AEON-7 image
    image = str(svc.get('image', '')).lower()
    if 'aeon' not in image:
        mml_patterns = [
            r'--max-model-len\s+(\S+)',
            r'VLLM_MAX_MODEL_LEN=(\S+)',
        ]
        mml_found = None
        for pat in mml_patterns:
            m = re.search(pat, args_blob)
            if m:
                mml_found = m.group(1)
                break
        if mml_found is not None:
            fb = re.search(r':-(\d+)', mml_found)
            actual = fb.group(1) if fb else mml_found
            try:
                if int(actual) > 131072:
                    violations.append(f"{name}: max_model_len={actual} > 131072 (gemma-4 64K context only §8)")
            except ValueError:
                pass

    # Check 3: mem_limit ≥ 96g
    mem = svc.get('mem_limit', '')
    if mem:
        m = re.search(r'(\d+)\s*([gGmM])', str(mem))
        if m:
            num = int(m.group(1))
            unit = m.group(2).lower()
            mb = num * 1024 if unit == 'g' else num
            if mb < 96 * 1024:
                violations.append(f"{name}: mem_limit={mem} < 96g (DGX Spark unified-memory minimum)")

    # Check 4 (NEW 2026-05-18): JSON-typed args MUST NOT appear inside
    # command: as inline values — they get shlex-stripped by compose. Detect
    # legacy patterns and flag.
    cmd_blob = str(svc.get('command', ''))
    if isinstance(svc.get('command'), list):
        cmd_blob = ' '.join(str(c) for c in svc['command'])
    for bad_arg in ('--speculative-config', '--rope-scaling'):
        if bad_arg in cmd_blob:
            violations.append(
                f"{name}: '{bad_arg}' present in `command:` — JSON-typed args must travel via VLLM_*_CONFIG env vars (see templates/vllm-config/entrypoint.sh)"
            )

print(f"CHECKED={checked}")
for v in violations:
    print(v)
PY
)"

    checked_count="$(echo "$result" | grep '^CHECKED=' | cut -d'=' -f2)"
    violations="$(echo "$result" | grep -v '^CHECKED=' | grep -v '^$' || true)"

    if [[ "${checked_count:-0}" -eq 0 ]]; then
        echo "  PASS: ${relpath} — no vLLM services (skip)"
        pass=$((pass+1))
        continue
    fi

    if [[ -z "$violations" ]]; then
        echo "  PASS: ${relpath} — ${checked_count} vLLM service(s) pass sanity (gpu-mem-util≤${GPU_UTIL_MAX}, max-model-len≤131072, mem_limit≥96g, no inline JSON args)"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — vLLM args violations:"
        echo "$violations" | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

# ------------------------------------------------------------------
# Part 2: lib/wizard.sh static analysis (NEW 2026-05-18)
# Regression class: --speculative-config <path> / --rope-scaling <path>
# in VLLM_EXTRA_ARGS assignments. argparse type=json.loads in vLLM
# rejects path-as-value. JSON must travel via dedicated env vars.
# ------------------------------------------------------------------
WIZARD="${REPO_ROOT}/lib/wizard.sh"
if [[ -f "$WIZARD" ]]; then
    if grep -nE '(--speculative-config|--rope-scaling)[[:space:]]+/' "$WIZARD" >/dev/null 2>&1; then
        echo "  FAIL: lib/wizard.sh contains '--speculative-config <path>' or '--rope-scaling <path>':"
        grep -nE '(--speculative-config|--rope-scaling)[[:space:]]+/' "$WIZARD" | sed 's/^/        /'
        echo "        → vLLM argparse has type=json.loads on these args; path is rejected."
        echo "        → Use VLLM_SPECULATIVE_CONFIG / VLLM_ROPE_SCALING_CONFIG env vars."
        fail=$((fail+1))
    else
        echo "  PASS: lib/wizard.sh — no --speculative-config/--rope-scaling path patterns"
        pass=$((pass+1))
    fi

    # Also reject inline JSON inside VLLM_EXTRA_ARGS assignments only —
    # shlex-stripped by compose. We scan ONLY assignment RHS to avoid
    # false-positives on `"${VLLM_EXTRA_ARGS:-}"` reads. JSON marker is
    # `{"` (open brace immediately followed by double-quote) — distinguishes
    # from bash `${VAR}` parameter expansion which has no quote after `{`.
    if awk '
        /VLLM_EXTRA_ARGS=/ {
            # Only flag assignment lines (LHS = VLLM_EXTRA_ARGS=...), not reads
            if ($0 !~ /VLLM_EXTRA_ARGS=["'\'']/) next
            line = $0
            sub(/^[[:space:]]*VLLM_EXTRA_ARGS=/, "", line)
            # Look for JSON object marker: {" (open brace + double quote)
            # which is not produced by bash ${VAR} expansion.
            if (line ~ /\{"/) {
                print FILENAME ":" NR ": " line
                found = 1
            }
        }
        END { exit !found }
    ' "$WIZARD" >/dev/null 2>&1; then
        echo "  FAIL: lib/wizard.sh embeds inline JSON ({\"...\"}) inside VLLM_EXTRA_ARGS:"
        awk '/VLLM_EXTRA_ARGS=["'\'']/ { line = $0; sub(/^[[:space:]]*VLLM_EXTRA_ARGS=/, "", line); if (line ~ /\{"/) print FILENAME ":" NR ": " line }' "$WIZARD" | sed 's/^/        /'
        echo "        → docker compose shlex-strips inner quotes. Use dedicated env vars."
        fail=$((fail+1))
    else
        echo "  PASS: lib/wizard.sh — no inline JSON inside VLLM_EXTRA_ARGS"
        pass=$((pass+1))
    fi
else
    echo "  SKIP: lib/wizard.sh not found"
fi

# ------------------------------------------------------------------
# Part 3: entrypoint wrapper exists + handles both JSON args
# ------------------------------------------------------------------
WRAPPER="${REPO_ROOT}/templates/vllm-config/entrypoint.sh"
if [[ -f "$WRAPPER" ]]; then
    missing=()
    for env_var in VLLM_SPECULATIVE_CONFIG VLLM_ROPE_SCALING_CONFIG VLLM_MODEL; do
        grep -qF "$env_var" "$WRAPPER" || missing+=( "$env_var" )
    done
    if (( ${#missing[@]} )); then
        echo "  FAIL: ${WRAPPER#"${REPO_ROOT}"/} missing env handlers: ${missing[*]}"
        fail=$((fail+1))
    else
        echo "  PASS: entrypoint.sh handles VLLM_SPECULATIVE_CONFIG + VLLM_ROPE_SCALING_CONFIG + VLLM_MODEL"
        pass=$((pass+1))
    fi
    # Repo enforces core.fileMode=false but wrapper must be +x on disk for
    # the bind-mount to be executable inside the container.
    if [[ ! -x "$WRAPPER" ]]; then
        echo "  FAIL: ${WRAPPER#"${REPO_ROOT}"/} is not executable (chmod 0755). git update-index --chmod=+x in case core.fileMode=false."
        fail=$((fail+1))
    else
        echo "  PASS: entrypoint.sh has +x permission"
        pass=$((pass+1))
    fi
else
    echo "  FAIL: ${WRAPPER#"${REPO_ROOT}"/} not found — vLLM JSON args cannot survive compose shlex"
    fail=$((fail+1))
fi

# ------------------------------------------------------------------
# Part 4: lib/peer.sh::_render_worker_env must forward the new env vars
# Regression caught 2026-05-19 fresh-install: master .env had
# VLLM_SPECULATIVE_CONFIG set correctly, but `_render_worker_env` did NOT
# emit it, so peer .env arrived without the variable → vLLM on peer
# started without speculative decoding (speculative_config=None in logs).
# Whitelist must be kept in sync with the entrypoint wrapper.
# ------------------------------------------------------------------
PEER_LIB="${REPO_ROOT}/lib/peer.sh"
if [[ -f "$PEER_LIB" ]]; then
    # Extract _render_worker_env function body
    render_start=$(awk '/^_render_worker_env\(\)/ { print NR; exit }' "$PEER_LIB")
    if [[ -z "$render_start" ]]; then
        echo "  SKIP: lib/peer.sh::_render_worker_env not found"
    else
        render_end=$(awk -v s="$render_start" 'NR > s && /^}$/ { print NR; exit }' "$PEER_LIB")
        if [[ -z "$render_end" ]]; then
            echo "  FAIL: lib/peer.sh::_render_worker_env body not bounded — cannot scan"
            fail=$((fail+1))
        else
            render_body=$(sed -n "${render_start},${render_end}p" "$PEER_LIB")
            for forwarded in VLLM_SPECULATIVE_CONFIG VLLM_ROPE_SCALING_CONFIG; do
                if ! grep -qF "$forwarded" <<<"$render_body"; then
                    echo "  FAIL: lib/peer.sh::_render_worker_env does not forward ${forwarded} to peer .env"
                    echo "         → Master will set it, peer will not see it, JSON args silently dropped."
                    fail=$((fail+1))
                else
                    echo "  PASS: lib/peer.sh::_render_worker_env forwards ${forwarded}"
                    pass=$((pass+1))
                fi
            done
        fi
    fi
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
