# AGmind Quickstart Guide

AGmind is a private RAG platform for NVIDIA DGX Spark (GB10). It deploys a complete
AI stack on your hardware with one command — no cloud, no data egress.

## What AGmind Is

AGmind runs 30+ containers on a single DGX Spark (or two Spark nodes in cluster mode):

- **Dify** — workflow orchestrator and primary user interface
- **vLLM** — local LLM inference (gemma-4-26B by default) on the Blackwell GPU
- **Weaviate** — vector database for semantic search
- **Docling-serve** — GPU-accelerated document extraction (PDF, DOCX, PPTX)
- **RAGFlow** (optional) — deep document parsing and retrieval pipeline
- **Monitoring** — Prometheus, Grafana, Loki with 10 dashboards

All data — documents, embeddings, conversations — stays on your hardware.

## Installing AGmind

One command brings up the full stack:

```bash
sudo bash install.sh
```

The installer wizard asks 10–15 questions (stack mode, LLM model, optional services,
security toggles, monitoring level). After about 25 minutes the stack is live at:

- Dify Console: `http://agmind-dify.local`
- RAGFlow: `http://agmind-rag.local`
- Grafana: `http://<spark-ip>:3001`

Credentials are saved to `/opt/agmind/credentials.txt` (chmod 600, root-only).

## Day-2 CLI: agmind

After install, the `agmind` CLI manages your stack without needing Docker knowledge:

### Diagnostics

```bash
agmind doctor                    # Full system diagnostics (drivers, mDNS, GPU, services)
agmind status                    # Service overview table (SERVICE | STATE | URL | NOTES)
agmind doctor --bundle           # Create support bundle for remote debugging (no secrets)
```

### Backup and Restore

```bash
sudo agmind backup create        # Backup PostgreSQL + Redis + Weaviate volumes
sudo agmind backup verify        # Check backup integrity
sudo agmind restore latest       # Restore from most recent backup (with dry-run support)
sudo agmind restore latest --dry-run   # Preview restore plan without changing anything
```

### Troubleshooting

```bash
agmind troubleshoot vllm         # vLLM not loading / CUDA issues
agmind troubleshoot dify         # Dify worker stuck / tasks hanging
agmind troubleshoot mdns         # mDNS / .local resolution problems
agmind troubleshoot memory       # OOM / unified memory budget
```

### Other Operations

```bash
agmind config validate           # Check .env validity, versions consistency
agmind profiles                  # List deployment profiles and active one
agmind estimate                  # RAM/disk/GPU estimates for current profile
agmind security audit            # Security posture scan (ports, docker.sock, secrets)
```

## Hardware Notes

AGmind runs on **NVIDIA DGX Spark (GB10 / aarch64 only)**. Key facts:

- 121 GiB unified memory (CPU + GPU share the same pool)
- AGmind budgets 85 GiB for containers (35 GiB reserved for kernel/swap/OS)
- NVIDIA driver 580.x — do not upgrade past 580.126.09 (confirmed regressions on GB10)
- For dual-Spark clusters: master node runs Dify/DB/monitoring; peer runs vLLM

## Knowledge Base RAG Pipeline

The typical knowledge base workflow in Dify:

1. Upload a document (PDF, DOCX, PPTX, MD, CSV, XLSX)
2. Docling-serve extracts text + OCR + optional VLM picture descriptions
3. Embeddings are generated via vLLM-embed (bge-m3, 1024-dim)
4. Vectors are stored in Weaviate with metadata
5. At query time: hybrid search (vector + BM25) → rerank → vLLM generates answer with citations

This document is the sample used by `agmind demo ingest` to test the pipeline end-to-end.
