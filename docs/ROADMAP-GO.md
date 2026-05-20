# Go Migration Roadmap

**Purpose:** Forward-looking reference for the v4.0+ Go port of AGmind CLI verbs.

**Status:** v3.2.0 ships ZERO Go code. This document is the staged-port plan;
v4.0 Stage 1 begins after v3.2.0 golden tests are battle-tested in production for ≥1 release.

**Driver decision:** [ADR-0010 — Go Migration Staged Port](adr/0010-go-migration-staged-port.md)

**Layout decision:** [ADR-0013 — Go single binary with internal/ packages (Q-07)](adr/0013-go-single-binary-internal-packages.md)

---

## What this document is NOT

- NOT a v3.2.0 deliverable plan — no Go code lands in v3.2.0.
- NOT a hard schedule — stage cadence depends on v3.2.0 stability in production.
- NOT a substitute for ADR-0010 / ADR-0013 — those are the binding decisions;
  this doc is operational detail (acceptance criteria, package mapping, stack pins).

---

## Already-shipped substrates (v3.2.0)

### Stage 0 — Critical bash invariants — DONE (v3.1.2)

Nine Critical findings closed in the v3.1.2 hotfix: HEALTH-01 grep-regex hardening,
LIC-DIFY-01, NGINX-HEALTH-01, and six further Critical-class bash traps. These findings
are codified in the LANDMINES.md / `.tsv` registry that Stage 0.5 builds on.

### Stage 0.5 — Golden tests substrate — DONE (v3.2.0 Phase 13)

**Delivered artifacts:**

- `tests/golden/run.sh` harness + 5 baseline scenarios (`minimal_lan`, `full_lan`,
  `rag_milvus`, `ragflow`, `cluster_peer`) with 105 expected-output files
- Name-based deterministic RNG via `lib/common.sh::generate_random_named`
  (keyed on `AGMIND_TEST_SEED`; blocked in production by guard in `lib/common.sh`)
- `tests/lint/test_landmines_md_tsv_in_sync.sh` — enforces LANDMINES.md / .tsv parity
- CI lane `golden-tests` matrix job; `golden-accept-reason:` commit-msg trailer required
  for snapshot updates

**Significance:** This is the equivalence-proof substrate every Go port stage must pass.
A Go reimplementation of any CLI verb cannot claim correctness until it produces
byte-identical output for all 5 scenarios under the same `AGMIND_TEST_SEED`.

### Stage 0.7 — Service registry substrate — DONE (v3.2.0 Phase 12)

**Delivered artifacts:**

- `templates/services/registry.yaml` — 50-service declarative catalog (single source
  of truth for all AGmind Docker Compose services)
- `lib/registry.sh` — dual-backend reader (yq + python3+PyYAML fallback)
- `scripts/codegen/registry-to-indexed.sh` → `lib/_registry.indexed.sh`
- Parity gate `tests/compose/test_registry_compose_parity.sh` — enforces 1:1 with compose

**Significance:** This is the data substrate every Go port stage consumes via
`compose-go/v2`. See also [ADR-0012](adr/0012-service-registry-codegen.md).

---

## v4.0 staged port plan — Stages 1–6

> **HARD GATE (equivalence-proof preconditions):** No Stage 1 Go code may begin until
> Stage 0 + Stage 0.5 + Stage 0.7 are all green for the bash baseline in ≥1 production
> release window. Enforced via [ADR-0010](adr/0010-go-migration-staged-port.md).

---

### Stage 1 — `agmind doctor` (foundational)

**Goal:** Port `agmind doctor` to Go as the first equivalence-proof exercise.
This stage produces `go.mod`, the `cmd/agmind/` entry point, and the first
`internal/` package. All subsequent stages extend this single binary.

**Packages introduced:** `cmd/agmind/`, `internal/doctor/`

**Depends on:** Stage 0, Stage 0.5, Stage 0.7

**Acceptance criteria:**

1. `agmind doctor --json` output is byte-identical to the bash baseline, verified via
   `goldie/v2` snapshot equivalence. Differences permitted only in fields that bash
   renders non-deterministically; all JSON keys and exit codes must match.
2. **arm64-only pre-flight check** is the first thing `main` runs. This is prevention
   item 4 of the AGmind-Autofix-Architecture-Spec-v1.0.2 §PITFALLS Pitfall 10
   (cross-build architecture mismatch prevention). Verbatim snippet required:

