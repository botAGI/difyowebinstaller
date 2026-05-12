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

# ============================================================================
# SC1 Hardening assertions (07-02): docker-socket-proxy, no-new-privileges,
# read_only exporters, Portainer profile gate, alloy-config.river routing.
# These run only on templates/docker-compose.yml (the main compose file).
# ============================================================================
MAIN_COMPOSE="${REPO_ROOT}/templates/docker-compose.yml"
ALLOY_CONFIG="${REPO_ROOT}/monitoring/alloy-config.river"

if [[ -f "${MAIN_COMPOSE}" ]]; then
    sc1_result="$(python3 - "${MAIN_COMPOSE}" <<'PY'
import sys, yaml

data = yaml.safe_load(open(sys.argv[1])) or {}
services = data.get('services', {}) if isinstance(data, dict) else {}
violations = []

# SC1-5: docker-socket-proxy exists with read-only env-allowlist
proxy = services.get('docker-socket-proxy')
if proxy is None:
    violations.append("SC1-5_MISSING: docker-socket-proxy service not found")
else:
    env = proxy.get('environment', {}) or {}
    # environment can be dict {KEY: val} or list ["KEY=val"]
    if isinstance(env, list):
        env_dict = {}
        for item in env:
            if '=' in str(item):
                k, v = str(item).split('=', 1)
                env_dict[k.strip()] = v.strip()
            else:
                env_dict[str(item).strip()] = ''
        env = env_dict
    containers_val = env.get('CONTAINERS', env.get('CONTAINERS', None))
    post_val = env.get('POST', None)
    exec_val = env.get('EXEC', None)
    build_val = env.get('BUILD', None)
    if not (str(containers_val) in ('1', 'True', 'true')):
        violations.append(f"SC1-5_PROXY_ALLOWLIST: docker-socket-proxy CONTAINERS should be 1, got {containers_val!r}")
    if str(post_val) not in ('0', 'False', 'false'):
        violations.append(f"SC1-5_PROXY_ALLOWLIST: docker-socket-proxy POST should be 0, got {post_val!r}")
    if str(exec_val) not in ('0', 'False', 'false'):
        violations.append(f"SC1-5_PROXY_ALLOWLIST: docker-socket-proxy EXEC should be 0, got {exec_val!r}")
    if str(build_val) not in ('0', 'False', 'false'):
        violations.append(f"SC1-5_PROXY_ALLOWLIST: docker-socket-proxy BUILD should be 0, got {build_val!r}")

# SC1-6: alloy and cadvisor do NOT have /var/run/docker.sock in volumes
for svc_name in ('alloy', 'cadvisor'):
    svc = services.get(svc_name, {}) or {}
    vols = svc.get('volumes', []) or []
    raw_sock = [v for v in vols if '/var/run/docker.sock' in str(v)]
    if raw_sock:
        violations.append(f"SC1-6_RAW_SOCK: {svc_name} still has /var/run/docker.sock mount: {raw_sock}")

# SC1-7: only portainer has raw rw docker.sock (proxy has :ro, which is ok)
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    vols = svc.get('volumes', []) or []
    for v in vols:
        vs = str(v)
        if '/var/run/docker.sock' in vs:
            # proxy's :ro mount is allowed; portainer's rw mount is expected
            if name == 'docker-socket-proxy' and vs.endswith(':ro'):
                pass  # ok — read-only proxy mount
            elif name == 'portainer' and not vs.endswith(':ro'):
                pass  # ok — portainer rw mount is documented and accepted
            elif vs.endswith(':ro'):
                violations.append(f"SC1-7_UNEXPECTED_RO_SOCK: {name} has unexpected raw :ro docker.sock mount")
            else:
                violations.append(f"SC1-7_UNEXPECTED_RW_SOCK: {name} has unexpected rw docker.sock mount (only portainer allowed)")

# SC1-8: portainer is in profile 'portainer' not 'monitoring'
portainer_svc = services.get('portainer', {}) or {}
portainer_profiles = portainer_svc.get('profiles', []) or []
if portainer_profiles != ['portainer']:
    violations.append(f"SC1-8_PORTAINER_PROFILE: expected ['portainer'], got {portainer_profiles}")

# SC1-9: no-new-privileges:true on all except cadvisor/sandbox
NNP_EXCEPTIONS = {'cadvisor', 'sandbox'}
missing_nnp = []
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    if name in NNP_EXCEPTIONS:
        continue
    sec_opt = svc.get('security_opt', []) or []
    if 'no-new-privileges:true' not in str(sec_opt):
        missing_nnp.append(name)
if missing_nnp:
    violations.append(f"SC1-9_MISSING_NNP: these services lack no-new-privileges:true: {sorted(missing_nnp)}")
# Assert exceptions do NOT have it
for exc in NNP_EXCEPTIONS:
    if exc in services:
        exc_opt = services[exc].get('security_opt', []) or []
        if 'no-new-privileges:true' in str(exc_opt):
            violations.append(f"SC1-9_EXCEPTION_HAS_NNP: {exc} should NOT have no-new-privileges:true")

# SC1-10: read_only:true on the 3 distroless exporters
READ_ONLY_REQUIRED = {'redis-exporter', 'postgres-exporter', 'nginx-exporter'}
for name in READ_ONLY_REQUIRED:
    svc = services.get(name, {}) or {}
    if svc.get('read_only') is not True:
        violations.append(f"SC1-10_MISSING_READONLY: {name} should have read_only: true")

print('\n'.join(violations))
PY
)"

    if [[ -z "$sc1_result" ]]; then
        echo "  PASS: SC1 hardening — socket-proxy allowlist, no raw sock on cadvisor/alloy, only-portainer-rw, portainer profile, broad no-new-privileges, read_only exporters"
        pass=$((pass+1))
    else
        echo "  FAIL: SC1 hardening violations:"
        echo "$sc1_result" | head -20 | sed 's/^/        /'
        fail=$((fail+1))
    fi
fi

# SC1-alloy-config: alloy-config.river must use docker-socket-proxy TCP, not raw unix socket
if [[ -f "${ALLOY_CONFIG}" ]]; then
    unix_count="$(grep -c 'unix:///var/run/docker.sock' "${ALLOY_CONFIG}" 2>/dev/null)" || unix_count=0
    proxy_count="$(grep -c 'tcp://docker-socket-proxy:2375' "${ALLOY_CONFIG}" 2>/dev/null)" || proxy_count=0
    unix_count="${unix_count%%[^0-9]*}"
    proxy_count="${proxy_count%%[^0-9]*}"
    if [[ "${unix_count:-0}" -eq 0 && "${proxy_count:-0}" -eq 2 ]]; then
        echo "  PASS: monitoring/alloy-config.river — both docker hosts routed through docker-socket-proxy (no raw unix socket)"
        pass=$((pass+1))
    else
        echo "  FAIL: monitoring/alloy-config.river — expected 0 unix socket refs and 2 proxy refs, got unix=${unix_count} proxy=${proxy_count}"
        fail=$((fail+1))
    fi
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
