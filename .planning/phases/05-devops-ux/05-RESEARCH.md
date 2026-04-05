# Phase 5: DevOps & UX — Research

**Researched:** 2026-03-18
**Domain:** Bash CLI tools, nginx static file serving, cron-based health generation, symlink management
**Confidence:** HIGH (all findings based on direct codebase analysis + established project patterns)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**CLI Entry Point**
- Single script `scripts/agmind.sh` with case-dispatch on subcommands
- Symlink `/usr/local/bin/agmind` → `/opt/agmind/scripts/agmind.sh` (created during `phase_complete()`)
- Full CLI-hub: status, doctor, backup, restore, update, uninstall, rotate-secrets, logs, help
- Existing scripts in `scripts/` become backends — agmind dispatches to them
- INSTALL_DIR defaults to `/opt/agmind`, overridable via `AGMIND_DIR` env var
- Privilege model: mixed — `agmind status` works without root (if user in docker group), other commands require sudo with clear error message "Запустите: sudo agmind <command>"

**agmind status**
- Compact dashboard format by default: sections Services, GPU, Models, Endpoints, Backup, Credentials
- Reuses existing `health.sh` functions: `check_all()`, `check_gpu_status()`, `check_ollama_models()`, `check_vector_health()`, `check_disk_usage()`, `check_backup_status()`
- `--json` flag outputs machine-parseable JSON (same schema as /health endpoint)
- Endpoints section reads DOMAIN, DEPLOY_PROFILE, ADMIN_UI_OPEN from `.env` — shows actual URLs
- Portainer/Grafana endpoints shown only if ADMIN_UI_OPEN=true
- Backup section with color-coded age: green <24h, yellow <72h, red >72h (existing `check_backup_status()` logic)
- Credentials section shows path `/opt/agmind/credentials.txt` only — never content (Phase 2 decision)

**agmind doctor**
- Checklist format with severity: [OK] / [WARN] / [FAIL] + actionable recommendation on issues
- Exit codes: 0 = all OK, 1 = warnings present, 2 = failures present (CI-friendly)
- `--json` flag for machine-parseable output (consistent with status)
- Checks (all 4 categories):
  1. Docker + Compose: installed, minimum versions (Docker 24+, Compose V2.20+)
  2. DNS + Network: resolves registry.ollama.ai, Docker Hub reachable
  3. GPU driver + runtime: nvidia-smi available, nvidia-container-toolkit installed, docker runtime nvidia configured
  4. Ports + Disk + RAM: ports 80/443 free (or in use by agmind), disk >20GB free, RAM >8GB
- Auto-detect mode: if /opt/agmind exists → post-install checks (restart loops, .env validity, log volume), otherwise pre-install only
- Reuses `detect.sh` functions: `detect_os()`, `detect_gpu()`, port detection, RAM detection

**Health Endpoint (/health)**
- Implementation: cron (every minute) runs `scripts/health-gen.sh` → writes `/opt/agmind/docker/nginx/health.json`
- Nginx serves static file at `/health` with `default_type application/json` and `Cache-Control: no-cache`
- JSON schema: summary + per-service detail (see CONTEXT.md for exact schema)
- Accessible externally without Authelia (bypass rule like /api/ routes — Phase 2 precedent)
- Rate limited: 1r/s (consistent with Phase 2 nginx rate limiting)
- Data freshness: up to 1 minute stale (cron interval)
- `agmind status --json` outputs the same schema for consistency

### Claude's Discretion
- Exact cron/systemd timer implementation for health-gen.sh
- How `agmind logs` dispatches to `docker compose logs`
- Exact minimum Docker/Compose version numbers for doctor checks
- Internal structure of agmind.sh (function organization)
- Whether doctor GPU checks are skipped when LLM_PROVIDER=external

