# Golden Snapshot Update Runbook

> AGmind Phase 13 / TEST-07 / D-14. Этот файл — runbook для **принятия** snapshot drift.
> Если ты читаешь это потому что CI упал — следуй чек-листу ниже.

## Prerequisites

- `docker` CLI установлен
- `docker compose` **v2.20+** (modern v2 plugin) — `docker compose version --short` должен вернуть ≥`2.20.0`
- Legacy `docker-compose` v1 (python) НЕ поддерживается (output format differences ломают byte-equivalence)
- Python 3.11+ для `scripts/golden-diff-summary.py`

Harness self-skip'ает (rc=77) если требования не выполнены — это OK для машин без docker, не FAIL.

## Когда ОК принимать drift

- ✅ Bump versions.env (postgres 17.2 → 17.3) — verified compat в changelog.
- ✅ Rename upstream блока в nginx (например, LLM_ON_PEER refactor).
- ✅ Добавлен новый service в registry.yaml + compose → новые строки в rendered compose.
- ✅ Sed-level templating change в `env.lan.template` (например, новая default value).

## Когда НЕ принимать (red flags 🚨)

- ❌ `gpu_memory_utilization: 0.70` или выше в shared-GPU compose — CLAUDE.md §8 «docling+vLLM shared GPU OOM».
- ❌ `:latest` в `image:` — §6 ban на mutable tags.
- ❌ `proxy_pass http://name;` БЕЗ `$` префикса — §8 nginx upstream IP locking.
- ❌ `minio/minio:RELEASE.*` ≠ pinned `2025-09-07T16-13-09Z` — §8 arm64 hold (verify через `docker manifest inspect`).
- ❌ `cadvisor:v0.5[6-9]` — §8 arm64 broken.
- ❌ `HTTP_REQUEST_NODE_MAX_TEXT_SIZE` уменьшилось — §8 ломает docling response.
- ❌ `PLUGIN_DAEMON_TIMEOUT` ниже 1800 — §8 валит heavy PDF.

`make golden-update` подсветит landmine-touching строки через `scripts/golden-diff-summary.py` —
если видишь ⚠️, **читай rationale в LANDMINES.md** прежде чем принимать.

## Workflow

```bash
# 1. Проверить какой scenario(ы) дрифтанули
bash tests/golden/run.sh --all
# Прочитать `tests/golden/.last-update.diff` если выпало.

# 2. Запустить интерактивный update
make golden-update SCENARIO=<name>            # один scenario (укажет какой)
# ИЛИ
AGMIND_GOLDEN_ACCEPT=1 make golden-update-all   # bulk

# 3. Прочитать summary
# scripts/golden-diff-summary.py выводит:
#   - image bumps : N
#   - mem_limit drift : N
#   - GPU memory ratio : N
#   - landmine-touching ⚠️ alerts (с anchor на §8)

# 4. ОБЯЗАТЕЛЬНО — commit с trailer
git add tests/golden/expected/<scenario>/
git commit -m "$(cat <<'EOF'
golden: update <scenario> after postgres minor bump

golden-accept-reason: postgres 17.2 → 17.3 — verified compat in upstream changelog
EOF
)"
```

## Trailer format

```
golden-accept-reason: <reason>
```

- Регекс enforcement: `^golden-accept-reason: [[:graph:]].{9,}` (≥10 non-space chars after `: `)
- Двойной gate: local pre-commit hook (`tests/golden/_commit_msg_guard.sh` через `.pre-commit-config.yaml`) + CI side check.
- **Никаких placeholder'ов** (`golden-accept-reason: ok` → REJECT). Сформулируй что меняется и **почему safe**.

## Valid examples

```
golden-accept-reason: postgres bump 17.2 → 17.3 — verified compat in upstream changelog
golden-accept-reason: nginx upstream rename to vllm-peer per LLM_ON_PEER cluster refactor
golden-accept-reason: dify env DIFY_LANG=ru added; en remains default in production
golden-accept-reason: docling-serve image bump 1.16.1 → 1.16.2 — verified arm64 manifest
```

## Invalid examples (will be rejected)

```
golden-accept-reason: ok                     ❌ 2 chars (need ≥10)
golden-accept-reason:                        ❌ empty
golden-accept-reason:    accept              ❌ leading whitespace fails [[:graph:]] first char
golden-accept                                ❌ missing `-reason:`
```

## Bypass (last resort)

Нет автоматического bypass. CI lane `golden-accept-reason-check` (Plan 13-06) проверяет
каждый commit в PR-touching `expected/`. Force-push в `main` blocked branch protection.

Если CI ловит false-positive (например, runner-specific output) — fix harness, не bypass.

## Auto-update в CI

❌ ЗАПРЕЩЕНО. `tests/golden/run.sh --update` отказывается работать если `AGMIND_GOLDEN_ACCEPT=1` И `CI=true`.
Snapshot acceptance — **сознательный человеческий акт**, не CI side-effect.
