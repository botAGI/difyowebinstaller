# 0011. State Store Substrate (Versioned + Atomic + Migration-Driven)

**Date:** 2026-05-16
**Status:** Accepted

## Context and Problem Statement

AGmind v3.1.x stores state ad-hoc: three `.preserved` files in `/var/lib/agmind/state/`
(`surrealdb_password`, `n8n_encryption_key`, `portainer_agent_secret`), `cluster.json`
managed by `lib/cluster_mode.sh`, and ~20 other secrets in `${INSTALL_DIR}/docker/.env`
that are **re-generated** every time `lib/config.sh::_generate_secrets` runs without
a `--keep-models` uninstall having stashed them. The result is the BACKUP-01
regression: re-installing over an existing host overwrites the DB password while the
Postgres volume keeps the old hash, breaking auth on next boot and silently corrupting
the RAG pipeline.

A versioned, atomically-writable state store with schema migrations and rollback is
the prerequisite for closing BACKUP-01 cleanly. Phase 11 (this ADR) ships the
substrate **dormant**: file format + locking + migration framework + `agmind upgrade`
CLI all land, but the legacy `.preserved` and `.env` readers continue to function
unchanged. Phase 14 (STATE-11) migrates live consumers to the `state_get_secret` API
and ships migration `002-cleanup-preserved.sh` that retires legacy files after the
consumer flip.

## Decision Outcome

**Chosen option:** "Flat-file state-store in `${STATE_DIR}/secrets.env` (KEY=VALUE,
`# schema=N` marker on line 1, mode 0600) + per-key files for non-secret state in
`${STATE_DIR}/<key>` + `flock` per-file locking in `${STATE_DIR}/.locks/` + discrete
bash migration scripts `lib/migrations/NNN-<name>.sh` with `tar`-backup before each
step."

**Reason:**

- Minimal substrate — no `jq`/`yq` dependency (those arrive in Phase 12 service registry).
- Reuses the existing `_env_get_raw` byte-exact awk parser from Phase 10
  (`lib/common.sh:300-322`), which already skips `^#` comment lines — the schema
  marker is invisible to key parsing for free.
- `tar` backup before every migration enables O(1) rollback via
  `agmind upgrade --rollback <N>`.
- `flock` per-file (shared for readers, exclusive for writers) lets parallel
  `agmind status` calls run without serialization while preventing torn writes.
- Phase 14 consumers swap to `state_get_secret(NAME)` without changing the storage
  format — no second refactor.

## Consequences

**Good:**

- Single source of truth for secrets after Phase 14 consumer flip — closes BACKUP-01.
- Re-install preserves all secrets (substrate + Phase 14 wire-up).
- Audit trail via `/var/backups/agmind/state-pre-NNN-<ts>.tar.gz` (mode 0600).
- Substrate reusable by Phase 12 (Service Registry hash), Phase 14 (consumer flip),
  Phase 16 (release upgrade tooling).
- No new container images, no new runtime daemons.

**Bad:**

- Dual-write window between Phase 11 ship and Phase 14 ship: `secrets.env` AND
  legacy `.preserved` files AND `docker/.env` all hold the same bytes. Migration
  `001-initial.sh` copies (not moves), so any path that reads either source returns
  a consistent value — but operators editing one by hand without the other will
  drift. Documented in README v3.2.0 (Phase 16 DOCS-02).
- Phase 14 must execute on schedule. If deferred, dual-write persists into
  production. Risk mitigated by HARD critical-path declaration in ROADMAP — Phase 14
  cannot be skipped without reverting Phase 11.
- Operators editing `${INSTALL_DIR}/docker/.env` directly (outside the `agmind` CLI)
  after v3.2.0 ships is no longer the canonical edit path — documented as a
  deprecation note in README.

## Architectural Decisions (Q-N references from spec)

### Q-01: Stateless Peer

The peer node (e.g. spark-69a2 in cluster mode) does **not** maintain its own
state-store. The master node is the single source of truth. When the peer needs a
secret it reads from master over SSH at deploy time (existing `peer_deploy` rsync of
`.env` — Phase 11 does not change this). Enforcement is **deferred** (open question
OQ-5): the substrate ships master-only; future hardening may add an explicit
`agmind upgrade` short-circuit when invoked on a worker-role node — until then the
peer-stateless property holds by contract only.

### Q-10: Prompt Rollback Default

`agmind upgrade --rollback <schema>` **always** prompts for interactive `yes`/`no`
confirmation unless `--yes` is explicitly passed. Reason: rollback is destructive
(replaces current state with a tarball snapshot), easily confused with `--apply`,
and rolled-down secrets cannot be recovered without the prior tarball. CI/scripted
callers must pass `--yes`.

`agmind upgrade --apply` follows the same convention for symmetry — prompts unless
`--yes` is passed.

### Schema Marker Contract