### Deferred Ideas (OUT OF SCOPE)
- `agmind update` / `agmind rollback` — full implementation in TLSU-02/TLSU-03 (v2.1), in v2.0 only dispatch on existing scripts/update.sh
- `agmind uninstall --volumes` / `--containers-only` — extended uninstall in INSE-02 (v2.1)
- `agmind --dry-run` — INSE-03 (v2.1)
- Real-time health endpoint (websocket/SSE)
- `agmind shell <service>`
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DEVX-01 | agmind status — containers, GPU, models, endpoints, credentials path | Covered: health.sh reuse + .env sourcing pattern; agmind.sh dispatcher design |
| DEVX-02 | agmind doctor — DNS, GPU driver, Docker version, port conflicts, disk, network | Covered: detect.sh reuse; preflight_checks() pattern analysis; exit code convention |
| DEVX-03 | Health endpoint /health — JSON with status of all services | Covered: nginx static file pattern; cron setup; health-gen.sh design using health.sh |
| DEVX-04 | Named volumes with agmind_ prefix | COMPLETE (delivered in Phase 4) — no work needed |
</phase_requirements>

---

## Summary

Phase 5 is a pure shell-scripting phase with no new external dependencies. All required functionality is assembled from existing components: `lib/health.sh` provides all container/GPU/model/backup check functions; `lib/detect.sh` provides all system detection functions; `detect.sh:preflight_checks()` already implements [PASS]/[WARN]/[FAIL] format almost identical to the required `agmind doctor` output. The main work is three new files: `scripts/agmind.sh` (dispatcher), `scripts/health-gen.sh` (JSON generator), and an nginx `/health` location block.

The health endpoint design is deliberately simple: cron writes a static JSON file, nginx serves it. This avoids dynamic endpoints, CGI, or runtime dependencies. The tradeoff — up to 1 minute stale data — is acceptable per the locked decision. The nginx service already has the volume mount infrastructure; we only need to add `health.json` to the mount and add the location block.

The symlink `/usr/local/bin/agmind` must be created inside `phase_complete()` in install.sh, not during `phase_config()`, because it must point to the fully-copied and chmod-ed `scripts/agmind.sh` which is copied in `phase_config()`. The copy-scripts block in `phase_config()` (lines 842-849) also needs `agmind.sh` added to it.

**Primary recommendation:** Build `agmind.sh` as a thin dispatcher that sources `lib/health.sh` and `lib/detect.sh` from `${AGMIND_DIR:-/opt/agmind}`, then delegates to existing functions and scripts. Minimize new logic; reuse maximally.

---

## Standard Stack

### Core
| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| Bash 5+ | system | Script runtime | Project standard; `set -euo pipefail` required |
| docker compose | v2.20+ | Container management in status/doctor | Already installed; V2 syntax (`docker compose`) |
| nginx:1.27.3-alpine | (pinned in versions.env) | Serves `/health` static file | Already in stack |
| cron (system) | system | Periodic health-gen.sh execution | Standard Linux, no extra install |

### Supporting
| Component | Version | Purpose | When to Use |
|-----------|---------|---------|-------------|
| `lib/health.sh` | project | All container/GPU/model checks | Status and health-gen reuse |
| `lib/detect.sh` | project | Docker/port/RAM/disk/DNS detection | Doctor checks reuse |
| `nvidia-smi` | system | GPU utilization in status | Only when GPU_TYPE=nvidia |
| `python3` (for JSON) | system | JSON parsing in health-gen.sh (e.g. vector health) | Already used in health.sh |

**Installation:** No new packages required. All tools already present.

---

## Architecture Patterns

### Recommended Project Structure (new files)

```
scripts/
├── agmind.sh           # NEW: CLI dispatcher (copied to /opt/agmind/scripts/)
├── health-gen.sh       # NEW: JSON health generator (copied to /opt/agmind/scripts/)
└── [existing scripts]  # backends for agmind subcommands

templates/
└── nginx.conf.template # MODIFY: add /health location block

install.sh              # MODIFY: phase_config() adds agmind.sh/health-gen.sh copy;
                        #          phase_complete() adds symlink + cron install
```

