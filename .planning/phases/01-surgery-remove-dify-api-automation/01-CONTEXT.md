# Phase 1: Surgery — Remove Dify API Automation - Context

**Gathered:** 2026-03-17
**Status:** Ready for planning

<domain>
## Phase Boundary

Delete import.py and all code that touches Dify API. Remove live plugin download from GitHub. Simplify install.sh from 11 to 9 phases. Remove wizard fields no longer needed. Keep rag-assistant.json as template with README. The installer stops at "stack is running" — AI configuration is the user's job in Dify UI.

</domain>

<decisions>
## Implementation Decisions

### Phase structure (11 → 9)
- Remove `phase_workflow` (phase 8) — contains import.py invocation and DIFY_API_KEY setup
- Remove `phase_connectivity` (phase 10) — contains Dokploy and Tunnel setup
- Final 9-phase sequence: diagnostics → wizard → docker → config → start → health → models → backups → complete
- Renumber display labels accordingly (e.g., [8/9] backups, [9/9] complete)

### Wizard simplification
- Remove `ADMIN_EMAIL` field and all references — user creates own Dify account on first login via browser
- Remove `ADMIN_PASSWORD` field and all references — same reason
- Remove `COMPANY_NAME` field and all references — no longer needed after Dify account setup is removed
- Remaining wizard fields stay as-is: deploy profile, domain (VPS only), vector store, ETL enhancement, LLM model, embedding model, tunnel settings (now deferred — see below)

### Credentials summary (post-install output + credentials.txt)
- Remove ADMIN_EMAIL from summary — no longer collected
- Remove DIFY_API_KEY from summary — no longer auto-created (import.py gone)
- Keep in summary: Dify Console URL, Open WebUI URL + auto-generated password, Grafana URL + password, Portainer URL
- Add INIT_PASSWORD to summary — needed for Dify's initial first-login setup screen (`INIT_PASSWORD` from .env)
- All credentials written to credentials.txt (chmod 600); terminal shows path only (Phase 2 handles this hardening, Phase 1 can leave existing stdout behavior)

### rag-assistant.json — keep as template + README
- File stays at `workflows/rag-assistant.json`
- Create `workflows/README.md` with:
  1. What the RAG assistant workflow does (brief description)
  2. How to import DSL into Dify UI (Settings → DSL Import → upload JSON)
  3. Required plugins per provider:
     - Ollama → install `langgenius/ollama` plugin
     - vLLM / External → install `langgenius/openai_api_compatible` plugin
     - ETL enhanced → install `s20ss/docling` plugin
  4. Post-import configuration: which nodes to reconfigure (LLM node: select model, KB node: select knowledge base, Embedding node: select embedding model)
- README deploys to `/opt/agmind/workflows/README.md` alongside JSON

### pipeline/ directory — delete entirely
- Delete `pipeline/Dockerfile`, `pipeline/dify_pipeline.py`, `pipeline/requirements.txt`
- Reason: pipeline is the Open WebUI → Dify bridge via DIFY_API_KEY; without import.py there is no auto-created key, so pipeline has no value as automated infrastructure
- Add manual instructions to `workflows/README.md` (or a new `docs/advanced/openwebui-dify.md`):
  > "After creating an app in Dify UI: copy the Service API Key → set `DIFY_API_KEY=app-xxx` in `/opt/agmind/docker/.env` → run `docker compose restart pipeline openwebui`"

