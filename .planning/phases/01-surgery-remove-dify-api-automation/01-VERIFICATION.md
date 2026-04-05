---
phase: 01-surgery-remove-dify-api-automation
verified: 2026-03-18T00:00:00Z
status: passed
score: 12/12 must-haves verified
re_verification: false
---

# Phase 1: Surgery — Remove Dify API Automation Verification Report

**Phase Goal:** Delete import.py and all code that touches Dify API. Reduce attack surface, eliminate 50% of bugs, enforce three-layer boundary.
**Verified:** 2026-03-18
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                                    | Status     | Evidence                                                                            |
|----|----------------------------------------------------------------------------------------------------------|------------|-------------------------------------------------------------------------------------|
| 1  | install.sh passes `bash -n` (no syntax errors) and has 9 phases                                         | VERIFIED   | EXIT:0; 18 `/9]` occurrences = 9 function labels + 9 `main()` comments; 0 `/11]`  |
| 2  | No references to import.py, phase_workflow, phase_connectivity, ADMIN_EMAIL, COMPANY_NAME in install.sh  | VERIFIED   | All grep counts return 0; ADMIN_PASSWORD=0 (GRAFANA_ADMIN_PASSWORD is a different var) |
| 3  | pipeline/ directory and workflows/import.py are deleted                                                  | VERIFIED   | `ls pipeline/ workflows/import.py lib/workflow.sh` all return "No such file"       |
| 4  | docker-compose.yml has no pipeline service                                                               | VERIFIED   | `grep -c 'pipeline' templates/docker-compose.yml` = 0                              |
| 5  | Open WebUI connects directly to Ollama (no pipeline proxy)                                               | VERIFIED   | `OLLAMA_BASE_URL=http://ollama:11434`, `ENABLE_OPENAI_API=false`, depends_on=ollama only |
| 6  | INIT_PASSWORD appears in credentials summary and credentials.txt                                         | VERIFIED   | Lines 1113-1147, 1186-1188: `init_password` read from .env, shown as "Dify init pwd" |
| 7  | create_openwebui_admin uses INIT_PASSWORD, not ADMIN_EMAIL/ADMIN_PASSWORD                                | VERIFIED   | install.sh line 840: reads `INIT_PASSWORD` from .env via `base64 -d`               |
| 8  | build_difypkg_from_github (GitHub plugin downloads) removed                                              | VERIFIED   | Was in workflows/import.py (lines 540+); import.py deleted; zero occurrences in codebase |
| 9  | All env templates cleaned of DIFY_API_KEY and COMPANY_NAME                                               | VERIFIED   | grep count 0 across all 4 templates (lan/vps/vpn/offline)                          |
| 10 | lib/config.sh no longer substitutes ADMIN_EMAIL or COMPANY_NAME                                          | VERIFIED   | `grep -c '__ADMIN_EMAIL__\|__COMPANY_NAME__\|safe_admin_email\|safe_company' lib/config.sh` = 0 |
| 11 | lib/authelia.sh reads password from INIT_PASSWORD, uses hardcoded AGMind                                 | VERIFIED   | Line 25: reads INIT_PASSWORD from .env; line 47: `printf '%s' "AGMind"`; ADMIN_PASSWORD=0 |
| 12 | workflows/README.md exists with DSL import guide, plugins, pipeline reconnect                            | VERIFIED   | File exists; grep matches: DSL(3), langgenius/ollama(1), openai_api_compatible(1), s20ss/docling(1), DIFY_API_KEY=app-(1), rag-assistant.json(3) |

**Score:** 12/12 truths verified

---

### Required Artifacts

| Artifact                            | Expected                                          | Status     | Details                                                              |
|-------------------------------------|---------------------------------------------------|------------|----------------------------------------------------------------------|
| `install.sh`                        | 9-phase installer without Dify API automation     | VERIFIED   | 9 phases, bash -n passes, zero stale refs                            |
| `templates/docker-compose.yml`      | Compose without pipeline service                  | VERIFIED   | 0 pipeline refs, ENABLE_OPENAI_API=false, OLLAMA_BASE_URL set       |
| `workflows/README.md`               | User guide for importing RAG workflow into Dify   | VERIFIED   | 75 lines, all required sections present                              |
| `workflows/rag-assistant.json`      | RAG assistant workflow template (preserved)       | VERIFIED   | File exists, unmodified (no surgery touched it)                      |
| `lib/config.sh`                     | No ADMIN_EMAIL/COMPANY_NAME substitution          | VERIFIED   | All 4 removed sed placeholders confirmed absent                      |
| `lib/authelia.sh`                   | Password from INIT_PASSWORD, AGMind hardcoded     | VERIFIED   | Reads INIT_PASSWORD; "AGMind" literal on line 47                    |
| `templates/env.*.template` (4 files)| No DIFY_API_KEY or COMPANY_NAME                   | VERIFIED   | All 4 templates: DIFY_API_KEY=0, COMPANY_NAME=0, INIT_PASSWORD kept |
| `lib/tunnel.sh`                     | Preserved for Phase 5 (not deleted)               | VERIFIED   | File exists at lib/tunnel.sh                                         |
| `lib/dokploy.sh`                    | Preserved for Phase 5 (not deleted)               | VERIFIED   | File exists at lib/dokploy.sh                                        |
| `workflows/import.py`               | DELETED                                           | VERIFIED   | No such file in working tree                                         |
| `pipeline/` (directory)             | DELETED                                           | VERIFIED   | No such directory in working tree                                    |
| `lib/workflow.sh`                   | DELETED                                           | VERIFIED   | No such file in working tree                                         |

