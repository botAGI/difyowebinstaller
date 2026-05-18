# Changelog

All notable changes to AGmind are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.2.0] — YYYY-MM-DD

### Architecture release: state store + service registry + golden tests + Go scaffolding.

Closes the v3.2.0 milestone (58 REQ-IDs across 7 phases, 35/35 plans complete).
v3.2.0 is **infrastructure code only** — zero new container images, zero new
daemons, zero new product features. Net diff ~+3500 / −500 LOC. Driven by
`AGmind-Autofix-Architecture-Spec-v1.0.2` §9.2 (deferred from v3.1.2 hotfix).

The release lands four substrates that future milestones (v3.3+, v4.0 Go port)
build on: versioned state store at `/var/lib/agmind/state/`, declarative service
registry at `templates/services/registry.yaml` with build-time codegen, byte-exact
golden tests under `tests/golden/`, and namespace-reserving Go scaffolding placeholders.

Three High findings deferred from v3.1.2 close in this milestone: **HEALTH-02B**
(resolver consolidation), **ENV-PARSE-01** (legacy `grep|cut` env parser migration),
**DUPLICATION-01** (`lib/X.sh` ↔ `scripts/X.sh` reconcile).

Target platform is unchanged: DGX Spark (GB10, aarch64), LAN profile only.

### Added — Architecture

**State store substrate (Phases 11 + 14):**

- **STATE-01** — `/var/lib/agmind/state/` directory created on install with `0700 root:root` perms.
- **STATE-02** — `lib/state.sh` API: `state_get` / `state_set` / `state_get_secret` / `state_set_secret` with `flock` per-file locking.
- **STATE-03** — Schema versioning via `${STATE_DIR}/schema_version` text file (integer, monotonic).
- **STATE-04** — Migration framework: `lib/migrations.sh` runner + discrete `lib/migrations/NNN-<name>.sh` scripts.
- **STATE-05** — First migration `001-initial.sh` copies legacy `*.preserved` files into versioned state.
- **STATE-06** — `agmind upgrade --check` reports current schema, pending migrations, and config diff vs `versions.env`.
- **STATE-07** — `agmind upgrade --apply` runs pending migrations atomically (`flock` + temp-then-rename + tar-backup).
- **STATE-08** — `agmind upgrade --rollback <schema_version>` restores from the auto-backup tarball.
- **STATE-09** — ADR-0011 documents state store architecture decisions.
- **STATE-10** — Integration test `test_upgrade_v3_1_2_to_v3_2_0.sh` against a real v3.1.2 baseline.
- **STATE-11** — Consumer migration: `lib/config.sh`, compose renderers, CLI commands now read secrets via `state_get_secret` (not direct `.env` parsing). Closes BACKUP-01.

**Service registry (Phase 12):**

- **REG-01** — `templates/services/registry.yaml` is the single source of truth for the service catalog.
- **REG-02** — `lib/registry.sh` dual-backend API (yq + python3+PyYAML fallback for airgapped hosts).
- **REG-03** — Build-time codegen `lib/_registry.indexed.sh` (fast bash assoc-arrays, generated artifact).
- **REG-04** — `lib/service-map.sh::SERVICE_GROUPS` derives from registry, not hand-curated.
- **REG-05** — `lib/service-map.sh::ALL_COMPOSE_PROFILES` derives from registry.
- **REG-06** — `lib/service-map.sh::NAMED_PROFILE_EXPANSION` derives from registry.
- **REG-07** — `tests/compose/test_registry_compose_parity.sh` enforces 1:1 registry ↔ compose match.
- **REG-08** — `tests/compose/test_no_hardcoded_service_lists.sh` forbids new hand-edited lists.
- **REG-09** — ADR-0012 documents the registry schema + codegen pipeline + drift-prevention strategy.

**Golden tests + lint + mock infra (Phase 13):**

