---
phase: 31-wizard-simplify-caddy-branch
plan: "01"
subsystem: wizard
tags: [wizard, deploy-profile, offline-removal, caddy-branch, simplification]
dependency_graph:
  requires: []
  provides: [simplified-wizard, caddy-branch-switch, offline-free-codebase]
  affects: [lib/wizard.sh, lib/compose.sh, lib/detect.sh, lib/config.sh, lib/docker.sh, lib/models.sh, install.sh]
tech_stack:
  added: []
  patterns: [2-choice-wizard, git-branch-exec-handoff]
key_files:
  created: []
  modified:
    - lib/wizard.sh
    - lib/compose.sh
    - lib/detect.sh
    - lib/config.sh
    - lib/docker.sh
    - lib/models.sh
    - install.sh
  deleted:
    - scripts/build-offline-bundle.sh
decisions:
  - "VDS/VPS wizard choice executes git fetch+checkout agmind-caddy then exec install.sh --vds (never returns)"
  - "Offline profile fully removed from codebase; no backward compat kept"
  - "LAN is now default choice 1 in 2-choice wizard menu"
  - "check_ollama_models() retained (still called from agmind.sh and health.sh)"
metrics:
  duration: "~10 minutes"
  completed: "2026-03-30"
  tasks_completed: 2
  files_modified: 7
  files_deleted: 1
---

# Phase 31 Plan 01: Wizard Simplify + Caddy Branch Summary

**One-liner:** 2-choice deploy wizard (LAN default, VDS/VPS via git branch exec) replacing 4-choice menu with full offline profile removal across all lib/*.sh files.

## Tasks Completed

| Task | Name | Commit | Key Changes |
|------|------|--------|-------------|
| 1 | Rewrite wizard profile to 2 choices + remove all offline from wizard.sh | 9236273 | _wizard_profile 4->2 choices; VDS/VPS exec to agmind-caddy branch; deleted _wizard_offline_warning; removed offline/vps guards from 8 functions |
| 2 | Remove offline from lib files + install.sh + delete bundle script | 8d57e4b | 5 lib files cleaned; build-offline-bundle.sh deleted; install.sh copy list updated |

## What Was Built

### Simplified 2-Choice Wizard

`_wizard_profile()` now presents exactly 2 choices:
1. LAN — локальная / офисная сеть (по умолчанию)
2. VDS/VPS — публичный сервер (переключение на ветку agmind-caddy)

Choosing VDS/VPS executes `git fetch origin agmind-caddy && git checkout agmind-caddy && exec bash install.sh --vds` — process replacement, never returns to main branch wizard.

### wizard.sh Cleaned Functions

- `_wizard_security_defaults()`: only LAN defaults remain
- `_wizard_admin_ui()`: VPS early-return removed
- `_wizard_domain()`: replaced with `return 0` (handled by agmind-caddy branch)
- `_wizard_etl()`: offline early-return block removed
- `_wizard_tls()`: VPS letsencrypt and offline none blocks removed
- `_wizard_monitoring()`: always shows 3 choices (no offline guard)
- `_wizard_alerts()`: always shows 3 choices (no offline guard)
- `_wizard_security()`: VPS UFW auto-enable and Authelia 2FA block removed
- `_wizard_tunnel()`: guard changed to `lan`-only (vpn removed)
- `_wizard_offline_warning()`: function deleted entirely

### lib/*.sh Cleaned

- `lib/compose.sh`: offline skip removed from `validate_images_exist()`, `compose_pull()`, `compose_start()`
- `lib/detect.sh`: offline skip removed from internet connectivity and DNS checks in `preflight_checks()`
- `lib/config.sh`: squid RFC1918 condition changed from `lan|offline` to `lan`
- `lib/docker.sh`: offline skip removed from `configure_docker_dns()`
- `lib/models.sh`: offline skip removed from `download_models()`; section comment cleaned

### Deleted

- `scripts/build-offline-bundle.sh` — deleted from filesystem and git
- Reference removed from `install.sh`'s `_copy_runtime_files()` scripts array

## Verification Results

- `grep -rn "offline" lib/*.sh install.sh | grep -v "^#"` — 0 matches
- `grep -rn 'DEPLOY_PROFILE="offline"' lib/*.sh install.sh` — 0 matches
- `test ! -f scripts/build-offline-bundle.sh` — PASS
- `grep "agmind-caddy" lib/wizard.sh` — 4 matches
- `grep "VDS/VPS" lib/wizard.sh` — 3 matches
- `bash -n` for all 7 modified files — all pass
- `git ls-files lib/health.sh lib/detect.sh | wc -l` — 2 (WZRD-05 satisfied)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Stale section comment in lib/models.sh**
- **Found during:** Task 2
- **Issue:** `check_ollama_models()` section comment said "(offline mode)" but offline-specific call was removed; function itself is still used by agmind.sh and health.sh
- **Fix:** Updated comment from "CHECK PRE-LOADED MODELS (offline mode)" to "CHECK PRE-LOADED MODELS"
- **Files modified:** lib/models.sh
- **Commit:** 8d57e4b

No other deviations — plan executed as written.

## Requirements Satisfied

- WZRD-01: Wizard deploy profile shows exactly 2 choices (LAN, VDS/VPS)
- WZRD-02: VDS/VPS executes git fetch+checkout agmind-caddy+exec install.sh --vds
- WZRD-03: No code path handles DEPLOY_PROFILE=offline anywhere in lib/*.sh or install.sh
- WZRD-05: lib/health.sh and lib/detect.sh are tracked in git (confirmed)

## Self-Check: PASSED

- lib/wizard.sh — exists, syntax OK, 0 offline refs
- lib/compose.sh — exists, syntax OK, 0 offline refs
- lib/detect.sh — exists, syntax OK, 0 offline refs
- lib/config.sh — exists, syntax OK, 0 offline refs
- lib/docker.sh — exists, syntax OK, 0 offline refs
- lib/models.sh — exists, syntax OK, 0 offline refs
- install.sh — exists, syntax OK, 0 build-offline-bundle refs
- scripts/build-offline-bundle.sh — does not exist (PASS)
- Commits 9236273 and 8d57e4b — exist in git log
