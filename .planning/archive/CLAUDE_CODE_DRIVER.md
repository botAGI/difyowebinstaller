# CLAUDE CODE DRIVER — читай это ПЕРВЫМ в каждой сессии

## Как работать с этим файлом

1. В начале КАЖДОЙ сессии Claude Code: "Прочитай CLAUDE_CODE_DRIVER.md и продолжи с текущей задачи"
2. Claude Code читает этот файл, видит где остановились, берёт следующую задачу
3. После выполнения задачи Claude Code обновляет статус ниже: TODO → DONE
4. В конце сессии Claude Code пишет краткий лог в секцию SESSION LOG внизу

## Правила

- ОДНА задача за раз. Не забегай вперёд.
- После каждой задачи — проверь что сделал (запусти тест/команду из колонки "Verify").
- Если verify FAIL — чини, не переходи к следующей.
- Зависимости: не начинай задачу если её depends_on ещё не DONE.
- Если нужен контекст — читай IMPLEMENTATION_GUIDE.md (полный гайд).

---

## ТЕКУЩИЙ СТАТУС

**Current phase:** Phase 6-7 — DOCS + COMMERCIAL
**Current task:** DOC-001
**Last session:** 2026-03-14
**Blockers:** none

---

## PHASE 0: HOT FIXES (Day 1) — DATA LOSS RISK

### BUG-001: Weaviate version conflict
- **Status:** DONE
- **What:** Weaviate 1.19.0 incompatible with Dify ≥1.9.2 (needs weaviate-client v4 → server 1.27.0+)
- **Files to change:**
  - `versions.env` → set WEAVIATE_VERSION=1.27.6
  - Any template `.env` file → remove WEAVIATE_VERSION if present (single source of truth = versions.env)
  - `docker-compose.yml` → verify image uses `${WEAVIATE_VERSION}` from versions.env
- **Verify:** `grep -r "WEAVIATE" versions.env templates/ docker-compose*` shows 1.27.6 everywhere and no 1.19.0
- **Depends on:** nothing

### BUG-002: Plugin Daemon version drift
- **Status:** DONE
- **What:** PLUGIN_DAEMON_VERSION=0.1.0-local is ancient. Upstream is 0.5.3+.
- **Files to change:**
  - `versions.env` → set PLUGIN_DAEMON_VERSION=0.5.3
  - Any template `.env` → remove PLUGIN_DAEMON_VERSION if duplicated
- **Verify:** `grep -r "PLUGIN_DAEMON" versions.env templates/` shows 0.5.3
- **Depends on:** nothing

### BUG-003: Pin ALL images (remove latest)
- **Status:** DONE
- **What:** OLLAMA_VERSION=latest, GRAFANA_VERSION=latest, PORTAINER_VERSION=latest, PROMETHEUS_VERSION=latest make the stack non-deterministic. Every `docker compose pull` can introduce breaking changes.
- **Files to change:**
  - `versions.env` → pin to specific versions:
    ```
    OLLAMA_VERSION=0.6.2
    GRAFANA_VERSION=11.4.0
    PORTAINER_VERSION=2.21.4
    PROMETHEUS_VERSION=v2.54.1
    CADVISOR_VERSION=v0.49.1
    LOKI_VERSION=3.3.2
    PROMTAIL_VERSION=3.3.2
    NGINX_VERSION=1.27.3-alpine
    REDIS_VERSION=7.4.1-alpine
    POSTGRES_VERSION=15.10-alpine
    ```
  - Check that docker-compose.yml uses these variables, not hardcoded tags
- **Verify:** `grep -r "latest" versions.env docker-compose* templates/` returns NOTHING
- **Depends on:** nothing

### BUG-004: Single source of truth for versions
- **Status:** DONE
- **What:** *_VERSION vars exist in BOTH versions.env AND template .env files. Dual source of truth = guaranteed drift.
- **Files to change:**
  - Template .env files → REMOVE all *_VERSION variables
  - docker-compose.yml → add `env_file: [.env, ../versions.env]` or source versions.env
  - install.sh → `source versions.env` before generating .env
  - update.sh → reads from versions.env exclusively
