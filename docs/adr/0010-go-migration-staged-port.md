# 0010. Go Migration — Staged Port After Equivalence Proof

**Date:** 2026-05-18
**Status:** Accepted

## Context and Problem Statement

AGmind v3.x is implemented entirely in Bash: `install.sh` (~900 lines) + `lib/*.sh`
(12 modules, ~4 500 lines) + `scripts/agmind.sh` CLI (~800 lines). This canonical bash
stack has served well through v3.1.x, but has hit real limits as the project matures:

- Complex state management requires layered workarounds (see ADR-0011 for the
  state-store substrate that Phase 11 had to invent to close BACKUP-01).
- Concurrency is text-process-based: `docker ps` stdout parsing, grep pipelines,
  awk-based env parsers. Correctness depends on column-width assumptions.
- No static type checking; ~9 critical entries in the project's institutional memory
  document bash-specific traps that unit tests now guard (golden tests, LANDMINES.md).
- Testing requires an elaborate mock-PATH infrastructure (`tests/mocks/`) and
  deterministic RNG via `AGMIND_TEST_SEED` (Phase 13) to make config rendering
  byte-reproducible.

A Go port addresses these limits: single static binary, structured logging, native
Docker SDK client (no text parsing), jsonschema validation for `registry.yaml`, and
`goldie/v2` snapshot equivalence proofs that compare Go output byte-for-byte against
the bash golden fixtures.

**No Go code ships in v3.2.0.** This release delivers only the intent ADR
(this document), `docs/ROADMAP-GO.md` with the staged plan, and namespace-reserving
`.gitkeep` placeholders (`cmd/agmind/` + `internal/`). All actual Go code is v4.0+.

## Decision Outcome

**Chosen option:** "Staged port — bash canonical through v3.2.0; v4.0+ executes
Stage 1→6 per `docs/ROADMAP-GO.md`, gated on equivalence-proof preconditions
being green."

**Reason:**

- Low risk: no flag day. Bash continues to function; Go replaces one verb at a time,
  starting with `agmind doctor` (Stage 1). Operators on v3.2.x see no change.
- Equivalence proof is the forcing function: the golden tests and name-based RNG
  (Phase 13, shipped) make the bash baseline byte-reproducible. A Go reimplementation
  cannot claim correctness until it passes the same byte-identical snapshot tests.
- arm64-only matches the parent platform decision (ADR-0001). Building an amd64 Go
  binary would undercut the hardware focus without any customer benefit — every
  supported appliance is a DGX Spark (GB10, aarch64).

## Equivalence-Proof Preconditions

No Stage 1 Go code may begin until **all three** of these gates are green for the
bash baseline:

**a) Golden tests** (Phase 13 — SHIPPED in v3.2.0)
`tests/golden/` contains 5 scenarios (`minimal_lan`, `full_lan`, `rag_milvus`,
`ragflow`, `cluster_peer`) with 105 expected-output files. The harness renders
config via `lib/config.sh::generate_config` under `AGMIND_TEST_SEED`, producing
byte-exact snapshots. Any Go reimplementation of config generation MUST produce
byte-identical output for all 5 scenarios to pass the equivalence gate.

**b) Name-based deterministic RNG** (Phase 13 — SHIPPED in v3.2.0)
`lib/common.sh::generate_random_named` accepts a stable slug and derives a
deterministic value under `AGMIND_TEST_SEED` via Python `random.Random`. This
makes secrets reproducible across test runs without leaking into production
(`AGMIND_TEST_SEED` in production is blocked by the guard in `lib/common.sh`).
The Go equivalent MUST accept the same seed and produce the same values.

**c) Service registry** (Phase 12 — SHIPPED in v3.2.0)
`templates/services/registry.yaml` is the machine-readable single source of truth
for all 50 AGmind services. `lib/registry.sh` exposes a read-only API consumed by
`agmind doctor`, `agmind health`, and `agmind status`. A Go reimplementation of
these verbs MUST read `registry.yaml` directly via `compose-go/v2` (or equivalent
YAML library) rather than parsing bash assoc-array output.

