# Known Pre-existing Test Failures

Failures that predate the current milestone (v3.2.0), deferred to future fix-passes.
Source-of-truth registry. `tests/run_all.sh` continues to surface these but
they don't gate develop merges.

Per Phase 14 / D-26 triage — confirmed not introduced by Phase 14 work
(none of plans 14-01..14-09 touch the affected code paths). Verified
via `git log --oneline tests/integration/<test>.sh` showing pre-Phase-14
authorship and unchanged content during Phase 14 commits.

## Active

| Test | Subcases | First seen | Root cause hypothesis | Triage owner | Notes |
|------|----------|-----------|------------------------|--------------|-------|
| tests/integration/test_all_bind_mounts_exist.sh | 12 (cell1-cell4 × B1/B2/B3 each) | Phase 13 baseline (commit d49ceec, pre-2026-05-17) | `_run_cell` subshell aborts under `set -u + pipefail` when `cat /var/lib/agmind/state/n8n_encryption_key.preserved` fails with `Permission denied` (file is `0600 root:root` on live host, test runs as non-root). Phase 13's golden harness fix (commit e01edcb) introduced `AGMIND_STATE_DIR` env override but this test sets up its own `_run_cell` subshell that does NOT export `AGMIND_STATE_DIR` — host state leak. | Open (fix-pass on develop, or Phase 16 if interfering with release) | Same class as fixed in commit e01edcb but in a different harness — needs `export AGMIND_STATE_DIR="${PER_TMP}/state"` added to `_run_cell` body (~line 122 region of test). Mechanism: `[[ -s preserved_file ]]` returns true even on permission-denied for the metadata stat, then `cat` fails silently, then `set -u` of unset `_N8N_ENCRYPTION_KEY` (or downstream) aborts the subshell. |
| tests/integration/test_env_bash_sourceable.sh | 38 (multiple cells × 6 assertions) | Phase 13 baseline (commit 27279fc, pre-2026-05-17) | Same root cause as `test_all_bind_mounts_exist.sh` — `_run_cell` setup does not isolate `/var/lib/agmind/state/`, so on dev hosts with prior real installs the wizard subshell dies before emitting `KEY=VALUE` markers; `_get` returns empty; assertions FAIL with `expected: X actual: ''`. | Open (same fix-pass as above) | Same pattern — add `export AGMIND_STATE_DIR="${PER_TMP}/state"` and `export AGMIND_CLUSTER_STATE_DIR="${PER_TMP}/cluster"` (latter already present) before sourcing wizard libs in `_run_cell`. |
| tests/integration/test_wizard_full_flow.sh | 2 (custom_qwen36fp8 C4 + custom_qwen36heretic C4 — `VLLM_EXTRA_ARGS contains dflash`) | Phase 13 baseline (commit 1807172, pre-2026-05-17); previously surfaced as `test_wizard_llm_profile.sh` in Phase 13 deferred-items.md | Production wizard (`lib/wizard.sh::_apply_blackwell_cu130`) was migrated away from `--speculative-config` DFlash args during AEON-7 v1.2 swap (memory: `project_aeon7_dflash_swap_recipe`). The test assertion was not updated — checks for `dflash` substring that no longer appears in current `VLLM_EXTRA_ARGS`. NOT a Phase 14 issue. | Open (fix-pass on develop — update assertions to current AEON-7 v1.2 args: `--enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3 --attention-backend flash_attn`) | Mechanism is purely assertion drift vs production code. Decision needed: either drop the `dflash` substring assertion (current production output) or roll back the wizard's args change (would regress live-deploy perf). Recommendation: drop the assertion. |

## Triage Decision Log

**Phase 14 / D-26 (2026-05-17):**
- All 3 failures verified pre-Phase-14 via `git log --oneline --follow` (no Phase 14 commits touch these test files or the libs they exercise).
- Phase 13 deferred-items.md referenced `test_static_renderer.sh` and `test_wizard_llm_profile.sh` — the underlying test files were renamed/consolidated during Phase 13 work (PASS:78 SKIP:3 FAIL:5 → PASS:87 SKIP:3 FAIL:4 means net `-1 FAIL`).
- Net effect of Phase 14: NO new regressions, 1 pre-existing FAIL accidentally resolved (likely the third static_renderer subcase via Plan 14-06 secret-read migration touching `lib/compose.sh` paths).

**Migrated here (out of Phase 14 scope):**
1. `test_all_bind_mounts_exist.sh` — needs harness isolation parity with golden harness
2. `test_env_bash_sourceable.sh` — same harness isolation gap
3. `test_wizard_full_flow.sh` (2 dflash subcases) — assertion drift vs AEON-7 v1.2

**Fix-forward NOT attempted in Plan 14-09** — scope of v3.2.0 was already closed by 14-01..14-08; touching these tests now would dilute the verification gate. Phase 16 (release cut) or a dedicated `fix(tests)` pass on develop will revisit.

## How to verify Phase 14 didn't cause any of these

```bash
# Per file, show that no Phase 14 commit touched the test file:
git log --oneline --since="2026-05-17" -- tests/integration/test_all_bind_mounts_exist.sh
git log --oneline --since="2026-05-17" -- tests/integration/test_env_bash_sourceable.sh
git log --oneline --since="2026-05-17" -- tests/integration/test_wizard_full_flow.sh
# All three return empty — no Phase 14 commits modified these files.

# Per failure, show that the symptom predates Phase 14:
git stash; git checkout 0816976  # Plan 14-01 RESOLVER baseline commit (pre 14-02..14-08)
bash tests/integration/test_all_bind_mounts_exist.sh; echo "rc=$? (expect 1 = FAIL = pre-existing)"
git checkout develop; git stash pop
```

## How to retire a row

When a pre-existing FAIL is fixed forward:
1. Land the fix commit on develop (`fix(tests): isolate _run_cell state dir in test_all_bind_mounts_exist`).
2. Verify `bash tests/run_all.sh` FAIL count drops by the appropriate amount.
3. Remove the row from "Active" table above.
4. Mention removal in commit body (`closes known-failure: test_all_bind_mounts_exist.sh`).

## How to revert this registry

```bash
git revert <SHA-of-known-failures-commit>
bash tests/run_all.sh  # registry is doc-only — no test behavior change
```