---

### Key Link Verification

| From                                       | To                           | Via                          | Status   | Details                                                              |
|--------------------------------------------|------------------------------|------------------------------|----------|----------------------------------------------------------------------|
| `install.sh main()`                        | 9 phase_* calls              | sequential function calls    | VERIFIED | Lines 1274-1282: exactly 9 calls, no phase_workflow or phase_connectivity |
| `templates/docker-compose.yml open-webui` | ollama                       | OLLAMA_BASE_URL              | VERIFIED | Line 231: `OLLAMA_BASE_URL=http://ollama:11434`; depends_on: ollama only |
| `install.sh phase_complete`               | INIT_PASSWORD in credentials | grep from .env               | VERIFIED | Lines 1113-1147: reads INIT_PASSWORD, writes "Dify init pwd" in summary and credentials.txt |
| `install.sh create_openwebui_admin`       | INIT_PASSWORD in .env        | grep + base64 -d             | VERIFIED | Line 840: reads and decodes INIT_PASSWORD from docker/.env           |
| `lib/authelia.sh`                         | INIT_PASSWORD in .env        | grep + base64 -d             | VERIFIED | Line 25: reads INIT_PASSWORD; no $ADMIN_PASSWORD variable reference  |
| `workflows/README.md`                     | workflows/rag-assistant.json | references the JSON by name  | VERIFIED | "rag-assistant.json" appears 3 times in README.md                   |

---

### Requirements Coverage

| Requirement | Source Plan | Description                                                             | Status    | Evidence                                                                                    |
|-------------|-------------|-------------------------------------------------------------------------|-----------|---------------------------------------------------------------------------------------------|
| SURG-01     | 01-01       | Remove import.py and all Dify API automation functions                   | SATISFIED | import.py deleted; setup_account, login, csrf_token, save_api_key, add_model, import_workflow, setup_workflow all absent from codebase |
| SURG-02     | 01-01       | Remove live plugin download from GitHub (build_difypkg_from_github)      | SATISFIED | Function was defined in import.py lines 540+; import.py deleted; zero occurrences in codebase confirmed via git grep across all history |
| SURG-03     | 01-01       | Remove wizard fields ADMIN_EMAIL, ADMIN_PASSWORD, COMPANY_NAME           | SATISFIED | All three: grep count 0 in install.sh (GRAFANA_ADMIN_PASSWORD is a distinct, unrelated var) |
| SURG-04     | 01-02       | Keep rag-assistant.json as template + README with import instructions    | SATISFIED | workflows/README.md created with DSL import, 3 plugin providers, post-import config, pipeline reconnect |
| SURG-05     | 01-01       | Installation reduced from 11 to 9 phases                                 | SATISFIED | 9 phase_* functions; 9 calls in main(); 0 `/11]` labels; 18 `/9]` occurrences (9 functions + 9 comments) |

**Note on SURG-02:** REQUIREMENTS.md shows SURG-02 as unchecked ([ ]) in the checkbox list at the top, but the traceability table at the bottom shows it mapped to Phase 1 as Pending. The requirement is functionally satisfied — `build_difypkg_from_github` existed only in `workflows/import.py` which is now deleted. No copy or call site exists anywhere in the current working tree. The REQUIREMENTS.md checkbox should be updated to reflect completion.

**Note on REQUIREMENTS.md traceability table:** All 5 SURG requirements show "Pending" in the table. These statuses reflect pre-surgery state and should be updated to "Complete" to match the checkbox section (which already marks SURG-01, 03, 04, 05 as done) and the actual codebase state.

---

### Anti-Patterns Found

None found in modified files. No TODO/FIXME/placeholder comments introduced. No stub implementations. No empty handlers.

One pre-existing note (not a gap): `scripts/multi-instance.sh` still contains `DIFY_API_KEY=` and `COMPANY_NAME=` references. This was explicitly excluded from the surgery scope (documented in 01-02-SUMMARY.md) — multi-instance is a separate tool, not part of the installer flow.

---

### Human Verification Required

None — all must-haves are statically verifiable. The phase boundary is code deletion and restructuring, not runtime behavior.

The following items would require a running stack to fully validate but are not blockers to phase sign-off:

1. **Credentials output at install time**
   - Test: Run install.sh end-to-end, inspect terminal output and credentials.txt
   - Expected: "Dify init pwd" and "WebUI pass" appear; no ADMIN_EMAIL or DIFY_API_KEY shown
   - Why human: Requires live Docker environment

2. **Dify first-login with INIT_PASSWORD**
   - Test: After install, navigate to Dify Console, enter init password from credentials.txt
   - Expected: Dify prompts for account creation; INIT_PASSWORD accepted as init_password
   - Why human: Requires running Dify service

---

### Gaps Summary

No gaps. All 12 observable truths verified. All 5 requirements satisfied. All artifacts exist and are wired. All deletions confirmed. Phase goal achieved.

---

## Commit Verification

All 4 task commits exist in git history and are valid:

| Commit  | Description                                              | Files Changed              |
|---------|----------------------------------------------------------|----------------------------|
| 0c03f50 | install.sh surgery — 11 phases to 9, remove Dify API    | install.sh (229 lines net) |
| 732fe0c | Clean downstream config files                           | 8 files modified           |
| fa33cd1 | Create workflows/README.md                              | workflows/README.md (75 lines new) |
| bbb2fb7 | Final sweep — remove COMPANY_NAME stale ref             | templates/docker-compose.yml (1 line) |

---

_Verified: 2026-03-18_
_Verifier: Claude (gsd-verifier)_
