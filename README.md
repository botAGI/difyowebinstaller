<p align="center">
  <img src="branding/logo.svg" width="200" alt="AGMind Logo">
</p>

<h1 align="center">AGMind Installer</h1>

<p align="center">Production-ready AI stack in one command</p>

<p align="center">
  <a href="https://github.com/botAGI/AGmind/actions/workflows/test.yml"><img src="https://github.com/botAGI/AGmind/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License"></a>
  <img src="https://img.shields.io/badge/docker-ready-blue?logo=docker" alt="Docker Ready">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu 24.04 LTS">
</p>

<p align="center">
  <a href="README.ru.md">&#127479;&#127482; &#1056;&#1091;&#1089;&#1089;&#1082;&#1072;&#1103; &#1074;&#1077;&#1088;&#1089;&#1080;&#1103;</a>
</p>

---

## Why AGMind

| Feature | Manual Setup | AGMind |
| ------- | ------------ | ------ |
| Install time | Hours of YAML editing | **5 minutes**, one command |
| GPU detection | Read docs, edit configs | **Automatic** (NVIDIA, AMD, Intel, Apple M) |
| Rollback on failure | Hope and pray | **Automatic** image restore on healthcheck failure |
| Reboot survival | Write systemd units yourself | **Built-in** systemd service |
| Health monitoring | `docker ps` and guessing | **`agmind doctor`** with 15+ checks |
| Offline install | Effectively impossible | **`build-offline-bundle.sh`** with models |
| Security hardening | DIY firewall, SSH, 2FA | **Automated**: tiered cap_drop, fail2ban, Authelia, SOPS |
| Backup & DR | Manual pg_dump scripts | **Daily cron**, S3 upload, encryption, DR drills |
| Secret management | Passwords in .env | **Auto-generated** 64-char keys, rotation via CLI |
| Multi-profile deploy | One config fits none | **4 profiles**: LAN, VPN, VPS, Offline |

---

## Quick Start

```bash
git clone https://github.com/botAGI/AGmind.git
cd AGmind
sudo bash install.sh
```

The interactive wizard handles deploy profile, LLM/embedding provider, model selection, TLS, and monitoring. 23-34 containers, running in ~5 minutes.

**Non-interactive:**

```bash
sudo DEPLOY_PROFILE=lan LLM_PROVIDER=ollama LLM_MODEL=qwen2.5:14b \
     EMBED_PROVIDER=ollama bash install.sh --non-interactive
```

---

## After Installation

| Service | URL | Notes |
|---------|-----|-------|
| Open WebUI (chat) | `http://<server>/` | Main interface |
| Dify Console | `http://<server>:3000/` | Workflow builder |
| Health endpoint | `http://<server>/health` | JSON status of all services |
| Grafana | `http://127.0.0.1:3001/` | When `MONITORING_MODE=local` |
| Portainer | `https://127.0.0.1:9443/` | When `MONITORING_MODE=local` |

Admin credentials: `/opt/agmind/credentials.txt` (chmod 600, never printed to stdout).

---

## CLI Reference

Installed as `/usr/local/bin/agmind`. Manages the full stack without memorizing Docker commands.

| Command | Description | Root |
|---------|-------------|------|
| `agmind status` | Containers, GPU, models, endpoints, credentials path | no |
| `agmind status --json` | Machine-readable JSON output | no |
| `agmind doctor` | Diagnostics: disk, RAM, Docker, GPU, DNS, ports, .env | no |
| `agmind doctor --json` | Diagnostics as JSON (for CI/monitoring) | no |
| `agmind update --check` | Show available version updates (no changes) | yes |
| `agmind update` | Interactive rolling update with automatic rollback | yes |
| `agmind update --component <name> --version <tag>` | Update a single service | yes |
| `agmind backup` | Manual backup (DB + volumes + config) | yes |
| `agmind restore <path>` | Restore from backup archive | yes |
| `agmind rotate-secrets` | Regenerate all passwords and API keys | yes |
| `agmind logs [service]` | Tail Docker Compose logs | no |
| `agmind uninstall` | Remove the entire stack | yes |
| `agmind help` | Show all commands | no |

