# TASKS.md — Задачи от деплой-агента (Gbot)

> Этот файл обновляется автоматически после каждого тестового деплоя.  
> Кодер: перед началом работы делай `git pull` и читай этот файл.  
> После фикса — коммить и пуш. Gbot подтянет, задеплоит, протестирует, обновит статусы.

---

## Текущий статус: ✅ install.sh exit 0, плагины/модели устанавливаются программно

**Последний тест:** 2026-03-16 16:15 PDT (ручной тест на деплое #8)  
**Сервер:** ragbot@192.168.50.26 (Ubuntu 24.04, Docker 29.3.0, RTX 5070 Ti)  
**Коммит:** 2b97bfe  

---

## 🔴 TASK-010: Полная автоматизация import.py — плагины с GitHub + модели + KB + workflow

**Приоритет:** 🔴 Критический — последний блокер для "из коробки"

### Проблема
import.py пытается скачать плагины из Dify Marketplace (marketplace.dify.ai) → получает HTTP 403 Forbidden. Без плагинов → провайдеры не существуют → модели не добавляются → KB не создаётся → workflow не импортируется.

### Решение (проверено вручную — работает!)

**Источники плагинов (НЕ marketplace):**
- ollama: `github.com/langgenius/dify-official-plugins` → `models/ollama/` → zip в .difypkg
- xinference: `github.com/langgenius/dify-official-plugins` → `models/xinference/` → zip в .difypkg  
- docling: `github.com/langgenius/dify-plugins` → `s20ss/docling_plugin.difypkg` (готовый файл)

**Обязательная настройка .env:**
```
FORCE_VERIFYING_SIGNATURE=false
```
Без этого upload отклоняется с "bad signature". Добавить в шаблон .env (или в generate_env).

**Auth flow (Dify 1.13+):**
```bash
# Login — пароль в base64, токен в COOKIE (не в body!)
PASS_B64=$(echo -n "$PASSWORD" | base64)
COOKIES=$(curl -sf -X POST http://localhost:3000/console/api/login \
  -H "Content-Type: application/json" -c - \
  -d '{"email":"EMAIL","password":"'$PASS_B64'","language":"en-US","remember_me":true}')
TOKEN=$(echo "$COOKIES" | grep access_token | awk '{print $NF}')
CSRF=$(echo "$COOKIES" | grep csrf_token | awk '{print $NF}')

# Все запросы с тройной авторизацией:
-H "Authorization: Bearer $TOKEN"
-H "X-CSRF-Token: $CSRF"
-H "Cookie: access_token=$TOKEN; csrf_token=$CSRF"
```

**Последовательность шагов import.py:**

```
1.  wait_for_api()
2.  init_validate()                    — INIT_PASSWORD base64
3.  setup_account()                    — skip if finished
4.  login()                            — base64 пароль, токен из cookie
5.  build_difypkg(ollama)              — git clone + zip models/ollama
6.  build_difypkg(xinference)          — git clone + zip models/xinference
7.  download_difypkg(docling)          — curl raw GitHub s20ss/docling_plugin.difypkg
8.  upload_plugin(ollama.difypkg)      — POST /plugin/upload/pkg (multipart)
9.  upload_plugin(xinference.difypkg)  — POST /plugin/upload/pkg
10. upload_plugin(docling.difypkg)     — POST /plugin/upload/pkg
11. install_plugin(ollama_id)          — POST /plugin/install/pkg {"plugin_unique_identifiers":[ID]}
12. install_plugin(xinference_id)      — POST /plugin/install/pkg
13. install_plugin(docling_id)         — POST /plugin/install/pkg
14. wait_for_plugins()                 — poll GET /plugin/tasks/{task_id} до status=success
15. add_model(LLM qwen2.5:7b)         — POST /model-providers/langgenius/ollama/ollama/models/credentials
16. add_model(embedding bge-m3)        — POST /model-providers/.../models/credentials
17. set_default(llm)                   — POST /default-model {"model_settings":[]}  ← массив!
18. set_default(text-embedding)        — POST /default-model {"model_settings":[]}
19. create_dataset()                   — теперь сработает (embedding default есть)
20. import_workflow()                  — import JSON
```

### API endpoints (проверены):

**Upload plugin:**
```
POST /console/api/workspaces/current/plugin/upload/pkg
Content-Type: multipart/form-data
-F "pkg=@/path/to/plugin.difypkg"
→ {"unique_identifier": "author/name:version@hash", "manifest": {...}}
```

**Install plugin:**
```
POST /console/api/workspaces/current/plugin/install/pkg
Content-Type: application/json
{"plugin_unique_identifiers": ["author/name:version@hash"]}
→ {"all_installed": false, "task_id": "UUID"}
```

**Poll task:**
```
GET /console/api/workspaces/current/plugin/tasks/{task_id}
→ {"task": {"status": "success|running|failed", "plugins": [...]}}
```

**Add model:**
```
POST /console/api/workspaces/current/model-providers/langgenius/ollama/ollama/models/credentials
{"model":"qwen2.5:7b","model_type":"llm","credentials":{"base_url":"http://ollama:11434","mode":"chat","context_size":"32768","max_tokens":"8192","vision_support":"false","function_call_support":"true"}}
→ {"result": "success"}
```

**Set default:**
```
POST /console/api/workspaces/current/default-model
{"model":"qwen2.5:7b","model_type":"llm","provider":"langgenius/ollama/ollama","model_settings":[]}
→ {"result": "success"}
```

### Сборка .difypkg из исходников:
```bash
# Клонировать (shallow):
git clone --depth 1 https://github.com/langgenius/dify-official-plugins.git /tmp/dify-plugins

# Собрать (только файлы, без директорий):
cd /tmp/dify-plugins/models/ollama
find . -type f | grep -v '.git' | zip /tmp/ollama.difypkg -@

cd /tmp/dify-plugins/models/xinference
find . -type f | grep -v '.git' | zip /tmp/xinference.difypkg -@

# Docling — готовый файл:
curl -sfL "https://raw.githubusercontent.com/langgenius/dify-plugins/main/s20ss/docling_plugin.difypkg" \
  -o /tmp/docling.difypkg
```

### Важные нюансы:
- `zip` должен содержать ТОЛЬКО файлы (не пустые директории) — иначе "is a directory" ошибка
- `FORCE_VERIFYING_SIGNATURE=false` должен быть в .env ДО docker compose up
- `model_settings` в set_default — это массив `[]`, не объект
- Пароль для login — base64 encoded
- Токен в cookie, не в body response
- CSRF обязателен для всех POST запросов
- Docling ставится ~1-2 мин (компиляция Python deps)

---

## ✅ Закрытые задачи

| Задача | Статус | Деплой | Коммит |
|--------|--------|--------|--------|
| ✅ TASK-009: cAdvisor v0.55.1 | Закрыт | #8 | 2b97bfe |
| ✅ TASK-002: cAdvisor name labels | Закрыт | #8 | 2b97bfe |
| ✅ BUG-009–BUG-017 | Закрыты | #3-8 | various |
| ✅ TASK-003,005,007,008 | Закрыты | #4-8 | various |

---

_Обновлено: 2026-03-16 16:20 PDT — Gbot (TASK-010 с полной документацией API)_