### Pattern 1: Case-dispatch CLI with sourced libs

`agmind.sh` follows the same pattern as install.sh top-level: source libs, then dispatch.

```bash
#!/usr/bin/env bash
# agmind — AGMind day-2 operations CLI
set -euo pipefail

AGMIND_DIR="${AGMIND_DIR:-/opt/agmind}"
INSTALL_DIR="$AGMIND_DIR"
SCRIPTS_DIR="${AGMIND_DIR}/scripts"
COMPOSE_FILE="${AGMIND_DIR}/docker/docker-compose.yml"

# Source shared libs (installed copies)
# shellcheck source=/dev/null
source "${AGMIND_DIR}/scripts/health.sh" 2>/dev/null || {
    echo "ERROR: AGMind not installed at ${AGMIND_DIR}" >&2; exit 1
}

# Colors (redeclare in case sourced from subshell)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}Требуется root. Запустите: sudo agmind ${1:-}${NC}" >&2
        exit 1
    fi
}

cmd_status() { ... }
cmd_doctor() { ... }
cmd_logs()   { exec docker compose -f "$COMPOSE_FILE" logs "$@"; }
cmd_help()   { ... }

case "${1:-help}" in
    status)         shift; cmd_status "$@" ;;
    doctor)         shift; cmd_doctor "$@" ;;
    backup)         _require_root backup; exec "${SCRIPTS_DIR}/backup.sh" "$@" ;;
    restore)        _require_root restore; exec "${SCRIPTS_DIR}/restore.sh" "$@" ;;
    update)         _require_root update; exec "${SCRIPTS_DIR}/update.sh" "$@" ;;
    uninstall)      _require_root uninstall; exec "${SCRIPTS_DIR}/uninstall.sh" "$@" ;;
    rotate-secrets) _require_root rotate-secrets; exec "${SCRIPTS_DIR}/rotate_secrets.sh" "$@" ;;
    logs)           shift; cmd_logs "$@" ;;
    help|--help|-h) cmd_help ;;
    *)              echo -e "${RED}Неизвестная команда: ${1}${NC}" >&2; cmd_help; exit 1 ;;
esac
```

**Key insight:** `health.sh` is already copied to `${INSTALL_DIR}/scripts/health.sh` in `phase_config()` (line 846). `agmind.sh` sources this copy. This means `INSTALL_DIR` must be exported or set before sourcing — use `INSTALL_DIR="$AGMIND_DIR"` assignment before the source call.

### Pattern 2: JSON output from bash (health-gen.sh)

Bash does not have a JSON library. Use printf/heredoc construction with manual escaping. For values from docker commands (container names, statuses), escape double-quotes and backslashes.

```bash
# Pattern: build JSON incrementally, then write atomically
TMPFILE=$(mktemp "${AGMIND_DIR}/docker/nginx/.health.json.XXXXXX")
# ... populate TMPFILE ...
mv "$TMPFILE" "${AGMIND_DIR}/docker/nginx/health.json"
```

Atomic write via mv prevents nginx from serving a partially-written file. This is critical because cron runs every minute and nginx may read health.json mid-write.

For container status collection:
```bash
# Pattern used in health.sh check_container()
status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Status}}' "$name" 2>/dev/null || echo "not found")
if echo "$status" | grep -qi "up\|healthy"; then result="running"; else result="stopped"; fi
```

For the JSON summary status calculation:
- If any service "stopped" → "unhealthy"
- If all services "running" → "healthy"
- If some starting/degraded → "degraded"

### Pattern 3: --json flag for dual output (status and doctor)

Both `agmind status` and `agmind doctor` support `--json`. Parse args before running checks:

```bash
cmd_status() {
    local output_json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) output_json=true; shift ;;
            *) echo -e "${RED}Unknown flag: $1${NC}" >&2; exit 1 ;;
        esac
    done
    if [[ "$output_json" == "true" ]]; then
        _status_as_json
    else
        _status_dashboard
    fi
}
```

