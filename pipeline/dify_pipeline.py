"""
AGMind Pipeline — OpenAI-compatible proxy to Dify Service API.

Endpoints:
  GET  /health              → health check
  GET  /v1/models           → list Dify apps as models
  POST /v1/chat/completions → proxy chat to Dify (stream & non-stream)
"""

import json
import os
import time
import logging
from typing import AsyncIterator

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DIFY_BASE_URL = os.getenv("DIFY_BASE_URL", "http://api:5001").rstrip("/")
DIFY_API_KEY = os.getenv("DIFY_API_KEY", "")
VERSION = "1.0.0"

app = FastAPI(title="AGMind Pipeline", version=VERSION)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("pipeline")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _dify_headers() -> dict:
    return {
        "Authorization": f"Bearer {DIFY_API_KEY}",
        "Content-Type": "application/json",
    }


def _not_configured():
    return JSONResponse(
        status_code=503,
        content={
            "error": "Pipeline not configured",
            "hint": "Set DIFY_API_KEY in .env",
        },
    )


def _ts() -> int:
    return int(time.time())


# ---------------------------------------------------------------------------
# GET /health
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    dify_connected = False
    if DIFY_API_KEY:
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                r = await c.get(
                    f"{DIFY_BASE_URL}/v1/models",
                    headers=_dify_headers(),
                )
                dify_connected = r.status_code < 500
        except Exception:
            pass
    return {"status": "ok", "dify_connected": dify_connected, "version": VERSION}


# ---------------------------------------------------------------------------
# GET /v1/models
# ---------------------------------------------------------------------------
@app.get("/v1/models")
async def list_models():
    if not DIFY_API_KEY:
        return {"object": "list", "data": []}

    # Dify doesn't have a native /v1/models that lists apps.
    # We return a single synthetic model entry representing the configured app.
    return {
        "object": "list",
        "data": [
            {
                "id": "dify",
                "object": "model",
                "created": _ts(),
                "owned_by": "dify",
            }
        ],
    }


# ---------------------------------------------------------------------------
# POST /v1/chat/completions
# ---------------------------------------------------------------------------
@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    t0 = time.monotonic()
    client_ip = request.client.host if request.client else "-"

    if not DIFY_API_KEY:
        log.info("%s | %s | - | 503 | 0ms", time.strftime("%Y-%m-%d %H:%M:%S"), client_ip)
        return _not_configured()

    body = await request.json()
    stream = body.get("stream", False)
    model = body.get("model", "dify")

    # Build Dify payload from OpenAI format
    messages = body.get("messages", [])
    query = ""
    conversation_id = ""
    files = []

    # Extract last user message as query
    for msg in reversed(messages):
        if msg.get("role") == "user":
            content = msg.get("content", "")
            if isinstance(content, str):
                query = content
            elif isinstance(content, list):
                # multimodal: extract text parts
                parts = []
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        parts.append(part.get("text", ""))
                query = " ".join(parts)
            break

    if not query:
        return JSONResponse(status_code=400, content={"error": "No user message found"})

    dify_payload = {
        "inputs": {},
        "query": query,
        "response_mode": "streaming" if stream else "blocking",
        "conversation_id": conversation_id,
        "user": client_ip,
        "files": files,
    }

    dify_url = f"{DIFY_BASE_URL}/v1/chat-messages"

    try:
        if stream:
            result = await _stream_response(dify_url, dify_payload, model, client_ip, t0)
            return result
        else:
            return await _blocking_response(dify_url, dify_payload, model, client_ip, t0)
    except httpx.HTTPStatusError as e:
        latency = int((time.monotonic() - t0) * 1000)
        log.info("%s | %s | %s | %d | %dms", time.strftime("%Y-%m-%d %H:%M:%S"), client_ip, model, e.response.status_code, latency)
        return JSONResponse(
            status_code=e.response.status_code,
            content={"error": f"Dify API error: {e.response.text}"},
        )
    except Exception as e:
        latency = int((time.monotonic() - t0) * 1000)
        log.info("%s | %s | %s | 502 | %dms", time.strftime("%Y-%m-%d %H:%M:%S"), client_ip, model, latency)
        return JSONResponse(status_code=502, content={"error": str(e)})