- **Verify:** `grep -c "_VERSION=" templates/*.env` returns 0 (no version vars in templates). Only versions.env has them.
- **Depends on:** BUG-003

---

## PHASE 1: SECURITY (Days 2-5)

### SEC-001: Remove admin secret URL
- **Status:** DONE
- **What:** Dify Console accessible at http://server/<admin_token>/ — this is a security anti-pattern. Replace with standard /signin login flow.
- **Files to change:**
  - nginx.conf → add: `location ~ ^/[a-f0-9]{24,}/ { return 404; }`
  - install.sh → use Dify Setup API (POST /console/api/setup) to create admin user
  - install.sh → remove ADMIN_TOKEN generation, add INIT_PASSWORD
  - template .env → remove ADMIN_TOKEN variable
- **Verify:** `curl -sf http://localhost/<any-hex-string>/` returns 404. `curl -sf http://localhost/signin` returns 200.
- **Depends on:** BUG-004

### SEC-002: Generate all secrets at install
- **Status:** DONE
- **What:** No default passwords anywhere. Every secret generated via `openssl rand`.
- **Files to change:**
  - install.sh → add `generate_secrets()` function:
    - SECRET_KEY, REDIS_PASSWORD, DB_PASSWORD, GRAFANA_ADMIN_PASSWORD, SANDBOX_API_KEY, PLUGIN_DAEMON_KEY, PLUGIN_INNER_API_KEY
    - All via `openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32`
  - install.sh → add validation: grep for known defaults ("difyai123456", "QaHbTe77", "changeme", "password") in .env → FAIL if found
  - install.sh → `chmod 600 .env && chown root:root .env`
- **Verify:** `grep -E "(changeme|password|difyai123456|QaHbTe77)" /opt/agmind/docker/.env` returns nothing. `stat -c '%a' /opt/agmind/docker/.env` returns 600.
- **Depends on:** BUG-004

### SEC-003: Redis hardening
- **Status:** DONE
- **What:** Redis needs: requirepass, bind 127.0.0.1, disable FLUSHALL/CONFIG/DEBUG/SHUTDOWN
- **Files to change:**
  - `docker/volumes/redis/redis.conf` → create or update with:
    ```
    bind 127.0.0.1
    requirepass ${REDIS_PASSWORD}
    maxmemory 512mb
    maxmemory-policy allkeys-lru
    rename-command FLUSHALL ""
    rename-command FLUSHDB ""
    rename-command CONFIG ""
    rename-command DEBUG ""
    rename-command SHUTDOWN ""
    appendonly yes
    ```
  - docker-compose.yml → redis service: mount redis.conf as read-only, use `command: redis-server /usr/local/etc/redis/redis.conf`
  - install.sh → template redis.conf with generated REDIS_PASSWORD
- **Verify:** `docker compose exec redis redis-cli PING` returns "NOAUTH". `docker compose exec redis redis-cli -a $REDIS_PASSWORD PING` returns "PONG". `docker compose exec redis redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory` returns error (CONFIG disabled).
- **Depends on:** SEC-002

### SEC-004: PostgreSQL hardening
- **Status:** DONE
- **What:** scram-sha-256 auth, ssl=on, connection limits, logging
- **Files to change:**
  - docker-compose.yml → db service command: add `-c ssl=on -c password_encryption=scram-sha-256 -c max_connections=100 -c log_connections=on`
  - install.sh → generate self-signed cert for internal PG SSL:
    `openssl req -new -x509 -days 3650 -nodes -out server.crt -keyout server.key -subj "/CN=agmind-db"`
  - Mount certs into PG container