The first line of `${STATE_DIR}/secrets.env` MUST be `# schema=N` where N is a
non-negative integer. The `${STATE_DIR}/schema_version` plain-text file holds the
canonical integer.

**Marker write semantics:** the marker is written **once at file creation** by
`state_init_dir` (initial value `# schema=0`). Subsequent migrations bump the
`schema_version` file but do NOT rewrite the marker in `secrets.env`. The
`schema_version` file is the authoritative source of truth; the marker is a
human-readable provenance hint and a sourceability proxy (see "Containers Healthy"
proxy below). A migration MAY choose to rewrite the marker if it materially changes
the key-value format of `secrets.env`; migration `001-initial.sh` does not.

**Parser visibility:** `_env_get_raw` already skips lines matching `^[[:space:]]*#`
(verified in Phase 10 RESEARCH TEST 4), so the marker is invisible to
`state_get_secret` callers and does not require special parsing.

**Drift detection:** `agmind upgrade --check` reads both the line-1 marker and the
`schema_version` file. If both are present and disagree on a value > 0, exit 2
(`blocked`) is returned with operator guidance to run
`agmind upgrade --rollback <current>`. If the marker is absent (= legacy
unmigrated file, pre-Phase 11), it is treated as schema 0.

### File Mode Contract

| Path                                          | Mode | Owner     |
|-----------------------------------------------|------|-----------|
| `${STATE_DIR}`                                | 0700 | root:root |
| `${STATE_DIR}/.locks/`                        | 0700 | root:root |
| `${STATE_DIR}/secrets.env`                    | 0600 | root:root |
| `${STATE_DIR}/schema_version`                 | 0644 | root:root |
| `${STATE_DIR}/<other-keys>` (future)          | 0644 | root:root |
| `/var/backups/agmind/state-pre-NNN-*.tar.gz`  | 0600 | root:root |

`STATE_DIR_OWNER` env override exists for CI runners (unprivileged user); tests
skip the chown when unset. `umask 077` is applied before tarball creation so
backup-tarballs inherit 0600 even on shells that leak a permissive umask.

### Q-Locking Contract

`flock -w 5` (5-second timeout, then bail) is used for all state operations:

- Readers (`state_get*`) take **shared** lock (`flock -s`) — parallel reads OK.
- Writers (`state_set*`) take **exclusive** lock (`flock -x`) — single writer at a
  time.
- `agmind upgrade --apply` takes a separate exclusive lock on `upgrade.lock`
  (non-blocking, `flock -n`) so concurrent `--apply` invocations exit immediately
  with `2 = blocked`.

**Nested locks are forbidden.** Single-purpose calls only. An accidental nested
lock will self-deadlock on the second `flock -x` attempt within 5 seconds and
return error to the caller.

### Storage Format Choice (KEY=VALUE vs JSON)

KEY=VALUE was chosen over JSON for three reasons:

1. **Zero dependencies.** `jq`/`yq` are Phase 12 territory; Phase 11 ships first.
2. **Atomic writes are simpler.** awk-rewrite + temp + rename is well-understood;
   `jq '.x = "y"'` requires temp + rename anyway and adds parse fragility.
3. **Codebase already speaks env.** `lib/common.sh::_env_get_raw` is the canonical
   reader; reusing it eliminates a new dialect.

### Bootstrap Contract

`state_init_dir` is **idempotent** and tolerates missing state:

- Creates `${STATE_DIR}` (0700), `${STATE_DIR}/.locks/` (0700), `schema_version=0`,
  and `secrets.env` with line-1 marker `# schema=0` (0600) — only if absent.
- Calling it a second time on a populated state-store is a no-op (file existence
  checks short-circuit; no truncation).
- On first run with NO prior state (= fresh install, no `.preserved` files):
  schema_version stays at 0; `migration_1_up` bumps to 1 even though there is
  nothing to copy — this is the canonical fresh-install path.
- On first run WITH prior v3.1.x `.preserved` files + `docker/.env`:
  `migration_1_up` reads them via `_env_get_raw`, writes byte-exact copies into
  `secrets.env` via `state_set_secret`, bumps `schema_version` to 1.
  **Originals are NOT deleted** (Phase 11 substrate is dormant — Phase 14
  `002-cleanup-preserved.sh` retires them after the consumer flip).
- No destructive operation runs on first apply. All migrations are preceded by a
  `tar` backup of the current state (even when current state is empty) into
  `${BACKUP_BASE}/state-pre-NNN-<ts>.tar.gz`.

### "Containers Healthy" Proxy (Phase 11 Scope)