The JSON schema for both `agmind status --json` and the `/health` endpoint must be identical (locked decision). This means `_status_as_json()` and `health-gen.sh` share the same JSON structure logic — extract this into a shared helper function, or have health-gen.sh call `agmind status --json` directly.

**Recommended:** health-gen.sh calls `"${AGMIND_DIR}/scripts/agmind.sh" status --json` and redirects output to `health.json`. This guarantees schema consistency without duplicating JSON assembly logic.

```bash
# health-gen.sh
#!/usr/bin/env bash
set -euo pipefail
AGMIND_DIR="${AGMIND_DIR:-/opt/agmind}"
TMPFILE=$(mktemp "${AGMIND_DIR}/docker/nginx/.health.json.XXXXXX")
"${AGMIND_DIR}/scripts/agmind.sh" status --json > "$TMPFILE" 2>/dev/null && \
    mv "$TMPFILE" "${AGMIND_DIR}/docker/nginx/health.json" || \
    rm -f "$TMPFILE"
```

### Pattern 4: Doctor severity accumulator

```bash
cmd_doctor() {
    local errors=0 warnings=0
    local output_json=false
    # parse --json flag...

    _check() {
        local severity="$1" label="$2" message="$3" fix="${4:-}"
        case "$severity" in
            OK)   echo -e "  ${GREEN}[OK]${NC}   $label" ;;
            WARN) echo -e "  ${YELLOW}[WARN]${NC} $label — $message"
                  [[ -n "$fix" ]] && echo -e "         ${CYAN}→ $fix${NC}"
                  warnings=$((warnings+1)) ;;
            FAIL) echo -e "  ${RED}[FAIL]${NC} $label — $message"
                  [[ -n "$fix" ]] && echo -e "         ${CYAN}→ $fix${NC}"
                  errors=$((errors+1)) ;;
        esac
    }

    # ... run checks calling _check ...

    if   [[ $errors -gt 0 ]];   then exit 2
    elif [[ $warnings -gt 0 ]]; then exit 1
    else exit 0; fi
}
```

This pattern matches `preflight_checks()` in `detect.sh` (lines 307-507) which already uses [PASS]/[WARN]/[FAIL] with identical counting logic. The doctor output is Russian-language per CONTEXT.md specifics.

### Pattern 5: Nginx /health static file location

The `/health` location must be added to the HTTP server on port 80 in `nginx.conf.template`. Based on Phase 2 precedent for Authelia bypass (API routes placed before auth rules), the `/health` location goes near the top of the server block, before the main `/` proxy location.

```nginx
# Health endpoint — static JSON, no auth, rate limited
location = /health {
    default_type application/json;
    add_header Cache-Control "no-cache, no-store, must-revalidate";
    add_header X-Content-Type-Options "nosniff" always;
    limit_req zone=health burst=5 nodelay;
    alias /opt/agmind-health/health.json;
}
```

Important: nginx container has `read_only: true` (line 658 docker-compose.yml). The health.json file is mounted as a volume from the host, not written inside the container. Two approaches:

**Option A — host directory mount (recommended):** Mount `${INSTALL_DIR}/docker/nginx/health.json` into the nginx container as a read-only file. health-gen.sh writes to the host path. This is consistent with how `./nginx/nginx.conf` is already mounted (line 673).

**Option B — named volume:** Create a shared volume between cron (or a health-gen container) and nginx. More complex, not needed given the simple approach works.

Nginx volume addition in docker-compose.yml:
```yaml
volumes:
  - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
  - ./nginx/health.json:/opt/agmind-health/health.json:ro   # NEW
  - ./volumes/certbot/conf:/etc/letsencrypt:ro
  # ...
```

The health.json file must exist before nginx starts (or nginx will fail on startup). `health-gen.sh` must be run during `phase_complete()` to generate an initial `health.json` before the cron takes over.

### Pattern 6: Cron installation for health-gen.sh

Cron entry added during `phase_complete()`:

