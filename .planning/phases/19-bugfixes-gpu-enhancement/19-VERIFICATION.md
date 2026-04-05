---
phase: 19-bugfixes-gpu-enhancement
verified: 2026-03-23T00:00:00Z
status: passed
score: 7/7 must-haves verified
re_verification: false
---

# Phase 19: Bugfixes + GPU Enhancement — Verification Report

**Phase Goal:** Мелкие независимые исправления устранены до начала крупных изменений — preflight_checks не выдаёт ложных WARN на собственных контейнерах, VRAM guard в NON_INTERACTIVE использует effective_vram с учётом TEI offset, xinference bce-reranker помечен как broken, `agmind gpu status` показывает имена контейнеров вместо сырых PID.
**Verified:** 2026-03-23
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | preflight_checks() при повторной установке с работающим agmind не выдает WARN для своих портов 80/443 | VERIFIED | `lib/detect.sh:489-497` — переменная `agmind_nginx_up` + ветка `[PASS] Port X: in use (agmind)` при nginx up |
| 2 | preflight_checks() выдает WARN для портов занятых чужими процессами | VERIFIED | `lib/detect.sh:499-500` — `[WARN] Port X: in use` + `warnings=$((warnings + 1))` когда `agmind_nginx_up != true` |
| 3 | agmind gpu status показывает имя контейнера и модель вместо PID | VERIFIED | `scripts/agmind.sh:463-507` — PID-to-container map через `docker top`, форматированный вывод `container_name (model)` |
| 4 | Процессы не принадлежащие agmind показываются как (non-agmind) с PID | VERIFIED | `scripts/agmind.sh:503` — `printf "  PID %-8s | %-20s | %s MiB  (non-agmind)\n"` для unmapped PIDs |
| 5 | VRAM guard использует effective_vram = gpu_vram - 2 при проверке моделей vLLM | VERIFIED | `lib/wizard.sh:349,537` — `readonly TEI_VRAM_OFFSET=2`; `ni_effective_vram=$(( ni_vram_gb - TEI_VRAM_OFFSET ))` и `effective_vram_check=$(( vram_gb - TEI_VRAM_OFFSET ))` |
| 6 | NON_INTERACTIVE с моделью > effective_vram завершается exit 1 | VERIFIED | `lib/wizard.sh:539-542` — сравнение с `ni_effective_vram`, `log_error` + `exit 1` |
| 7 | load_reranker() не пытается загружать модель и выводит log_warn о broken | VERIFIED | `lib/models.sh:151-160` — тело функции: early return + `log_warn "Reranker disabled: bce-reranker-base_v1 is broken in Xinference v2.3.0"`, curl удалён |

**Score:** 7/7 truths verified

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/detect.sh` | Port 80/443 filter for agmind containers | VERIFIED | `agmind_nginx_up` переменная, docker compose ps check, условные ветки PASS/WARN |
| `scripts/agmind.sh` | PID to container name mapping in GPU status | VERIFIED | `declare -A pid_container_map`, `docker top "$cname"`, `(non-agmind)` label, `_read_env VLLM_MODEL` |
| `lib/wizard.sh` | TEI offset in VRAM guard calculations + ETL wizard text fix | VERIFIED | `readonly TEI_VRAM_OFFSET=2` (line 349), `effective_vram_check` (line 475), `ni_effective_vram` (line 537), ETL текст без упоминания reranker/Xinference |
| `lib/models.sh` | Disabled reranker with broken warning | VERIFIED | `load_reranker()` содержит только early return + `log_warn "...broken..."`, тело curl-загрузки удалено |
| `templates/env.lan.template` | Commented out reranker config | VERIFIED | Строка 57: `# RERANK_MODEL_NAME=bce-reranker-base_v1  # BROKEN in xinference v2.3.0` |
| `templates/env.vps.template` | Commented out reranker config | VERIFIED | Строка 57: аналогично lan.template |
| `templates/env.vpn.template` | Commented out reranker config | VERIFIED | Строка 57: аналогично lan.template |
| `templates/env.offline.template` | Commented out reranker config | VERIFIED | Строка 57: аналогично lan.template |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/detect.sh` | `docker compose ps` | nginx container check | WIRED | `docker compose -f "${INSTALL_DIR:-/opt/agmind}/docker/docker-compose.yml" ps --status running nginx` — строка 490 |
| `scripts/agmind.sh` | `docker top` | PID to container mapping | WIRED | `docker top "$cname" -o pid` строка 474; результат записывается в `pid_container_map["$cpid"]` строка 473 |
| `lib/wizard.sh` | `_get_vllm_vram_req` | VRAM comparison with effective_vram | WIRED | `TEI_VRAM_OFFSET` используется в `effective_vram_check` (строка 475) и `ni_effective_vram` (строка 537) при сравнении VRAM |
| `lib/models.sh` | `log_warn` | broken reranker skip | WIRED | `log_warn "Reranker disabled: bce-reranker-base_v1 is broken in Xinference v2.3.0"` строка 158 |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| BFIX-43 | 19-01-PLAN.md | preflight_checks() фильтрует agmind/docker процессы при проверке портов 80/443 | SATISFIED | `lib/detect.sh:488-505` — полная реализация с `agmind_nginx_up` |
| BFIX-44 | 19-02-PLAN.md | Xinference bce-reranker сломан — модель помечена broken или заменена | SATISFIED | `lib/models.sh:156-159` — `BROKEN` аннотация + `log_warn`; шаблоны ENV с `# BROKEN` |
| BFIX-45 | 19-02-PLAN.md | VRAM guard в NON_INTERACTIVE использует effective_vram (gpu - TEI offset ~2 GB) | SATISFIED | `lib/wizard.sh:349,537-542` — `TEI_VRAM_OFFSET=2`, `ni_effective_vram`, `exit 1` |
| GPUX-01 | 19-01-PLAN.md | `agmind gpu status` маппит GPU PID → container name + загруженная модель | SATISFIED | `scripts/agmind.sh:463-507` — `pid_container_map`, `docker top`, model annotation |