- **Verify:** `docker compose exec db psql -U postgres -c "SHOW ssl"` returns "on". `docker compose exec db psql -U postgres -c "SHOW password_encryption"` returns "scram-sha-256".
- **Depends on:** SEC-002

### SEC-005: Docker container hardening
- **Status:** DONE
- **What:** Apply CIS Docker Benchmark to all containers
- **Files to change:**
  - docker-compose.yml → add to EVERY service:
    ```yaml
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
    ```
  - Add `cap_add: [SYS_ADMIN]` ONLY to ollama (for GPU)
  - Add `read_only: true` + `tmpfs: [/tmp]` where possible (nginx, redis)
  - Create networks: `frontend` (bridge), `backend` (internal: true)
  - nginx: networks [frontend, backend], ports exposed
  - db, redis, weaviate, ollama, api, worker: networks [backend] ONLY, NO ports
  - grafana, portainer: bind to 127.0.0.1 (VPS) or 0.0.0.0 (LAN)
  - Add resource limits (deploy.resources.limits.memory) per service
- **Verify:** `docker inspect <container> | jq '.[0].HostConfig.SecurityOpt'` includes "no-new-privileges". `docker inspect <container> | jq '.[0].HostConfig.CapDrop'` includes "ALL". `docker network inspect backend | jq '.[0].Internal'` returns true. No DB/Redis ports visible on host: `ss -tlnp | grep -E "5432|6379"` returns nothing.
- **Depends on:** BUG-004

### SEC-006: Nginx hardening
- **Status:** DONE
- **What:** Security headers + rate limiting + TLS config
- **Files to change:**
  - nginx.conf → add headers:
    ```
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; ..." always;
    ```
  - nginx.conf → add rate limiting:
    ```
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=ws:10m;
    location /api/ { limit_req zone=api burst=20 nodelay; }
    ```
  - nginx.conf → TLS (when enabled): `ssl_protocols TLSv1.2 TLSv1.3; ssl_prefer_server_ciphers on;`
- **Verify:** `curl -sI http://localhost | grep -i "x-frame-options"` returns "DENY". `curl -sI http://localhost | grep -i "x-content-type"` returns "nosniff".
- **Depends on:** BUG-004

### SEC-007: Production profile — security ON by default
- **Status:** DONE
- **What:** For VPS profile: ENABLE_UFW=true, ENABLE_FAIL2BAN=true, ENABLE_SOPS=true. For LAN: ENABLE_FAIL2BAN=true. Require explicit DISABLE_SECURITY_DEFAULTS=true to turn off.
- **Files to change:**
  - install.sh → in profile setup section:
    ```bash
    case "$DEPLOY_PROFILE" in
      vps)
        ENABLE_UFW="${ENABLE_UFW:-true}"
        ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
        ENABLE_SOPS="${ENABLE_SOPS:-true}"
        ;;
      lan|vpn)
        ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
        ;;
    esac
    ```
- **Verify:** `sudo bash install.sh --non-interactive` with DEPLOY_PROFILE=vps → check that UFW is active (`ufw status`), fail2ban running (`systemctl is-active fail2ban`).
- **Depends on:** SEC-001 through SEC-006

---

## PHASE 2: VERSION GOVERNANCE (Days 5-7)

### VER-001: Release manifest
- **Status:** DONE
- **What:** Create release-manifest.json schema. update.sh reads manifest, pulls by digest, saves rollback state.
- **Depends on:** BUG-004

### VER-002: COMPATIBILITY.md
- **Status:** DONE
- **What:** Document tested combinations of all components + host OS matrix.
- **Depends on:** BUG-001, BUG-002, BUG-003

### VER-003: CHANGELOG.md + semver
- **Status:** DONE
- **What:** Create CHANGELOG.md in keep-a-changelog format. Git tag v1.0.0-alpha.1.
- **Depends on:** nothing

### VER-004: Pre-flight validation
- **Status:** DONE
- **What:** install.sh checks: ports free, RAM ≥4GB, disk ≥20GB, Docker version, OS in matrix, idempotency.
- **Depends on:** VER-002

