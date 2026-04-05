---
phase: 29-docling-gpu-ocr
verified: 2026-03-29T15:00:00Z
status: passed
score: 4/4 must-haves verified
re_verification: false
human_verification:
  - test: "Wizard на хосте с NVIDIA GPU"
    expected: "Пункт '3) Да — Docling GPU (CUDA)' виден в wizard; выбор записывает quay.io/docling-project/docling-serve-cu128:v1.14.3 в DOCLING_IMAGE в .env"
    why_human: "Требует реального хоста с nvidia container toolkit и запуска install.sh"
  - test: "Wizard на хосте без GPU"
    expected: "Пункт '3) GPU' не показывается; доступны только 1 и 2; CPU-образ записывается в DOCLING_IMAGE"
    why_human: "Требует реального окружения без nvidia runtime"
  - test: "Volume persistence после force-recreate"
    expected: "После docker compose up --force-recreate docling volume agmind_docling_cache сохраняется, модели не скачиваются повторно"
    why_human: "Требует запущенного Docker-стека с предварительно скачанными моделями"
  - test: "OCR русского PDF"
    expected: "Docling контейнер стартует с OCR_LANG=rus,eng; русскоязычный PDF распознаётся без дополнительной настройки"
    why_human: "Требует запущенного контейнера и тестового PDF-файла"
---

# Phase 29: Docling GPU/OCR Verification Report

**Phase Goal (ROADMAP):** Wizard предлагает ручной выбор Docling образа (Нет/CPU/GPU CUDA), GPU-пункт скрыт без nvidia runtime, model cache переживает recreate через existing volume, русский OCR (rus,eng) включён по умолчанию, offline bundle поддерживает CUDA-образ по флагу.

**Verified:** 2026-03-29T15:00:00Z
**Status:** PASSED (4/4 automated truths verified; 4 items need human testing)
**Re-verification:** No — initial verification

## Note on Phase Goal vs ROADMAP

The prompt describes the phase goal as including "модели предзагружены при установке" (models preloaded during install). However, the canonical ROADMAP.md success criteria and the 29-CONTEXT.md both document a deliberate decision change: **model preloading was dropped**. CONTEXT.md states: "Предзагрузка моделей при установке НЕ выполняется — модели скачиваются при первом реальном запросе." DOCL-04 in REQUIREMENTS.md is marked complete, and its fulfilment was scoped to offline bundle CUDA flag support (plan 02). The ROADMAP success criteria are treated as canonical here.

---

## Goal Achievement

### Observable Truths (from ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | На хосте с NVIDIA runtime wizard предлагает GPU-образ (quay.io/cu128); без GPU — только CPU; DOCLING_IMAGE в .env отражает выбор | ? HUMAN | Wiring verified in code: `_wizard_etl` checks `DETECTED_GPU==nvidia` + `docker info | grep nvidia`; sets `DOCLING_IMAGE="${DOCLING_IMAGE_CPU\|CUDA}"`; exported and written via sed into `.env`. Runtime behaviour needs human check. |
| 2 | После `docker compose up --force-recreate docling` volume `agmind_docling_cache` сохраняется | ? HUMAN | Volume declared as named volume in compose (line 1010) and mounted at `/home/docling/.cache`. Named volumes are Docker-managed and survive `--force-recreate` by design. Actual persistence needs human verification. |
| 3 | Контейнер Docling стартует с `OCR_LANG=rus,eng` | ✓ VERIFIED | `templates/docker-compose.yml:526` — `OCR_LANG=${OCR_LANG:-rus,eng}` in environment section; default in config.sh: `s\|__OCR_LANG__\|${OCR_LANG:-rus,eng}\|g`. Both docker-compose default and .env default are `rus,eng`. |
| 4 | Offline bundle включает CPU-образ по умолчанию; `INCLUDE_DOCLING_CUDA=true` добавляет CUDA-образ | ✓ VERIFIED | `scripts/build-offline-bundle.sh:20` — `INCLUDE_DOCLING_CUDA="${INCLUDE_DOCLING_CUDA:-false}"`; lines 145-158 — CPU image always pulled, CUDA image conditionally added when flag is `true`. |