Any Go reimplementation of `agmind doctor` / `agmind health` / `agmind status`
MUST pass all three gates against the bash baseline before the PR is merged.
The Go equivalent test framework for gate (a) is `goldie/v2` (snapshot library).

## arm64-Only Enforcement

ADR-0001 is the parent platform decision: AGmind targets aarch64 (DGX Spark GB10)
exclusively. NGC vLLM (`vllm/vllm-openai:gemma4-cu130`) and Docling-serve cu130
publish only arm64 manifests; there are no supported amd64 builds.

Every future Go release artifact MUST be aarch64-only; no amd64 wheel is produced.
The enforcement mechanism is a pre-flight check at binary startup: the
`runtime.GOARCH != "arm64"` fail-fast pattern terminates the process immediately
on non-aarch64 hardware with a clear error message. The full Go snippet lives in
`docs/ROADMAP-GO.md` Stage 1 acceptance criteria (not here — Phase 15 ships zero
Go code).

The Makefile pattern for build enforcement: `GOARCH ?= arm64` with
`CGO_ENABLED=0` (static binary, no cgo).

## Scope Guard (Anti-recommendations)

The following are explicitly **NOT** in scope for v3.2.0 or even v4.0 Stage 1:

- No `go.mod`, no `go.sum`, no Go tooling installed on the appliance — no Go code ships in v3.2.0
- No Go web server — nginx stays; there is no reason to replace it with a Go HTTP server
- No cgo — `CGO_ENABLED=0` always; the binary must be fully static
- No GUI frameworks (no Wails, no Tauri, no Fyne) — `agmind` is a CLI tool, not a desktop app
- No Rust or Zig revisit — Go is the chosen language; alternatives were considered and rejected
  during v3.2.0 research; this decision is closed
- No multi-binary architecture — a single `cmd/agmind/` binary per ADR-0013; no separate
  per-subcommand binaries

## Consequences

**Good:**

- Equivalence proof forces correctness: a Go verb cannot ship until its output matches the
  bash baseline byte-for-byte. Regression surface is smaller than typical rewrites.
- arm64-only prevents CI matrix sprawl: no x86_64 matrix lane, no cross-compilation
  complexity, no separate QA pipeline for amd64.
- Scope guard prevents v4.0 from drifting into a "rewrite everything" initiative; each
  stage is a bounded, independently deliverable unit.
- Bash stays canonical through v3.2.x: point releases remain unblocked and do not depend
  on any Go toolchain availability.
- Single Go binary is build- and release-simple: one artifact, one `make build` target,
  one checksum to sign and publish.

**Bad:**

- v4.0 Stage 1 work is blocked until v3.2.0 golden tests are battle-tested for at least
  one production release; any instability in the golden baseline delays the Go port.
- Go ecosystem dependencies (Cobra v1.10, `compose-go/v2`, `goldie/v2`) introduce
  supply-chain surface area when adopted; a dependency audit is required before Stage 1.
- Future contributors must learn both the bash layout (`lib/*.sh`) and the Go layout
  (`cmd/agmind/`, `internal/<pkg>`) until Stage 6 completes the full migration.
- Dual-language repository state persists from v4.0 Stage 1 through Stage 6
  completion — estimated multiple milestone cycles.

## References

- `docs/adr/0001-arm64-only.md` — parent platform decision (arm64-only policy)
- `docs/adr/0011-state-store-architecture.md` — state store substrate that Go `internal/state` will consume
- `docs/adr/0012-service-registry-codegen.md` — service registry substrate that Go `internal/doctor` will read
- `docs/adr/0013-go-single-binary-internal-packages.md` — sibling ADR: single binary + `internal/` layout (Q-07)
- `docs/ROADMAP-GO.md` — staged port plan with package-per-stage mapping and Stage 1 acceptance criteria
- AGmind-Autofix-Architecture-Spec-v1.0.2 §8 — external driver specifying Go port requirements and stage ordering
