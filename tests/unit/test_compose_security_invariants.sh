#!/usr/bin/env bash
# test_compose_security_invariants.sh — security-инварианты docker-compose.
#
# Проверяет (CLAUDE.md §5 + security hardening):
#   1. Нет `privileged: true` (полный доступ к хосту — никогда не нужен в нашем стеке).
#   2. Нет опасных `cap_add` (SYS_ADMIN, SYS_PTRACE, NET_ADMIN, SYS_MODULE и т.п.)
#      — в стеке нет легитимных кейсов.
#   3. Каждый long-running service использует `<<: *security-defaults` или
#      `<<: *logging-defaults` (cap_drop hardening + log rotation). One-shots,
#      init-containers, GPU-сервисы с особыми требованиями — exempt по whitelist.
#   4. Порты с admin-UI (Portainer :9443, Grafana :3001, MinIO console :9001,
#      Notebook, SurrealDB, etc) — bind на 127.0.0.1 / ${...BIND_ADDR} / localhost,
#      НЕ на 0.0.0.0 (LAN attack surface). Сервисные порты (Dify nginx :80 — он за
#      nginx и должен быть доступен в LAN) — это норма, проверяем только admin-UI.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
    echo "SKIP: python3 + PyYAML not available"
    exit 77
fi

echo "## test_compose_security_invariants"

fail=0
pass=0

mapfile -t compose_files < <(find "${REPO_ROOT}/templates" -maxdepth 2 -name "docker-compose*.yml" -type f 2>/dev/null | sort)

for f in "${compose_files[@]}"; do
    relpath="${f#${REPO_ROOT}/}"

    result="$(python3 - "$f" <<'PY'
import sys, yaml, re

data = yaml.safe_load(open(sys.argv[1])) or {}
services = data.get('services', {}) if isinstance(data, dict) else {}

# services exempt from security-defaults requirement (one-shots, special needs)
EXEMPT_DEFAULTS = {
    'milvus-init',      # one-shot mc bucket creation
    'redis-lock-cleaner', # short-lived init
    'certbot',          # one-shot SSL renew
    'milvus',           # needs seccomp:unconfined (memfd_create for mmap) — has its own security_opt
    'docling',          # GPU service, logging-defaults
    'vllm', 'vllm-embed', 'vllm-rerank', 'tei', 'tei-embed', 'tei-rerank',  # GPU, logging-defaults
    'ollama',           # GPU profile
    'k6',               # manual-run loadtest tool (now has logging-defaults; kept exempt as fallback)
}
# Services with intentional security exceptions (documented, no safer alternative):
#   sandbox  — Dify code-execution sandbox: SYS_ADMIN required for its internal
#              namespace/seccomp isolation (the sandbox IS the security boundary).
#   cadvisor — standard cAdvisor deploy requires privileged for /sys/fs/cgroup
#              + container metrics access (well-known, monitoring profile only).
INTENTIONAL_PRIVILEGED = {'cadvisor'}
INTENTIONAL_CAPS = {'sandbox': {'SYS_ADMIN'}}
DANGEROUS_CAPS = {'SYS_ADMIN','SYS_PTRACE','SYS_MODULE','SYS_RAWIO','NET_ADMIN','MKNOD','SYS_BOOT','DAC_READ_SEARCH'}
# admin-UI services whose ports MUST bind to localhost / BIND_ADDR (not 0.0.0.0)
ADMIN_UI_SERVICES = {'portainer','grafana','minio','open-notebook','surrealdb','milvus','dbgpt','crawl4ai','searxng'}

# Detect if a service uses YAML anchor merge (<<: *X) — pyyaml resolves the merge,
# so we can't see the anchor name directly. Instead check for hardening markers:
# security-defaults adds cap_drop list; logging-defaults adds logging.driver.
def has_hardening(svc):
    if not isinstance(svc, dict): return False
    has_cap_drop = isinstance(svc.get('cap_drop'), list) and len(svc['cap_drop']) > 0
    has_logging = isinstance(svc.get('logging'), dict)
    has_sysctls = isinstance(svc.get('sysctls'), list)
    return has_cap_drop or has_logging or has_sysctls

violations = []

for name, svc in services.items():
    if not isinstance(svc, dict):
        continue

    # 1. privileged (skip intentional exceptions like cadvisor)
    if svc.get('privileged') is True and name not in INTENTIONAL_PRIVILEGED:
        violations.append(f"PRIVILEGED: {name} has privileged: true")

    # 2. dangerous cap_add (subtract intentional per-service exceptions)
    cap_add = svc.get('cap_add', []) or []
    if isinstance(cap_add, list):
        bad = set(str(c).upper() for c in cap_add) & DANGEROUS_CAPS
        bad -= INTENTIONAL_CAPS.get(name, set())
        if bad:
            violations.append(f"DANGEROUS_CAP: {name} cap_add {sorted(bad)}")

    # 3. security/logging defaults applied
    if name not in EXEMPT_DEFAULTS and not has_hardening(svc):
        violations.append(f"NO_HARDENING: {name} missing <<: *security-defaults / *logging-defaults (no cap_drop/logging/sysctls)")

    # 4. admin-UI ports bind localhost
    if name in ADMIN_UI_SERVICES:
        for p in svc.get('ports', []) or []:
            ps = str(p)
            # forms: "127.0.0.1:9443:9443", "${X:-127.0.0.1}:9443:9443", "9443:9443", "0.0.0.0:9443:9443"
            # If it has host-binding part (3 colons-segments) check first segment
            parts = ps.split(':')
            if len(parts) >= 3:
                host_bind = parts[0].strip('"').strip("'")
                # ${...BIND_ADDR:-127.0.0.1} or 127.0.0.1 or localhost — ok
                if 'BIND_ADDR' in host_bind or '127.0.0.1' in host_bind or host_bind == 'localhost':
                    pass
                elif host_bind == '0.0.0.0' or host_bind == '':
                    violations.append(f"ADMIN_UI_EXPOSED: {name} port {ps} binds to {host_bind or 'all interfaces'} (should be 127.0.0.1/BIND_ADDR)")
                # ${VAR} without explicit 127.0.0.1 default — flag as risky
                elif host_bind.startswith('${') and '127.0.0.1' not in host_bind and 'BIND_ADDR' not in host_bind:
                    violations.append(f"ADMIN_UI_RISKY_BIND: {name} port {ps} host-bind {host_bind} — no localhost default")
            elif len(parts) == 2:
                # "9443:9443" — no host bind = binds to 0.0.0.0 → expose admin UI on all interfaces
                violations.append(f"ADMIN_UI_NO_BIND: {name} port {ps} has no host-bind (defaults to 0.0.0.0)")

print('\n'.join(violations))
PY
)"

    if [[ -z "$result" ]]; then
        echo "  PASS: ${relpath} — security invariants hold (no privileged, no dangerous caps, hardening applied, admin-UI ports localhost-bound)"
        pass=$((pass+1))
    else
        echo "  FAIL: ${relpath} — security invariant violations:"
        echo "$result" | head -15 | sed 's/^/        /'
        fail=$((fail+1))
    fi
done

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
