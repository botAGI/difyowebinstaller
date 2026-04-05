---
phase: 20-xinference-removal
verified: 2026-03-23T09:00:00Z
status: gaps_found
score: 5/7 must-haves verified
gaps:
  - truth: "ENABLE_RERANKER flag introduced as separate flag replacing ETL_ENHANCED for reranker control"
    status: failed
    reason: "ENABLE_RERANKER does not exist anywhere in the codebase. ROADMAP Goal, Success Criterion #2, and XINF-02 all require it, but implementation deferred it to Phase 22 without updating the requirement text or the phase goal."
    artifacts:
      - path: "lib/wizard.sh"
        issue: "No ENABLE_RERANKER variable, default, wizard step, or export"
      - path: "lib/compose.sh"
        issue: "No ENABLE_RERANKER profile logic"
      - path: "templates/env.lan.template"
        issue: "No ENABLE_RERANKER=false line"
      - path: "templates/env.vps.template"
        issue: "No ENABLE_RERANKER=false line"
      - path: "templates/env.vpn.template"
        issue: "No ENABLE_RERANKER=false line"
      - path: "templates/env.offline.template"
        issue: "No ENABLE_RERANKER=false line"
    missing:
      - "ENABLE_RERANKER variable stub (defaulting to false) in wizard.sh, compose.sh, and all 4 env templates, OR update ROADMAP Goal, XINF-02 description, and Success Criterion #2 to correctly reflect that ENABLE_RERANKER belongs to Phase 22"
  - truth: "ETL_ENHANCED fully replaced — no non-compat standalone use remains"
    status: partial
    reason: "ETL_ENHANCED appears correctly only inside backward-compat expansions (${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}). This is correct and intentional. No standalone assignments remain. Partial only because XINF-02 gap affects the broader 'ETL_ENHANCED replaced by two flags' framing."
    artifacts: []
    missing: []
human_verification:
  - test: "Install from scratch with default profile, then run: docker ps | grep xinference"
    expected: "No xinference container appears — zero rows"
    why_human: "Requires a live Docker environment to run install.sh"
  - test: "Install with ENABLE_DOCLING=true, verify: docker ps | grep docling"
    expected: "agmind-docling container is running, no agmind-xinference container"
    why_human: "Requires live install to verify profile activation"
  - test: "Simulate upgrade from old install (with agmind-xinference container present): run agmind update and verify container/volume removed"
    expected: "Container agmind-xinference stopped and removed; volume agmind_xinference_data removed"
    why_human: "Requires existing legacy installation to simulate"
---

# Phase 20: Xinference Removal — Verification Report

**Phase Goal:** Xinference убран из обязательного стека — реранк через TEI-rerank, Docling независим от Xinference, флаг ETL_ENHANCED заменён на раздельные ENABLE_DOCLING и ENABLE_RERANKER.
**Verified:** 2026-03-23T09:00:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Xinference service block removed from docker-compose.yml | VERIFIED | `grep -c "xinference" templates/docker-compose.yml` = 0; profile `docling` present at line 502 |
| 2 | Profile `etl` renamed to `docling` in docker-compose.yml and compose.sh | VERIFIED | `grep "- docling" docker-compose.yml` hits line 502; `grep "\- etl$"` = 0 |
| 3 | ETL_ENHANCED replaced by ENABLE_DOCLING in wizard, compose, config (with backward-compat shim) | VERIFIED | `ENABLE_DOCLING="${ENABLE_DOCLING:-${ETL_ENHANCED:-false}}"` (wizard.sh:28); compose.sh:25; config.sh:242 — ETL_ENHANCED only in compat expansions |
| 4 | load_reranker() and all call sites removed from lib/models.sh | VERIFIED | `grep -c "load_reranker" lib/models.sh` = 0; `grep -c "XINFERENCE RERANKER" lib/models.sh` = 0 |
| 5 | Env templates use ENABLE_DOCLING instead of Xinference vars | VERIFIED | All 4 templates (lan/vps/vpn/offline) have `ENABLE_DOCLING=false` at line 56; zero XINFERENCE references |
| 6 | Peripheral scripts, configs, and docs free of Xinference references (except update.sh cleanup) | VERIFIED | agmind.sh, check-upstream.sh, generate-manifest.sh, check-manifest-versions.py = 0 xinference refs; COMPONENTS.md, COMPATIBILITY.md, versions.env = 0; release-manifest.json valid JSON, 0 xinference entries |
| 7 | ENABLE_RERANKER flag introduced as separate control replacing ETL_ENHANCED for reranker | FAILED | ENABLE_RERANKER does not exist anywhere outside .planning/. ROADMAP Goal, Success Criterion #2, and XINF-02 all require it. CONTEXT.md deferred it to Phase 22 without updating the requirement. |

**Score: 5/7 truths verified**

---

### Required Artifacts (Plan 20-01)

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `templates/docker-compose.yml` | Docling in profile docling, no xinference service or volume | VERIFIED | Profile `docling` at line 502; 0 xinference matches; agmind_xinference_data volume gone |
| `lib/compose.sh` | build_compose_profiles with ENABLE_DOCLING and backward-compat shim | VERIFIED | Lines 23-27: ENABLE_DOCLING with ETL_ENHANCED fallback, profile `docling` |
| `lib/wizard.sh` | ENABLE_DOCLING variable, fixed summary line | VERIFIED | Lines 28, 195, 206, 207, 863, 918: all use ENABLE_DOCLING |
| `lib/models.sh` | No load_reranker function, no xinference references | VERIFIED | 0 matches for load_reranker, 0 matches for xinference |