- **TEST-01** — `tests/golden/` directory structure: `inputs/`, `expected/`, `scenarios.list`.
- **TEST-02** — 5 baseline scenarios: `minimal_lan`, `full_lan`, `rag_milvus`, `ragflow`, `cluster_peer`.
- **TEST-03** — Per-scenario byte-exact diff: `.env`, compose, nginx.conf, monitoring configs.
- **TEST-04** — `generate_random_named` deterministic mode under `AGMIND_TEST_SEED` (name-based, not counter-based).
- **TEST-05** — `tests/lint/LANDMINES.md` codifies project "learned the hard way" invariants as machine-readable patterns.
- **TEST-06** — `tests/unit/test_golden_no_known_landmines.sh` enforces LANDMINES against rendered configs.
- **TEST-07** — `make golden-update` documented; commit-msg `golden-accept-reason: <text>` trailer required.
- **TEST-08** — `tests/mocks/README.md` documents PATH-override mock pattern + 28-mock inventory.
- **TEST-09** — Pre-commit hooks added: golden-update guard + ASCII-only-bash (manual stage).
- **TEST-10** — CI lane `golden-tests` matrix (5 scenarios parallel) runs on every push.

**Go migration scaffolding — zero Go code (Phase 15):**

- **GO-01** — `cmd/agmind/.gitkeep` reserves the binary namespace.
- **GO-02** — `internal/.gitkeep` reserves the internal-packages namespace.
- **GO-03** — `docs/ROADMAP-GO.md` documents Stage 0.5/0.7 (already shipped) plus Stage 1-6 plan.
- **GO-04** — ADR-0010 captures Go migration intent + equivalence-proof requirements + arm64-only enforcement.
- **GO-05** — ADR-0013 captures the single Go binary `cmd/agmind/` decision with `internal/` packages (Q-07).
- **GO-06** — README mentions Go scaffolding + "no Go code in v3.2.0" disclaimer (EN + RU).

### Added — CLI surface

- `agmind upgrade --check` — read-only schema + pending-migrations report (STATE-06).
- `agmind upgrade --apply` — atomic migration with auto-backup tarball (STATE-07).
- `agmind upgrade --rollback <schema_version>` — restore from auto-backup (STATE-08).

### Changed — Refactors

**HEALTH-02B resolver consolidation (Phase 14):**

- **RESOLVER-01** — `lib/health.sh::resolve_active_services` replaces `get_service_list` plus ad-hoc compose detection.
- **RESOLVER-02** — Resolver reads from the service registry (REG-02 path); no compose round-trip in the hot path.
- **RESOLVER-03** — Existing 65+ health tests pass against the new resolver via a thin backward-compat alias.
- **RESOLVER-04** — `tests/unit/test_resolve_active_services.sh` adds 14 test cases / 43 assertions.

**ENV-PARSE-01 migration (Phase 14, 73 callsites across 7 files):**

- **ENV-03b** — Canary migration: 3 callsites in `lib/health.sh::_resolve_active_services_uncached` (`VECTOR_STORE`/`LLM_PROVIDER`/`EMBED_PROVIDER`).
- **ENV-03c** — Bulk sweep: 41 (boolean/enum) + 3 (numeric) + 29 (secrets) callsites = 73 total across `lib/{health,compose,authelia,openwebui,config,restore}.sh` + `install.sh` + `scripts/agmind.sh`.

> Dormant helpers shipped in Phase 10 — activated by ENV-03b / ENV-03c migration above:
>
> - **ENV-01** — `lib/common.sh::_env_get` (`source`-based reader for boolean/enum toggles where bash expansion is desired).
> - **ENV-02** — `lib/common.sh::_env_get_raw` (awk byte-exact reader for secrets and literal values).
> - **ENV-03** — Lint gate `tests/lint/test_no_legacy_env_parse.sh` forbids new `grep ^X= | cut -d=` patterns.
> - **ENV-04** — `tests/unit/test_env_get.sh` covers all edge cases (`#`-in-value, escaped quotes, missing trailing newline, multiline heredocs).
> - **ENV-05** — `docs/env-parsing.md` documents the migration recipe + when to use `_env_get` vs `_env_get_raw`.