```bash
# Install health-gen cron (every minute, as root)
local cron_entry="* * * * * root ${INSTALL_DIR}/scripts/health-gen.sh >> ${INSTALL_DIR}/health-gen.log 2>&1"
echo "$cron_entry" > /etc/cron.d/agmind-health
chmod 644 /etc/cron.d/agmind-health
```

`/etc/cron.d/` format requires username field (root). This is the correct approach for system-wide cron vs user crontab — consistent with existing `backup-cron.template` pattern.

**Systemd timer alternative** (Claude's Discretion): On systemd systems, a `.timer` + `.service` unit is more reliable than cron. However, the project already uses cron for backups (`templates/backup-cron.template`), so cron is the established pattern. Recommend cron for consistency.

### Pattern 7: Symlink creation in phase_complete()

```bash
# Create agmind symlink (idempotent)
ln -sf "${INSTALL_DIR}/scripts/agmind.sh" /usr/local/bin/agmind
echo -e "${GREEN}Команда agmind доступна: agmind help${NC}"
```

`ln -sf` is idempotent (safe to re-run on reinstall). Place after the existing summary box output.

### Anti-Patterns to Avoid

- **Sourcing health.sh from the installer source tree inside agmind.sh:** agmind.sh must source from `${AGMIND_DIR}/scripts/health.sh` (the installed copy), not from the installer's `lib/health.sh`. The installer tree may not be present on the server.
- **Writing JSON incrementally without atomic swap:** Never write directly to `health.json` — always write to a tmp file then mv. Nginx may read mid-write otherwise.
- **Hardcoding /opt/agmind in agmind.sh:** Always use `AGMIND_DIR` variable. The installed symlink points to `/opt/agmind/scripts/agmind.sh` which sets `AGMIND_DIR` from its own path using `$(dirname "$(realpath "$0")")`.
- **Skipping `|| true` on non-critical commands in health-gen.sh:** health-gen.sh runs as cron; any uncaught error will make the file stale. Wrap docker commands in `|| true` to produce degraded JSON rather than crashing silently.
- **Using `docker-compose` (V1) syntax:** Project uses V2 `docker compose` (no hyphen). Doctor checks must verify this.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Container status check | Custom docker inspect loop | `health.sh:check_all()` + `check_container()` | Already handles status parsing, color output, service list |
| GPU detection | Custom nvidia-smi parsing | `health.sh:check_gpu_status()` + `detect.sh:detect_gpu()` | Already handles nvidia/amd/intel/cpu cases |
| Model listing | Custom Ollama API call | `health.sh:check_ollama_models()` | Already handles exec -T, error cases |
| Docker version parsing | Custom version compare | `detect.sh:preflight_checks()` internal logic (lines 367-403) | Already parses major.minor, handles WARN/FAIL thresholds |
| Port availability check | Custom ss/lsof loop | `detect.sh:detect_ports()` | Already checks 80/443/3000/5001/8080/11434 |
| RAM detection | Custom /proc/meminfo parse | `detect.sh:detect_ram()` | Already handles Linux + macOS |
| Disk space check | Custom df parse | `detect.sh:detect_disk()` | Already handles Linux + macOS |
| DNS check | Custom nslookup | `detect.sh:detect_network()` + curl to registry.ollama.ai | Consistent with pre-install checks |

**Key insight:** detect.sh and health.sh together cover every diagnostic need for doctor and status. The phase is primarily about composition and CLI plumbing, not new detection logic.

---

## Common Pitfalls

### Pitfall 1: health.sh sources COMPOSE_DIR from INSTALL_DIR globally

**What goes wrong:** `health.sh` sets `COMPOSE_DIR="${INSTALL_DIR:-/opt/agmind}/docker"` at module level (line 7). When `agmind.sh` sources `health.sh`, `INSTALL_DIR` must already be set — or all health check functions will use `/opt/agmind/docker` as a fallback.

**Why it happens:** The variable is evaluated when the file is sourced (line 7 runs at source time), not when check functions are called.

**How to avoid:** In `agmind.sh`, set `export INSTALL_DIR="$AGMIND_DIR"` before sourcing health.sh.

**Warning signs:** `docker compose` errors saying compose file not found, even though the stack is running.

### Pitfall 2: Nginx reads health.json at startup — file must pre-exist

**What goes wrong:** If `health.json` does not exist when nginx container starts, the `alias` directive will cause a 404 on `/health`. Worse, if the volume mount references a non-existent file, nginx may fail to start entirely.

**Why it happens:** The health-gen cron runs every minute — but on fresh install, the first cron tick may be up to 60 seconds after nginx starts.

**How to avoid:** In `phase_complete()`, run `health-gen.sh` once before starting or restarting nginx. Create an initial `health.json` with `{"status":"starting","timestamp":"..."}` as a placeholder created during `phase_config()`.

**Warning signs:** `curl localhost/health` returns 404 immediately after install.

### Pitfall 3: read_only nginx container cannot write files inside itself

**What goes wrong:** The nginx container has `read_only: true` in docker-compose.yml. Any attempt to write `health.json` from inside the container (e.g., a cron inside nginx) will fail.

**Why it happens:** Security hardening from Phase 2/4.

**How to avoid:** health-gen.sh runs on the HOST (via cron.d), writes to `${INSTALL_DIR}/docker/nginx/health.json`, which is mounted into the nginx container as a read-only volume. The host path is writable by root; the container mount is `:ro`.

### Pitfall 4: `agmind logs` without TTY check

**What goes wrong:** `docker compose logs -f` blocks the terminal. If called from scripts or CI without TTY, the `-f` flag must not be the default.

**Why it happens:** `logs` subcommand passes all args through to docker compose logs. User expects `agmind logs` to tail by default (like `docker logs`), but in CI this blocks.

**How to avoid:** Default `agmind logs` to no `-f` (just recent logs). Require user to pass `-f` explicitly: `agmind logs -f`.

### Pitfall 5: Doctor GPU checks when LLM_PROVIDER=external

**What goes wrong:** Doctor running GPU checks on a server with no GPU and `LLM_PROVIDER=external` creates FAIL entries for "nvidia-smi not found" that are irrelevant and confusing.

**Why it happens:** Doctor checks categories unconditionally.

**How to avoid** (Claude's Discretion): If `/opt/agmind` exists and `.env` is readable, source it and check `LLM_PROVIDER`. If `LLM_PROVIDER=external` and `EMBED_PROVIDER=external`, skip GPU category entirely and show `[SKIP] GPU — внешний провайдер`.

### Pitfall 6: `--json` output mixed with colored text from sourced functions

**What goes wrong:** `agmind status --json` must output pure JSON, but sourced functions like `check_all()` emit colored text to stdout.

**Why it happens:** The existing check_* functions are designed for human-readable terminal output. They write to stdout, not stderr.

**How to avoid:** The `_status_as_json()` function must NOT call check_all() or other text-output functions. It must implement its own data collection loop using the same underlying docker/smi commands but assembling JSON output. Redirect any unavoidable function output to /dev/null.

---

## Code Examples

Verified patterns from existing codebase:

### Source health.sh with INSTALL_DIR pre-set (from install.sh line 846 pattern)
```bash
# agmind.sh — source order
INSTALL_DIR="${AGMIND_DIR:-/opt/agmind}"
export INSTALL_DIR
# shellcheck source=/dev/null
source "${INSTALL_DIR}/scripts/health.sh"
```

### Atomic JSON write (based on project's safe_write_file pattern)
```bash
# Source: lib/config.sh safe_write_file() pattern
HEALTH_JSON="${AGMIND_DIR}/docker/nginx/health.json"
TMPFILE=$(mktemp "${AGMIND_DIR}/docker/nginx/.health.json.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" << ENDJSON
{
  "status": "${overall_status}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "services": {
    "total": ${total},
    "running": ${running},
    "details": { ${service_json} }
  },
  "gpu": { ${gpu_json} }
}
ENDJSON

mv "$TMPFILE" "$HEALTH_JSON"
```

### Cron entry install (based on templates/backup-cron.template pattern)
```bash
# Source: install.sh backup cron pattern + /etc/cron.d/ format
cat > /etc/cron.d/agmind-health << EOF
* * * * * root ${INSTALL_DIR}/scripts/health-gen.sh >> ${INSTALL_DIR}/health-gen.log 2>&1
EOF
chmod 644 /etc/cron.d/agmind-health
```

### Symlink creation (idempotent)
```bash
# Source: standard ln -sf pattern, place in phase_complete()
if [[ -d /usr/local/bin ]]; then
    ln -sf "${INSTALL_DIR}/scripts/agmind.sh" /usr/local/bin/agmind
    echo -e "${GREEN}Команда 'agmind' доступна глобально${NC}"
fi
```

### Docker version comparison (from detect.sh:preflight_checks lines 367-384)
```bash
# Source: lib/detect.sh preflight_checks()
local docker_ver
docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")
local docker_major="${docker_ver%%.*}"
if [[ "$docker_major" -ge 24 ]] 2>/dev/null; then
    _check OK "Docker" "v${docker_ver}"
elif [[ "$docker_major" -ge 20 ]] 2>/dev/null; then
    _check WARN "Docker" "v${docker_ver}" "Рекомендуется 24.0+. Обновите: apt-get install docker-ce"
else
    _check FAIL "Docker" "v${docker_ver} — требуется 24.0+" "sudo apt-get install docker-ce"
fi
```

### Nginx /health location block (based on Phase 2 /api rate limit pattern)
```nginx
# Add rate limit zone at http level (alongside existing api/login zones):
limit_req_zone $binary_remote_addr zone=health:10m rate=1r/s;

# In server block on port 80, BEFORE the / proxy location:
location = /health {
    default_type application/json;
    add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    limit_req zone=health burst=5 nodelay;
    alias /etc/nginx/health/health.json;
}
```

Docker-compose volume addition for nginx service:
```yaml
volumes:
  - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
  - ./nginx/health.json:/etc/nginx/health/health.json:ro   # ADD THIS
  - ./volumes/certbot/conf:/etc/letsencrypt:ro
```

### Redirect ports 80 vs 3000 consideration

The nginx config has TWO server blocks: port 80 (Open WebUI) and port 3000 (Dify Console). The `/health` endpoint should go on port 80 (the primary public port). The CONTEXT.md specifies `curl localhost/health`, confirming port 80.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| check_all() called directly after install | `agmind status` wraps it | Phase 5 | Operator has day-2 tool, not just install-time health check |
| Manual docker ps inspection | `agmind doctor` with actionable recommendations | Phase 5 | Reduced MTTR for common config issues |
| No /health endpoint | Nginx serves static JSON via cron | Phase 5 | External monitoring integration (Uptime Kuma, etc.) |
| health.sh output: human text only | Dual mode: text dashboard + --json | Phase 5 | CI/CD compatible status checks |

**No deprecated approaches** in this phase. The pattern of reusing existing check functions and adding a CLI wrapper is the correct direction.

---

## Open Questions

1. **Should health-gen.sh delegate to `agmind status --json` or reimplement JSON assembly?**
   - What we know: Delegating guarantees schema consistency; reimplementing allows health-gen.sh to be lighter and avoid sourcing all of agmind.sh
   - What's unclear: Whether circular dependency (agmind → health-gen → agmind) is an issue (it's not if health-gen.sh calls the binary, not sources it)
   - Recommendation: health-gen.sh calls `"${INSTALL_DIR}/scripts/agmind.sh" status --json`. Clean, avoids duplication.

2. **How does `agmind logs` handle the service argument?**
   - What we know: CONTEXT.md says dispatch to `docker compose logs`
   - What's unclear: Whether `agmind logs web` or `agmind logs -f web` should be the primary UX
   - Recommendation: `exec docker compose -f "$COMPOSE_FILE" logs "$@"` — pass all args through, including service names and flags like `-f --tail=100`. No smart parsing needed.

3. **GPU checks when LLM_PROVIDER=external (Claude's Discretion)**
   - Recommendation: Source `.env` if it exists and skip GPU category with `[SKIP]` status if both providers are external. This prevents false FAIL on CPU-only VPS deployments.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | BATS (Bash Automated Testing System) |
| Config file | none — run directly with `bats tests/` |
| Quick run command | `bats tests/test_agmind_cli.bats` |
| Full suite command | `bats tests/` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DEVX-01 | `agmind status` outputs dashboard with Services/GPU/Endpoints sections | smoke | `bash -n scripts/agmind.sh` (syntax) | ❌ Wave 0 |
| DEVX-01 | `agmind status --json` outputs valid JSON with required schema fields | unit | `bats tests/test_agmind_cli.bats::status_json_schema` | ❌ Wave 0 |
| DEVX-02 | `agmind doctor` exits 0/1/2 based on check results | unit | `bats tests/test_agmind_cli.bats::doctor_exit_codes` | ❌ Wave 0 |
| DEVX-02 | `agmind doctor` detects Docker version below threshold | unit | `bats tests/test_agmind_cli.bats::doctor_docker_version` | ❌ Wave 0 |
| DEVX-03 | `health-gen.sh` produces valid JSON at expected path | unit | `bats tests/test_agmind_cli.bats::health_gen_output` | ❌ Wave 0 |
| DEVX-03 | nginx `/health` location serves JSON with correct Content-Type | manual | N/A — requires running nginx container | manual-only |
| DEVX-04 | Named volumes have agmind_ prefix | ✅ COMPLETE | already in test_compose_profiles.bats | ✅ |

### Sampling Rate
- **Per task commit:** `bash -n scripts/agmind.sh && bash -n scripts/health-gen.sh`
- **Per wave merge:** `bats tests/test_agmind_cli.bats`
- **Phase gate:** `bats tests/` (full suite) green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tests/test_agmind_cli.bats` — covers DEVX-01, DEVX-02, DEVX-03 automated checks
- [ ] `scripts/agmind.sh` — must exist before tests run
- [ ] `scripts/health-gen.sh` — must exist before tests run
- [ ] Initial `health.json` creation in `phase_complete()` — nginx startup dependency

---

## Sources

### Primary (HIGH confidence)
- Direct analysis of `lib/health.sh` (lines 1-385) — all check_* functions and report_health()
- Direct analysis of `lib/detect.sh` (lines 1-507) — preflight_checks(), detect_* functions
- Direct analysis of `install.sh` (lines 774-864) — phase_config() script copy pattern
- Direct analysis of `install.sh` (lines 1258-1427) — phase_complete() pattern and credentials handling
- Direct analysis of `templates/nginx.conf.template` (lines 1-288) — nginx server blocks, rate limit zones, volume mounts
- Direct analysis of `templates/docker-compose.yml` (lines 648-693) — nginx service, read_only flag, volume mounts
- `.planning/codebase/CONVENTIONS.md` — naming, error handling, logging standards
- `.planning/codebase/STRUCTURE.md` — directory layout, where to add new scripts

### Secondary (MEDIUM confidence)
- `.planning/phases/05-devops-ux/05-CONTEXT.md` — locked decisions and implementation design
- `.planning/phases/02-security-hardening-v2/02-CONTEXT.md` (referenced in CONTEXT.md) — Authelia bypass and rate limiting precedent

### Tertiary (LOW confidence)
- None — all claims are based on direct codebase analysis

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new dependencies; all from existing codebase
- Architecture: HIGH — patterns directly derived from existing code analysis
- Pitfalls: HIGH — identified from direct code reading (INSTALL_DIR scope, read_only nginx, etc.)

**Research date:** 2026-03-18
**Valid until:** 2026-04-18 (stable Bash patterns; re-verify if nginx template changes before planning)