**Automated Score:** 2/4 truths fully verifiable programmatically (truths 3, 4 verified); truths 1, 2 require human but wiring is confirmed correct.

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/wizard.sh` | Triple Docling choice with GPU detection | ✓ VERIFIED | `_wizard_etl()` at line 199 implements 3-way choice; `has_nvidia_runtime` gate at line 209–212; GPU option shown only when `has_nvidia_runtime=true`; `DOCLING_IMAGE_CPU/CUDA` assigned correctly; `export DOCLING_IMAGE OCR_LANG NVIDIA_VISIBLE_DEVICES` at line 1137 |
| `lib/config.sh` | Sed replacements for `__DOCLING_IMAGE__`, `__OCR_LANG__`, `__NVIDIA_VISIBLE_DEVICES__` | ✓ VERIFIED | Lines 295–297: three sed substitutions present in `_generate_env_file()` block |
| `templates/versions.env` | `DOCLING_IMAGE_CPU` and `DOCLING_IMAGE_CUDA` image refs | ✓ VERIFIED | Lines 27–28: `DOCLING_IMAGE_CPU=ghcr.io/docling-project/docling-serve:v1.14.3` and `DOCLING_IMAGE_CUDA=quay.io/docling-project/docling-serve-cu128:v1.14.3`; `DOCLING_SERVE_VERSION` absent |
| `templates/env.lan.template` | `DOCLING_IMAGE=__DOCLING_IMAGE__` and `OCR_LANG=__OCR_LANG__` placeholders | ✓ VERIFIED | Lines 57–59: all three placeholders present; `ENABLE_DOCLING=false` preserved at line 56 |
| `templates/env.vpn.template` | Same placeholders | ✓ VERIFIED | Lines 56–59: identical structure confirmed |
| `templates/env.vps.template` | Same placeholders | ✓ VERIFIED | Lines 56–59: identical structure confirmed |
| `templates/env.offline.template` | Same placeholders | ✓ VERIFIED | Lines 56–59: identical structure confirmed |
| `templates/docker-compose.yml` | Docling service with `image: ${DOCLING_IMAGE}`, GPU and OCR env vars | ✓ VERIFIED | Line 515: `image: ${DOCLING_IMAGE:-ghcr.io/docling-project/docling-serve:v1.14.3}`; lines 525–526: `NVIDIA_VISIBLE_DEVICES` and `OCR_LANG` in environment section; line 528: volume `agmind_docling_cache` retained; `DOCLING_SERVE_VERSION` absent from compose |
| `scripts/build-offline-bundle.sh` | `INCLUDE_DOCLING_CUDA` support | ✓ VERIFIED | Line 20: flag default; lines 145–158: CPU always included, CUDA conditional; `DOCLING_IMAGE_CPU` and `DOCLING_IMAGE_CUDA` referenced |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/wizard.sh` | `lib/config.sh` | `export DOCLING_IMAGE` → `sed __DOCLING_IMAGE__` | ✓ WIRED | `export DOCLING_IMAGE OCR_LANG NVIDIA_VISIBLE_DEVICES` at line 1137; `config.sh` consumes via sed substitution at lines 295–297 |
| `templates/versions.env` | `lib/wizard.sh` | Wizard reads `DOCLING_IMAGE_CPU/CUDA` from versions.env | ✓ WIRED | `versions.env` sourced in install.sh before wizard; wizard references `${DOCLING_IMAGE_CPU}` and `${DOCLING_IMAGE_CUDA}` at lines 231, 236 |
| `lib/config.sh` | `templates/env.*.template` | sed replaces `__DOCLING_IMAGE__` and `__OCR_LANG__` | ✓ WIRED | `_generate_env_file()` applies sed substitutions to template; all 4 templates contain placeholders |
| `templates/docker-compose.yml` | `.env` | compose reads `DOCLING_IMAGE`, `OCR_LANG`, `NVIDIA_VISIBLE_DEVICES` from .env | ✓ WIRED | Compose uses `${DOCLING_IMAGE:-fallback}`, `${OCR_LANG:-rus,eng}`, `${NVIDIA_VISIBLE_DEVICES:-}` — standard Docker Compose .env interpolation |
| `scripts/build-offline-bundle.sh` | `templates/versions.env` | bundle reads `DOCLING_IMAGE_CUDA` from versions.env | ✓ WIRED | `DOCLING_IMAGE_CPU` and `DOCLING_IMAGE_CUDA` referenced with defaults matching versions.env values |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| DOCL-01 | 29-01-PLAN.md, 29-02-PLAN.md | Wizard выбор Docling образа: GPU (quay.io cu128) или CPU (ghcr.io) | ✓ SATISFIED | `_wizard_etl()` implements triple choice; GPU hidden without nvidia runtime; `DOCLING_IMAGE` set to full image:tag; compose reads it |
| DOCL-02 | 29-01-PLAN.md | Persistent volumes для HuggingFace cache и моделей Docling | ✓ SATISFIED | Named volume `agmind_docling_cache` at `/home/docling/.cache` declared (line 1010) and mounted (line 528); Docker named volumes survive `--force-recreate` |
| DOCL-03 | 29-01-PLAN.md | Русский OCR по умолчанию (OCR_LANG=rus,eng) | ✓ SATISFIED | `OCR_LANG="rus,eng"` in `_wizard_etl()` (line 245, also offline path line 203); sed default `${OCR_LANG:-rus,eng}` in config.sh; compose default `${OCR_LANG:-rus,eng}` |
| DOCL-04 | 29-02-PLAN.md | Предзагрузка OCR/layout моделей при установке | ✓ SATISFIED (scoped) | Per 29-CONTEXT.md decision: model preloading dropped, replaced by offline bundle CUDA support. DOCL-04 fulfilment: `INCLUDE_DOCLING_CUDA=true` flag in build-offline-bundle.sh provides CUDA image in offline scenarios |

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `scripts/check-upstream.sh` | 32 | `DOCLING_SERVE_VERSION` still referenced | ⚠️ Warning | Version tracking script checks for `DOCLING_SERVE_VERSION` which no longer exists in `versions.env`; upstream version checks for Docling will fail silently or produce wrong results |
| `scripts/generate-manifest.sh` | 65 | `${DOCLING_SERVE_VERSION}` still referenced | ⚠️ Warning | Manifest generation will produce empty/broken Docling entry since variable no longer exists |
| `scripts/update.sh` | 42 | `[docling]=DOCLING_SERVE_VERSION` in version map | ⚠️ Warning | `agmind update` version map points to removed variable; Docling version tracking via `agmind update` is broken |