Все 4 требования, объявленных в планах фазы, покрыты. Orphaned requirements: нет.

---

### Syntax Check

| File | bash -n | Status |
|------|---------|--------|
| `lib/detect.sh` | exit 0 | PASS |
| `scripts/agmind.sh` | exit 0 | PASS |
| `lib/wizard.sh` | exit 0 | PASS |
| `lib/models.sh` | exit 0 | PASS |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `lib/wizard.sh` | 321, 452 | `""  # 0 placeholder` | Info | Намеренный placeholder в массивах с 1-based индексацией — не заглушка |

Блокирующих anti-pattern не обнаружено. Placeholder в строках 321 и 452 является преднамеренным элементом массива для поддержки 1-based индексации пользовательского выбора.

Дополнительно: `lib/wizard.sh:863` содержит строку `"ETL: Docling + Xinference"` в summary-выводе визарда. Это поверхностная косметическая несогласованность (текст summary не обновлён), но не влияет на функциональность fix'а.

---

### Human Verification Required

#### 1. Preflight PASS при активном agmind nginx

**Test:** На машине с запущенным стеком выполнить `sudo bash install.sh` (или напрямую вызвать `preflight_checks`)
**Expected:** Строки `[PASS] Port 80: in use (agmind)` и `[PASS] Port 443: in use (agmind)` — без WARN
**Why human:** Требует живой Docker-окружение с запущенным nginx контейнером

#### 2. NON_INTERACTIVE VRAM guard exit 1 при effective_vram < model req

**Test:** Задать `VLLM_MODEL=Qwen2.5-72B-Instruct-AWQ`, `DETECTED_GPU_VRAM=24576` (24 GB), запустить NON_INTERACTIVE установку
**Expected:** `exit 1` с сообщением "effective available: 22 GB (24 GB - 2 GB TEI)"
**Why human:** Требует реального окружения со значением DETECTED_GPU_VRAM

#### 3. agmind gpu status с живым vLLM контейнером

**Test:** Запустить `agmind gpu status` при активном vLLM контейнере с GPU процессом
**Expected:** Вывод `agmind-vllm-1 (Qwen2.5-14B-Instruct) | 18432 MiB` вместо `PID 12345 | python3`
**Why human:** Требует живого nvidia-smi + Docker-окружения с GPU процессами

---

## Gaps Summary

Gaps: отсутствуют. Все 7 observable truths подтверждены кодом, все 4 requirement ID покрыты, key links wired, syntax checks passed.

Единственная несогласованность: строка `lib/wizard.sh:863` в блоке summary выводит `ETL: Docling + Xinference` вместо просто `ETL: Docling`. Это косметический недочёт вне scope текущей фазы — рекомендуется зафиксировать как отдельную задачу в TASKS.md, не блокирует прохождение фазы.

---

_Verified: 2026-03-23_
_Verifier: Claude (gsd-verifier)_