Phase 11 cannot validate `docker compose config` against migrated state — that
requires the consumer flip (Phase 14, STATE-11). The Phase 11 acceptance proxy is
that the **line-1 marker of `secrets.env` is sourceable in a clean subshell** —
i.e. `bash -c "source ${STATE_DIR}/secrets.env"` returns 0. This is asserted in
`tests/integration/test_upgrade_v3_1_2_to_v3_2_0.sh` (assertion #20). Full
compose-rendering validation is deferred to Phase 14.

### `.broken-*` Retention Policy

On rollback, the current `${STATE_DIR}` is renamed to `${STATE_DIR}.broken-<ts>`
(sibling directory) before the tarball is extracted into a fresh `${STATE_DIR}`.
The last 3 `.broken-*` directories are retained for forensics; older ones pruned
by `ls -1dt | tail -n +4 | xargs rm -rf`. Typical total cost is ~3× state-dir size
(<10 MB in practice).

### Threat Model (substrate scope — full STRIDE in per-plan threat models)

- **Symlink attack on `${STATE_DIR}`** → mitigated by 0700 + root ownership
  (single-tenant LAN profile).
- **Backup tarballs world-readable** → mitigated by `umask 077` before tarball
  creation + explicit `chmod 0600` after rename.
- **Concurrent `--apply` corruption** → mitigated by `upgrade.lock` non-blocking
  flock.
- **Partial migration split-brain** → mitigated by `schema_version` bumped only
  after `migration_NNN_up` returns 0; `upgrade --check` returns 2 on
  marker/schema_version mismatch.
- **Secret leak via `log_*`** → mitigated by `tests/lint/test_state_no_secret_logging.sh`
  CI gate (Plan 11-06 — forbids `$value`/`$val`/`$v` in `log_(info|warn|error|success|debug)`
  calls within state/migrations code).

## Open Questions Resolved (Phase 11 spec)

The following design questions raised during Phase 11 research were locked during
plan revision iteration 1:

- **OQ-1 — `agmind upgrade --check` UX scope:** kept **LIGHT** in Phase 11
  (compares schema_version + marker only; reports pending migration count). Full
  `versions.env` diff and image-availability checks are deferred to Phase 16
  release tooling.
- **OQ-2 — migrations module deployment path:** copied via `cp -r lib/migrations/`
  into `${INSTALL_DIR}/scripts/migrations/` in
  `lib/config.sh::_copy_runtime_files`, matching the existing pattern for
  per-feature subdirectories (`scripts/loadtest/` precedent).
- **OQ-3 — `agmind uninstall --keep-models=false` cleanup:** removes
  `secrets.env` and `schema_version` from `${STATE_DIR}`; does **not** touch
  legacy `.preserved` files (legacy stash retention is governed by the existing
  `--keep-models` semantics, separate from state-store substrate).
- **OQ-4 — partial migration support:** `migrations_apply --target N` is
  supported and lands in Phase 11; useful for staged rollouts and for the
  Phase 14 consumer flip rehearsal.
- **OQ-5 — peer enforcement:** documented as contract (see Q-01 above) but not
  enforced in code. A future hardening pass may add an explicit short-circuit
  when `agmind upgrade` runs on a worker-role node.

## Acceptance Evidence

- `tests/integration/test_upgrade_v3_1_2_to_v3_2_0.sh` — 27 assertions, all PASS
  against the synthetic v3.1.2 baseline tarball
  (`tests/fixtures/state/v3.1.2-baseline.tar.gz`), satisfying ROADMAP success
  criterion #4 (real-baseline integration test).
- `tests/integration/test_state_layout.sh` — STATE-01 dir/mode/owner contract.
- `tests/integration/test_migration_001_initial.sh` — STATE-04/05 bridge.
- `tests/unit/test_state_api.sh` — STATE-02/03 public API.
- `tests/unit/test_migrations_runner.sh` — runner discovery + ordering.
- `tests/unit/test_upgrade_cli.sh` — `--check` / `--apply` / `--rollback`
  exit-code matrix.
- `tests/lint/test_state_no_secret_logging.sh` — R7 mitigation CI gate.
- `tests/lint/test_adr_0011_present.sh` — STATE-09 ADR presence + cross-link gate.

## References

- `lib/state.sh` — public API (state_get/set/get_secret/set_secret, schema_version,
  upgrade_check/apply/rollback)
- `lib/migrations.sh` — runner (discovery, pending, atomic apply with tar-backup)
- `lib/migrations/001-initial.sh` — bootstrap migration (copy legacy `.preserved` +
  `.env`)
- `scripts/agmind.sh::cmd_upgrade` — CLI entrypoint
- `tests/integration/test_upgrade_v3_1_2_to_v3_2_0.sh` — end-to-end coverage
- `tests/integration/test_state_layout.sh` — STATE-01 coverage
- `docs/adr/0007-force-recreate-trap.md` — MADR-lite operational-ADR style
  reference
- `.planning/REQUIREMENTS.md` — STATE-01..STATE-11 (STATE-11 is Phase 14, not
  Phase 11)
- `.planning/phases/11-state-store-substrate-adr-0011/11-RESEARCH.md` — design
  rationale + verified primitives
- Phase 14 plan — consumer migration (STATE-11) and `002-cleanup-preserved.sh`
