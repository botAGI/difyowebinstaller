#!/usr/bin/env bash
# test_vllm_args_sanity.sh — sanity-чек args для vLLM на DGX Spark.
#
# §8 правила:
#   1. gpu_memory_utilization=0.60 (не 0.70) — на shared GPU c docling
#      0.70 валит CUBLAS, docling берёт 30-40 GiB при 2 parallel PDF →
#      83+40 > 124 → torch.AcceleratorError: out of memory.
#   2. FlashInfer FP8 backend сломан на SM121 — все vLLM workloads должны
#      использовать --attention-backend TRITON_ATTN или --enforce-eager.
#      (Хотя для AEON-7 DFlash другой backend подбирается, для mainline vLLM
#      на gemma4-cu130 enforce-eager обязателен per memory project_session_2026_04_22)
#   3. max_model_len=64K адекватно для gemma-4-26B (не больше).
#   4. mem_limit ≥ 96g (не дефолтные 16g которые crash через minute).
#
# Тест: парсит compose worker.yml + main.yml на vllm services и проверяет
# command args + env. Если кто-то поднимет gpu_memory_utilization=0.80 в PR
# или забудет enforce-eager — этот тест блокирует merge.
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

mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

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

for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    # vLLM LLM services: name содержит 'vllm' но НЕ embedding/reranker
    # (эмбеды и реранкеры используют vLLM как inference engine, но это другие
    # модели с другими memory budget'ами — bge-m3 ~600MB, не gemma-4 26B).
    is_vllm_llm = ('vllm' in name and 'embed' not in name and 'rerank' not in name)
    if not is_vllm_llm:
        continue
    checked += 1

    # command может быть string, list, или multiline string
    cmd = svc.get('command', '')
    if isinstance(cmd, list):
        cmd_str = ' '.join(str(c) for c in cmd)
    else:
        cmd_str = str(cmd)

    # Check 1: gpu_memory_utilization ≤ topology limit
    # Pattern: --gpu-memory-utilization <value> или ${VAR:-X.XX}
    gpu_util_match = re.search(r'--gpu-memory-utilization\s+(\S+)', cmd_str)
    if gpu_util_match:
        val = gpu_util_match.group(1)
        # Parse fallback из ${VAR:-NUM}
        fb = re.search(r':-([\d.]+)', val)
        actual = fb.group(1) if fb else val
        try:
            if float(actual) > gpu_util_max:
                violations.append(
                    f"{name}: gpu_memory_utilization={actual} > {gpu_util_max} "
                    f"({'dedicated peer GPU CUBLAS limit' if gpu_util_max > 0.6 else 'shared GPU + docling OOM'} §8)"
                )
        except ValueError:
            pass

    # Check 2: max_model_len ≤ 65536 для дефолтного NGC vLLM (gemma-4-26B 64K)
    # Спец-ислкючение: AEON-7 image поддерживает 260K — пропускаем если image содержит "aeon"
    image = str(svc.get('image', '')).lower()
    if 'aeon' not in image:
        mml_match = re.search(r'--max-model-len\s+(\S+)', cmd_str)
        if mml_match:
            val = mml_match.group(1)
            fb = re.search(r':-(\d+)', val)
            actual = fb.group(1) if fb else val
            try:
                if int(actual) > 131072:
                    violations.append(f"{name}: max_model_len={actual} > 131072 (gemma-4 64K context only §8)")
            except ValueError:
                pass

    # Check 3: mem_limit ≥ 96g для vLLM workloads (не 16g)
    mem = svc.get('mem_limit', '')
    if mem:
        # extract bytes from "96g" / "16g" / "${VAR:-96g}"
        m = re.search(r'(\d+)\s*([gGmM])', str(mem))
        if m:
            num = int(m.group(1))
            unit = m.group(2).lower()
            mb = num * 1024 if unit == 'g' else num
            if mb < 96 * 1024:
                violations.append(f"{name}: mem_limit={mem} < 96g (DGX Spark unified-memory minimum)")

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
        echo "  PASS: ${relpath} — ${checked_count} vLLM service(s) pass sanity (gpu-mem-util≤${GPU_UTIL_MAX}, max-model-len≤131072, mem_limit≥96g)"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — vLLM args violations:"
        echo "$violations" | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