**DUPLICATION-01 closure (Phase 14):**

- **DUP-01** — `scripts/health.sh` + `scripts/detect.sh` are verified symlinks to `../lib/X.sh`.
- **DUP-02** — `docs/lib-scripts-pairs.md` inventory documents 4 pairs across 3 types (symlink × 2, justified-divergence × 2).
- **DUP-03** — `install.sh::_copy_runtime_files` uses `cp -P` (preserves symlinks; previously converted them to regular files).
- **DUP-04** — `tests/compose/test_lib_scripts_parity.sh` CI gate enforces per-row contract (symlink target / byte-identity / justified-divergence).
- **DUP-05** — Gate fails on any byte-divergence or symlink-target move.

### Breaking Changes

#### 1. State store at `/var/lib/agmind/state/`

**What changed:** Fresh installs initialize a versioned state directory under
`/var/lib/agmind/state/` with `schema_version=1`. Upgrades from v3.1.x trigger
the `agmind upgrade --check` flow that detects the missing directory and
migrates legacy `.preserved` files (`n8n_encryption_key`, `surrealdb_password`,
`portainer_agent_secret`) plus `${INSTALL_DIR}/docker/.env` secrets into the
versioned namespace via migration `001-initial.sh`.

**Why:** Closes BACKUP-01 — the v3.1.x regression where re-running `install.sh`
on an existing host regenerated secrets (DB password, JWT keys, etc.) without
preserving the existing Postgres volume's hashes, breaking auth on next boot.

**Rollback:** Restore the auto-backup tarball:

```bash
sudo tar -xzf /var/lib/agmind/state/state.bak.<timestamp>/state.tar.gz -C /
git checkout v3.1.2
sudo bash install.sh
```

The migration is **non-destructive** of the legacy `.preserved` files and legacy
`${INSTALL_DIR}/docker/.env` — both remain in place after the migration for one
full release cycle.

#### 2. ENV-PARSE-01 semantics

**What changed:** All legacy `grep ^X=... | cut -d=` patterns in `lib/*.sh`
and `install.sh` are now migrated to `_env_get` (source-based, for default
cases) or `_env_get_raw` (awk byte-exact, for secrets and literal cases). The
migration spans 73 callsites across 7 source files (`lib/{health,compose,authelia,openwebui,config,restore}.sh`,
`install.sh`, `scripts/agmind.sh`) plus the new lint gate `tests/lint/test_no_legacy_env_parse.sh`
forbids new occurrences.

**Why:** The old `grep|cut` pattern matched `KEY=value` literally but silently
truncated values containing `#` outside quotes, escaped quotes, multiline
heredocs, and missing-trailing-newline edge cases. `_env_get_raw` (awk-based,
no shell interpretation) preserves byte-exact secret values; `_env_get`
(`source`-based) is appropriate for boolean/enum toggles where bash expansion
is desired.

**Rollback:** `git revert <ENV-MIGRATION-COMMITS>` (Phase 14 plans 14-03 through
14-06). Behavior is byte-identical for valid `.env` files; only error reporting
and edge-case handling differ. Golden tests (TEST-01..03) confirm byte-identical
rendered `.env` pre/post migration.

#### 3. Service registry codegen artifact

**What changed:** `lib/_registry.indexed.sh` is now a **generated file** —
regenerate via `make registry-codegen` whenever `templates/services/registry.yaml`
changes. The CI `registry-verify` gate fails on drift between `registry.yaml`
and the generated `_registry.indexed.sh`.

**Why:** Phase 12 promotes service definitions from 5 hand-edited bash
assoc-arrays in `lib/service-map.sh` to a single YAML source of truth. Hand-editing
`_registry.indexed.sh` directly is forbidden (file header declares
`# DO NOT HAND-EDIT — generated from templates/services/registry.yaml`). The
codegen step locks down the single source of truth and prevents
PROFILES-ALL-01-class regressions.