```go
// arm64-only pre-flight check (docs/adr/0010-go-migration-staged-port.md)
// References: ADR-0001 (parent arm64 platform decision), ADR-0010 (Go-side enforcement)
if runtime.GOARCH != "arm64" {
    fmt.Fprintln(os.Stderr, "agmind: fatal: aarch64-only binary — must run on DGX Spark")
    os.Exit(1)
}
```

3. Makefile cross-build target enforces arm64-only artifact (no Go code in v3.2.0 —
   this target lands at Stage 1 only):

```makefile
GOOS   ?= linux
GOARCH ?= arm64
build:
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) go build -o dist/agmind-$(GOOS)-$(GOARCH) ./cmd/agmind
```

   The `CGO_ENABLED=0` flag produces a fully static binary with no cgo dependencies.
   See AGmind-Autofix-Architecture-Spec-v1.0.2 §PITFALLS Pitfall 10 for the full
   prevention checklist and Makefile pattern rationale.

4. `internal/doctor/` reads `templates/services/registry.yaml` via `compose-go/v2`
   (not via bash `lib/registry.sh` subprocess call).
5. CI gate: `go vet ./...` + `goldie/v2` snapshot assertions pass on aarch64 runner.

---

### Stage 2 — `agmind health` + `agmind status`

**Goal:** Replace text-parsing of `docker ps` output with the official
`docker/docker/client` Docker API client. This stage structurally eliminates
the HEALTH-01 grep-regex class of bug.

**Packages introduced:** `internal/health/`, `internal/status/`

**Depends on:** Stage 1

**Acceptance criteria:**

1. `docker/docker/client` (`ContainerInspect`) replaces all `docker ps | grep` patterns
   from bash `lib/health.sh` and `lib/status.sh`. No text-parsing of `docker` CLI output.
2. `agmind health --json` and `agmind status --json` byte-identical to bash baseline
   via `goldie/v2` snapshot equivalence.
3. HEALTH-01 grep-regex class of bug is structurally impossible in `internal/health/`:
   service state is derived from the Docker API `ContainerState`, not CLI column widths.
4. Service list resolution reads `templates/services/registry.yaml` via `compose-go/v2`;
   no hardcoded service names.
5. Docker API client version pinned to match the daemon API version declared in
   `versions.env` (see stack pin table below).

---

### Stage 3 — `agmind config validate` + `agmind upgrade --check`

**Goal:** Read state store and registry in Go; emit structured config diff. This stage
brings `internal/config/` and `internal/state/` into the binary, enabling the Go binary
to reason about install state independently of bash.

**Packages introduced:** `internal/config/`, `internal/state/`

**Depends on:** Stage 1, Stage 2

**Acceptance criteria:**

1. `internal/config/` parses `templates/docker-compose.yml` + `versions.env` +
   `registry.yaml` via `compose-go/v2`; exposes typed structs.
2. `internal/state/` reads `/var/lib/agmind/state/` in the flat-file format from
   [ADR-0011](adr/0011-state-store-architecture.md): `secrets.env` (KEY=VALUE,
   mode 0600), `schema_version`, `.locks/` per-key flock files.
3. `agmind upgrade --check --json` exit code matrix matches bash: `0` = up-to-date,
   `1` = pending upgrades, `2` = blocked (locked service).
4. Findings registry validation via `github.com/santhosh-tekuri/jsonschema/v5`.
5. `goldie/v2` snapshot equivalence for all output against the bash baseline.

---

### Stage 4 — `agmind phase-run` / install glue

**Goal:** Phase descriptor → Go struct mapping; `install.sh` delegates phase execution
to the Go binary rather than sourcing bash phase scripts directly.

**Packages introduced:** `internal/phase/`

**Depends on:** Stage 3

**Acceptance criteria:** Stage 4 acceptance criteria will be defined in the v4.0
milestone planning document. The scope is forward-looking; the bash `install.sh`
bootstrap shell remains as the host OS entrypoint regardless.

---

### Stage 5 — `agmind gsd` plugin runtime port (deferred)

**Goal:** Port the GSD plugin runtime from `scripts/gsd-run.sh` to Go, enabling
`jsonschema/v5`-validated findings and structured plugin lifecycle management.

**Packages introduced:** `internal/gsd/`

**Depends on:** Stage 3, Stage 4

**Note:** This stage was originally scoped for v3.3 (bash) during Phase 15 research
but was deferred to v4.0 Go. It is the most architecturally complex stage and depends
on Stage 3 + Stage 4 being stable.

**Acceptance criteria:** Refined in v4.0 milestone planning.

---

### Stage 6 — Full Go binary replaces bash CLI

**Goal:** `agmind` Go binary handles all CLI verbs. Bash `install.sh` + bootstrap
scripts remain as the host OS entrypoint (OS-level setup, Docker Compose lifecycle)
but no bash code remains on the `$PATH`-facing CLI surface.

