---
sidebar_position: 1
slug: /
---

# AGMind Documentation

AGMind is a production-ready AI platform installer for small and medium businesses. It deploys a complete AI stack including:

- **Dify** — LLM application platform (workflows, RAG, agents)
- **Open WebUI** — ChatGPT-like interface for local LLMs
- **Ollama** — Local LLM inference engine
- **Vector stores** — Weaviate or Qdrant for RAG
- **Monitoring** — Prometheus, Grafana, Alertmanager, Loki
- **Security** — Network isolation, secret management, hardened containers

## Key Features

| Feature | Description |
|---------|-------------|
| **One-command install** | `sudo bash install.sh` — interactive wizard or fully non-interactive |
| **4 deployment profiles** | VPS, LAN, VPN, Offline |
| **GPU auto-detection** | NVIDIA, AMD ROCm, Intel Arc, CPU fallback |
| **Security by default** | No default passwords, network isolation, CIS Docker Benchmark |
| **Automated backups** | Cron-scheduled with rotation, S3 upload, encryption |
| **Rolling updates** | Version-pinned updates with automatic rollback |
| **Health monitoring** | 26-check health script with alerting (Telegram, webhook) |
| **DR tested** | Monthly DR drills, 7-step verified restore |

## Quick Start

```bash
git clone https://github.com/agmind/agmind-installer.git
cd agmind-installer
sudo bash install.sh
```

See [Quickstart Guide](installation/quickstart) for detailed instructions.

## Architecture

```
                    ┌─────────────┐
                    │   Nginx     │ ← TLS termination, rate limiting
                    │  (reverse   │
                    │   proxy)    │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────┴─────┐ ┌───┴───┐ ┌─────┴─────┐
        │ Open WebUI │ │  Dify │ │  Grafana   │
        │ (chat UI)  │ │ (API) │ │ (monitor)  │
        └─────┬──────┘ └───┬───┘ └───────────┘
              │            │
              └────┬───────┘
                   │
            ┌──────┴──────┐
            │   Ollama    │ ← GPU-accelerated LLM inference
            └─────────────┘
                   │
    ┌──────────────┼──────────────┐
    │              │              │
┌───┴───┐   ┌─────┴─────┐  ┌────┴────┐
│ Postgres│  │  Redis    │  │ Weaviate│
│  (DB)  │  │ (cache)   │  │ (vector)│
└────────┘  └───────────┘  └─────────┘
```

## Version Compatibility

All component versions are pinned in `templates/versions.env` with verified
arm64 manifests. Run `bash tests/compose/test_image_tags_exist.sh` to validate.
