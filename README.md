# AGMind Installer

One-command installer for a production-ready AI stack: **Dify + Open WebUI + Ollama/vLLM + vector DB + monitoring** — all in Docker Compose.

[![Lint](https://github.com/botAGI/difyowebinstaller/actions/workflows/lint.yml/badge.svg)](https://github.com/botAGI/difyowebinstaller/actions/workflows/lint.yml)
[![Tests](https://github.com/botAGI/difyowebinstaller/actions/workflows/test.yml/badge.svg)](https://github.com/botAGI/difyowebinstaller/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

## Quick Start

```bash
git clone https://github.com/botAGI/difyowebinstaller.git
cd difyowebinstaller
sudo bash install.sh
```

The interactive wizard guides you through choosing a deploy profile, LLM/embedding provider, model, TLS, and monitoring. After ~5 minutes you get a fully working AI platform with 23-34 containers.

**Non-interactive:**

```bash
sudo DEPLOY_PROFILE=lan LLM_PROVIDER=ollama LLM_MODEL=qwen2.5:14b \
     EMBED_PROVIDER=ollama bash install.sh --non-interactive
```

**After install:**

| Service | URL | Note |
|---------|-----|------|
| Open WebUI (chat) | `http://server/` | Main interface |
| Dify Console | `http://server:3000/` | Workflow management |
| Health endpoint | `http://server/health` | JSON status of all services |
| Grafana | `http://127.0.0.1:3001/` | When `MONITORING_MODE=local` |
| Portainer | `https://127.0.0.1:9443/` | When `MONITORING_MODE=local` |

Admin password: `/opt/agmind/credentials.txt` (chmod 600)

```bash
agmind status          # Stack overview: containers, GPU, models, endpoints
agmind doctor          # Diagnose problems: DNS, GPU, Docker, disk, ports
agmind backup          # Manual backup
agmind help            # All commands
```

---

## Requirements

| Parameter | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu 20.04, Debian 11, CentOS Stream 9 | Ubuntu 22.04+ |
| RAM | 4 GB | 16 GB+ (32 GB for GPU inference) |
| CPU | 2 cores | 4+ cores |
| Disk | 20 GB | 100 GB+ (SSD) |
| Docker | 24.0+ | 27.0+ (installed automatically) |
| Compose | 2.20+ | 2.29+ (installed automatically) |
| GPU (optional) | NVIDIA Pascal+ | Ampere+ (CUDA 12.0+) |

Pre-flight checks run automatically (skip: `SKIP_PREFLIGHT=true`).

---

## Architecture

```
+-----------------------------------------------------------------+
|  Infra Layer (installer)   |  install.sh, lib/*.sh              |
|  -> Deploys and secures infrastructure                          |
+-----------------------------------------------------------------+
|  AI Config Layer (user)    |  Dify UI, Open WebUI               |
|  -> User configures workflows, KB, models via UI                |
+-----------------------------------------------------------------+
|  Operations Layer (CLI)    |  agmind status/doctor/backup/...   |
|  -> Day-2 operations and monitoring                             |
+-----------------------------------------------------------------+
```

The installer **never touches the Dify API** — it doesn't create accounts, import workflows, or install plugins. All AI configuration is done by the user through the UI.

### Services (23-34 containers)

```
+------------------------- agmind-frontend -------------------------+
|                            nginx :80/:443                         |
|                        +--------+--------+                        |
|                   Open WebUI :8080   Dify Web :3000               |
|  Grafana :3001    Portainer :9443                                 |
+-------------------------------------------------------------------+
+------------------------- agmind-backend --------------------------+
|  Dify API :5001    Dify Worker    Plugin Daemon :5002             |
|  PostgreSQL :5432  Redis :6379                                    |
|  Ollama :11434 / vLLM :8000 / TEI :8080                          |
|  Weaviate :8080 / Qdrant :6333    Sandbox :8194                  |
|  Docling :8765     Xinference :9997                               |
|  Prometheus  Alertmanager  cAdvisor  Loki  Promtail  Authelia     |
+-------------------------------------------------------------------+
+------------- ssrf-network ---------------+
|  sandbox  ssrf_proxy :3128  api  worker  |
+------------------------------------------+
```

**Networks:**
- `agmind-frontend` — bridge: nginx, grafana, portainer
- `agmind-backend` — bridge, **internal**: all core services (no ports exposed)
- `ssrf-network` — bridge, **internal**: sandbox + ssrf_proxy + api + worker (SSRF isolation)

---

## Installation Phases

Installation supports **checkpoint/resume** — if interrupted, re-running `sudo bash install.sh` continues from the last phase. Full log: `/opt/agmind/install.log`.

| Phase | What happens | Timeout |
|-------|-------------|---------|
| 1/9 | System diagnostics + pre-flight checks (OS, GPU, RAM, disk, ports) | -- |
| 2/9 | Interactive wizard (profile, LLM/embedding provider, model, TLS, monitoring) | -- |
| 3/9 | Install Docker + Compose + NVIDIA toolkit (if missing) | -- |
| 4/9 | Generate .env, nginx.conf, redis.conf, credentials.txt, cron | -- |
| 5/9 | Start containers (`docker compose up --profile ...`) | 300s + retry |
| 6/9 | Wait for healthchecks (core: 300s, GPU: 600s) | auto-retry |
| 7/9 | Download LLM + embedding models (Ollama/vLLM) | 1200s + retry |
| 8/9 | Configure cron backups + SSH hardening + systemd service | -- |
| 9/9 | Verify service endpoints + show credentials summary | -- |

Timeout exceeded? Phase automatically retries with 2x limit. If retry fails — shows manual continuation instructions.

---

## LLM Providers

The wizard asks for LLM and embedding providers separately. Compose profiles activate only the chosen services.

### LLM

| Provider | Compose profile | Description |
|----------|----------------|-------------|
| Ollama | `ollama` | Local inference, auto-downloads models |
| vLLM | `vllm` | Production-grade, OpenAI-compatible API, tensor parallelism |
| External | -- | External API (OpenAI, Anthropic, etc.) — no LLM container |
| Skip | -- | No LLM, Dify + Open WebUI only |

### Embedding

| Provider | Compose profile | Description |
|----------|----------------|-------------|
| Ollama | `ollama` | Embedding via Ollama (bge-m3, etc.) |
| TEI | `tei` | HuggingFace Text Embeddings Inference |
| External | -- | External embedding API |
| Same | -- | Same provider as LLM |

### Model Selection (Ollama)

The installer detects GPU/RAM and recommends an optimal model (`lib/detect.sh` -> `recommend_model()`).

| # | Model | Params | RAM | VRAM |
|---|-------|--------|-----|------|
| 1 | `gemma3:4b` | 4B | 8GB+ | 6GB+ |
| 2 | `qwen2.5:7b` | 7B | 8GB+ | 6GB+ |
| 3 | `qwen3:8b` | 8B | 8GB+ | 6GB+ |
| 4 | `llama3.1:8b` | 8B | 8GB+ | 6GB+ |
| 5 | `mistral:7b` | 7B | 8GB+ | 6GB+ |
| 6 | `qwen2.5:14b` * | 14B | 16GB+ | 10GB+ |
| 7 | `phi-4:14b` | 14B | 16GB+ | 10GB+ |
| 8 | `mistral-nemo:12b` | 12B | 16GB+ | 10GB+ |
| 9 | `gemma3:12b` | 12B | 16GB+ | 10GB+ |
| 10 | `qwen2.5:32b` | 32B | 32GB+ | 16GB+ |
| 11 | `gemma3:27b` | 27B | 32GB+ | 16GB+ |
| 12 | `command-r:35b` | 35B | 32GB+ | 16GB+ |
| 13 | `qwen2.5:72b-instruct-q4_K_M` | 72B | 64GB+ | 24GB+ |
| 14 | `llama3.1:70b-instruct-q4_K_M` | 70B | 64GB+ | 24GB+ |
| 15 | `qwen3:32b` | 32B | 32GB+ | 16GB+ |
| 16 | Custom model | -- | -- | -- |

\* default

---

## Deploy Profiles

| Profile   | Internet | TLS           | UFW | Fail2ban | SOPS | Description |
|-----------|----------|---------------|-----|----------|------|-------------|
| `vps`     | yes      | Let's Encrypt | yes | yes      | yes  | Public access via domain |
| `lan`     | yes      | Optional      | no  | yes      | no   | Local office network |
| `vpn`     | yes      | Optional      | no  | yes      | no   | Corporate VPN |
| `offline` | no       | no            | no  | no       | no   | Air-gapped network |

---

## Compose Profiles

| Profile | Services | Activation |
|---------|----------|------------|
| *(default)* | db, redis, api, worker, web, open-webui, nginx, sandbox, ssrf_proxy, plugin_daemon, pipelines | Always |
| `ollama` | ollama | `LLM_PROVIDER=ollama` or `EMBED_PROVIDER=ollama` |
| `vllm` | vllm | `LLM_PROVIDER=vllm` |
| `tei` | tei | `EMBED_PROVIDER=tei` |
| `weaviate` | weaviate | `VECTOR_STORE=weaviate` |
| `qdrant` | qdrant | `VECTOR_STORE=qdrant` |
| `etl` | docling, xinference | `ETL_ENHANCED=true` |
| `monitoring` | prometheus, alertmanager, grafana, cadvisor, loki, promtail, portainer, node-exporter | `MONITORING_MODE=local` |
| `vps` | certbot | `DEPLOY_PROFILE=vps` |
| `authelia` | authelia | `ENABLE_AUTHELIA=true` |

---

## agmind CLI

Installed as `/usr/local/bin/agmind`. Manages the stack without memorizing Docker commands.

| Command | Description | Root |
|---------|-------------|------|
| `agmind status` | Containers, GPU, models, endpoints, credentials path | no |
| `agmind status --json` | Same as JSON | no |
| `agmind doctor` | Diagnostics: DNS, GPU, Docker, ports, disk, RAM, .env | no |
| `agmind doctor --json` | Diagnostics as JSON | no |
| `agmind backup` | Manual backup | yes |
| `agmind restore <path>` | Restore from backup | yes |
| `agmind update` | Rolling update with rollback | yes |
| `agmind update --check` | Check available versions (no changes) | yes |
| `agmind update --component <name> --version <tag>` | Update single component | yes |
| `agmind uninstall` | Remove stack | yes |
| `agmind rotate-secrets` | Rotate secrets | yes |
| `agmind logs [service]` | Docker logs (proxies docker compose logs) | no |
| `agmind help` | All commands | no |

---

## GPU Support

Auto-detected by `lib/detect.sh`:

| GPU | Detection | Docker method |
|-----|-----------|---------------|
| NVIDIA | `nvidia-smi` | deploy.resources.reservations (CUDA) |
| AMD ROCm | `/dev/kfd`, `rocminfo` | device passthrough + `OLLAMA_ROCM=1` |
| Intel Arc | `/dev/dri` + `lspci` | device passthrough |
| Apple M | arm64 + Darwin | Metal native (GPU blocks removed) |
| CPU | fallback | GPU blocks removed, `OLLAMA_NUM_PARALLEL=2` |

Override:
```bash
FORCE_GPU_TYPE=amd bash install.sh --non-interactive    # Force AMD
SKIP_GPU_DETECT=true bash install.sh --non-interactive  # No GPU
```

---

## Security

### Container Level

All services inherit security defaults:
- `cap_drop: [ALL]` — all capabilities dropped
- `no-new-privileges:true` — prevent privilege escalation
- IPv6 disabled, log rotation (10m x 5 files)
- Per-service `cap_add` only where needed

### Host Level

| Mechanism | Profile | Description |
|-----------|---------|-------------|
| UFW | VPS | Deny incoming, allow 22/80/443 |
| Fail2ban | VPS/LAN/VPN | SSH jail (3 retries -> 10d ban) |
| SOPS + Age | VPS | Encrypt .env -> .env.enc |
| SSH Hardening | All | Key-only auth (with lockout prevention warning) |
| Secret Rotation | Opt-in | `agmind rotate-secrets` |

### Data Protection

- **Credentials**: stored only in `credentials.txt` (chmod 600) — passwords never printed to stdout
- **Nginx**: rate limiting (10r/s API, 1r/10s login), security headers, `server_tokens off`
- **Admin UI**: Grafana/Portainer bound to `127.0.0.1` — opt-in via wizard
- **SSRF Proxy**: isolated network, ACL blocks RFC1918 + link-local + `169.254.169.254`
- **Authelia**: 2FA on `/console/*`; API routes bypass (own API key auth + rate limiting)
- **PostgreSQL**: `password_encryption=scram-sha-256`
- **Redis**: `requirepass`, dangerous commands disabled (FLUSHALL, CONFIG, DEBUG, SHUTDOWN)
- **Secrets**: auto-generated (64-char SECRET_KEY, 32-char passwords), blocks `changeme`/`password`
- **.env**: `chmod 600`, `chown root:root`

---

## Monitoring

Activated with `MONITORING_MODE=local`.

| Component | Role | Port |
|-----------|------|------|
| Prometheus | Metrics collection (15s scrape) | 9090 (internal) |
| Alertmanager | Alert routing | 9093 (internal) |
| Grafana | Dashboards | 3001 (127.0.0.1) |
| cAdvisor | Container metrics | 8081 (internal) |
| Node Exporter | Host metrics | 9100 (internal) |
| Loki | Log aggregation (30d retention) | 3100 (internal) |
| Promtail | Docker log collection | 9080 (internal) |
| Portainer | Container management | 9443 (127.0.0.1) |

**Dashboards** (auto-provisioned): overview, containers, logs, alerts.

**Alert rules:**

| Alert | Condition | Severity |
|-------|-----------|----------|
| ContainerDown | Container missing >2 min | critical |
| ContainerRestartLoop | >3 restarts in 15 min | critical |
| HighCpuUsage | >90% CPU >5 min | warning |
| HighMemoryUsage | >90% RAM | warning |
| DiskSpaceLow | <15% free | warning |
| DiskSpaceCritical | <5% free | critical |

**Notifications:** `ALERT_MODE=telegram` or `ALERT_MODE=webhook`.

---

## Component Versions

All images pinned in `templates/versions.env` — single source of truth. No `:latest` tags.

| Component | Version |
|-----------|---------|
| Dify API/Worker/Web | 1.13.0 |
| Open WebUI | v0.5.20 |
| Ollama | 0.6.2 |
| vLLM | v0.17.1 |
| TEI | cuda-1.9.2 |
| PostgreSQL | 16-alpine |
| Redis | 7.4.1-alpine |
| Weaviate | 1.27.6 |
| Qdrant | v1.12.1 |
| Nginx | 1.27.3-alpine |
| Grafana | 11.4.0 |
| Portainer | 2.21.4 |
| Prometheus | v2.54.1 |

Full list: [`templates/versions.env`](templates/versions.env)

---

## Backup & Restore

```bash
sudo agmind backup                    # Manual backup
sudo agmind restore /var/backups/agmind/2026-03-15_0300  # Restore
```

Contents: `dify_db.sql.gz`, `dify_plugin_db.sql.gz`, `volumes.tar.gz`, `config.tar.gz`, `sha256sums.txt`

Cron: `0 3 * * *` (daily 3 AM). Storage: `/var/backups/agmind/`

```bash
BACKUP_RETENTION_COUNT=10       # Keep N latest
ENABLE_S3_BACKUP=true           # Upload via rclone
ENABLE_BACKUP_ENCRYPTION=true   # Encrypt with age
ENABLE_DR_DRILL=true            # Monthly DR drill cron
```

---

## Update

```bash
sudo agmind update                                       # Interactive rolling update
sudo agmind update --check                               # Check available versions
sudo agmind update --component dify-api --version 1.4.0  # Single component
```

Flow: pre-flight -> backup -> compare with `versions.env` -> rolling restart per service -> healthcheck -> rollback on failure -> notification.

If a healthcheck fails after update, the previous image tag is automatically restored.

---

## Offline Installation

```bash
# 1. On a machine with internet: build bundle
./scripts/build-offline-bundle.sh --include-models qwen2.5:14b,bge-m3 --platform linux/amd64

# 2. Transfer archive to air-gapped server

# 3. Install
sudo DEPLOY_PROFILE=offline bash install.sh
```

---

## Environment Variables

### Core

| Variable | Description | Default |
|----------|-------------|---------|
| `DEPLOY_PROFILE` | Profile: vps/lan/vpn/offline | lan |
| `DOMAIN` | Domain (required for VPS) | -- |
| `LLM_PROVIDER` | LLM provider: ollama/vllm/external/skip | ollama |
| `EMBED_PROVIDER` | Embedding provider: ollama/tei/external/same | same |
| `LLM_MODEL` | LLM model (Ollama/vLLM) | qwen2.5:14b |
| `EMBEDDING_MODEL` | Embedding model | bge-m3 |
| `VECTOR_STORE` | weaviate / qdrant | weaviate |
| `ETL_ENHANCED` | Docling + Xinference | false |
| `TLS_MODE` | none / self-signed / custom / letsencrypt | none |
| `MONITORING_MODE` | none / local / external | none |
| `NON_INTERACTIVE` | Skip wizard | false |

### Timeouts

| Variable | Description | Default |
|----------|-------------|---------|
| `TIMEOUT_START` | Phase 5 timeout (container startup) | 300s |
| `TIMEOUT_HEALTH` | Phase 6 timeout (core healthchecks) | 300s |
| `TIMEOUT_GPU_HEALTH` | Phase 6 timeout (GPU model loading) | 600s |
| `TIMEOUT_MODELS` | Phase 7 timeout (model download) | 1200s |

### Security

| Variable | Description | Default |
|----------|-------------|---------|
| `ENABLE_UFW` | UFW firewall | per profile |
| `ENABLE_FAIL2BAN` | Fail2ban IDS | per profile |
| `ENABLE_SOPS` | SOPS + age encryption | per profile |
| `ENABLE_AUTHELIA` | Authelia 2FA proxy | false |
| `ADMIN_UI_OPEN` | Expose Grafana/Portainer on 0.0.0.0 | false |
| `FORCE_GPU_TYPE` | Force GPU type (nvidia/amd/intel/apple) | auto |
| `SKIP_GPU_DETECT` | Skip GPU detection | false |

---

## Post-Install: Configuring Dify

After installation, configure your AI providers in Dify. See [`workflows/README.md`](workflows/README.md) for step-by-step instructions:

- **Ollama**: install `langgenius/ollama` plugin, set URL `http://ollama:11434`
- **vLLM**: install `langgenius/openai_api_compatible`, set URL `http://vllm:8000/v1`
- **TEI**: install `langgenius/openai_api_compatible`, set URL `http://tei:80/v1`
- **External**: install provider plugin, configure API key

A RAG assistant workflow template is included at `/opt/agmind/workflows/rag-assistant.json` — import it via Dify Studio > Create from DSL.

---

## Troubleshooting

```bash
agmind status                    # Stack overview
agmind doctor                    # Full diagnostics
agmind logs api                  # Service logs
curl localhost/health | jq .     # Health endpoint

# Resume after crash
sudo bash install.sh             # Continues from last checkpoint

# Full install log
cat /opt/agmind/install.log
```

---

## Project Structure

```
difyowebinstaller/
+-- install.sh              # Main installer (9 phases, checkpoint/resume)
+-- lib/                    # Modular libraries
|   +-- common.sh           # Logging, validation, utilities
|   +-- wizard.sh           # Interactive setup wizard
|   +-- config.sh           # .env and config generation
|   +-- compose.sh          # Docker Compose operations
|   +-- health.sh           # Health checks, verification
|   +-- detect.sh           # GPU/system detection
|   +-- docker.sh           # Docker installation
|   +-- security.sh         # SSH hardening, fail2ban, UFW
|   +-- models.sh           # Model download orchestration
|   +-- backup.sh           # Backup/restore logic
|   +-- tunnel.sh           # Cloudflare tunnel setup
|   +-- openwebui.sh        # Open WebUI admin creation
|   +-- authelia.sh         # Authelia 2FA configuration
+-- scripts/                # Operational scripts (copied to /opt/agmind/scripts/)
|   +-- agmind.sh           # CLI entry point
|   +-- backup.sh           # Backup with checksums
|   +-- restore.sh          # Interactive restore
|   +-- update.sh           # Rolling update with rollback
|   +-- health-gen.sh       # Health JSON generator (cron)
|   +-- rotate_secrets.sh   # Secret rotation
|   +-- uninstall.sh        # Stack removal
|   +-- build-offline-bundle.sh  # Offline archive builder
|   +-- dr-drill.sh         # DR test automation
+-- templates/              # Config templates
|   +-- docker-compose.yml  # 25+ services, 3 networks
|   +-- versions.env        # Pinned image versions
|   +-- env.*.template      # Per-profile .env templates
|   +-- nginx/              # Nginx configs
|   +-- agmind-stack.service.template  # systemd unit
+-- workflows/              # Dify workflow templates + setup guide
+-- monitoring/             # Prometheus, Grafana, Loki configs
+-- branding/               # Open WebUI white-label assets
+-- tests/                  # BATS unit tests
+-- LICENSE                 # Apache 2.0
```

---

## CI/CD

| Workflow | Checks | Blocking |
|----------|--------|----------|
| **Lint** | ShellCheck (all .sh), yamllint, JSON validate, `bash -n` | Yes |
| **Tests** | BATS unit tests, Trivy security scan (CRITICAL/HIGH) | Yes |

---

## License

[Apache License 2.0](LICENSE)

Copyright 2024-2026 AGMind Contributors
