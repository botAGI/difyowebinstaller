# AGmind v2.0 — Roadmap

> Принцип: установщик поднимает инфраструктуру и защищает её. Настройка AI — в руках пользователя через Dify UI.

---

## Фаза 0: Хирургия — убрать лишнее

### 0.1 Удалить import.py и всё связанное
- Удалить `workflows/import.py` полностью
- Удалить `phase_workflow` из `install.sh`
- Удалить `phase_connectivity` (зависит от import)
- Оставить `workflows/rag-assistant.json` как **шаблон** + README с инструкцией "Import DSL через Dify UI"
- Убрать из визарда: `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `COMPANY_NAME` — больше не нужны для автоматизации
- Убрать `setup_account()`, `login()`, CSRF-танцы, `save_api_key()`
- Установка: **9 фаз** вместо 11
- **Результат:** ~500 строк кода удалено, 50% багов исчезают

### 0.2 Убрать live download плагинов с GitHub
- Сейчас: `build_difypkg_from_github()` тянет код с GitHub без проверки подписи
- Плагины теперь устанавливает **пользователь** через Dify UI Marketplace (или CLI)
- Документация: README с командами/ссылками на нужные плагины
- **Результат:** убрана RCE-поверхность через подмену upstream

---

## Фаза 1: Security — закрыть дыры

### 1.1 🔴 Portainer/Grafana — bind 127.0.0.1
- **Проблема:** LAN/VPN/offline профили биндят на `0.0.0.0`. Portainer = docker.sock = root на хосте
- **Фикс:** по умолчанию `127.0.0.1:9443` и `127.0.0.1:3001`
- Визард: "Открыть Portainer/Grafana в сеть? [no/yes]" — явный opt-in
- VPS профиль: Portainer вообще выключен по умолчанию
- Файлы: `templates/env.*.template`, `templates/docker-compose.yml:867`

### 1.2 🔴 Authelia 2FA — покрыть весь Dify surface
- **Проблема:** часть маршрутов Dify не закрыта auth, можно обойти
- **Фикс:** auth на все location блоки Dify (`/console/api/`, `/api/`, `/v1/`, `/files/`)
- Проверить: `/console/api/setup`, `/console/api/login` — единственные исключения
- Файлы: `templates/authelia/configuration.yml.template:28`, `templates/nginx.conf.template:145`

### 1.3 🔴 Credentials в summary — убрать из терминала
- **Проблема:** `bc31c8c` печатает пароли в stdout — попадают в логи, скрины, CI output
- **Фикс:** credentials ТОЛЬКО в `credentials.txt` (chmod 600). В терминале — путь к файлу
- Баннер: `cat /opt/agmind/credentials.txt` — пользователь сам откроет

### 1.4 🟡 SSRF Sandbox — запретить приватные адреса
- **Проблема:** Squid не блокирует internal/metadata IP (169.254.x.x, 10.x.x.x, link-local)
- **Фикс:** ACL deny для RFC1918 + link-local + cloud metadata (169.254.169.254)
- Или: `network_mode: none` для sandbox по умолчанию (Dify сама так рекомендует)
- Файл: `install.sh:788`, squid config

### 1.5 🟡 Fail2ban — починить или убрать
- **Проблема:** смотрит в host path nginx лога, которого нет (логи в Docker)
- **Фикс А:** монтировать nginx access.log на хост + правильный jail
- **Фикс Б:** убрать Fail2ban, заменить на rate limiting в nginx (`limit_req_zone`)
- Файлы: `lib/security.sh:80`, `templates/nginx.conf.template:46`

### 1.6 🟡 Backup/Restore — починить
- **Проблема:** remote backup не включается, restore удаляет .age в source dir
- **Фикс:** restore через tmpdir копию, parser флагов починить
- Тест: backup → destroy → restore → verify
- Файлы: `lib/backup.sh:30`, `scripts/backup.sh:32`, `scripts/restore.sh:84`

---

## Фаза 2: Архитектура провайдеров

### 2.1 Визард: выбор LLM провайдера
```
Выберите LLM провайдер:
  1) Ollama     — локальный, dev/пилот (1-3 юзера)
  2) vLLM       — локальный, прод (10-30+ юзеров, GPU batching)
  3) External   — внешний API (OpenAI/Anthropic/любой OpenAI-compatible)
  4) Skip       — настрою позже в Dify UI
```

### 2.2 Compose-профили по выбору
- `ollama` → контейнер `ollama/ollama` + sysctls + GODEBUG
- `vllm` → контейнер `vllm/vllm-openai` + GPU passthrough + model preload
- `external` → без LLM контейнера, только Dify + infra
- `skip` → без LLM контейнера, плагины не ставятся

### 2.3 Embedding провайдер отдельно
```
Выберите Embedding провайдер:
  1) Ollama     — bge-m3 через Ollama (dev)
  2) TEI        — HuggingFace Text Embeddings Inference (прод, батчинг)
  3) External   — внешний API
  4) Same as LLM — использовать тот же провайдер
```

### 2.4 Плагины — документация вместо автоустановки
- README: какие плагины ставить для каждого провайдера
- `ollama` → langgenius/ollama
- `vllm` / `external` → langgenius/openai_api_compatible
- `xinference` → langgenius/xinference (если reranker)
- `docling` → s20ss/docling (если ETL enhanced)

---

## Фаза 3: DevOps & UX

### 3.1 `agmind status`
Одна команда — полная картина:
- Контейнеры: up/down/unhealthy
- GPU: utilization, VRAM
- Модели: загружены/нет
- Endpoints: HTTP check каждого сервиса
- Credentials: путь к файлу

### 3.2 `agmind doctor`
Диагностика перед/после установки:
- DNS резолвинг (IPv4/IPv6)
- GPU driver + CUDA
- Docker version compatibility
- Port conflicts
- Disk space
- Network: can reach registry.ollama.ai / HuggingFace

### 3.3 Non-interactive режим
- `config.yaml` или env vars — полный набор параметров
- CI/CD ready: `sudo bash install.sh --config production.yaml`
- Idempotent: повторный запуск не ломает существующую установку

---

## Фаза 4: Production hardening

### 4.1 TLS из коробки
- LAN: self-signed с mkcert (trust на уровне хоста)
- VPS: Caddy/Traefik + Let's Encrypt auto-cert
- Визард: `TLS: [auto/self-signed/manual/none]`

### 4.2 Мониторинг v2
- cAdvisor → Victoria Metrics (легче Prometheus для single-node)
- GPU мониторинг: nvidia-smi exporter
- vLLM metrics: встроенный Prometheus endpoint
- Алерты: disk >80%, GPU OOM, container restart loop

### 4.3 Update mechanism
- `agmind update` — обновить Dify + сервисы без потери данных
- Миграция между провайдерами: `agmind switch-provider vllm`
- Changelog / breaking changes warning

---

## Порядок выполнения

```
Фаза 0 ──→ Фаза 1.1-1.3 ──→ Фаза 2.1-2.2 ──→ Деплой-тест ──→ Фаза 1.4-1.6
  (1 день)    (2 дня)           (2-3 дня)        (1 день)         (2 дня)
                                                      │
                                                      ↓
                                              Фаза 2.3-2.4 ──→ Фаза 3 ──→ Фаза 4
                                                (1 день)        (2 дня)    (ongoing)
```

**MVP (Фазы 0-2):** ~1-2 недели кодинга
**Production-ready (Фазы 0-3):** ~2-3 недели
**Полный цикл:** ongoing, по мере роста нагрузки

---

_Создан: 2026-03-17 — Gbot + Сэр_