### Dokploy and Tunnel — remove from install flow, defer CLI tools
- Remove `phase_connectivity` invocation from `main()`
- Remove `lib/tunnel.sh` and `lib/dokploy.sh` from being called during install (or delete the lib files if they're only used by phase_connectivity)
- These are advanced use cases (multi-node, remote access) — not default install flow
- New CLI tools `agmind enable-tunnel` / `agmind enable-dokploy` are deferred to Phase 5
- Interim: document manual setup in `docs/advanced/` (Dokploy, Tunnel) — this is a best-effort addition during Phase 1, not a hard requirement

### Code files to delete
- `workflows/import.py` — entire file
- `pipeline/Dockerfile`
- `pipeline/dify_pipeline.py`
- `pipeline/requirements.txt`
- Functions to remove from `install.sh`: `setup_account()`, `login()`, `csrf_token()`, `save_api_key()`, `add_model()`, `phase_workflow()`, `phase_connectivity()`
- Variables to remove: `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `COMPANY_NAME` and all their usages (wizard prompt, export, summary display, env passing)

### Claude's Discretion
- Whether to keep `lib/tunnel.sh` and `lib/dokploy.sh` as files (for future Phase 5 use) or delete them
- Exact format of the `workflows/README.md` (tone, length)
- Whether to add a `docs/advanced/openwebui-dify.md` or fold those instructions into `workflows/README.md`
- Handling of any remaining minor references to deleted variables (Claude can grep and clean up)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Surgery scope
- `.planning/REQUIREMENTS.md` §Surgery — SURG-01 through SURG-05: exact list of what must be removed and kept
- `.planning/ROADMAP.md` §Phase 1 — Key deliverables and success criteria

### Code to delete
- `workflows/import.py` — full file, all functions are being removed
- `install.sh` — 1442 lines; key sections: phase_wizard (line 207), phase_workflow (line 1147), phase_connectivity (line 1186), credentials summary (line ~1262), main() call sequence (line ~1429)

No external specs — requirements are fully captured in decisions above and in REQUIREMENTS.md/ROADMAP.md.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `install.sh` phase structure (lines 172–1440): each phase is a named function; removing phases is a matter of deleting functions and removing calls from `main()`
- `lib/*.sh`: modular library files — tunnel.sh and dokploy.sh are only called from phase_connectivity; other lib files are unaffected

### Established Patterns
- Phase functions follow naming convention `phase_NAME()` with display label `[N/11]` — update display labels to `[N/9]` after removing 2 phases
- `NON_INTERACTIVE` variable guards all `read -rp` prompts — wizard simplification must handle both interactive and non-interactive paths
- Variables collected in wizard are exported at end of wizard function and again at start of phase_workflow — remove the phase_workflow export block entirely

### Integration Points
- `main()` at line ~1429 calls all phases sequentially — remove `phase_workflow` and `phase_connectivity` calls here
- Credentials summary in `phase_complete()` (line ~1215) reads `ADMIN_EMAIL`, `DIFY_API_KEY` — both must be removed from this function
- `install.sh` copies `workflows/import.py` to `INSTALL_DIR` at line 758 — this copy step must also be removed
- `.env` generation in `phase_config()` may reference `ADMIN_EMAIL`/`COMPANY_NAME` — scan and clean

</code_context>

<specifics>
## Specific Ideas

- INIT_PASSWORD in post-install summary: "needed for Dify's initial first-login setup screen" — show as `Dify init password: <value>` in credentials.txt
- `agmind enable-tunnel` and `agmind enable-dokploy` mentioned as future CLI commands — note these as Phase 5 items
- Manual pipeline connect instructions: "After creating app in Dify UI: copy Service API Key → set `DIFY_API_KEY=app-xxx` in `/opt/agmind/docker/.env` → `docker compose restart pipeline openwebui`"
- rag-assistant README provider plugin names: `langgenius/ollama`, `langgenius/openai_api_compatible`, `s20ss/docling`

</specifics>

<deferred>
## Deferred Ideas

- `agmind enable-tunnel` CLI command — Phase 5 (DevOps & UX)
- `agmind enable-dokploy` CLI command — Phase 5 (DevOps & UX)
- Advanced docs for Tunnel/Dokploy in `docs/advanced/` — best-effort in Phase 1, confirmed scope in Phase 5
- Credential stdout hardening (credentials.txt chmod 600, no stdout) — Phase 2 (Security Hardening v2, SECV-03)

</deferred>

---

*Phase: 01-surgery-remove-dify-api-automation*
*Context gathered: 2026-03-17*
