<div align="center">

<img src="branding/logo.svg" alt="AGMind" width="160">

# AGMind

**Private RAG platform for NVIDIA DGX Spark — one command, production-ready**

[![Tests](https://github.com/botAGI/AGmind/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/botAGI/AGmind/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Bash 5+](https://img.shields.io/badge/bash-5%2B-green)](#)
[![aarch64](https://img.shields.io/badge/arch-aarch64-blue)](#)
[![NVIDIA GB10](https://img.shields.io/badge/GPU-NVIDIA%20GB10-76b900)](#)
[![Dual Spark](https://img.shields.io/badge/cluster-dual--Spark-purple)](#)
[![Containers](https://img.shields.io/badge/containers-30%2B-orange)](#)



[Quick Start](#-quick-start) · [Architecture](#-architecture) · [Cluster](#-cluster-dual-spark) · [Operations](#-operations) · [Troubleshooting](#-troubleshooting) · [🇷🇺 Русский](#-русская-документация)

</div>

---

> [!IMPORTANT]
> **Supported platform: `aarch64` / NVIDIA GB10** (DGX Spark and equivalents).
> Since 2026-04-25, `x86_64` support has been removed — `install.sh` exits 1 on
> other architectures. Override: `AGMIND_ALLOW_AMD64=true` (no guarantees —
> NGC vLLM and Docling cu130 ship arm64-only manifests).

## 📖 Overview

AGMind is a one-command installer for a private RAG platform on **NVIDIA DGX
Spark** (GB10, 128 GB unified memory). It deploys 30+ containers via Docker
Compose: **Dify + vLLM + Weaviate/Qdrant + RAGFlow + Docling + monitoring**,
with an interactive wizard, hardware autodetection, and optional dual-Spark
clustering over 200G QSFP.

```bash
sudo bash install.sh
```

**Built for:** DevOps engineers, ML teams, and IT departments running a
private AI stack on DGX Spark hardware — no vendor lock-in, no cloud egress.

### Why AGMind

- ⚡ **One command, ~30 minutes** to a working stack — wizard → configs →
  image pull → start → admin user → final URL screen. No manual YAML.
- 🔒 **Local models, zero data egress** — gemma-4-26B (vLLM) + bge-m3 +
  bge-reranker run on the GB10. Documents and queries stay on your hardware.
- 🛡️ **Production hardening** — UFW + fail2ban + Authelia (optional 2FA),
  30+ Linux capabilities dropped, rate limiting, SSRF proxy, secret rotation.
- 🧠 **GB10 unified memory aware** — calibrated `mem_limit` and
  `gpu_memory_utilization` for the 121 GiB shared pool; mDNS via avahi for
  `.local` resolution; NAT-on-demand for air-gapped peer Spark.
- 🔧 **Day-2 CLI** — `agmind status / health / backup / update / ragflow /
  docling bench / plugin-daemon / mdns-status` — operations without `docker`
  knowledge.

---

## 💻 Hardware Requirements

> [!WARNING]
> AGMind targets **DGX Spark / GB10 unified memory only**. Anything else is
> unsupported.

| Parameter | Required | Notes |
|-----------|----------|-------|
| **Platform** | NVIDIA DGX Spark (GB10) or equivalent aarch64 + Blackwell | x86_64 path removed 2026-04-25 |
| **OS** | DGX OS 7.5.0 (Ubuntu 24.04 LTS arm64) | NVIDIA driver 580.142 — **do not upgrade past 580.x** |
| **CPU** | 20-core ARM (10× Cortex-X925 + 10× Cortex-A725, MediaTek-co-developed) | Compute capability `sm_121` exposed via SoC architecture |
| **Memory** | 128 GB LPDDR5X unified (CPU+GPU shared), 273 GB/s bandwidth | AGMind budgets 121 → 85 GiB for containers; 35 GiB reserved for kernel/swap |
| **GPU** | Blackwell, 48 SM / 6144 CUDA cores, 5th-gen Tensor Cores with FP4 | MIG **not available** on GB10. FP8 broken in FlashInfer — use `VLLM_ATTENTION_BACKEND=TRITON_ATTN` |
| **Disk** | 100 GB+ free on `/` | gemma-4 weights ~52 GB, container images ~30 GB |
| **Network** | Ethernet for LAN; optional QSFP 200G DAC for dual-Spark | mDNS via avahi requires UDP/5353 free |
| **Docker** | 29.0+ with NVIDIA Container Toolkit | install.sh installs both |

> [!CAUTION]
> **Do not upgrade NVIDIA driver past 580.x** on Spark. Three independent
> regressions on GB10 unified memory: CUDAGraph capture deadlock, UMA memory
> leak (~80 GiB ghost), and Blackwell TMA bug in 595.58.03. NVIDIA staff:
> *"we do not support new drivers past 580.126.09 on Spark"*.
> Pin: `apt-mark hold nvidia-driver-580-open`.

---

## 🚀 Quick Start

```bash
git clone https://github.com/botAGI/AGmind.git
cd AGmind
sudo bash install.sh
```

The wizard asks 10–15 questions depending on choices (stack mode, LLM model,
optional services, security toggles, monitoring). After ~25 minutes the
stack is live.

### Endpoints (mDNS — no DNS server needed)

| Service          | URL                              | Login                            |
|------------------|----------------------------------|----------------------------------|
| Dify App         | `http://agmind-dify.local`       | `admin@agmind.ai`                |
| Dify Console     | `http://agmind-dify.local/console` | (same — see `credentials.txt`) |
| RAGFlow          | `http://agmind-rag.local`        | register on first visit          |
| Open WebUI       | `http://agmind-chat.local`       | (same admin) — _optional_        |
| LiteLLM Gateway  | `http://agmind-litellm.local`    | master key in `credentials.txt`  |
| MinIO Console    | `http://agmind-storage.local`    | creds in `credentials.txt`       |
| Grafana          | `http://<spark-ip>:3001`         | password in `credentials.txt`    |
| Portainer        | `https://<spark-ip>:9443`        | first visit creates admin        |

> [!NOTE]
> All credentials live in `/opt/agmind/credentials.txt` (`chmod 600`,
> root-only).

### Language

The wizard is bilingual (English / Russian). Language selection works as follows:

1. **Interactive:** the wizard's first question is "Language / Язык" — prefilled
   with the autodetected value. Answer `en` or `ru`.
2. **Env override:** set `AGMIND_LANG=en` or `AGMIND_LANG=ru` before running
   `install.sh` / `agmind` to force a language. Takes precedence over locale.
3. **Autodetect:** if `AGMIND_LANG` is not set, the system locale
   (`LC_ALL` → `LC_MESSAGES` → `LANG`) is checked; a value starting with `ru`
   resolves to Russian, everything else to English (default `en`).

```bash
# Force Russian
sudo AGMIND_LANG=ru bash install.sh

# Force English (also the default when locale is not ru_*)
sudo AGMIND_LANG=en bash install.sh
```

### Non-Interactive Install

```bash
sudo NON_INTERACTIVE=true \
     LLM_MODEL=gemma-4-26b \
     EMBED_PROVIDER=vllm EMBEDDING_MODEL=bge-m3 \
     ENABLE_RAGFLOW=true \
     bash install.sh
```

---

## 📦 What's Included

### Core Stack

| Component | Image / Tag | Purpose |
|-----------|-------------|---------|
| **Dify** | `langgenius/dify-api:1.13.3` | Workflow orchestrator + primary frontend |
| **vLLM (LLM)** | `vllm/vllm-openai:gemma4-cu130` | NVIDIA playbook build for arm64 + SM_121 |
| **vLLM (embed)** | `nvcr.io/nvidia/vllm:26.02-py3` | `bge-m3` embeddings (1024-dim) |
| **vLLM (rerank)** | `nvcr.io/nvidia/vllm:26.02-py3` | `bge-reranker-v2-m3` |
| **Docling-serve cu130** | `docling-serve-cu130:v1.16.1` | GPU document extractor + OCR + VLM picture-description |
| **PostgreSQL** | `postgres:16-alpine3.23` | Dify metadata, plugin state |
| **Redis** | `redis:7.4.8-alpine` | Task queue, plugin cache |
| **Weaviate / Qdrant** | `semitechnologies/weaviate:1.37.2` | Vector store (Weaviate default) |
| **nginx** | `nginx:1.30.0-alpine` | Reverse proxy (variable-form `proxy_pass`) |
| **plugin_daemon** | `langgenius/dify-plugin-daemon:0.5.3-local` | Dify plugin runtime |

### RAGFlow Integration

- **RAGFlow v0.24.1-spark** — deep document parsing + retrieval, image
  `ar2r223/ragflow-spark:v0.24.1-spark` (cherry-picked TitleChunker /
  TokenChunker / 7 ingestion templates from upstream main + multilingual OCR
  Latin/Cyrillic/Chinese, file metadata in ES chunks, AVIF, Russian VLM
  prompts for image describe).
- **Dify ↔ RAGFlow** via `witmeng/ragflow-api` plugin from Dify Marketplace
  (8K+ installs).
- **Storage:** MySQL + Elasticsearch 9.x + MinIO (S3-compatible).
- Toggle: `ENABLE_RAGFLOW=true` in wizard or env.

### Monitoring & Ops

- **Prometheus + Grafana** — 10 dashboards (overview, containers, GPU master,
  GPU worker, peer-worker, logs, alerts, audit, RAG, RAGFlow). Custom textfile
  collector for `agmind_gpu_*` metrics (NVML returns N/A on GB10 unified
  memory — `dcgm-exporter` does **not** work).
- **Loki + Grafana Alloy** (Promtail → Alloy migration, 2026-04). Searchable
  container logs.
- **Alertmanager** — Telegram / webhook channels.
- **Portainer 2.39.1** — visual container management (master + auto-deployed
  agent on peer Spark).
- **fail2ban + UFW** — bruteforce protection, LAN-only firewall by default.

### Optional Services

<details>
<summary><strong>Wizard checklist (click to expand)</strong></summary>

| Service | RAM | Purpose |
|---------|-----|---------|
| Open WebUI | ~300 MB | Alternative chat UI at `agmind-chat.local` |
| LiteLLM | ~1 GB | OpenAI-compatible gateway over multiple providers |
| SearXNG | ~256 MB | Private metasearch (Google/Bing/DDG) for Dify agents |
| DB-GPT | ~1 GB | NL2SQL agent + dataset chat |
| Crawl4AI | ~2 GB | Headless Chromium web crawler with REST API |
| RAGFlow | ~13 GB | Deep document parsing + retrieval (see above) |
| Authelia 2FA | ~150 MB | TOTP/WebAuthn for Grafana / Portainer |
| Open Notebook | ~500 MB | _BROKEN in v3.0.1 — do not enable_ |

</details>

---

## 🏗 Architecture

```
                                Clients (LAN)
                                      │
                                      ▼  mDNS resolution (*.local → 192.168.x.x)
       ┌─────────────────────────────────────────────────────────────────────┐
       │  nginx — variable-form proxy_pass · agmind-*.local server-blocks    │
       │           :80  :443  :3000  :4001 LiteLLM                           │
       └────┬────────┬─────────┬───────────┬──────────────┬──────────────────┘
            │        │         │           │              │
   agmind-dify   agmind-rag  /litellm  /storage     agmind-chat (opt)
   .local (Dify) .local      .local    .local       .local (Open WebUI)
            │        │
            ▼        ▼
       ┌────────────────────────────────────────────────────────────────────┐
       │  Dify (api · worker · web · sandbox · plugin_daemon)               │
       │  RAGFlow (ragflow + mysql + ES) + Dify plugin witmeng/ragflow-api  │
       └────────┬───────────┬───────────┬──────────────────┬────────────────┘
                │           │           │                  │
                ▼           ▼           ▼                  ▼
            Postgres     Redis      Weaviate           MinIO (S3-compat)
            metadata    queues       vectors           agmind-storage.local

  ─── ML inference on GB10 unified memory (121 GiB pool) ───────────────────
   vLLM-embed (NGC 26.02-py3) :8001  bge-m3 1024-dim
   vLLM-rerank (NGC 26.02-py3) :8002  bge-reranker-v2-m3
   Docling-serve cu130        :8765  PDF/DOCX/PPTX → MD + OCR + VLM
   vLLM gemma-4-26B-A4B (cu130)
       single-Spark → shares GPU above, wizard asks ctx 32K/64K/128K
       dual-Spark   → peer 192.168.100.2:8000, dedicated GPU, 128K default

  ─── Monitoring (always on) ────────────────────────────────────────────────
   Prometheus :9090 → Grafana :3001 (10 dashboards)
   Loki + Grafana Alloy (Promtail migrated 2026-04)
   Alertmanager → Telegram / Webhook
   Portainer :9443 — master + auto-deployed agent on peer:9001
   node-exporter + cAdvisor — both nodes; agmind_gpu_* via textfile collector

  ─── Docker networks ───────────────────────────────────────────────────────
   agmind-frontend — nginx ↔ web UIs · Grafana · Portainer
   agmind-backend  — all services east-west
   ssrf-network    — isolated: Dify Sandbox ↔ Squid proxy
```

> [!TIP]
> For rendered diagrams see [`docs/architecture/`](docs/architecture/) — service
> topology, data-flow, and network/security zones (Mermaid). The ASCII above is
> the quick reference.

### Repository Layout

```
agmind/
├── install.sh                   # Main orchestrator (11 phases)
├── lib/                         # 16 modules: wizard, config, compose, health, security, detect, …
├── scripts/                     # Day-2 CLI: agmind, update, backup, restore, mdns-status, docling-bench, gpu-metrics
├── templates/                   # docker-compose.yml, docker-compose.worker.yml, nginx.conf, env templates, versions.env
├── monitoring/                  # Prometheus, Grafana dashboards, Loki, Alloy, Alertmanager
├── tests/                       # unit + integration + compose manifest tests (run via tests/run_all.sh)
├── docs/                        # Detailed documentation
└── branding/                    # Logo + theme
```

### Docker Networks

| Network            | Purpose                                            |
|--------------------|----------------------------------------------------|
| `agmind-frontend`  | nginx ↔ web UIs, Grafana, Portainer                |
| `agmind-backend`   | All services, internal east-west                   |
| `ssrf-network`     | Isolated: Dify Sandbox ↔ Squid (SSRF-safe egress)  |

### Install Phases

<details>
<summary><strong>11 phases — click to expand</strong></summary>

| #  | Name          | What it does                                                              |
|----|---------------|---------------------------------------------------------------------------|
| 1  | Diagnostics   | OS, CPU, GPU, driver, disk, RAM, ports, mDNS prerequisites                |
| 2  | Wizard        | 10–15 interactive questions (stack mode, LLM, optionals, security)        |
| 3  | Docker        | Install Docker CE + NVIDIA Container Toolkit (idempotent)                 |
| 4  | Configuration | Generate `.env`, nginx config, secrets, mDNS aliases                      |
| 5  | Pull          | Validate manifests (arm64 required) and pull images                       |
| 6  | Start         | `docker compose up -d`, create Dify admin, init databases                 |
| 7  | Deploy Peer   | Master only: scp worker compose + `.env` to peer, deploy vLLM via SSH     |
| 8  | Health        | Wait for healthchecks, smoke-test critical endpoints                      |
| 9  | Models        | Download gemma-4 + bge-m3 + bge-reranker (cached on re-install)           |
| 10 | Backups       | Establish baseline backup + cron schedule                                 |
| 11 | Complete      | systemd unit, final URL screen + credentials                              |

</details>

---

## 🌐 Cluster (Dual-Spark)

AGMind supports a two-node configuration: **master + peer over QSFP 200G DAC**.

```
  ┌─────────────────────┐                       ┌─────────────────────┐
  │  spark-master       │   QSFP 200G DAC       │  spark-peer         │
  │  (frontend + DB +   │ ◄──── direct link ───►│  (vLLM + heavy GPU  │
  │  Dify + RAGFlow +   │   192.168.100.0/24    │  workloads)         │
  │  monitoring)        │                       │                     │
  │  WAN: ethernet      │                       │  WAN: NAT via       │
  │  iptables MASQUERADE│ ────── default gw ────►│  master QSFP        │
  └─────────────────────┘                       └─────────────────────┘
```

| Capability | Detail |
|------------|--------|
| **Symmetric install** | `sudo bash install.sh` on both nodes; wizard detects QSFP via LLDP, falls back to ping. `--mode=master` / `--mode=worker` for non-interactive |
| **Frontend on master** | Dify, RAGFlow, Postgres, Redis, Weaviate, nginx, monitoring all on master. Peer runs only vLLM |
| **vLLM on peer** | `LLM_ON_PEER=true` flag in `.env`. Master ↔ peer via OpenAI-compatible HTTP (no LiteLLM router) |
| **NAT on demand** | Peer's WAN egress (image pull, model download) goes through master's QSFP gateway via `iptables MASQUERADE`. Air-gap intent preserved when WAN disabled (`agmind nat off`) |
| **Passwordless SSH** | Wizard configures master ↔ peer key auth |
| **Monitoring** | Two Grafana dashboards (`gpu-master`, `gpu-worker`), peer textfile collector + cron for `agmind_gpu_*` |
| **Portainer agent** | `agmind-portainer-agent` auto-deployed on peer with shared `PORTAINER_AGENT_SECRET` (persistent across re-installs) |

> [!TIP]
> **Adding peer to master Portainer (one-time manual step):**
> Open `https://<master-ip>:9443` → `Environments → Add → Agent` →
> `URL=<peer_ip>:9001`, `SECRET` from `credentials.txt`.

---

## ⚙️ Configuration

All settings live in `/opt/agmind/docker/.env` (chmod 600). The wizard
populates everything; no manual edits required.

### LLM Provider

vLLM is the default and only first-class choice on GB10. Ollama exists as a
hidden override (`LLM_PROVIDER=ollama`) but is gated behind a Compose profile.

| Variable | Default | Purpose |
|----------|---------|---------|
| `LLM_PROVIDER` | `vllm` | `vllm` (default) or `external` (BYO API) |
| `VLLM_MODEL` | `gemma-4-26B-A4B-it` | HF-style model id |
| `VLLM_GPU_MEM_UTIL` | `0.60` | Lower than upstream — leaves headroom for docling-serve (peaks 16 GiB) |
| `VLLM_MAX_MODEL_LEN` | `65536` | 65K context with fp8 KV cache |
| `VLLM_ATTENTION_BACKEND` | `TRITON_ATTN` | FP8 / FlashInfer broken on SM_121 |

The Spark wizard offers **three paths** for vLLM model selection:

1. **Gemma 4 26B-A4B** (NVIDIA playbook default — recommended)
2. **Curated list** — Qwen / Llama / Mistral / phi-4 with VRAM hints
3. **Custom HuggingFace model** — input field, e.g.
   `meta-llama/Llama-3.1-70B-Instruct`

> [!NOTE]
> On **dual-Spark** the context question is skipped — peer has dedicated GPU
> → 128K default. On **single-Spark** the wizard asks 32K / 64K / 128K
> because vLLM shares GPU with docling.

### Optional Service Toggles

`ENABLE_OPENWEBUI`, `ENABLE_LITELLM`, `ENABLE_DOCLING`, `ENABLE_SEARXNG`,
`ENABLE_DBGPT`, `ENABLE_CRAWL4AI`, `ENABLE_RAGFLOW`, `ENABLE_AUTHELIA`,
`ENABLE_DIFY_PREMIUM`, `ENABLE_MINIO`. All set by the wizard; override via
env for non-interactive installs.

### Image Versions

All image tags pinned in `templates/versions.env`. The `:latest` tag is
forbidden. Each tag must have an `arm64` manifest verified via
`docker manifest inspect`.

```bash
bash tests/compose/test_image_tags_exist.sh   # CI test
```

---

## 🛠 Operations

> `agmind <cmd>` is installed to `PATH`. Run `agmind help` for the full list.

### Status & Diagnostics

```bash
agmind status [--json] [--watch] [--service <name>]   # Stack overview table
agmind doctor [--peer] [--json] [--fix [--dry-run]] [--bundle]   # System diagnostics
agmind health                        # Alias for doctor
agmind logs [-f] <service>           # Tail container logs
agmind mdns-status                   # Verify avahi publishing for *.local
agmind troubleshoot <topic>          # Print the matching docs/troubleshooting.md section
agmind security audit [--json]       # Read-only scan: exposed ports / privileged / docker.sock / weak secrets
agmind config validate [--json]      # Static check: .env / versions↔manifest / compose schema
agmind config diff                   # Pinned-vs-target update preview (read-only)
```

### Access & Credentials

```bash
agmind open <svc>|--list             # Open a service URL (headless/SSH → prints the URL, pipeable)
agmind endpoints [--json]            # List all public service URLs (SERVICE | URL | STATE)
sudo agmind creds show [--show] [--json]   # Show stack credentials (root; masked unless --show)
sudo agmind creds rotate             # Regenerate passwords / keys (wraps rotate_secrets.sh)
```

### Profiles & Sizing

```bash
agmind profiles [--json]             # The 8 named deployment profiles + the active one
agmind estimate [<profile>] [--json] # RAM / disk / GPU-mem estimate for a profile vs available

# Install controls (install.sh):
sudo bash install.sh --profile rag          # Pick a named profile non-interactively
sudo bash install.sh --dry-run              # Print the phase plan, change nothing
sudo bash install.sh --resume-from <phase>  # Re-run from a given install phase
```

### Lifecycle

```bash
agmind stop                          # Stop all containers
agmind start                         # Start configured services
agmind restart                       # Restart all
agmind upgrade --diff                # Compare pinned versions vs running
agmind update [--check|--auto]       # Update stack from main branch
```

### GPU & Models

```bash
agmind gpu status                    # Loaded models, VRAM, utilization
agmind gpu assign <svc> <id>         # Pin service to GPU id
agmind model list                    # All loaded models (vLLM endpoints)
```

### RAGFlow

```bash
agmind ragflow status                # 3 ragflow containers state
agmind ragflow query <text>          # Test retrieval
agmind ragflow es-health             # Elasticsearch cluster health
```

### Plugin Daemon & Marketplace

```bash
agmind plugin-daemon status          # State + health
agmind plugin-daemon stop|start      # Toggle (root) — Dify plugins stop working when off
agmind plugin-daemon logs            # Tail logs

agmind plugins status                # ONLINE / OFFLINE
agmind plugins online                # Enable marketplace.dify.ai (default)
agmind plugins offline               # Local .difypkg only (supply-chain hardened)
```

### Performance & Demo

```bash
agmind loadtest list                 # k6 scenarios
agmind loadtest chat --vus 8         # Concurrent chat load test
agmind docling bench <pdf>           # Cold/warm/per-page timing for any PDF
agmind demo install|ingest|ask       # ~5-min RAG demo: sample workflow + KB + bundled doc → answer with citations
```

### Backup & Restore

```bash
sudo agmind backup create [--include-models]   # PostgreSQL + Redis + volumes (+ vLLM cache)
agmind backup list                             # DATE / SIZE / STATUS
agmind backup verify [latest|<dir>] [--json]   # Integrity check; exit 0 = valid, 1 = corrupt/incomplete
sudo agmind restore [latest|<dir>] [--dry-run] [--service <name>]   # Restore (--dry-run prints the plan)
sudo agmind rotate-secrets           # Regenerate passwords/keys
sudo agmind uninstall [--keep-models]  # Remove stack
```

---

## 📁 Server Layout

```
/opt/agmind/
├── docker/
│   ├── .env                         # Secrets and config (chmod 600)
│   ├── docker-compose.yml           # All services
│   ├── nginx/nginx.conf             # Reverse proxy
│   └── volumes/                     # Postgres, Redis, vectors, models, MinIO
├── credentials.txt                  # All passwords (chmod 600)
├── scripts/                         # Day-2 CLI + lib modules mirrored here (doctor/status/config/restore/security/…)
├── templates/                       # init SQL, env templates
├── monitoring/                      # Prometheus rules, Grafana dashboards
├── docs/                            # architecture/ · adr/ · compatibility & decision matrices · troubleshooting · operations
├── .install-phases.jsonl            # Per-phase install record (durations / errors)
├── install-report.json              # Machine-readable install summary
└── install.log                      # Full install transcript
```

---

## 🩺 Troubleshooting

| Symptom | First check |
|---------|------------|
| Service stuck unhealthy | `agmind logs <service>` — last 50 lines tell the story |
| Dify Console 502 | `docker restart agmind-nginx` (then verify nginx config uses variable-form `proxy_pass`) |
| Model not loading | `nvidia-smi` + `docker logs agmind-vllm` — usually OOM or driver mismatch |
| `agmind-rag.local` unresolved | `agmind mdns-status` — checks for second mDNS responder on UDP/5353 |
| Indexing stuck after recreate | `redis-cli DEL generate_task_belong:* celery-task-meta-*` then `docker restart agmind-worker agmind-api` |
| 502 on every request | full `agmind doctor` — fail2ban / UFW / GPU driver health |
| Disk full | `docker system prune -a` then `agmind backup` and prune `/var/backups/agmind/` |
| DR-grade restore | `agmind restore /var/backups/agmind/<latest>/` |

> [!TIP]
> Detailed runbooks for known gotchas live in [`docs/`](docs/). Open an
> issue if you hit something missing — we backfill the runbook.

---

## ✅ Definition of Done

A change is only complete when these checks pass green:

```bash
# Bash hygiene
shellcheck -S warning lib/*.sh scripts/*.sh install.sh

# Compose schema + image existence
cd /opt/agmind/docker && sudo docker compose config | grep 'image:' | sort -u
bash tests/compose/test_image_tags_exist.sh core/compose.yml

# Live health
sudo docker ps --format '{{.Names}} {{.Status}}' | grep -v 'healthy\|Up'   # must be empty
avahi-resolve -n agmind-dify.local                                          # must resolve
curl -sf http://agmind-dify.local/console/api/setup                         # must 200
```

All checks must pass before a PR is mergeable.

---

## 📊 Benchmarks

Results on NVIDIA DGX Spark (GB10, 128 GB unified memory):

| Metric                      | gemma-4-26B-A4B-it (MoE) |
|-----------------------------|--------------------------|
| TTFT (streaming)            | 183 ms                   |
| TPS (single request)        | 23–24 tokens/sec         |
| TPS (3 concurrent)          | 50 tokens/sec aggregate  |
| Long generation (500 tok)   | 20.6s @ 24.3 TPS         |
| Context window              | 65K tokens (fp8 KV cache)|
| Max concurrency @ 65K       | 45 parallel requests     |
| Memory: model weights       | 48.5 GiB (bfloat16)      |
| Memory: KV cache            | 41.7 GiB (fp8)           |
| Total footprint             | ~95 GiB                  |

Docling (5-page arxiv PDF, warm): **6.04s**, 0.32s/page, ~1.6 GiB GPU memory.

---

## 🗺 Roadmap & Status

- **v3.1.1** _(current)_ — release housekeeping: version strings synced `v3.0.2` → `v3.1.1`
  (`RELEASE` / `install.sh` `VERSION` / `templates/release-manifest.json`), `versions.env`
  header refreshed; ADR `Status: Accepted` lines confirmed; manifest digest regen → backlog 999.6.
- **v3.1** — Day-2 UX + hardening + docs (9 phases): `agmind doctor`
  (preflight/health + `--fix` + sanitized `--bundle`), `agmind status`
  (overview table + `--json`/`--watch`), `agmind open`/`endpoints`/`creds`,
  `agmind config validate`/`diff` + `install --dry-run`/`--resume-from` +
  `install-report.json`, `agmind backup verify`/`restore --dry-run`, installer
  refactored into a phase engine (`lib/phases.sh`) + peer module, security
  hardening (docker-socket-proxy, airgapped mode, `agmind security audit`),
  onboarding docs (`docs/architecture/` Mermaid diagrams, compatibility &
  decision matrices, `docs/troubleshooting.md` + `agmind troubleshoot`,
  `docs/adr/` ADR-0001…0009, `Makefile`, `agmind demo`), profiles UX (named
  deployment profiles in the wizard, `agmind profiles`, `agmind estimate`).
- **v3.0.2** — RAGFlow upgrade to `v0.24.1-spark` (TitleChunker / TokenChunker +
  7 ingestion templates + Russian VLM prompts), Pipeline framework patches.
- **v3.0.1** — mDNS hardening, dual-Spark cluster, master/worker wizard,
  NAT-on-demand peer, Portainer peer agent.
- **2026-04-26** — RAGFlow integrated via DockerHub `ar2r223/ragflow-spark`.
- **2026-04-25** — Yellow-zone version bumps (7/8 components arm64
  re-verified). x86_64 path retired.
- **Next** — TUI in `agmind update` (toggle new tools introduced in updates),
  native AGmind chat plugin for Dify (file upload → KB, slash commands).

---

## 📚 Documentation

| Document | Description |
|---|---|
| [docs/architecture/](docs/architecture/) | Service topology, network layout, deploy phases |
| [docs/compatibility-matrix.md](docs/compatibility-matrix.md) | Driver / OS / container version compatibility |
| [docs/vector-db-decision-matrix.md](docs/vector-db-decision-matrix.md) | Weaviate vs Qdrant vs Milvus — selection rationale |
| [docs/dify-vs-ragflow.md](docs/dify-vs-ragflow.md) | Dify and RAGFlow integration patterns |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Topic-by-topic fixes (`agmind troubleshoot <topic>`) |
| [docs/adr/](docs/adr/) | Architecture Decision Records (ADR-0001 … ADR-0009) |

Quick navigation via CLI:
```bash
agmind troubleshoot vllm       # vLLM model not loading → docs/troubleshooting.md §1
agmind troubleshoot gpu        # CUDA not visible in container → §2
agmind troubleshoot dify       # Dify worker / tasks stuck → §4
agmind troubleshoot mdns       # mDNS / .local resolution → §6
agmind troubleshoot memory     # OOM / unified memory → §10
#  (no-arg `agmind troubleshoot` lists all topics; sections: 1 vllm · 2 gpu · 3 ragflow/es · 4 dify · 5 ports · 6 mdns · 7 model-download · 8 restore · 9 update · 10 memory)
```

---

## 🤝 Contributing

- Work on `main` only — no feature branches, no merge commits. PRs are cut
  from `main` on demand.
- Use the `Makefile` task runner: `make lint` (shellcheck), `make test`
  (unit + integration), `make compose-config`, `make manifest-check`,
  `make release-check`. `make` with no target prints the list.
- Every PR must pass [Definition of Done](#-definition-of-done) and
  `make manifest-check` (a.k.a. `tests/compose/test_image_tags_exist.sh`).
- Image tag bumps require `docker manifest inspect <image>:<tag> | grep arm64`
  evidence in the commit message — LLMs hallucinate registry tags.
- Architectural decisions go in [`docs/adr/`](docs/adr/) as MADR-lite records;
  reference them from code comments instead of internal notes.

---

## 📜 License

[Apache License 2.0](LICENSE)

Copyright © 2024–2026 AGMind Contributors.

---

# 🇷🇺 Русская документация

<details>
<summary><strong>Развернуть полный перевод (click to expand)</strong></summary>

**Сайт:** [prem.agmind.dev](https://prem.agmind.dev/)

## 📖 Обзор

AGMind — установщик приватной RAG-платформы для **NVIDIA DGX Spark**
(GB10, 128 GB unified memory). Одной командой разворачивает 30+
контейнеров через Docker Compose: **Dify + vLLM + Weaviate/Qdrant +
RAGFlow + Docling + мониторинг**, с интерактивным визардом, автодетектом
железа и опциональным dual-Spark кластером по 200G QSFP.

```bash
sudo bash install.sh
```

**Для кого:** DevOps-инженеры, ML-команды, IT-отделы, которым нужен
приватный AI-стек на DGX Spark — без vendor lock-in и облачного egress.

### Зачем AGMind

- ⚡ **Одна команда, ~30 минут** до рабочего стека
- 🔒 **Локальные модели, нулевой egress** — gemma-4 + bge-m3 локально
- 🛡️ **Production hardening** — UFW + fail2ban + Authelia 2FA + drop caps
- 🧠 **GB10-aware бюджеты памяти** — 121 GiB unified pool, mDNS, NAT-on-demand
- 🔧 **Day-2 CLI** — `agmind status / health / backup / update / ragflow`

---

## 💻 Требования к железу

> [!WARNING]
> AGMind рассчитан **только на DGX Spark / GB10**. Всё остальное не
> поддерживается.

| Параметр | Требуется | Замечания |
|----------|-----------|-----------|
| Платформа | NVIDIA DGX Spark (GB10) | x86_64 удалён 2026-04-25 |
| ОС | DGX OS 7.5.0 (Ubuntu 24.04 LTS arm64) | Driver 580.142 — **не обновлять выше 580.x** |
| CPU | 20-ядерный ARM (10× Cortex-X925 + 10× Cortex-A725, MediaTek) | Compute capability `sm_121` |
| RAM | 128 GB LPDDR5X unified, 273 GB/s | AGMind резервирует 121 → 85 GiB |
| GPU | Blackwell, 48 SM / 6144 CUDA, 5th-gen Tensor Cores с FP4 | MIG недоступен; FP8 FlashInfer сломан |
| Диск | 100 GB+ свободно | gemma-4 ~52 GB, образы ~30 GB |
| Сеть | Ethernet (LAN) + опционально QSFP 200G DAC | mDNS требует UDP/5353 |
| Docker | 29.0+ с NVIDIA Container Toolkit | install.sh ставит сам |

> [!CAUTION]
> **Не обновлять NVIDIA driver выше 580.x.** Три регрессии на GB10:
> CUDAGraph deadlock, UMA leak ~80 GiB, TMA bug 595.58.03. NVIDIA staff:
> *"we do not support new drivers past 580.126.09 on Spark"*.

---

## 🚀 Быстрый старт

```bash
git clone https://github.com/botAGI/AGmind.git
cd AGmind
sudo bash install.sh
```

Визард задаст 10–15 вопросов в зависимости от выборов. Через ~25 минут стек поднят.

### Эндпоинты (через mDNS)

| Сервис           | URL                              | Логин                               |
|------------------|----------------------------------|-------------------------------------|
| Dify App         | `http://agmind-dify.local`       | `admin@agmind.ai`                   |
| Dify Console     | `http://agmind-dify.local/console` | (та же — см. `credentials.txt`)   |
| RAGFlow          | `http://agmind-rag.local`        | регистрация при первом входе        |
| Open WebUI       | `http://agmind-chat.local`       | (тот же admin) — _опционально_      |
| LiteLLM Gateway  | `http://agmind-litellm.local`    | master key в `credentials.txt`      |
| MinIO Console    | `http://agmind-storage.local`    | креды в `credentials.txt`           |
| Grafana          | `http://<spark-ip>:3001`         | пароль в `credentials.txt`          |
| Portainer        | `https://<spark-ip>:9443`        | первый вход создаёт admin           |

### Неинтерактивная установка

```bash
sudo NON_INTERACTIVE=true \
     LLM_MODEL=gemma-4-26b \
     EMBED_PROVIDER=vllm EMBEDDING_MODEL=bge-m3 \
     ENABLE_RAGFLOW=true \
     bash install.sh
```

---

## 🌐 Кластер (Dual-Spark)

Поддержка двух DGX Spark машин: **master + peer по QSFP 200G DAC**.

| Возможность | Деталь |
|-------------|--------|
| Симметричная установка | `sudo bash install.sh` на обеих нодах |
| Фронтенд на master | Dify, RAGFlow, Postgres, Redis, Weaviate, мониторинг |
| vLLM на peer | `LLM_ON_PEER=true` в `.env` |
| NAT on demand | Peer выходит в WAN через QSFP master'а |
| Passwordless SSH | Визард настраивает обоюдный key auth |
| Мониторинг | 2 дашборда Grafana (`gpu-master`, `gpu-worker`) |
| Portainer agent | `agmind-portainer-agent` авто-деплоится на peer |

> [!TIP]
> **Добавление peer в master Portainer** (один ручной шаг):
> Открой `https://<master-ip>:9443` → `Environments → Add → Agent` →
> `URL=<peer_ip>:9001`, `SECRET` из `credentials.txt`.

---

## ⚙️ Конфигурация

В визарде на DGX Spark предлагается **3 пути выбора модели vLLM**:

1. **Gemma 4 26B-A4B** (рекомендуемый default — NVIDIA playbook)
2. **Общий список** (Qwen / Llama / Mistral / phi-4 с оценкой VRAM)
3. **Своя HuggingFace модель** (поле ввода — например
   `meta-llama/Llama-3.1-70B-Instruct`)

> [!NOTE]
> На **dual-Spark** вопрос про контекст пропускается (peer имеет dedicated
> GPU → 128K по умолчанию). На **single-Spark** спрашивается 32K / 64K /
> 128K, так как vLLM делит GPU с docling.

### Toggle опциональных сервисов

`ENABLE_OPENWEBUI`, `ENABLE_LITELLM`, `ENABLE_DOCLING`, `ENABLE_SEARXNG`,
`ENABLE_DBGPT`, `ENABLE_CRAWL4AI`, `ENABLE_RAGFLOW`, `ENABLE_AUTHELIA`,
`ENABLE_DIFY_PREMIUM`, `ENABLE_MINIO`.

---

## 🛠 Эксплуатация

```bash
# Статус
agmind status [--json]
agmind doctor [--peer]
agmind logs [-f] <service>

# GPU
agmind gpu status
agmind model list

# RAGFlow
agmind ragflow status
agmind ragflow query <text>

# Plugin daemon
agmind plugin-daemon status|stop|start|restart|logs
agmind plugins status|online|offline       # marketplace.dify.ai toggle

# Производительность
agmind loadtest chat --vus 8
agmind docling bench <pdf>

# Бэкапы
sudo agmind backup
sudo agmind restore <path>
sudo agmind rotate-secrets
```

---

## 🩺 Troubleshooting

| Симптом | Первая проверка |
|---------|-----------------|
| Сервис висит unhealthy | `agmind logs <service>` |
| Dify Console 502 | `docker restart agmind-nginx` |
| Модель не грузится | `nvidia-smi` + `docker logs agmind-vllm` |
| `.local` не резолвится | `agmind mdns-status` |
| Индексация висит после recreate | `redis-cli DEL generate_task_belong:* celery-task-meta-*` |
| Полный диск | `docker system prune -a` |
| Восстановление | `agmind restore /var/backups/agmind/<latest>/` |

Подробные runbook'и для известных граблей — в [`docs/`](docs/).

---

## 📊 Бенчмарки

| Метрика                | gemma-4-26B-A4B-it (MoE)  |
|------------------------|---------------------------|
| TTFT (streaming)       | 183 ms                    |
| TPS (1 запрос)         | 23–24 tokens/sec          |
| TPS (3 параллельных)   | 50 tokens/sec aggregate   |
| Контекст               | 65K (fp8 KV cache)        |
| Max concurrency @ 65K  | 45 параллельных запросов  |
| Память: веса           | 48.5 GiB (bfloat16)       |
| Память: KV cache       | 41.7 GiB (fp8)            |
| Общий footprint        | ~95 GiB                   |

Docling (5 страниц arxiv PDF, warm): **6.04s**, 0.32s/page.

---

## 🤝 Контрибьюции

- Работа только в `main`. PR из `main` по запросу.
- Каждый PR обязан проходить [DoD](#-definition-of-done) и
  `tests/compose/test_image_tags_exist.sh`.
- Bump тега образа = свидетельство `docker manifest inspect <image>:<tag> | grep arm64` в commit message.

---
**Website:** [prem.agmind.dev](https://prem.agmind.dev/)
## 📜 Лицензия

[Apache License 2.0](LICENSE) © 2024–2026 AGMind Contributors.

</details>
