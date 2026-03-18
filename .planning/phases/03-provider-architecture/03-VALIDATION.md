---
phase: 3
slug: provider-architecture
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-18
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | BATS (Bash Automated Testing System) |
| **Config file** | tests/ directory (existing BATS tests from Phase 2) |
| **Quick run command** | `bats tests/test_wizard_provider.bats tests/test_compose_profiles.bats` |
| **Full suite command** | `bats tests/ --formatter tap` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bats tests/test_wizard_provider.bats tests/test_compose_profiles.bats`
- **After every plan wave:** Run `bats tests/ --formatter tap`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 03-01-01 | 01 | 0 | PROV-01 | unit | `bats tests/test_wizard_provider.bats` | ❌ W0 | ⬜ pending |
| 03-01-02 | 01 | 0 | PROV-02 | unit | `bats tests/test_wizard_provider.bats` | ❌ W0 | ⬜ pending |
| 03-01-03 | 01 | 0 | PROV-03 | unit | `bats tests/test_compose_profiles.bats` | ❌ W0 | ⬜ pending |
| 03-01-04 | 01 | 0 | PROV-04 | smoke | `grep -q "langgenius/ollama" workflows/README.md` | ❌ W0 | ⬜ pending |
| 03-02-01 | 01 | 1 | PROV-01 | unit | `bats tests/test_wizard_provider.bats` | ❌ W0 | ⬜ pending |
| 03-02-02 | 01 | 1 | PROV-01 | unit | `bats tests/test_wizard_provider.bats` | ❌ W0 | ⬜ pending |
| 03-03-01 | 02 | 1 | PROV-03 | unit | `bats tests/test_compose_profiles.bats` | ❌ W0 | ⬜ pending |
| 03-03-02 | 02 | 1 | PROV-03 | unit | `bats tests/test_compose_profiles.bats` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test_wizard_provider.bats` — stubs for PROV-01, PROV-02 (wizard LLM/embed provider selection, GPU fallback, non-interactive mode)
- [ ] `tests/test_compose_profiles.bats` — stubs for PROV-03 (COMPOSE_PROFILES builder for ollama/vllm/tei, external/skip exclusion)

*Existing infrastructure covers BATS framework — no framework install needed.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| vLLM container starts with GPU passthrough | PROV-03 | Requires NVIDIA GPU hardware | `docker compose --profile vllm up -d && docker exec vllm nvidia-smi` |
| TEI model download completes | PROV-03 | Requires network + time | `docker compose --profile tei up -d && curl -sf http://localhost:8080/health` |
| Dify plugin installation per provider | PROV-04 | Requires running Dify UI | Follow workflows/README.md per-provider section |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
