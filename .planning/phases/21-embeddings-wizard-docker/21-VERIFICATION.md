---
phase: 21-embeddings-wizard-docker
verified: 2026-03-23T00:00:00Z
status: passed
score: 5/5 must-haves verified
---

# Phase 21: Embeddings Wizard + Docker Verification Report

**Phase Goal:** Пользователь выбирает embedding модель в отдельном шаге визарда, выбор записывается в .env и используется docker-compose для TEI-embed контейнера.
**Verified:** 2026-03-23
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth | Status | Evidence |
|----|-------|--------|---------|
| 1  | Wizard shows embedding model menu with 3 models + custom when EMBED_PROVIDER=tei | VERIFIED | `lib/wizard.sh:597-620` — `_wizard_embedding_model()` shows 4-item TEI menu (BAAI/bge-m3, Qwen3-Embedding-0.6B, multilingual-e5-large-instruct, manual input) when `EMBED_PROVIDER == "tei"` |
| 2  | Selected EMBEDDING_MODEL is written to .env with full HuggingFace ID | VERIFIED | `lib/wizard.sh:965` exports `EMBEDDING_MODEL`; `lib/config.sh:231,257` substitutes `__EMBEDDING_MODEL__` in env templates; all 4 env templates (lan/vps/vpn/offline) have `EMBEDDING_MODEL=__EMBEDDING_MODEL__` placeholder |
| 3  | TEI container in docker-compose uses EMBEDDING_MODEL variable instead of hardcoded model | VERIFIED | `templates/docker-compose.yml:353`: `command: --model-id ${EMBEDDING_MODEL:-BAAI/bge-m3} --port 80`; zero occurrences of bare `--model-id BAAI/bge-m3 --port` remain |
| 4  | NON_INTERACTIVE mode uses EMBEDDING_MODEL from env if set, otherwise defaults to BAAI/bge-m3 | VERIFIED | `lib/wizard.sh:583-593` — NON_INTERACTIVE block returns early if `EMBEDDING_MODEL` is non-empty and not "bge-m3"; otherwise sets `BAAI/bge-m3` for tei, `bge-m3` for ollama |
| 5  | Ollama embed provider still uses existing _ask prompt flow (no TEI menu) | VERIFIED | `lib/wizard.sh:623-633` — ollama branch calls `_ask "Модель эмбеддингов [bge-m3]:"` unchanged from previous behavior |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/wizard.sh` | `_wizard_embedding_model()` with TEI model menu | VERIFIED | Function at line 581; contains all 3 preset models + manual input option; called from `run_wizard()` at line 951; syntax check passes (`bash -n`) |
| `templates/docker-compose.yml` | Parameterized TEI model-id | VERIFIED | Line 353: `--model-id ${EMBEDDING_MODEL:-BAAI/bge-m3} --port 80` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/wizard.sh` | `lib/config.sh` | `export EMBEDDING_MODEL` | WIRED | `lib/wizard.sh:965` exports `EMBEDDING_MODEL` in `run_wizard()` |
| `lib/config.sh` | `templates/env.*.template` | `sed __EMBEDDING_MODEL__` | WIRED | `lib/config.sh:231,257` — `safe_embedding_model` via `escape_sed`, substituted into all 4 profile templates which contain `EMBEDDING_MODEL=__EMBEDDING_MODEL__` |
| `templates/docker-compose.yml` | `.env` | docker-compose variable substitution | WIRED | `${EMBEDDING_MODEL:-BAAI/bge-m3}` on line 353; fallback ensures backward compatibility |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|---------|
| EMBD-01 | 21-01-PLAN.md | Новый шаг визарда `_wizard_embedding_model()` с выбором TEI модели (BAAI/bge-m3, Qwen3-Embedding-0.6B, multilingual-e5-large-instruct, ввод вручную) | SATISFIED | Function at `lib/wizard.sh:581`; all 4 menu options verified; `_ask_choice "Выбор [1-4, Enter=1]: " 1 4 1` at line 606; old `_wizard_embed_model` is absent |
| EMBD-02 | 21-01-PLAN.md | Переменные EMBEDDING_MODEL и EMBED_PROVIDER=tei записываются в .env и используются docker-compose | SATISFIED | Export chain: wizard.sh → config.sh → env templates; docker-compose uses `${EMBEDDING_MODEL:-BAAI/bge-m3}` |

### Anti-Patterns Found

No anti-patterns detected. No TODOs, placeholders, or empty implementations found in the two modified files. Both commits (112b813, d0a2f45) verified in git log.

### Human Verification Required

#### 1. Interactive TEI menu flow

**Test:** Run `sudo bash install.sh` on a machine, select TEI as embed provider, verify menu displays 4 options, select option 3, confirm `.env` contains `EMBEDDING_MODEL=intfloat/multilingual-e5-large-instruct`.
**Expected:** `.env` has full HuggingFace ID; `docker-compose config` shows `--model-id intfloat/multilingual-e5-large-instruct --port 80` in TEI service command.
**Why human:** Interactive shell flow cannot be tested programmatically.

#### 2. Custom model ID validation

**Test:** Run wizard interactively, choose option 4 (Ввод вручную), enter an invalid model name (e.g. spaces or special chars).
**Expected:** Warning logged, fallback to `BAAI/bge-m3`.
**Why human:** Requires interactive input and visual confirmation of warning text.

### Gaps Summary

No gaps. All 5 observable truths verified, both artifacts present and substantive, all 3 key links wired, both requirement IDs (EMBD-01, EMBD-02) satisfied. No orphaned requirements found.

---

_Verified: 2026-03-23_
_Verifier: Claude (gsd-verifier)_