**Examples:**

```bash
agmind status                    # Quick overview of running services
agmind doctor                    # Full health check (exit 0=ok, 1=warn, 2=critical)
agmind update --check            # See which images have newer versions
sudo agmind update --component dify-api --version 1.4.0   # Update one service
sudo agmind backup && ls /var/backups/agmind/              # Backup and verify
```

---

## Architecture

```
                          +-----------+
                          |   nginx   |  :80 / :443
                          +-----+-----+
                            /       \
                 +---------+         +-----------+
                 | Open    |         | Dify Web  |
                 | WebUI   |         | + Console |
                 +---------+         +-----+-----+
                                       /       \
                               +------+    +--------+
                               |  API |    | Worker |
                               +--+---+    +---+----+
                                  |            |
              +--------+   +------+------------+----------+
              |Plugin  |   |      |            |          |
              |Daemon  |   |  +---+---+  +-----+----+ +--+------+
              +--------+   |  | Redis |  |Ollama/   | |Weaviate/|
                           |  +-------+  |vLLM/TEI  | |Qdrant   |
  +-------------+     +----+---+         +----------+ +---------+
  | SSRF Proxy  +-----+Sandbox |
  | (Squid)     |     +--------+    +----------+
  +-------------+                   | Postgres |
                                    +----------+

  Monitoring (optional): Prometheus -> Grafana, Loki -> Promtail,
                         cAdvisor, Alertmanager, Portainer
```

The installer deploys infrastructure only. All AI configuration (workflows, knowledge bases, model connections) happens through the Dify and Open WebUI interfaces.

---

## LLM Providers

| Provider | Type | Key Feature |
|----------|------|-------------|
| Ollama | Local | Auto-downloads models, GPU/CPU inference |
| vLLM | Local (production) | OpenAI-compatible API, tensor parallelism |
| TEI | Local (embedding) | HuggingFace Text Embeddings Inference |
| External | Remote | OpenAI, Anthropic, or any OpenAI-compatible API |

The installer wizard detects GPU/RAM and recommends the optimal model automatically.

---

## Requirements

| Parameter | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu 20.04, Debian 11, CentOS Stream 9 | Ubuntu 22.04+ |
| RAM | 4 GB | 16 GB+ (32 GB for GPU inference) |
| CPU | 2 cores | 4+ cores |
| Disk | 20 GB | 100 GB+ SSD |
| Docker | 24.0+ | 27.0+ (installed automatically) |
| Compose | 2.20+ | 2.29+ (installed automatically) |
| GPU (optional) | NVIDIA Pascal+ / AMD ROCm | Ampere+ (CUDA 12.0+) |

Pre-flight checks run automatically. Skip with `SKIP_PREFLIGHT=true`.

---

## Update System

```bash
sudo agmind update --check                               # Version comparison table
sudo agmind update --component dify-api --version 1.4.0  # Update single service
sudo agmind update                                        # Full rolling update
```

Flow: pre-flight check, automatic backup, image pull, rolling restart per service, healthcheck verification. If a healthcheck fails after update, the previous image tag is restored automatically. Zero manual intervention required.

---

## Health & Diagnostics

`agmind doctor` runs 15+ checks in one pass:

- **Disk**: free space warnings at <15% and <5%
- **RAM**: available memory vs running services
- **Docker**: daemon status, compose version, socket access
- **GPU**: driver loaded, CUDA/ROCm available, device accessible
- **Containers**: unhealthy, exited, restart loops (>3 in 15 min)
- **HTTP endpoints**: Open WebUI, Dify API, health endpoint reachability
- **.env completeness**: required variables present, no placeholder values

Exit codes: `0` = all green, `1` = warnings, `2` = critical failures. Use `--json` for integration with monitoring systems.

---

## Security

