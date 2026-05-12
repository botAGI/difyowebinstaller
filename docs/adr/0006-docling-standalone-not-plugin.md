# 0006. Docling Runs as Standalone Container, Not Dify Plugin

**Date:** 2026-04-25
**Status:** Accepted

## Context and Problem Statement

Document conversion and OCR in AGmind uses Docling-serve (cu130 GPU-accelerated build).
Docling was initially deployed as a Dify plugin (`s20ss/docling`) that ran inside the
plugin daemon container. This caused GPU memory contention and made it impossible to
tune batch sizes or GPU utilization independently from the plugin daemon lifecycle.

## Decision Outcome

**Chosen option:** "Run Docling as a standalone `agmind-docling` container (docling-serve cu130); remove s20ss/docling Dify plugin"

**Reason:** Two instances of Docling GPU inference running simultaneously — one in the
plugin daemon and one standalone — would compete for the same unified memory pool on GB10
and cause CUDA out-of-memory errors. The standalone architecture also enables independent
tuning of batch sizes (`LAYOUT_BATCH_SIZE`, `OCR_BATCH_SIZE`) and proper `mem_limit`
enforcement. The plugin daemon remains lightweight (~4 GiB ceiling) handling only
non-GPU Python plugins.

## Consequences

**Good:**
- No GPU contention between plugin daemon and document extraction.
- Docling GPU batch inference can be independently configured (`WORKERS`, `LAYOUT_BATCH_SIZE`,
  `OCR_BATCH_SIZE`, `UVICORN_WORKERS`).
- Plugin daemon stays lightweight; its `mem_limit` reflects actual usage (~645 MiB peak
  under load, 4 GiB ceiling with headroom).
- VLM picture description (`do_picture_description=true`) works cleanly with dedicated GPU access.

**Bad:**
- One additional container to operate and monitor (`agmind-docling`).
- Dify KB pipelines call Docling via an HTTP Request node
  (`POST http://docling:8765/v1/convert/file`) rather than via a native Dify plugin API.
- Any Docling plugin updates from `s20ss/docling` are no longer automatically available;
  feature upgrades require updating the standalone image in `templates/versions.env`.

## References

- `docs/architecture/data-flow.md` — document ingestion sequence diagram
- `docs/docling-presets.md` — configuration reference
- `templates/versions.env` — `DOCLING_VERSION` pin
- `docs/compatibility-matrix.md` (Docling row)