**Rollback:** `git checkout v3.1.2 -- lib/service-map.sh` (restore hand-edited
arrays) + remove `templates/services/registry.yaml` + revert
`install.sh::_copy_runtime_files` whitelist additions. **Not recommended** —
v3.1.2 hand-maintained service lists are the regression Phase 12 closed.
Stay on v3.2.0 and edit `registry.yaml` instead.

### Internal — Tooling

**Documentation + release-cut substrate (Phase 16, this phase):**

- **DOCS-01** — This CHANGELOG v3.2.0 entry: all 58 REQ-IDs enumerated with one-line descriptions, three Breaking Changes (state store / ENV parser / registry codegen) with What/Why/Rollback, footer REQ category → Phase mapping.
- **DOCS-02** — `docs/adr/INDEX.md` updated with ADR-0010..0013 rows; sentinel-marker bootstrap.
- **DOCS-03** — `scripts/generate-adr-index.py` + `make adr-index` / `make adr-index-check` auto-regenerate the INDEX table between sentinel markers; pre-commit hook + CI job enforce drift gate.
- **DOCS-04** — `README.md` / `README.ru.md` updated with v3.2.0 architecture overview, Go scaffolding disclaimer, link to `docs/ROADMAP-GO.md`.
- **DOCS-05** — `release-manifest.json` published (`v3.2.0` version, REQ-ID list, commit SHA, release-date single source of truth).
- **DOCS-06** — Version bumps across `install.sh` / `lib/common.sh::AGMIND_VERSION` / `templates/versions.env` / README badges, all derived from `release-manifest.json` (D-18 single-source-of-truth rule).

**Build + CI surface:**

- `make adr-index` / `make adr-index-check` — auto-regenerate `docs/adr/INDEX.md`
  table between sentinel markers (DOCS-03, this phase).
- `make golden-test` / `make golden-update` / `make golden-update-all` /
  `make landmines-check` / `make landmines-sync` — golden-test surface (Phase 13).
- `make registry-codegen` / `make registry-verify` — registry codegen + drift gate (Phase 12).
- Pre-commit hooks: 16 total — 14 inherited (shellcheck, yamllint, gitleaks,
  markdownlint, standard hygiene) + 2 added in Phase 13 (golden-update-guard
  commit-msg hook, ascii-only-bash manual-stage hook) + 1 added in Phase 16
  (adr-index local hook).
- CI workflow `.github/workflows/test.yml` jobs: `syntax`, `shellcheck`,
  `unit-tests` (amd64), `unit-tests-arm64`, `image-tags`, `manifest-consistency`,
  `adr-index-check` (new), `trivy`, `golden-tests` (matrix × 5),
  `golden-accept-reason-check`.

## [3.1.2] — 2026-05-16

### Hotfix release: 9 critical and high-severity findings.

Driven by `AGmind-Autofix-Architecture-Spec-v1.0.2` §3 (Findings Register).
All fixes ship behind regression tests in `tests/unit/`. Track-B architecture
work (state store, registry.yaml, golden tests, GSD plugin runtime, Go
migration, HEALTH-02B resolver refactor, ENV-PARSE-01, DUPLICATION-01) is
explicitly out of scope and slated for v3.2.0.

### Fixed

- **LIC-DIFY-01** — `ENABLE_DIFY_PREMIUM` default flipped from `true` to
  `false` in four sites (lib/wizard.sh × 3, lib/config.sh × 1). Fresh
  installs no longer auto-apply the third-party Dify premium feature
  patches without explicit user opt-in.
- **GEN-01** — `lib/common.sh::generate_random` rewritten with a
  length-guarantee contract. The old `head -c 256 /dev/urandom | tr -dc |
  head -c $length` pipeline failed length=64 about 59% of the time
  (entropy filter discarded more bytes than the source provided). New
  implementation prefers Python `secrets.choice` and falls back to a
  bash `dd`-into-tempfile loop with 100-attempt retry. Affected secrets:
  SECRET_KEY, AUTHELIA_JWT_SECRET, AUTHELIA_SESSION_SECRET,
  AUTHELIA_STORAGE_KEY, and any other 64-char value. Also flips the
  inline duplicate in lib/openwebui.sh:43 to use the helper.