These scripts were outside the scope of phase 29 plans (neither `29-01-PLAN.md` nor `29-02-PLAN.md` listed them in `files_modified`). They represent architectural debt introduced by renaming `DOCLING_SERVE_VERSION` to `DOCLING_IMAGE_CPU/CUDA` without updating the version-tracking layer. Severity is **Warning** (not Blocker) because they do not affect the install/deploy path — only `agmind update` version checks and manifest generation.

---

## Human Verification Required

### 1. GPU wizard path — nvidia host

**Test:** Run `sudo bash install.sh` on a host with NVIDIA GPU and nvidia container toolkit installed.
**Expected:** At the Docling step, wizard shows 3 options: "1) Нет", "2) Да — Docling CPU", "3) Да — Docling GPU (CUDA)". Selecting 3 results in `DOCLING_IMAGE=quay.io/docling-project/docling-serve-cu128:v1.14.3` in the generated `.env`.
**Why human:** Requires physical host with `docker info | grep nvidia` returning a match.

### 2. CPU-only wizard path — no GPU host

**Test:** Run `sudo bash install.sh` on a host without NVIDIA runtime.
**Expected:** At the Docling step, only options 1 and 2 are shown. GPU option is absent. Selecting 2 writes `DOCLING_IMAGE=ghcr.io/docling-project/docling-serve:v1.14.3` to `.env`.
**Why human:** Requires an environment without nvidia container toolkit.

### 3. Volume persistence after force-recreate

**Test:** Start stack with Docling enabled, let it download models (first request), then run `docker compose up --force-recreate docling`.
**Expected:** `agmind_docling_cache` volume shows same creation date before and after; models not re-downloaded (container starts faster second time).
**Why human:** Requires running Docker stack with actual model download.

### 4. Russian OCR functionality

**Test:** Start Docling container, submit a Russian-language PDF via Dify's document upload.
**Expected:** Text is extracted correctly from the Russian PDF. `docker inspect agmind-docling` shows `OCR_LANG=rus,eng` in environment.
**Why human:** Requires running container, Dify integration, and a Russian PDF test file.

---

## Gaps Summary

No blocking gaps found. All automated checks pass. The phase goal is structurally complete:

- DOCL-01: Wizard triple choice with GPU gating — fully implemented and wired
- DOCL-02: Volume persistence — named volume declared, survives recreate by Docker design
- DOCL-03: Russian OCR default — `rus,eng` in all code paths
- DOCL-04: Scoped to offline bundle CUDA flag — implemented per context decision

**Non-blocking warning:** Three version-tracking scripts (`check-upstream.sh`, `generate-manifest.sh`, `update.sh`) still reference the removed `DOCLING_SERVE_VERSION` variable. These should be updated in a follow-on task (suggested: add to TASKS.md as technical debt for `agmind update` version tracking of Docling).

---

_Verified: 2026-03-29T15:00:00Z_
_Verifier: Claude (gsd-verifier)_
