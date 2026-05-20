# LANDMINES.md — Machine-Readable §8 Invariants

> AGmind Phase 13 / TEST-05.
> Эта таблица — **single source of truth** для landmine-patterns. `tests/lint/LANDMINES.tsv`
> генерится из неё через `scripts/landmines-sync.sh` (или `make landmines-sync`).
> Hand-edit TSV запрещён (sync-test поймает drift).

## Conventions

- **`pattern`** — POSIX ERE для `grep -E`. PCRE-only конструкции (`(?!...)` etc.) не поддерживаются.
  Для exclusion logic использовать negative pattern + separate row OR в-rationale документировать compound approach.
  Distroless healthcheck rule enforced separately by `tests/unit/test_distroless_no_healthcheck.sh`
  (multi-line context analysis — line-level ERE can't express NEGATION).
- **`file_glob`** — `*` = scan все rendered configs; иначе literal substring match по basename
  (e.g., `docker-compose.rendered.yml`, `nginx.conf`, `.env.rendered`).
- **`severity`** — `critical` валит CI (exit 1); `warning` логирует (exit 0) для phase-in новых правил.
- **`claude_md_anchor`** — секция в CLAUDE.md (humans cross-link).
- **`introduced_at`** — YYYY-MM-DD аудит-trail.

## Adding a new landmine (§9 self-update)

1. Воспроизвести pattern locally: `grep -nE "<pattern>" tests/golden/expected/*/<file>` должен находить planted violation.
2. Добавить строку в таблицу ниже.
3. Запустить `make landmines-sync` (regen TSV) ИЛИ `bash scripts/landmines-sync.sh`.
4. Запустить `bash tests/lint/test_landmines_md_tsv_in_sync.sh` (должен PASS).
5. Запустить `bash tests/unit/test_golden_no_known_landmines.sh` (должен PASS на clean expected/).

## Catalog

| id  | pattern                                                                              | file_glob                    | severity | claude_md_anchor                          | rationale                                       | introduced_at |
|-----|--------------------------------------------------------------------------------------|------------------------------|----------|-------------------------------------------|-------------------------------------------------|---------------|
| L01 | `gpu_memory_utilization[[:space:]]*[:=][[:space:]]*"?0\.([7-9]\|6[1-9])`             | docker-compose.rendered.yml  | critical | §8 docling+vLLM shared GPU OOM            | shared-GPU max 0.60; >0.60 валит docling OOM    | 2026-05-17    |
| L02 | `:latest($\|[[:space:]]\|"\|')`                                                      | docker-compose.rendered.yml  | critical | §6 «Запрещено :latest»                    | image tag drift                                 | 2026-05-17    |
| L03 | `proxy_pass[[:space:]]+http://[^$]+;`                                                | nginx.conf                   | critical | §8 nginx upstream IP locking              | upstream без `$` блочит IP при container recreate | 2026-05-17  |
| L04 | `image:[[:space:]]+minio/minio:RELEASE\.[0-9]`                                       | docker-compose.rendered.yml  | warning  | §8 MinIO arm64 HOLD                       | любой RELEASE.* tag — verify против 2025-09-07T16-13-09Z в `test_image_tags_exist.sh`; warning тут для double-coverage | 2026-05-17 |
| L05 | `image:[[:space:]]+gcr\.io/cadvisor/cadvisor:v0\.5[6-9]`                             | docker-compose.rendered.yml  | critical | §8 cAdvisor v0.56+ arm64 broken           | arm64 manifest broken upstream                  | 2026-05-17    |
| L06 | `^HTTP_REQUEST_NODE_MAX_TEXT_SIZE=([0-9]\|[1-9][0-9])($\|[^0-9])`                    | .env.rendered                | critical | §8 Dify HTTP_REQUEST_NODE_MAX_TEXT_SIZE   | < 100MB ломает docling response handling        | 2026-05-17    |
| L07 | `^PLUGIN_DAEMON_TIMEOUT=([0-9]\|[1-9][0-9]\|[1-9][0-9]{2}\|1[0-7][0-9]{2})($\|[^0-9])` | .env.rendered              | critical | §8 PLUGIN_DAEMON_TIMEOUT = 1800           | < 1800 валит heavy PDF (400-600s docling)       | 2026-05-17    |
| L08 | `runtime:[[:space:]]+nvidia`                                                         | docker-compose.rendered.yml  | warning  | §8 NVIDIA_DRIVER_CAPABILITIES missing     | enforcer checks post-match: grep -A 30 from `runtime: nvidia` match line for `NVIDIA_DRIVER_CAPABILITIES`; missing = warning (silent CPU fallback) | 2026-05-17 |
| L09 | `vllm/vllm-openai:[^[:space:]]+gemma`                                                | docker-compose.rendered.yml  | warning  | §8 vLLM gemma4-cu130 pin                  | bumping past 26.02 breaks UMA stability         | 2026-05-17    |
| L10 | `^[[:space:]]*image:[[:space:]]+[^[:space:]#]+:0+(\.0+)?($\|[[:space:]])`            | docker-compose.rendered.yml  | warning  | §6 image:tag pinning rule                 | suspicious 0.0 / 0.0.0 tag — likely typo        | 2026-05-17    |
| L11 | `--speculative-config[[:space:]]+/`                                                  | *                            | critical | §8 vLLM JSON args via env, not path       | `--speculative-config` has argparse type=json.loads — vLLM rejects path values. Travel via VLLM_SPECULATIVE_CONFIG env consumed by templates/vllm-config/entrypoint.sh. Regression 9dcacb0 → caught 2026-05-18 on peer install timeout | 2026-05-18    |
| L12 | `--rope-scaling[[:space:]]+/`                                                        | *                            | critical | §8 vLLM JSON args via env, not path       | same root cause as L11 — `--rope-scaling` also type=json.loads. Use VLLM_ROPE_SCALING_CONFIG env. | 2026-05-18    |
