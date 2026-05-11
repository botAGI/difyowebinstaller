#!/usr/bin/env bash
# test_dify_chunk_structure_enum.sh — §8 правило про knowledge-index ноды.
#
# > knowledge-index node `chunk_structure` — enum из 3 значений, не произвольная
# > строка: `text_model` (flat paragraphs), `qa_model` (QA pairs),
# > `hierarchical_model` (parent-child). Любое другое значение (`general_model`,
# > `paragraph_model`, etc) → runtime ValueError: Index type X is not supported
# > в IndexProcessorFactory. Pipeline FAIL'ит на knowledgeBase ноде с 0 tokens.
#
# Тест: все pipeline DSL в pipelines/ с knowledge-index / knowledge-base нодами
# имеют `chunk_structure` ∈ {text_model, qa_model, hierarchical_model}.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PIPELINES_DIR="${REPO_ROOT}/pipelines"

if [[ ! -d "$PIPELINES_DIR" ]]; then
    echo "SKIP: ${PIPELINES_DIR} not found"
    exit 77
fi

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_dify_chunk_structure_enum"

fail=0
pass=0

ALLOWED="text_model qa_model hierarchical_model"

mapfile -t dsl_files < <(find "$PIPELINES_DIR" -type f \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | sort)

found_any_index_node=0

for f in "${dsl_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    result="$(python3 - "$f" "$ALLOWED" <<'PY'
import sys, yaml

path = sys.argv[1]
allowed = set(sys.argv[2].split())

try:
    data = yaml.safe_load(open(path))
except Exception:
    sys.exit(0)  # not valid yaml — другой тест поймает

if not isinstance(data, dict):
    sys.exit(0)

# Найти все ноды в workflow.graph.nodes
workflow = data.get('workflow', {})
if not isinstance(workflow, dict):
    sys.exit(0)
graph = workflow.get('graph', {})
if not isinstance(graph, dict):
    sys.exit(0)
nodes = graph.get('nodes', [])
if not isinstance(nodes, list):
    sys.exit(0)

violations = []
index_nodes_found = 0

for node in nodes:
    if not isinstance(node, dict):
        continue
    ndata = node.get('data', {})
    if not isinstance(ndata, dict):
        continue
    ntype = ndata.get('type', '')
    # knowledge-index / knowledge-base / knowledge-retrieval node types
    if ntype not in ('knowledge-index', 'knowledge-base', 'knowledgeBase'):
        continue
    index_nodes_found += 1
    # chunk_structure может быть напрямую в data, либо вложен
    cs = ndata.get('chunk_structure')
    if cs is None:
        # check nested under index_chunk_variable_selector / chunk_settings
        for k in ('chunk_settings', 'index_settings'):
            sub = ndata.get(k, {})
            if isinstance(sub, dict) and 'chunk_structure' in sub:
                cs = sub['chunk_structure']
                break
    if cs is None:
        # node без chunk_structure — может быть OK (retrieval node)
        continue
    if cs not in allowed:
        nid = node.get('id', '?')
        violations.append(f"node {nid} (type={ntype}): chunk_structure={cs!r} not in {sorted(allowed)}")

print(f"INDEX_NODES={index_nodes_found}")
for v in violations:
    print(v)
PY
)"

    idx_count="$(echo "$result" | grep '^INDEX_NODES=' | cut -d'=' -f2)"
    violations="$(echo "$result" | grep -v '^INDEX_NODES=' | grep -v '^$' || true)"

    if [[ "${idx_count:-0}" -gt 0 ]]; then
        found_any_index_node=1
    fi

    if [[ -n "$violations" ]]; then
        echo "  FAIL: ${relpath} — invalid chunk_structure (IndexProcessorFactory ValueError §8):"
        echo "$violations" | sed 's/^/        /'
        fail=$((fail+1))
    elif [[ "${idx_count:-0}" -gt 0 ]]; then
        echo "  PASS: ${relpath} — ${idx_count} knowledge-index node(s), chunk_structure valid"
        pass=$((pass+1))
    fi
done

if [[ "$found_any_index_node" -eq 0 ]]; then
    echo "  PASS: no knowledge-index nodes in any pipeline (nothing to check)"
    pass=$((pass+1))
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
