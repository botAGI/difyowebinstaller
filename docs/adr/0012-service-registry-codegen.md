# 0012. Service Registry as Single Source of Truth (YAML + Build-Time Codegen)

**Date:** 2026-05-16
**Status:** Accepted

## Context and Problem Statement

`lib/service-map.sh` (188 lines, 8 globals — 6 `declare -A` + 2 scalar strings)
encoded the canonical service catalog for AGmind v3.1.x: image-name → versions.env
key map, group membership, named meta-profile expansions, implied env defaults,
display order for the `agmind status` table, and the all-profiles list for
`compose down --remove-orphans`. Every addition or rename touched it. Drift was
silent: adding a service to `templates/docker-compose.yml` without updating
`service-map.sh` caused `agmind status` to miss it; adding it to
`service-map.sh` but not to compose made `compose down` skip a profile.

The hand-edited `NAME_TO_VERSION_KEY` table also accumulated **public CLI
aliases** across v3.1.x releases — keys like `dify-api`, `dify-worker`, `dify-web`,
`postgres`, `squid`, `plugin-daemon`, `openwebui`, `tei-embed` that mapped to
compose service names (`api`, `worker`, `web`, `db`, `ssrf_proxy`, `plugin_daemon`,
`open-webui`, `tei`). `agmind update <name>` and `agmind update rollback <name>`
accept all of these as documented CLI input. Any reorganization must preserve
that contract.

Phase 14 (`HEALTH-02B`, `RESOLVER-01..04`) and Phase 13 (golden tests) need
machine-readable service metadata that is not buried in bash assoc-arrays.

## Decision Outcome

**Chosen option:** "Declarative `templates/services/registry.yaml` as single
source of truth + build-time codegen to `lib/_registry.indexed.sh` (bash
assoc-arrays) which `lib/service-map.sh` sources. The 8 public symbols of
`service-map.sh` (`NAME_TO_VERSION_KEY`, `NAME_TO_SERVICES`, `SERVICE_GROUPS`,
`SERVICE_GROUP_ORDER`, `ALL_COMPOSE_PROFILES`, `NAMED_PROFILE_EXPANSION`,
`NAMED_PROFILE_DESC`, `NAMED_PROFILE_IMPLIED`) are preserved byte-identically;
all 4 lib-consumer modules and 2 scripts unchanged. Backward-compat CLI aliases
are preserved via a per-service optional `aliases:` field in the registry schema."

**Reason:**

- YAML is human-readable and diff-friendly. Adding a service is +6 lines in
  registry.yaml, not edits across 5 separate `declare -A` blocks scattered
  through `service-map.sh`.
- Codegen preserves the Phase 11 substrate pattern — `lib/_registry.indexed.sh`
  is git-committed and drift-detected via `git diff --exit-code` after
  `make registry-codegen`.
- Dual API backend (`yq` mikefarah v4 preferred; python3+PyYAML fallback)
  ensures the registry is readable at runtime on any host AGmind already
  provisions. PyYAML 6.0.3 ships preinstalled on Ubuntu CI runners and DGX
  Spark; `yq` is opportunistic.
- Air-gap compatibility: codegen never runs at install time. Generated
  artifact ships pre-built in the release tarball; `_copy_runtime_files`
  distributes it.
- Phase 13 golden tests and Phase 14 RESOLVER read the registry directly —
  no service-map shim needed for new consumers.

## Consequences

**Good:**

- Single source of truth for service metadata after Phase 12 — closes the
  silent-drift bug class structurally.
- Machine-readable catalog for Phase 13 golden tests, Phase 14 RESOLVER, and
  Phase 16 release tooling.
- Diff-friendly — adding a service is a localized +6-line YAML edit.
- Hermetic CI parity test — no docker daemon, no resolved env, pure PyYAML
  (mirrors the production pattern in `lib/estimate.sh::_est_services_for_profiles`).
