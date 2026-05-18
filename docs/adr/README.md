# Architecture Decision Records — Format and Conventions

> **Catalogue:** see [INDEX.md](INDEX.md) for the full list of ADRs in this repository.
> This README documents the MADR-lite format used and how to write a new ADR.

## Format: MADR-lite

These ADRs are the public projection of key architectural decisions in AGmind.
Each ADR follows the MADR-lite layout:

- `# NNNN. Title` — top-level heading, period after the number, sentence-case title
- `**Date:** YYYY-MM-DD` and `**Status:** Accepted` (or `Superseded`, etc.) on separate lines below the title
- `## Context and Problem Statement` — prose explaining the historical pain and why a decision is needed
- `## Decision Outcome` — `**Chosen option:** "..."` followed by `**Reason:**` and rationale
- `## Consequences` — `**Good:**` and `**Bad:**` bullet sub-labels (bold inline, not sub-headings)
- `## References` — dash-list of relative paths to related ADRs and external links

Additional `##` sections between Consequences and References are permitted for long-form
ADRs (see [0011-state-store-architecture.md](0011-state-store-architecture.md) for an
example with `## Architectural Decisions (Q-N references)`).

## When to write an ADR

When code comments need to point at a decision rationale, they reference
`docs/adr/NNNN-...` (a tracked, public file). If the rationale is operational and
short-lived, prefer an inline `# WHY:` comment or a note in `../troubleshooting.md`.
Not every operational note warrants a dedicated ADR.

## Adding a new ADR

1. Pick the next free number (current max + 1; check [INDEX.md](INDEX.md) for the count).
2. Create `NNNN-slug.md` matching the format above.
3. Add a row to [INDEX.md](INDEX.md) manually (Phase 16 will wire auto-regeneration via
   `make adr-index` pre-commit hook — until then, manual update is required).
4. Cross-link from related ADRs' `## References` section.

## Existing references

For the canonical list and per-ADR titles, see [INDEX.md](INDEX.md).
