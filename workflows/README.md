# RAG Assistant Workflow

Pre-built workflow template for Dify that provides a Retrieval-Augmented Generation assistant.

## What This Does

The `rag-assistant.json` file is a Dify DSL (Domain Specific Language) workflow that:
- Accepts user questions via chat interface
- Retrieves relevant context from a Knowledge Base
- Generates answers using your configured LLM
- Supports conversation history

## How to Import

1. Open Dify Console in your browser (default: `http://<your-ip>:3000`)
2. On first visit, set up your admin account using the init password shown during installation
3. Go to **Studio** (top nav)
4. Click **Create from DSL** (or **Import DSL** in the app list)
5. Upload `rag-assistant.json` from `/opt/agmind/workflows/`
6. The workflow will appear in your app list

## Required Plugins

After importing, install the plugins your provider needs. Go to **Plugins** in Dify and search for:

### Ollama (default)
- `langgenius/ollama` — Ollama model provider

### vLLM / External OpenAI-compatible API
- `langgenius/openai_api_compatible` — OpenAI-compatible model provider

### Enhanced ETL (if enabled during install)
- `s20ss/docling` — Advanced document parsing

## Post-Import Configuration

After importing the workflow, configure these nodes:

1. **LLM Node** — Select your model (e.g., `qwen2.5:14b` for Ollama)
2. **Knowledge Base Node** — Create a Knowledge Base first, then select it in this node
3. **Embedding Node** — Select your embedding model (e.g., `bge-m3` for Ollama)

### Setting Up Model Providers

1. Go to **Settings > Model Providers**
2. Add your provider:
   - **Ollama**: Base URL = `http://ollama:11434`
   - **vLLM**: Base URL = `http://vllm:8000/v1`
   - **External API**: Enter your provider's URL and API key

## Connecting Open WebUI to Dify (Optional)

By default, Open WebUI connects directly to Ollama for chat. If you want Open WebUI
to use Dify workflows (for RAG, agents, etc.), you need to set up the pipeline bridge:

1. Create an app in Dify UI and publish it
2. Go to **API Access** in your app and copy the **Service API Key**
3. Edit `/opt/agmind/docker/.env`:
   ```
   DIFY_API_KEY=app-xxxxxxxxxxxxxxxx
   ```
4. Rebuild and restart the pipeline service:
   ```bash
   cd /opt/agmind/docker
   docker compose up -d --build pipeline
   docker compose restart open-webui
   ```

> **Note:** The pipeline service container is not started by default.
> It requires a valid DIFY_API_KEY to function.

## Files

- `rag-assistant.json` — Dify DSL workflow template (do not edit unless customizing)
- `README.md` — This file