- No new container images, no new runtime daemons.
- **`agmind status` now includes 5 previously hidden services** (init-containers
  and distroless exporters: `redis-lock-cleaner`, `ragflow_es_exporter`,
  `docker-socket-proxy`, `milvus-init`, `k6`). Status table grows from ~30 to
  ~35 rows. This surfaces failures in init/exporter containers that were
  silently invisible pre-Phase 12 — net win for ops visibility.

**Bad:**

- New build step (`make registry-codegen`) for any registry.yaml edit. CI
  drift gate fails LOUD if forgotten, but adds friction.
- One more file to ship (`lib/_registry.indexed.sh`) — minor disk cost
  (under 20 KB generated for 50 services + 8 aliases).
- Two ways to read service metadata at runtime: indexed bash file (fast, used
  by service-map.sh shim) and YAML via `lib/registry.sh` API (slower, used by
  future resolver + tests). Documented; both paths read from the same
  source-of-truth.

## Architectural Decisions

### Schema (v1)

Top-level keys: `schema_version`, `services`, `profile_expansions`,
`profile_descriptions`, `profile_implied`, `group_order`,
`all_compose_profiles`.

Per-service keys:
- `image_key` (str)               — `versions.env` reference
- `group` (str)                   — display group for `agmind status`
- `profiles` (list[str])          — raw compose profiles; empty = always-on
- `healthcheck` (enum)            — `present` / `absent` / `distroless-no-health`
- `mem_limit` (str, optional)     — compose mem_limit value; omit if compose has none
- `services_for_restart` (list, optional) — multi-service restart bundle
- `aliases` (list[str], optional) — extra short names accepted by `agmind update`
                                    CLI; codegen emits one `NAME_TO_VERSION_KEY`
                                    entry per alias in addition to the service name.

`schema_version: 1` is the bootstrap version. Future schema bumps require
this ADR addendum and a Phase 16+ migration note.

The `healthcheck` enum encodes the distroless-no-health rule documented in
ADR-0009: services like `loki`, `redis-exporter`, `nginx-exporter`, and
`alloy` have no `/bin/sh` and cannot run `CMD-SHELL` healthchecks — they
are tagged `distroless-no-health` so Phase 13 golden tests and any future
auto-generated healthcheck validator can skip them cleanly.

### Backward-compat CLI aliases (`aliases:` field)

`lib/service-map.sh:15-57` (pre-Phase-12) had 41 entries in `NAME_TO_VERSION_KEY`.
Of those, 8 were **not** compose service names but human-friendly aliases
consumed by `scripts/update.sh::resolve_component` (the `agmind update <name>`
CLI):

| Alias (CLI name) | Compose service | `image_key`             |
|------------------|-----------------|-------------------------|
| `dify-api`       | `api`           | `DIFY_VERSION`          |
| `dify-worker`    | `worker`        | `DIFY_VERSION`          |
| `dify-web`       | `web`           | `DIFY_VERSION`          |
| `postgres`       | `db`            | `POSTGRES_VERSION`      |
| `squid`          | `ssrf_proxy`    | `SQUID_VERSION`         |
| `plugin-daemon`  | `plugin_daemon` | `PLUGIN_DAEMON_VERSION` |
| `openwebui`      | `open-webui`    | `OPENWEBUI_VERSION`     |
| `tei-embed`      | `tei`           | `TEI_EMBED_VERSION`     |

These names are part of the v3.1.x public CLI contract and must continue to
resolve in v3.2.0. The registry schema preserves them via an optional
`aliases: [...]` list on each affected service:

```yaml
services:
  db:
    image_key: POSTGRES_VERSION
    # ...
    aliases: [postgres]
  ssrf_proxy:
    image_key: SQUID_VERSION
    # ...
    aliases: [squid]
  # ... etc for api/worker/web/plugin_daemon/open-webui/tei
```

