# `lib/` ↔ `scripts/` pairing inventory

Phase 14 / DUP-02 inventory. Single source of truth for which `lib/X.sh`
files have a corresponding `scripts/X.sh` entry and what relationship
those two paths have. Enforced by `tests/compose/test_lib_scripts_parity.sh`.

Pair types:

- **symlink** — `scripts/X.sh` is a symlink whose target is `../lib/X.sh`.
  Single source of truth lives in `lib/`. Edit `lib/X.sh` only.
- **byte-identical-copy** — `scripts/X.sh` is a regular file with the exact
  bytes of `lib/X.sh`. Sync managed by `install.sh::_copy_runtime_files`
  at deploy time; in-repo both files must match byte-for-byte (CI enforced).
- **justified-divergence** — `scripts/X.sh` and `lib/X.sh` intentionally
  differ. Typically: `scripts/X.sh` is a thin exec entrypoint;
  `lib/X.sh` is the library implementation. NO parity check applied;
  manual review on changes. Sync of the library copy into the runtime
  is enforced by `tests/unit/test_copy_runtime_files.sh` (source-of-truth
  pattern matcher: every `${SCRIPTS_DIR}/X.sh` sourced by `scripts/agmind.sh`
  must be produced by `install.sh::_copy_runtime_files`).

## Inventory

| lib | scripts | type | rationale | enforced_by_test |
|-----|---------|------|-----------|------------------|
| lib/health.sh | scripts/health.sh | symlink | Library with no script-specific entrypoint; symlink shipped 2026-05-16 (Phase 12) | tests/compose/test_lib_scripts_parity.sh |
| lib/detect.sh | scripts/detect.sh | symlink | Library with no script-specific entrypoint; symlink shipped Phase 12 | tests/compose/test_lib_scripts_parity.sh |
| lib/backup.sh | scripts/backup.sh | justified-divergence | scripts/backup.sh = thin exec entrypoint (CLI dispatcher); lib/backup.sh = library impl sourced by agmind.sh | manual review + tests/unit/test_copy_runtime_files.sh |
| lib/restore.sh | scripts/restore.sh | justified-divergence | scripts/restore.sh = thin exec entrypoint; lib/restore.sh copied as scripts/restore-lib.sh at install.sh (name-collision avoidance per CLAUDE.md §8) | manual review + tests/unit/test_copy_runtime_files.sh |

## Adding a new pair

1. If `lib/NEW.sh` is library code with no separate CLI entrypoint → ship as **symlink**:
   ```bash
   cd scripts && ln -s ../lib/NEW.sh NEW.sh
   ```
   Add row to inventory above. Run `bash tests/compose/test_lib_scripts_parity.sh` — must pass.

2. If `scripts/NEW.sh` must be a thin entrypoint and `lib/NEW.sh` is the impl:
   - Pick a distinct lib name (e.g., `lib/NEW-lib.sh` OR keep `lib/NEW.sh` but in
     `install.sh::_copy_runtime_files` copy it AS `scripts/NEW-lib.sh` to avoid name collision)
   - Document the divergence rationale in this inventory under "justified-divergence"

## Removing a pair

1. If symlink no longer needed (scripts/X.sh entrypoint no longer wanted):
   `rm scripts/X.sh` + remove row from inventory + verify parity test passes.
2. If diverging: convert symlink to copy OR convert copy to symlink + update inventory row.

## CI enforcement

`tests/compose/test_lib_scripts_parity.sh` runs in CI's `compose:` lane
(Phase 12 wired into tests/run_all.sh). On every push:

- For each inventory row, verifies the stated pair type holds.
- For `symlink` rows: asserts `[[ -L scripts/X.sh ]]` AND `readlink == ../lib/X.sh`.
- For `byte-identical-copy` rows: asserts `diff -q lib/X.sh scripts/X.sh` exits 0.
- For `justified-divergence` rows: both files exist; no content check.

CI fails if:

- Inventory row references a non-existent file pair
- Pair type stated in inventory disagrees with on-disk state
- Required test for inventory row is missing from the repo

## Historical context

`install.sh::_copy_runtime_files` previously had explicit `cp lib/health.sh scripts/health.sh`
and `cp lib/detect.sh scripts/detect.sh` lines that DEREFERENCED the source symlink at
install time, converting `scripts/health.sh` from a symlink (in-repo) to a regular file
(on the deployed host). Plan 14-07 (DUP-03 fix) changed the glob copy at the top of
`_copy_runtime_files` to `cp -P` (preserve symlinks) and removed the redundant explicit
copies. See `docs/adr/0012-service-registry-codegen.md` for the related ADR pattern and
`tests/unit/test_copy_runtime_files.sh::check_symlink_preservation` for the regression
test that catches reverts of this fix.
