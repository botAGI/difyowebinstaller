# Phase 15: Pull & Download UX - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Two improvements: (1) detect and report missing Docker images after compose pull; (2) show model download progress and handle timeout gracefully.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — infrastructure phase. Key constraints:

**DLUX-01 — Post-pull image validation (lib/compose.sh):**
1. After `wait "$pull_pid" || true` (line 76) — check exit code, don't just ignore
2. After the final `for img in "${images[@]}"` loop (line 81-83) — images with `ready` count < total
3. For each missing image: print `"ERROR: Образ не найден: <image:tag>. Проверьте versions.env"` in RED
4. Do NOT abort installation — log errors and continue (other images may have pulled fine)
5. Return non-zero from _pull_with_progress if ANY image missing (caller can decide severity)

**DLUX-02 — Model download progress (lib/models.sh + install.sh):**
1. In `pull_model()` (line 42): use `docker exec -it` instead of `docker exec` to pass TTY — Ollama shows progress bar when TTY is attached
2. BUT: in non-interactive installs (piped/logged output), `-it` may fail — use `docker exec -t` with fallback to `docker exec` if tty not available
3. For vLLM: model downloads at container startup — show `docker logs -f agmind-vllm` filtered for download progress lines during phase_health or phase_models
4. In `run_phase_with_timeout()` (install.sh): when phase_models times out — change from fatal error to WARNING + instruction: "Модель не скачана. Скачайте позже: agmind model pull <model>"
5. Phase_models timeout should NOT block progression to phase 8 (Backups) and phase 9 (Complete)

### Model Size Display
- Before Ollama pull: show approximate size — use a lookup table or parse Ollama manifest
- Keep it simple: hardcode common sizes (qwen2.5:14b ~8.5GB, qwen2.5:7b ~4.7GB, bge-m3 ~1.2GB)
- For unknown models: skip size display

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `_pull_with_progress()` in lib/compose.sh:44-85 — main pull function with background monitoring
- `_print_pull_status()` in lib/compose.sh:87-98 — progress display helper
- `pull_model()` in lib/models.sh:42-60 — single model pull via docker exec
- `download_models()` in lib/models.sh:146+ — orchestrator for all model downloads
- `run_phase_with_timeout()` in install.sh:91-114 — timeout wrapper with retry logic

### Established Patterns
- compose.sh uses background pull + polling loop for progress
- models.sh uses `docker exec agmind-ollama ollama pull` for downloads
- install.sh phase 7 (Models) uses run_phase_with_timeout with TIMEOUT_MODELS

### Integration Points
- lib/compose.sh:76 — `wait "$pull_pid" || true` (error swallowing)
- lib/compose.sh:80-84 — post-pull ready count
- lib/models.sh:54 — `docker exec agmind-ollama ollama pull "$model"`
- install.sh:101-113 — timeout/retry handling for phases
- install.sh:442 — phase_models invocation

</code_context>

<specifics>
## Specific Ideas

From WISH-010: "docker manifest inspect перед pull с понятным сообщением" — simplified to post-pull check (faster, no extra API calls).
From WISH-011: "Стримить docker logs -f agmind-ollama во время pull — Ollama выводит progress bar."

</specifics>

<deferred>
## Deferred Ideas

- Pre-pull manifest inspect (adds latency, API rate limits) — use post-pull check instead
- Download speed estimation / ETA display — too complex for v2.3

</deferred>
