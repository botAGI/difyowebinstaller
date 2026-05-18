# 0013. Go CLI as Single Binary with internal/ Packages (Q-07)

**Date:** 2026-05-18
**Status:** Accepted

## Context and Problem Statement

When the v4.0 Go port begins (per ADR-0010), the codebase must choose a binary layout:

**(a) Single binary** — one `go.mod` at the repo root, one `cmd/agmind/main.go` entry
point, concerns split into `internal/<package>` sub-packages (e.g., `internal/doctor/`,
`internal/health/`, `internal/status/`). One release artifact per stage.

**(b) Modules per concern** — separate `go.mod` per logical CLI verb or subsystem
(`agmind-doctor/`, `agmind-health/`, etc.), each independently versioned and compiled
into its own binary or merged via `replace` directives.

AGmind ships as a single CLI installer/operator: `agmind doctor`, `agmind health`,
`agmind status`, `agmind backup`, `agmind config`. The user experience is "one command,
one binary on PATH". The Go ecosystem precedent for exactly this UX pattern is
unambiguous: `kubectl` (k8s.io/kubernetes/cmd/kubectl), `gh` (cli/cli/cmd/gh), and
`docker` (docker/cli/cmd/docker) all use a single-binary layout with `internal/` packages.

No `go.mod` lands in v3.2.0 — per ADR-0010 scope guard, zero Go code ships in this
release. This ADR locks the layout decision **for v4.0 Stage 1** and reserves the
namespaces (`cmd/agmind/`, `internal/`) via `.gitkeep` placeholders.

## Decision Outcome

**Chosen option:** "Single Go binary built from `cmd/agmind/main.go`, with concerns split
into `internal/<package>` sub-packages under one `go.mod`."

**Reason:**

- **Single artifact simplifies the arm64-only release pipeline** (per ADR-0001 and
  ADR-0010): one binary, one SHA256, one signing step. No per-module release matrix.
- **`internal/` import-path discipline** enforces Go's built-in visibility constraint —
  external consumers cannot depend on AGmind's implementation packages. This is the
  standard CLI-tool norm; deviation requires explicit justification.
- **Stage→package mapping** documented in `docs/ROADMAP-GO.md` (Stage 1 →
  `internal/doctor/`, Stage 2 → `internal/health/` + `internal/status/`, etc.) maps
  naturally to a single-module tree; a multi-module layout would require `replace`
  directives between sibling modules during active development.
- **kubectl / gh / docker-cli precedent** — all three use single binary + `internal/`
  layout at far greater scale than AGmind. No ecosystem benefit exists for per-concern
  module splitting at AGmind's current scale (one operator, one appliance, no external
  extension points yet).

**Alternative considered and rejected:** Separate `go.mod` per concern (multi-module
layout, e.g., `agmind-doctor/go.mod`, `agmind-health/go.mod`).

Rejection rationale: multi-module overhead is high at AGmind's scale — `replace`
directives between sibling modules, version drift between sibling modules, harder
vendoring, wider CI matrix. No compensating benefit exists: there are no external
consumers of AGmind's internal packages, no independent release cadence per verb is
required, and AGmind has no plugin runtime yet (GSD plugin runtime is deferred to v3.3+;
and even then, plugins are bash scripts, not Go modules). Revisit only if a third-party
plugin ecosystem ships and demands independent Go module boundaries.

## Consequences

**Good:**

- Build/release pipeline is one `go build ./cmd/agmind` + one signing step + one arm64
  manifest entry. Matches the Makefile pattern from ADR-0010 (`GOARCH=arm64 CGO_ENABLED=0`).
- `internal/<pkg>` packages are testable in isolation; ports of `lib/health.sh` →
  `internal/health/` are intended to be 1:1 behavioural translations, verifiable via
  the golden-test equivalence gate (ADR-0010 precondition a).
- Aligns with AGmind-Autofix-Architecture-Spec-v1.0.2 §10 Q-07 default
  (single-binary recommendation, confirmed during Phase 15 research).
- Future contributors find a familiar layout — kubectl / gh / docker precedent is
  well-documented, widely understood, and does not require explanation.

**Bad:**

- `cmd/agmind/` and `internal/` directories land empty (only `.gitkeep`) in v3.2.0 —
  looks unusual to newcomers until v4.0 Stage 1 fills them with actual Go code.
- Single-binary couples the release cadence of all CLI verbs: if `agmind doctor` has a
  bug in v4.0.3, all verbs get a new release tag even if they were unchanged.
- If a third-party plugin ecosystem emerges later, single-binary layout forces a
  revisit of this decision — acceptable tradeoff; defer until concrete pressure exists.

## References

- `docs/adr/0010-go-migration-staged-port.md` — parent ADR: staged migration intent,
  arm64-only enforcement, equivalence-proof preconditions
- `docs/adr/0011-state-store-architecture.md` — `internal/state` will consume this
  substrate in Stage 3
- `docs/adr/0012-service-registry-codegen.md` — `internal/doctor` will read
  `registry.yaml` directly in Stage 1
- `docs/ROADMAP-GO.md` — stage→package mapping table (Stage 1–6)
- AGmind-Autofix-Architecture-Spec-v1.0.2 §10 Q-07 — external driver specifying
  single-binary as the recommended layout
- https://github.com/kubernetes/kubernetes/tree/master/cmd/kubectl — ecosystem precedent
- https://github.com/cli/cli/tree/trunk/cmd/gh — ecosystem precedent
