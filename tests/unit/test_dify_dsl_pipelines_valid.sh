#!/usr/bin/env bash
# test_dify_dsl_pipelines_valid.sh — статическая валидация всех Dify DSL
# в pipelines/. Pipelines stash — конкурентное преимущество (memory
# project_pipeline_templates_stash), битый DSL = сломанный продукт у клиента.
#
# Контракт DSL (Dify 0.6.0+, ref `feedback_dify_dsl_format_validation.md`):
#   - root keys: app, kind, version, workflow (для workflow-modes)
#   - kind: "app"
#   - app.mode ∈ {chat, advanced-chat, workflow, completion, agent-chat}
#   - app.name (non-empty string)
#   - version: semver-like
#   - если workflow-mode — workflow.graph c nodes/edges (не обязательно
#     валидируем глубже — Dify сам проверит при import_app)
#
# Бажные DSL раньше валидировались только при попытке import_app() в
# agmind-api (см. memory feedback_dify_dsl_format_validation). Этот тест
# ловит большинство bug'ов на CI до push.
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

echo "## test_dify_dsl_pipelines_valid"

fail=0
pass=0

mapfile -t dsl_files < <(find "$PIPELINES_DIR" -type f \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | sort)

if [[ ${#dsl_files[@]} -eq 0 ]]; then
    echo "  SKIP: no DSL files in pipelines/"
    exit 77
fi

# Allowed app modes — из core/api/services/app_dsl_service.py Dify upstream
ALLOWED_MODES="chat advanced-chat workflow completion agent-chat"

for f in "${dsl_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    # Skip non-DSL files (e.g. README, dependencies, config json)
    # Heuristic: DSL файлы имеют root key "app" + "kind: app".
    is_dsl="$(python3 - "$f" <<'PY' 2>/dev/null
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1]))
    if isinstance(d, dict) and d.get('kind') == 'app' and 'app' in d:
        print('yes')
except Exception:
    pass
PY
)"
    if [[ "$is_dsl" != "yes" ]]; then
        continue  # quietly skip non-DSL YAML
    fi

    # Schema validation — collect all violations in one pass
    result="$(python3 - "$f" "$ALLOWED_MODES" <<'PY' 2>&1
import sys, yaml

path = sys.argv[1]
allowed = sys.argv[2].split()

errors = []

try:
    data = yaml.safe_load(open(path))
except Exception as e:
    print(f"YAML parse error: {e}")
    sys.exit(1)

if not isinstance(data, dict):
    errors.append("root is not a mapping")

# kind
if data.get('kind') != 'app':
    errors.append(f"kind must be 'app' (got {data.get('kind')!r})")

# version present
if 'version' not in data:
    errors.append("missing 'version' field")

# app block
app = data.get('app', {})
if not isinstance(app, dict):
    errors.append("'app' is not a mapping")
else:
    name = app.get('name')
    if not name or not isinstance(name, str):
        errors.append(f"app.name missing or not string (got {name!r})")
    mode = app.get('mode')
    if mode not in allowed:
        errors.append(f"app.mode {mode!r} not in {allowed}")

# workflow modes должны иметь workflow.graph
mode = app.get('mode') if isinstance(app, dict) else None
if mode in ('workflow', 'advanced-chat', 'agent-chat'):
    workflow = data.get('workflow')
    if not isinstance(workflow, dict):
        errors.append(f"mode={mode} requires top-level 'workflow' mapping")
    else:
        graph = workflow.get('graph')
        if not isinstance(graph, dict):
            errors.append(f"mode={mode} requires workflow.graph mapping")
        else:
            nodes = graph.get('nodes')
            if not isinstance(nodes, list) or len(nodes) == 0:
                errors.append("workflow.graph.nodes must be non-empty list")

if errors:
    for e in errors:
        print(e)
    sys.exit(1)

sys.exit(0)
PY
)"
    rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  PASS: ${relpath}"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath}"
        echo "$result" | head -10 | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