The codegen step (`scripts/codegen/registry-to-indexed.sh`) emits both the
compose service name AND each alias as separate keys into
`NAME_TO_VERSION_KEY` and `NAME_TO_SERVICES`. Resulting count: 50 service
keys + 8 alias keys = 58 entries (vs 41 pre-Phase-12 — net gain because
several compose services like `k6`, `milvus-init`, `redis-lock-cleaner`,
`docker-socket-proxy`, `ragflow_es_exporter` are now exposed too).

Adding a new alias is a one-line registry.yaml edit; codegen + drift gate
handle the rest. Removing an alias is a breaking change to the public CLI
contract and requires an ADR addendum.

The parity test `tests/unit/test_service_map_parity.sh` asserts all 8
backward-compat aliases remain present in `NAME_TO_VERSION_KEY` after
refactor. The schema test `tests/unit/test_registry_schema.sh` asserts the
same 8 service→alias mappings exist in `registry.yaml`.

### Codegen pipeline

`scripts/codegen/registry-to-indexed.sh` reads registry.yaml (single
backend: python3+PyYAML for deterministic output) and writes
`lib/_registry.indexed.sh`.

**Determinism contract:** `sorted()` all keys; `' '.join(sorted(...))` all
multi-value strings; alias emit also uses `sorted()` to keep alias order
inside registry.yaml irrelevant. Re-running on unchanged input produces
byte-identical output. CI gate `tests/integration/test_registry_codegen_drift.sh`
re-runs codegen in a temp file and diffs against the committed artifact.

**Atomic write:** temp file + `mv` — Ctrl-C mid-generation leaves the
previous artifact intact.

**Header contract:** generated file begins with `# DO NOT HAND-EDIT` plus
a `Source SHA-12: <hash>` debug clue. The SHA is for operator forensics
only, not security.

### Runtime API (`lib/registry.sh`)

Four public functions:
- `reg_list_services` — sorted list of all service names
- `reg_get_profiles <svc>` — comma-joined profiles, empty = always-on
- `reg_get_group <svc>` — group label (default "optional")
- `reg_get_healthcheck <svc>` — enum value

Each function detects backend on first call. yq (mikefarah v4+) is preferred;
PyYAML fallback works on every AGmind host because Python 3 + PyYAML are
already installed by `install.sh` for other purposes. Tests can pre-set
`REG_BACKEND=python` (or `yq`) to force a specific branch independent of
host yq availability.

Exit codes:
- 0 — output emitted
- 1 — service unknown or registry unreadable
- 2 — no backend available (rare; logged as ERROR)

### Drift prevention

Three CI gates compound to prevent silent drift:

1. **Codegen no-drift** (`tests/integration/test_registry_codegen_drift.sh`)
   re-runs codegen and asserts no diff against the committed artifact.
   Catches "edited registry.yaml but forgot `make registry-codegen`".
2. **Registry-compose parity** (`tests/compose/test_registry_compose_parity.sh`)
   — 1:1 match between registry services + profiles and compose services +
   profiles; healthcheck enum sanity; AND an 8-named-profile sweep that
   expands each meta-profile (`core`, `rag`, `ragflow`, `observability`,
   `security`, `agents`, `full`, `dev`) via `profile_expansions` into raw
   profiles and verifies per-raw-profile set equality between registry and
   compose. Catches "added compose service but not registry entry", mismatched
   healthcheck flags, OR drift in named-profile expansions where individual
   services still appear consistent.
3. **No hand-edited service lists** (`tests/lint/test_no_hardcoded_service_lists.sh`)
   — STRICT mode (zero allowlist outside `lib/_registry.indexed.sh` and
   `scripts/codegen/registry-to-indexed.sh`). Catches "someone re-introduced
   `declare -A SERVICE_GROUPS=` in a new file".

### Air-gap compatibility

