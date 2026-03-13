# Dify Workflow API Reference (v1.13.0)

## Auth

Пароль при логине передаётся в **Base64** (не RSA).  
Все POST/PUT/DELETE требуют **CSRF токен** (Cookie + X-CSRF-Token).

### Login
```bash
B64PASS=$(echo -n 'password' | base64)
curl -sv http://localhost/console/api/login -X POST \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@admin.com","password":"'$B64PASS'"}'
# Ответ: Set-Cookie: access_token=...; csrf_token=...
```

### Auth headers для всех запросов
```
Cookie: access_token=$TOKEN; csrf_token=$CSRF
X-CSRF-Token: $CSRF
```

## Datasets (Knowledge Base) API

### Create KB
```bash
POST /console/api/datasets
{"name":"Documents","indexing_technique":"high_quality","permission":"all_team_members"}
# Ответ: {"id":"uuid-kb-id",...}
```

### Upload document to KB
```bash
POST /console/api/datasets/{dataset_id}/document/create-by-file
Content-Type: multipart/form-data
file=@document.pdf
data={"indexing_technique":"high_quality","process_rule":{"mode":"automatic"}}
```

### Service API (альтернативный endpoint)
```bash
POST /v1/datasets/{dataset_id}/document/create_by_file
Authorization: Bearer {api_key}
```

## Apps API

### Create app
```bash
POST /console/api/apps
{"name":"RAG Bot","mode":"advanced-chat","icon_type":"emoji","icon":"📚","icon_background":"#E4FBCC"}
# mode: "advanced-chat" = Chatflow, "workflow" = Workflow
```

## Workflow Draft API

### Get current draft
```bash
GET /console/api/apps/{app_id}/workflows/draft
# Ответ: {"id":"...","graph":{"nodes":[...],"edges":[...]},"features":{...},"hash":"..."}
```

### Update draft (SyncDraftWorkflowPayload)
```bash
POST /console/api/apps/{app_id}/workflows/draft
{
  "graph": {"nodes": [...], "edges": [...]},
  "features": {...},
  "hash": "<текущий hash из GET>"  // ОБЯЗАТЕЛЬНО! Иначе 409 draft_workflow_not_sync
}
```

### Publish workflow
```bash
POST /console/api/apps/{app_id}/workflows/publish
{}
# Ответ: {"result":"success","created_at":...}
```

## Node Types

### start
```json
{"type":"start","title":"Начало","variables":[]}
```
File upload настраивается через features.file_upload, не через start node.

### if-else
```json
{
  "type":"if-else",
  "title":"Условие",
  "cases":[{
    "id":"case_id",
    "case_id":"case_id",
    "logical_operator":"and",
    "conditions":[{
      "id":"cond1",
      "varType":"array[file]",
      "variable_selector":["sys","files"],
      "comparison_operator":"not empty",
      "value":""
    }]
  }]
}
```
Edge sourceHandle: case_id для true ветки, "false" для else.

### knowledge-retrieval
```json
{
  "type":"knowledge-retrieval",
  "title":"Поиск",
  "query_variable_selector":["sys","query"],
  "dataset_ids":["kb-uuid"],
  "retrieval_mode":"multiple",
  "multiple_retrieval_config":{
    "top_k":5,
    "score_threshold":0.3,
    "reranking_enable":false
  }
}
```
Output: {node_id}.result — передаётся в LLM context.

### llm
```json
{
  "type":"llm",
  "model":{
    "provider":"langgenius/ollama/ollama",
    "name":"qwen2.5:14b",
    "mode":"chat",
    "completion_params":{"temperature":0.1,"num_predict":2048}
  },
  "prompt_template":[
    {"role":"system","text":"Системный промпт\n\nКонтекст:\n{{#context#}}"},
    {"role":"user","text":"{{#sys.query#}}"}
  ],
  "context":{
    "enabled":true,
    "variable_selector":["kb_node_id","result"]
  },
  "memory":{"window":{"enabled":true,"size":10}}
}
```
Output: {node_id}.text

### answer
```json
{
  "type":"answer",
  "title":"Ответ",
  "answer":"{{#llm_node_id.text#}}"
}
```

## Edges
```json
{
  "id":"unique-edge-id",
  "source":"source_node_id",
  "sourceHandle":"source",  // или case_id для if-else
  "target":"target_node_id",
  "targetHandle":"target",
  "type":"custom",
  "data":{"sourceType":"start","targetType":"if-else"}
}
```

## Features
```json
{
  "file_upload":{
    "enabled":true,
    "allowed_file_types":["document"],
    "allowed_file_extensions":[".pdf",".doc",".docx",".txt",".csv",".xlsx",".md"],
    "number_limits":5
  },
  "opening_statement":"Приветствие",
  "citation":{"enabled":true},
  "retriever_resource":{"enabled":true},
  "suggested_questions_after_answer":{"enabled":true}
}
```

## Важные нюансы

1. **hash обязателен** при POST draft — получить из GET draft, иначе 409
2. **Node ID** — произвольная строка, но должна быть уникальной
3. **Variable references** в промптах: `{{#node_id.field#}}`, системные: `{{#sys.query#}}`, `{{#sys.files#}}`
4. **Context template** в LLM: `{{#context#}}` — подставляет результат KB retrieval
5. **Edge sourceHandle** для if-else: case_id (true ветка) или "false" (else)