# ---------------------------------------------------------------------------
# Blocking (non-stream) response
# ---------------------------------------------------------------------------
async def _blocking_response(url: str, payload: dict, model: str, client_ip: str, t0: float):
    async with httpx.AsyncClient(timeout=300) as c:
        r = await c.post(url, json=payload, headers=_dify_headers())
        r.raise_for_status()

    data = r.json()
    answer = data.get("answer", "")
    msg_id = data.get("message_id", "")

    latency = int((time.monotonic() - t0) * 1000)
    log.info("%s | %s | %s | 200 | %dms", time.strftime("%Y-%m-%d %H:%M:%S"), client_ip, model, latency)

    return {
        "id": f"chatcmpl-{msg_id}",
        "object": "chat.completion",
        "created": _ts(),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": answer},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": data.get("metadata", {}).get("usage", {}).get("prompt_tokens", 0),
            "completion_tokens": data.get("metadata", {}).get("usage", {}).get("completion_tokens", 0),
            "total_tokens": data.get("metadata", {}).get("usage", {}).get("total_tokens", 0),
        },
    }


# ---------------------------------------------------------------------------
# Streaming response (Dify SSE → OpenAI SSE)
# ---------------------------------------------------------------------------
async def _stream_response(url: str, payload: dict, model: str, client_ip: str, t0: float):

    async def generate() -> AsyncIterator[bytes]:
        msg_id = ""
        try:
            async with httpx.AsyncClient(timeout=300) as c:
                async with c.stream("POST", url, json=payload, headers=_dify_headers()) as resp:
                    resp.raise_for_status()
                    buffer = ""
                    async for chunk in resp.aiter_text():
                        buffer += chunk
                        while "\n" in buffer:
                            line, buffer = buffer.split("\n", 1)
                            line = line.strip()
                            if not line or not line.startswith("data:"):
                                continue
                            json_str = line[5:].strip()
                            if json_str == "[DONE]":
                                continue
                            try:
                                event = json.loads(json_str)
                            except json.JSONDecodeError:
                                continue

                            event_type = event.get("event", "")
                            msg_id = event.get("message_id", msg_id)

                            if event_type == "message":
                                token = event.get("answer", "")
                                if token:
                                    oai_chunk = {
                                        "id": f"chatcmpl-{msg_id}",
                                        "object": "chat.completion.chunk",
                                        "created": _ts(),
                                        "model": model,
                                        "choices": [
                                            {
                                                "index": 0,
                                                "delta": {"content": token},
                                                "finish_reason": None,
                                            }
                                        ],
                                    }
                                    yield f"data: {json.dumps(oai_chunk)}\n\n".encode()

                            elif event_type == "message_end":
                                # Final chunk with finish_reason
                                oai_chunk = {
                                    "id": f"chatcmpl-{msg_id}",
                                    "object": "chat.completion.chunk",
                                    "created": _ts(),
                                    "model": model,
                                    "choices": [
                                        {
                                            "index": 0,
                                            "delta": {},
                                            "finish_reason": "stop",
                                        }
                                    ],
                                }
                                yield f"data: {json.dumps(oai_chunk)}\n\n".encode()

                            elif event_type == "error":
                                error_msg = event.get("message", "Unknown error")
                                oai_chunk = {
                                    "id": f"chatcmpl-{msg_id}",
                                    "object": "chat.completion.chunk",
                                    "created": _ts(),
                                    "model": model,
                                    "choices": [
                                        {
                                            "index": 0,
                                            "delta": {"content": f"\n[Error: {error_msg}]"},
                                            "finish_reason": "stop",
                                        }
                                    ],
                                }
                                yield f"data: {json.dumps(oai_chunk)}\n\n".encode()

        except Exception as e:
            error_chunk = {
                "id": f"chatcmpl-error",
                "object": "chat.completion.chunk",
                "created": _ts(),
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "delta": {"content": f"\n[Pipeline error: {e}]"},
                        "finish_reason": "stop",
                    }
                ],
            }
            yield f"data: {json.dumps(error_chunk)}\n\n".encode()

        yield b"data: [DONE]\n\n"

        latency = int((time.monotonic() - t0) * 1000)
        log.info("%s | %s | %s | 200 | %dms", time.strftime("%Y-%m-%d %H:%M:%S"), client_ip, model, latency)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