`lib/_registry.indexed.sh` is committed to git and shipped in release
tarballs. `install.sh::_copy_runtime_files` copies it (and `lib/registry.sh`
and `templates/services/registry.yaml`) into the runtime layout. **No
codegen ever runs on a customer machine.** The codegen script
(`scripts/codegen/registry-to-indexed.sh`) is a dev/CI tool — stays in the
repo, never copied to `${INSTALL_DIR}/scripts/`.

`lib/_registry.indexed.sh` is a sourceable data file, not an executable —
its repo mode is `100644` and `install.sh` explicitly applies `chmod 0644`
to its runtime copy after the broad `chmod +x ${INSTALL_DIR}/scripts/*.sh`
glob, so file permissions stay consistent dev ↔ runtime.

### Backward compatibility with `lib/service-map.sh` public API

The 8 public symbols remain available to consumers post-refactor.
`lib/service-map.sh` becomes a thin shim that resolves both dev (`lib/`) and
installed (`scripts/`) layouts:

```bash
if [[ -f "${_SM_DIR}/_registry.indexed.sh" ]]; then
    source "${_SM_DIR}/_registry.indexed.sh"
elif [[ -f "${_SM_DIR}/../lib/_registry.indexed.sh" ]]; then
    source "${_SM_DIR}/../lib/_registry.indexed.sh"
else
    echo "ERROR: _registry.indexed.sh not found" >&2; return 1
fi
```

All 4 lib-consumer modules (`compose.sh`, `health.sh`, `status.sh`,
`estimate.sh`) and 2 scripts (`agmind.sh`, `update.sh`) work unchanged.
The dormant-substrate pattern matches Phase 11 state-store: the substrate
lands now, live consumers may eventually adopt the YAML API in Phase 14
(`RESOLVER-02` for `lib/health.sh::resolve_active_services`) but `service-map.sh`
consumers stay on the indexed bash file for performance.

`agmind status` rendering behaviour: Phase 12 widens `SERVICE_GROUPS`
membership to include 5 services that were previously invisible
(`redis-lock-cleaner`, `ragflow_es_exporter`, `docker-socket-proxy`,
`milvus-init`, `k6`). The status table grows from ~30 to ~35 rows. Service
order within each group is now alphabetical (codegen sorts member names).
Functional behaviour of all consumers is unchanged.

### Schema migration policy

Schema bumps (e.g. v1 → v2) require:

1. New ADR addendum (or supersession) documenting the format change.
2. Update to `scripts/codegen/registry-to-indexed.sh` if the bash projection
   contract changes.
3. Migration note in `CHANGELOG.md` for the release that ships the bump.
4. Existing `lib/_registry.indexed.sh` regenerated as part of the bump
   commit.

Field additions inside schema v1 (new optional per-service key like
`mem_limit_alarm_pct`) do NOT bump schema_version — they are
backward-compatible additions; older registry.yaml files without the key
still parse cleanly with PyYAML default-None semantics. The `aliases:`
field was added as part of the v1 bootstrap and is treated as optional.

## Open Questions Resolved (Phase 12 spec)

The following design questions raised during Phase 12 research were locked
during planning:

- **OQ-1 — `lib/registry.sh` dual-layout path resolution:** YES, mirrors
  the `_SM_DIR` pattern in `lib/service-map.sh`. Both dev (`lib/`) and
  installed (`scripts/`) layouts work via REGISTRY_FILE env-var with a
  relative-path default.
- **OQ-2 — codegen output target:** only `lib/_registry.indexed.sh`. The
  `scripts/_registry.indexed.sh` runtime copy is produced by
  `install.sh::_copy_runtime_files`, not by codegen.
- **OQ-3 — registry.yaml runtime path:** `${INSTALL_DIR}/templates/services/registry.yaml`,
  mirroring the existing `templates/` runtime data convention (e.g.
  `templates/init-dify-plugin-db.sql`).
- **OQ-4 — drift gate location:** `tests/integration/` not `tests/lint/`,
  because the gate re-runs the codegen pipeline (an integration-style
  end-to-end check, not a pure pattern match).
