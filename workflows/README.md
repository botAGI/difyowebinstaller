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

## Plugin Setup by Provider

After installation, install the Dify plugins for your chosen provider. Go to **Plugins** in Dify and search for the plugin name.

### Ollama

If you chose **Ollama** as your LLM or Embedding provider:

1. Install plugin: `langgenius/ollama`
2. Go to **Settings > Model Providers > Ollama**
3. Set Base URL: `http://ollama:11434`
4. Your models (e.g., `qwen2.5:14b`, `bge-m3`) will be auto-detected

### vLLM

If you chose **vLLM** as your LLM provider:

1. Install plugin: `langgenius/openai_api_compatible`
2. Go to **Settings > Model Providers > OpenAI-API-compatible**
3. Set API Endpoint URL: `http://vllm:8000/v1`
4. Set API Key: any non-empty value (e.g., `token-abc123`) — vLLM does not validate keys by default
5. Add your model name manually (must match the model running in vLLM, e.g., `Qwen/Qwen2.5-14B-Instruct`)

### TEI (Text Embeddings Inference)

If you chose **TEI** as your Embedding provider:

1. Install plugin: `langgenius/openai_api_compatible`
2. Go to **Settings > Model Providers > OpenAI-API-compatible**
3. Set API Endpoint URL: `http://tei:80/v1`
4. Set API Key: any non-empty value (e.g., `token-abc123`)
5. Add model name: `BAAI/bge-m3`
6. Set model type to **Text Embedding**

> **Note:** If you use both vLLM and TEI, add two separate OpenAI-API-compatible providers in Dify — one for LLM (vLLM endpoint) and one for Embedding (TEI endpoint).

### External API

If you chose **External API** as your provider:

1. Install plugin: `langgenius/openai_api_compatible`
2. Go to **Settings > Model Providers > OpenAI-API-compatible**
3. Set your external provider's API Endpoint URL and API Key
4. Add your model names manually

Compatible external providers: OpenAI, Azure OpenAI, Anthropic, Google AI, Groq, Together AI, and any OpenAI-compatible API.

### Enhanced ETL (Docling)

If you enabled Enhanced ETL during installation:

1. Install plugin: `s20ss/docling`
2. The Docling service is pre-configured at `http://docling:8765`
3. Go to **Settings > Document Processing** to select Docling as the parser

## Post-Import Configuration

After importing the workflow, configure these nodes:

1. **LLM Node** — Select your model from the configured provider
2. **Knowledge Base Node** — Create a Knowledge Base first, then select it
3. **Embedding Node** — Select your embedding model from the configured provider

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