### Required Artifacts (Plan 20-02)

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/agmind.sh` | gpu assign without xinference option | VERIFIED | Line 584: "Valid services: vllm, tei"; line 646: help text updated |
| `scripts/update.sh` | Xinference orphan cleanup in update flow | VERIFIED | Lines 981-991: cleanup block in main() before perform_bundle_update |
| `templates/versions.env` | No XINFERENCE_VERSION line | VERIFIED | `grep -c "XINFERENCE_VERSION" templates/versions.env` = 0 |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| lib/wizard.sh | lib/compose.sh | export ENABLE_DOCLING | WIRED | wizard.sh:918 exports ENABLE_DOCLING; compose.sh:25 reads it with compat fallback |
| lib/compose.sh | templates/docker-compose.yml | profile docling in COMPOSE_PROFILE_STRING | WIRED | compose.sh appends `docling` to profiles string; docker-compose.yml Docling service declares `profiles: [docling]` |
| lib/config.sh | templates/env.*.template | ENABLE_DOCLING → ETL_TYPE=unstructured_api | WIRED | config.sh:242 maps ENABLE_DOCLING=true to ETL_TYPE=unstructured_api |
| scripts/update.sh | docker (runtime) | cleanup orphan xinference container on update | WIRED | Lines 981-991: docker stop/rm + docker volume rm with safe no-op guards |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| XINF-01 | 20-01, 20-02 | Xinference убран из обязательного стека | SATISFIED | Service removed from docker-compose, 0 refs in all scripts, orphan cleanup in update.sh |
| XINF-02 | 20-01 | ETL_ENHANCED заменён на ENABLE_DOCLING + ENABLE_RERANKER | BLOCKED | ENABLE_DOCLING fully implemented and wired. ENABLE_RERANKER absent from codebase. The requirement explicitly states both flags. |
| XINF-03 | 20-01 | Docling перенесён в отдельный profile `docling`, независимый от Xinference | SATISFIED | Profile renamed etl→docling in docker-compose.yml and compose.sh; ENABLE_DOCLING=true activates only docling |

**XINF-02 gap note:** The CONTEXT.md (`.planning/phases/20-xinference-removal/20-CONTEXT.md`) line 25 explicitly states: "ENABLE_RERANKER появится в фазе 22 вместе с TEI reranker". However, REQUIREMENTS.md, the ROADMAP Goal, and Success Criterion #2 all specify ENABLE_RERANKER as part of Phase 20 scope. The requirement text was not updated to reflect the deferral decision. The gap is real against the stated ROADMAP and REQUIREMENTS.md contracts.

---

### Anti-Patterns Found

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| None | No stubs, no TODO/FIXME/placeholder in modified files | — | — |

Scan performed on: templates/docker-compose.yml, lib/wizard.sh, lib/compose.sh, lib/config.sh, lib/models.sh, lib/health.sh, templates/env.*.template, scripts/agmind.sh, scripts/update.sh, scripts/uninstall.sh, templates/versions.env, COMPONENTS.md, COMPATIBILITY.md.

---

### Human Verification Required

#### 1. Default install — no xinference container

**Test:** Run `sudo bash install.sh` with default (non-docling) profile, then `docker ps | grep xinference`
**Expected:** Zero rows — xinference container not started
**Why human:** Requires live Docker environment

#### 2. Docling profile activation

**Test:** Run install with `ENABLE_DOCLING=true`, then `docker ps | grep -E "docling|xinference"`
**Expected:** `agmind-docling` running; no `agmind-xinference` row
**Why human:** Requires live Docker environment with ENABLE_DOCLING set

#### 3. Upgrade migration (orphan cleanup)

**Test:** On an existing installation that has `agmind-xinference` container and `agmind_xinference_data` volume, run `agmind update`
**Expected:** Cleanup block fires, container and volume removed before the update proceeds
**Why human:** Requires legacy installation state to reproduce

---

### Gaps Summary

**One real gap blocking full XINF-02 satisfaction:** The ENABLE_RERANKER flag does not exist in the codebase. Both the ROADMAP Goal and REQUIREMENTS.md XINF-02 require that ETL_ENHANCED be replaced by TWO flags — ENABLE_DOCLING and ENABLE_RERANKER. The implementation correctly introduces ENABLE_DOCLING and the backward-compat shim, but ENABLE_RERANKER was deferred to Phase 22.

**Resolution options (pick one):**

1. **Add a minimal ENABLE_RERANKER stub now** — `ENABLE_RERANKER="${ENABLE_RERANKER:-false}"` default in wizard.sh with export, and `ENABLE_RERANKER=false` in all 4 env templates. No actual reranker container yet (that's Phase 22). This satisfies the flag-split contract at minimum cost.

2. **Update the planning artifacts** — Change XINF-02 in REQUIREMENTS.md to say "ETL_ENHANCED заменён на ENABLE_DOCLING; ENABLE_RERANKER вводится в Phase 22 (RNKR-01)". Update the ROADMAP Goal and Success Criterion #2 to remove ENABLE_RERANKER from Phase 20 scope. Mark XINF-02 as satisfied.

Option 1 is safer (code contract) since REQUIREMENTS.md is the source of truth. Option 2 is acceptable only if the requirement was always intended to be split across phases.

---

_Verified: 2026-03-23T09:00:00Z_
_Verifier: Claude (gsd-verifier)_