- **OQ-5 — `active_when` env predicate:** deferred to Phase 14 RESOLVER.
  Registry v1 is a static catalog — what services exist, what profiles
  they live in. Dynamic active-set resolution (which services run for a
  given `LLM_PROVIDER=vllm + ENABLE_LITELLM=true` combination) is the
  resolver's job, not the registry's.
- **OQ-6 — codegen sort order:** alphabetical (`sorted()`) everywhere for
  deterministic byte-identical output across reruns. Alias lists also
  sorted before emit.
- **OQ-7 — yq binary install in install.sh:** deferred to Phase 16+.
  PyYAML fallback is sufficient for Phase 12; performance optimization
  can wait for the Phase 14 resolver implementation when the hot-path
  cost becomes measurable.
- **OQ-8 — `lib/health.sh::get_service_list` migration:** Phase 14
  RESOLVER-02 territory, NOT Phase 12. Registry ships dormant.
- **OQ-9 — parity test mem_limit check:** yes, included as the 4th check
  in `test_registry_compose_parity.sh`. Registry-declared mem_limit must
  have a corresponding compose `mem_limit:` block; default values can
  differ (env override flexibility).
- **OQ-10 — CLI alias preservation:** YES, modelled as optional per-service
  `aliases: [...]` list in the registry schema. Codegen emits one
  `NAME_TO_VERSION_KEY` entry per service AND per alias. The parity test
  asserts all 8 v3.1.x aliases survive the refactor (Blocker #1 contract).
- **OQ-11 — `agmind status` row growth:** ACCEPTED. Five previously
  hidden services surface (`redis-lock-cleaner`, `ragflow_es_exporter`,
  `docker-socket-proxy`, `milvus-init`, `k6`). This improves operator
  visibility into init-container and exporter health.

## Acceptance Evidence

- `tests/unit/test_registry_schema.sh` — REG-01 schema validation +
  backward-compat alias presence.
- `tests/unit/test_registry_api.sh` — REG-02 API coverage (yq + PyYAML
  backends + explicit `REG_BACKEND=python` override).
- `tests/integration/test_registry_codegen_drift.sh` — REG-03 drift gate.
- `tests/unit/test_service_map_parity.sh` — REG-04/05/06 public symbol
  preservation + alias presence + newly-visible services.
- `tests/compose/test_registry_compose_parity.sh` — REG-07 1:1 parity +
  8-named-profile sweep.
- `tests/lint/test_no_hardcoded_service_lists.sh` — REG-08 STRICT lint.
- `tests/lint/test_adr_0012_present.sh` — REG-09 ADR presence CI gate.
- `tests/unit/test_copy_runtime_files.sh` — install.sh wiring guard
  (Phase 12 extension verified).

## References

- `templates/services/registry.yaml` — source of truth (50 services + 8 aliases)
- `lib/_registry.indexed.sh` — generated artifact (DO NOT HAND-EDIT)
- `scripts/codegen/registry-to-indexed.sh` — codegen tool (dev/CI only)
- `lib/registry.sh` — YAML API (dual backend: yq mikefarah v4 / PyYAML 6+)
- `lib/service-map.sh` — thin shim sourcing the indexed file
- `tests/compose/test_registry_compose_parity.sh` — REG-07 parity gate
- `tests/lint/test_no_hardcoded_service_lists.sh` — REG-08 STRICT lint
- `tests/integration/test_registry_codegen_drift.sh` — codegen drift gate
- `docs/adr/0009-cadvisor-minio-arm64-holds.md` — distroless-no-health
  origin
- `docs/adr/0011-state-store-architecture.md` — analogous dormant
  substrate ADR
- `.planning/REQUIREMENTS.md` — REG-01..REG-09 (Phase 12)
- `.planning/phases/12-service-registry-codegen-parity-gates-adr-0012/12-RESEARCH.md`
  — full design rationale and verified primitives