- **HEALTH-01** — `lib/health.sh` and `scripts/health.sh` (byte-identical
  duplicate) replaced three `grep -qi "up\|healthy"` / `up\|starting`
  status checks with `docker inspect` enum-based logic. The string-match
  pattern matched `"Up 5 minutes (unhealthy)"` as if it were OK, giving
  false-positives for any container with a failing healthcheck.
- **NGINX-HEALTH-01** — `lib/common.sh::ensure_bind_mount_files` and
  `preflight_bind_mount_check` now reference `nginx/health/health.json`
  (the directory-based mount in `templates/docker-compose.yml`) instead
  of the legacy single-file `nginx/health.json` path. Cleanup of the
  legacy artifact in install.sh carries the `# LEGACY_NGINX_HEALTH_CLEANUP_OK`
  allowlist marker for the regression gate.
- **HEALTH-02A** — `lib/health.sh::get_service_list` now reports MinIO
  when any of `ENABLE_MINIO=true`, `ENABLE_RAGFLOW=true`, or
  `VECTOR_STORE=milvus` are set. Previously a stopped MinIO on a RAGFlow
  or Milvus deploy slipped past the post-install health gate.
- **SEC-RAGFLOW-01** — `templates/docker-compose.yml` RAGFlow port mapping
  now defaults `RAGFLOW_BIND_ADDR` to `127.0.0.1`. The admin-signup race
  ("first user wins" until first registration) is no longer open to the
  LAN by default. Wizard prompts opt-in to expose `:9380` directly; nginx
  vhost `agmind-rag.local` continues to proxy local port for normal LAN
  access.
- **SEC-PEER-01** — `lib/peer.sh::phase_deploy_peer` now `chmod 600 +
  chown root:root` the worker `.env` on peer via SSH immediately after
  scp. scp preserved the peer user's umask (typically `0644`), exposing
  VLLM_IMAGE, HF_TOKEN, PORTAINER_AGENT_SECRET, etc. to any
  unprivileged shell on the peer.
- **SEC-UFW-01 + SEC-UFW-02** — `lib/security.sh::configure_ufw`
  rewritten as append-only with `_ufw_add_or_keep` helper. Reset is now
  explicit opt-in via `AGMIND_UFW_RESET=true`. Admin's existing rules
  (custom SSH ports, fail2ban hooks, k8s nodeport allowlists) survive
  install. LAN allows narrowed from `ufw allow from $SUBNET` (every
  internal port wide-open) to per-port rules for `:80` and `:443` only.
  Grafana `:3001` and Portainer `:9443` gated behind explicit
  `EXPOSE_GRAFANA_LAN` / `EXPOSE_PORTAINER_LAN` env opt-ins. Default
  `LAN_SUBNET` tightened from `/16` to `/24`. New
  `uninstall_agmind_ufw_rules` removes only `agmind-*`-tagged rules in
  reverse-numeric order.
- **RAGFLOW-URL-01** — `lib/status.sh` now reports
  `http://agmind-rag.local` (matches the nginx vhost and the
  avahi-mdns-publish advertisement). The stale `agmind-ragflow.local`
  caused mDNS resolution timeouts and confused users running `agmind
  status` / `agmind status --json`.
- **PROFILES-ALL-01** — `lib/service-map.sh::ALL_COMPOSE_PROFILES` synced
  with the actual `profiles:` keys in `templates/docker-compose.yml`.
  Added `ragflow`, `loadtest`, `vps`. Removed stale `etl`.
  `_compose_down_all` no longer leaves orphaned containers after
  `agmind uninstall` on a RAGFlow/loadtest/vps deploy.

### Also