**Packages introduced:** Consolidates all `internal/` packages. No new packages expected.

**Depends on:** Stages 1–5 all stable in production.

**Acceptance criteria:** Refined in v4.0 milestone planning.

---

## Stack pin table

> All versions as researched 2026-05-16. **Verify against latest releases before
> v4.0 Stage 1 begins** — these pins are advisory, not a lockfile. Go release cadence
> is ~6 months; treat all entries as `[unverified]` until reconfirmed at Stage 1 kickoff.
> Per project conventions, treat as `[unverified]` until reconfirmed at Stage 1 kickoff.

| Library | Pinned Version | Purpose |
|---------|---------------|---------|
| Go | 1.25 (linux-arm64 official binaries) | Compiler/runtime; supported through 2026-08 minimum |
| `github.com/spf13/cobra` | v1.10.0 | CLI framework (subcommands, flags, shell completion) |
| `gopkg.in/yaml.v3` | latest stable | YAML parsing for non-compose YAML configs |
| `github.com/compose-spec/compose-go/v2` | v2.x | Authoritative Docker Compose YAML parser (registry.yaml consumer) |
| `github.com/sebdah/goldie/v2` | v2.5.x | Snapshot/golden-test equivalence library (Stage 0.5 bridge) |
| `github.com/docker/docker/client` | match daemon API version in `versions.env` | Docker API client (replaces text-parsing in Stage 2) |
| `github.com/santhosh-tekuri/jsonschema/v5` | v5.x | JSON Schema validation for findings registry and config (Stage 3) |

---

## Anti-Recommendations / Scope-Creep Wall

> Repeated from [ADR-0010 §Scope Guard](adr/0010-go-migration-staged-port.md).
> A v4.0 contributor reading only this file must see the guardrails.

The following are **NOT** in scope — neither in Stage 1 nor any subsequent stage
unless a specific, binding decision explicitly overrides one of these items:

- **No `go.mod` / `go.sum` in v3.2.0** — no Go code in v3.2.0 release tarball.
  First `go.mod` lands in v4.0 at Stage 1. Verified by `tests/lint/test_no_go_code_in_v320.sh`.
- **No Go web server** — nginx stays as the HTTP front-end for all Dify/Open WebUI/vLLM
  traffic. `agmind` is a CLI operator tool, not a web service.
- **No cgo** — `CGO_ENABLED=0` always; fully static binary only. cgo introduces OS-level
  shared-library dependencies that conflict with the static-binary arm64-only release goal.
- **No GUI frameworks** — no Wails, no Tauri, no Fyne. `agmind` is a CLI tool.
  Any web-based management surface is handled by Dify Console (already in the stack).
- **No Rust or Zig revisit** — Go is the chosen language. Alternatives were debated during
  Phase 15 research and rejected. This decision is closed per ADR-0010. Revisit only
  after v4.0 Stage 6 ships and concrete evidence for a better language exists.
- **No multi-binary architecture** — single `cmd/agmind/` binary per ADR-0013 (Q-07).
  Per-concern Go modules (separate `go.mod` per verb) rejected; see ADR-0013 for rationale.
- **No third-party Go plugin runtime** — GSD plugins remain bash scripts;
  Go is the host, not the plugin language. The GSD runtime port (Stage 5) adds
  a Go lifecycle manager but the plugin scripts themselves stay in bash.

---

## References

- [docs/adr/0010-go-migration-staged-port.md](adr/0010-go-migration-staged-port.md) —
  Migration intent, equivalence-proof preconditions, arm64-only enforcement, scope guard
- [docs/adr/0013-go-single-binary-internal-packages.md](adr/0013-go-single-binary-internal-packages.md) —
  Q-07 single-binary + `internal/` layout decision
- [docs/adr/0001-arm64-only.md](adr/0001-arm64-only.md) —
  Parent arm64-only platform decision (drives Go arm64-only enforcement)
- [docs/adr/0011-state-store-architecture.md](adr/0011-state-store-architecture.md) —
  State store substrate (`internal/state/` consumer in Stage 3)
- [docs/adr/0012-service-registry-codegen.md](adr/0012-service-registry-codegen.md) —
  Service registry substrate (`internal/doctor/` consumer in Stage 1)
- AGmind-Autofix-Architecture-Spec-v1.0.2 §8 (Go migration intent and stage ordering),
  §10 Q-07 (single-binary recommendation), §PITFALLS Pitfall 10
  (arm64 cross-build architecture mismatch prevention checklist)