### VER-005: Manifest-based update with rollback
- **Status:** DONE
- **What:** update.sh: download new manifest → compare digests → snapshot current state to .rollback/ → rolling update → health check each → auto-rollback on failure.
- **Depends on:** VER-001

---

## PHASE 3: ALERTING (Days 7-9)

### ALR-001: Alertmanager in docker-compose
- **Status:** DONE
- **Depends on:** SEC-005

### ALR-002: Alert rules
- **Status:** DONE
- **Depends on:** ALR-001

### ALR-003: Telegram/webhook receiver
- **Status:** DONE
- **Depends on:** ALR-001

### ALR-004: Grafana provisioned dashboards (4 dashboards)
- **Status:** DONE
- **Depends on:** SEC-005

### ALR-005: health.sh v2.0 (26 checks + cron + auto-alert)
- **Status:** DONE
- **Depends on:** ALR-001, ALR-003

---

## PHASE 4: CI/CD (Days 9-12)

### CI-001: Lint pipeline (shellcheck + yamllint + hadolint)
- **Status:** DONE
- **Depends on:** VER-003

### CI-002: BATS unit tests
- **Status:** DONE
- **Depends on:** CI-001

### CI-003: Trivy security scan
- **Status:** DONE
- **Depends on:** CI-001

### CI-004: Smoke test — fresh install
- **Status:** DONE
- **Depends on:** CI-001

### CI-005: Smoke test — upgrade
- **Status:** DONE
- **Depends on:** VER-005, CI-004

### CI-006: Smoke test — backup/restore
- **Status:** DONE
- **Depends on:** CI-004

---

## PHASE 5: DR (Days 12-14)

### DR-001: restore-runbook.sh with 7-step verification
- **Status:** DONE
- **Depends on:** ALR-005

### DR-002: DR policy (RPO/RTO document)
- **Status:** DONE
- **Depends on:** nothing

### DR-003: Monthly DR drill (cron)
- **Status:** DONE
- **Depends on:** DR-001

### DR-004: Upgrade-failure → restore scenario
- **Status:** DONE
- **Depends on:** VER-005, DR-001

---

## PHASE 6-7: DOCS + COMMERCIAL (Days 14-20)

### DOC-001: Docusaurus site
- **Status:** DONE
- **Depends on:** All Phase 1-5

### DOC-002: Incident response runbook
- **Status:** DONE
- **Depends on:** ALR-005

### COM-001: Authelia + LDAP
- **Status:** DONE
- **Depends on:** SEC-007

### COM-002: Offline bundle builder
- **Status:** DONE
- **Depends on:** BUG-003

### COM-003: License + v1.0.0 GA tag
- **Status:** SKIPPED (проект open-source, BSL не нужна)

---

## SESSION LOG

### Session 1 — 2026-03-14
- Started: BUG-001
- Completed: BUG-001, BUG-002, BUG-003, BUG-004
- Issues: config.sh sed-replace broke after removing _VERSION from templates; fixed with append approach
- Next: SEC-001

### Session 2 — 2026-03-14
- Started: BUG-004 verify, SEC-001
- Completed: BUG-004, SEC-001, SEC-002, SEC-003, SEC-004, SEC-005, SEC-006, SEC-007
- Issues: none
- Next: VER-001

### Session 3 — 2026-03-14
- Started: VER-001
- Completed: VER-001, VER-002, VER-003, VER-004, VER-005, ALR-001, ALR-002, ALR-003, ALR-004, ALR-005, CI-001, CI-002, CI-003, CI-004, CI-005, CI-006, DR-001, DR-002, DR-003, DR-004
- Issues: restore-runbook.sh had `local` keyword outside function (fixed); macOS sed corrupted CI-001 header (fixed with Edit tool)
- Next: DOC-001 (Phase 6-7)

<!-- Claude Code: add new session entries here after each work session -->
