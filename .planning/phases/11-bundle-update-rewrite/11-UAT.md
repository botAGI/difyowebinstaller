---
status: testing
phase: 11-bundle-update-rewrite
source: [11-01-SUMMARY.md, 11-02-SUMMARY.md]
started: 2026-03-22T11:45:00Z
updated: 2026-03-22T14:30:00Z
---

## Current Test

[paused — bugs fixed, awaiting re-test on live server]

## Tests

### 1. Bundle Check — Release Comparison
expected: Run `agmind update --check`. Shows current vs latest release with per-component version diff. If current == latest: "You are up to date (vX.Y.Z)".
result: pass
note: "/opt/agmind/RELEASE не создаётся при установке — fixed in a1acd93"

### 2. Bundle Update Full Flow
expected: Run `agmind update`. Shows version diff, asks "Update to vX.Y.Z? [y/N]". On confirm: creates backup, saves rollback state, applies new versions to .env, pulls only changed images, rolling restart in dependency order, writes RELEASE file. Success message: "Update to vX.Y.Z completed successfully!"
result: issue → fixed, needs re-test
reported: "BUG-V3-044 + BUG-V3-045"
fixes: "a1acd93 (RELEASE file), a1acd93 (*_VERSION filter), ebb6ca8 (SERVICES_TO_UPDATE counter)"

### 3. Emergency Mode Warning
expected: Run `agmind update --component dify-api --version 1.13.2`. Shows yellow WARNING banner: "Single-component update bypasses release compatibility", "Recommended: use 'agmind update'", and "Continue anyway? [y/N]" confirmation.
result: issue → fixed, needs re-test
reported: "SERVICES_TO_UPDATE: unbound variable (строка 820)"
fixes: "ebb6ca8 (svc_count counter instead of ${#array[@]})"

### 4. Force Flag Bypass
expected: Run `agmind update --component dify-api --version 1.13.2 --force`. No warning shown — proceeds directly to component update without [y/N] prompt.
result: issue → fixed, needs re-test
reported: "--force не пропускает confirmation + CURRENT_VERSIONS: bad array subscript"
fixes: "ebb6ca8 (FORCE check in resolve_component, exit→return, caller check)"

### 5. Bundle Rollback
expected: Run `agmind update --rollback` (no component name). Restores previous bundle from .rollback/ directory: .env, versions.env, RELEASE file. Shows "Rolling back bundle: vX -> vY", runs verify_rollback, logs the action.
result: issue → fixed, needs re-test
reported: "BUG-V3-046: web не перезапускается при откате dify-core группы"
fixes: "1f62b4e (final docker compose up -d after rollback)"

### 6. Updated Help Text
expected: Run `agmind help` or `agmind update --help`. Update section shows: --check (mentions GitHub Releases), --component labeled "Emergency", --force option listed, --rollback split into bundle (no arg) and legacy component (with arg).
result: [pending]

### 7. BUG-V3-041 ANSI in grep
expected: Run `agmind update --component dify-api --version X` (shared image group). resolve_component() output doesn't leak ANSI codes into version_key.
result: fixed, needs re-test
fixes: "ae12013 (UI output → stderr in resolve_component)"

## Summary

total: 7
passed: 1
issues: 5 (all fixed)
pending: 1
skipped: 0
needs_retest: 5

## Gaps

- truth: "agmind update выполняет полный bundle update flow без ошибок"
  status: fixed
  reason: "BUG-V3-044 (RELEASE), BUG-V3-045 (*_VERSION filter), SERVICES_TO_UPDATE unbound"
  severity: blocker
  test: 2
  root_cause: "RELEASE file missing at install, non-version keys in NEW_VERSIONS, empty assoc array with set -u"
  artifacts:
    - path: "install.sh"
      issue: "No RELEASE file created"
    - path: "scripts/update.sh:fetch_release_info"
      issue: "VLLM_CUDA_SUFFIX parsed into NEW_VERSIONS"
    - path: "scripts/update.sh:perform_bundle_update"
      issue: "${#SERVICES_TO_UPDATE[@]} on empty assoc array"
  missing: []
  debug_session: ""

- truth: "--force пропускает все confirmation prompts"
  status: fixed
  reason: "resolve_component() не проверял FORCE, exit в subshell не выходил из скрипта"
  severity: blocker
  test: 4
  root_cause: "resolve_component() checked AUTO_UPDATE only, not FORCE; exit 0 inside $() only exits subshell"
  artifacts:
    - path: "scripts/update.sh:resolve_component"
      issue: "exit→return, added FORCE check"
  missing: []
  debug_session: ""

- truth: "rollback перезапускает все сервисы группы включая web"
  status: fixed
  reason: "BUG-V3-046: depends_on cascade stops web when api stops"
  severity: major
  test: 5
  root_cause: "Sequential stop in rollback_component() caused depends_on cascade"
  artifacts:
    - path: "scripts/update.sh:rollback_component"
      issue: "Added final docker compose up -d"
  missing: []
  debug_session: ""

- truth: "resolve_component() не пропускает ANSI коды в version_key"
  status: fixed
  reason: "BUG-V3-041: log_warn stdout captured by $()"
  severity: blocker
  test: 7
  root_cause: "UI output mixed with return value on stdout"
  artifacts:
    - path: "scripts/update.sh:resolve_component"
      issue: "All UI → stderr"
  missing: []
  debug_session: ""