- `_init_dify_admin` no longer fails on Dify 1.14.1's stricter password
  validator. The previous `init_password | base64 -d` admin password
  occasionally landed without any digit; the validator
  (`^(?=.*[a-zA-Z])(?=.*\d).{8,}$`) returned HTTP 422 on setup. Now uses
  the raw INIT_PASSWORD with a guaranteed-digit append.
- `lib/peer.sh::_render_worker_env` heredoc switched to single-quoted
  `VLLM_EXTRA_ARGS`; double-quoted form broke docker compose `.env`
  parser when the value contained JSON (e.g. `--speculative-config`).
- `templates/docker-compose.worker.yml` declares `entrypoint: ["vllm",
  "serve"]` for the vllm service. NGC's base image entrypoint
  (`/opt/nvidia/nvidia_entrypoint.sh`) does a bare `exec "$@"` so
  passing `--model …` as the command failed with `exec: --: invalid
  option`.
- Phase 8 (Deploy Peer) timeout bumped from 1800s to 3600s (effective
  ceiling 10800s with retry). Qwen3.6-35B-A3B-FP8 first-time HF download
  + load + CUDAGraph capture for 36 batch sizes can exceed the previous
  budget on slower peer WAN links.

### Artifacts

Each finding ships a regression test under `tests/unit/`:

- `test_dify_premium_default_off.sh` (LIC-DIFY-01)
- `test_generate_random_length.sh` (GEN-01)
- `test_health_check_container.sh` (HEALTH-01)
- `test_bind_mount_nginx_health.sh` (NGINX-HEALTH-01)
- `test_get_service_list.sh` (HEALTH-02A)
- `test_ragflow_bind_localhost.sh` (SEC-RAGFLOW-01)
- `test_peer_env_lockdown.sh` (SEC-PEER-01)
- `test_configure_ufw.sh` (SEC-UFW-01 + SEC-UFW-02)
- `test_ragflow_url_alias.sh` (RAGFLOW-URL-01)
- `test_all_profiles_synced.sh` (PROFILES-ALL-01)

PR-1 and PR-2 (LIC-DIFY-01, GEN-01) also include apply/verify scripts
under `scripts/gsd/{apply,verify}/` as proof-of-concept for the GSD
plugin contract (§7 of the spec); these scaffolds will be consumed by
the runtime in v3.2.0. PR-3..PR-9 use direct edits with regression tests
only.

## [3.1.1] — 2026-05-12

Prior release. See `git log v3.1.1..v3.1.2` for the full set of changes
that preceded this CHANGELOG.

[3.2.0]: https://github.com/botAGI/AGmind/compare/v3.1.2...v3.2.0
[3.1.2]: https://github.com/botAGI/AGmind/compare/v3.1.1...v3.1.2

**REQ category → Phase mapping:**

- **ENV helpers (dormant)** → Phase 10 (ENV-01..05)
- **State Store substrate** → Phase 11 (STATE-01..10) — see [ADR-0011](docs/adr/0011-state-store-architecture.md)
- **State Store consumer migration** → Phase 14 (STATE-11)
- **Service Registry** → Phase 12 (REG-01..09) — see [ADR-0012](docs/adr/0012-service-registry-codegen.md)
- **Golden tests / LANDMINES / mocks** → Phase 13 (TEST-01..10)
- **HEALTH-02B closure (RESOLVER)** → Phase 14 (RESOLVER-01..04)
- **ENV-PARSE-01 migration** → Phase 14 (ENV-03b canary + ENV-03c bulk)
- **DUPLICATION-01 closure** → Phase 14 (DUP-01..05)
- **Go scaffolding** → Phase 15 (GO-01..06) — see [ADR-0010](docs/adr/0010-go-migration-staged-port.md), [ADR-0013](docs/adr/0013-go-single-binary-internal-packages.md), [docs/ROADMAP-GO.md](docs/ROADMAP-GO.md)
- **Documentation + release cut** → Phase 16 (DOCS-01..06, this entry)