- **Tiered security**: `cap_drop` on infrastructure (DB, Redis, nginx, monitoring); Dify app services (API, Worker, Plugin Daemon) use Dify's own isolation (SSRF proxy, sandbox, plugin process isolation)
- **SSH hardening** with lockout prevention (validates key access before disabling passwords)
- **Authelia 2FA** on admin routes (`/console/*`)
- **SSRF sandbox** on isolated network, blocks RFC1918 + link-local + metadata endpoints
- **SOPS + age encryption** for `.env` at rest (VPS profile)
- **Credentials** stored in `credentials.txt` (chmod 600), never printed to stdout or logs
- **Redis** dangerous commands disabled (FLUSHALL, CONFIG, DEBUG, SHUTDOWN)
- **Auto-generated secrets**: 64-char SECRET_KEY, 32-char passwords, rejects `changeme`/`password`
- **Nginx**: rate limiting (10r/s API, 1r/10s login), security headers, `server_tokens off`

| Security Feature | LAN | VPN | VPS | Offline |
| ---------------- | --- | --- | --- | ------- |
| Fail2ban | yes | yes | yes | no |
| UFW firewall | no | no | yes | no |
| SOPS encryption | no | no | yes | no |
| SSH hardening | yes | yes | yes | yes |
| Container hardening | yes | yes | yes | yes |

---

## GPU Support

| GPU | Detection | Docker Method |
|-----|-----------|---------------|
| NVIDIA (CUDA) | `nvidia-smi` | deploy.resources.reservations |
| AMD (ROCm) | `/dev/kfd` + `rocminfo` | Device passthrough + `OLLAMA_ROCM=1` |
| Intel Arc | `/dev/dri` + `lspci` | Device passthrough |
| Apple M (Metal) | arm64 + Darwin | Native Metal (GPU blocks removed) |
| CPU fallback | Automatic | GPU blocks removed, `OLLAMA_NUM_PARALLEL=2` |

Override detection: `FORCE_GPU_TYPE=amd` or `SKIP_GPU_DETECT=true`. vLLM uses `cu130` image suffix for Blackwell and newer GPUs.

---

## Backup & DR

```bash
sudo agmind backup                                        # Manual: DB dumps + volumes + config + checksums
sudo agmind restore /var/backups/agmind/2026-03-15_0300   # Restore from archive
```

Automated cron runs daily at 3:00 AM. Supports S3 upload via rclone (`ENABLE_S3_BACKUP=true`), age encryption (`ENABLE_BACKUP_ENCRYPTION=true`), and monthly DR drills (`ENABLE_DR_DRILL=true`). Retention is configurable (`BACKUP_RETENTION_COUNT=10`).

---

## Offline Installation

```bash
# 1. On a machine with internet access
./scripts/build-offline-bundle.sh --include-models qwen2.5:14b,bge-m3 --platform linux/amd64

# 2. Transfer the archive to the air-gapped server

# 3. Install
sudo DEPLOY_PROFILE=offline bash install.sh
```

The bundle includes all Docker images, models, and installer files. No internet required during installation.

---

## Project Structure

```
AGmind/
├── install.sh          # Main installer: 10 phases, checkpoint/resume
├── lib/                # Modular Bash libraries (detect, config, health, security, ...)
├── scripts/            # Day-2 ops scripts (agmind CLI, backup, restore, update, ...)
├── templates/          # Docker Compose, versions.env, .env templates, nginx configs
├── monitoring/         # Prometheus, Grafana dashboards, Loki, alert rules
├── branding/           # Open WebUI white-label assets (logo, theme)
├── docs/               # Docusaurus documentation site
└── LICENSE             # Apache 2.0
```

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-change`)
3. Make your changes
4. Run `bash -n` on changed scripts
5. Submit a pull request

All shell scripts must pass `shellcheck` and `bash -n`. CI runs syntax checks on every PR.

---

## License

[Apache License 2.0](LICENSE) -- Copyright 2024-2026 AGMind Contributors
