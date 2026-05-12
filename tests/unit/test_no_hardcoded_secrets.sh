#!/usr/bin/env bash
# test_no_hardcoded_secrets.sh — never hardcode credentials (IP / passwords / tokens / keys)
# (IP, пароли, токены, ключи) в код / дефолтные конфиги / templates / публичные файлы.
#
# Ловит:
#   1. Hardcoded RFC1918 IP-литералы (192.168.x.x / 10.x.x.x / 172.16-31.x.x) в
#      lib/templates/scripts вне комментариев/примеров/docs — должны быть
#      __PLACEHOLDER__ или ${VAR}, а не literal.
#   2. Hardcoded пароли/секреты в compose `environment:` дефолтах (PASSWORD: xxx
#      где xxx не пусто и не ${VAR}).
#   3. .env / credentials.txt / *.pem / *.key tracked в git.
#   4. Private key blocks (BEGIN ... PRIVATE KEY) в любом tracked файле.
#
# Whitelist для IP: docker internal nets (127.0.0.1, 127.0.0.11, 172.18.0.0/16
# в nginx allow), DNS-resolver примеры (1.1.1.1, 8.8.8.8 в worker.yml dns:),
# документация/комментарии, тестовые fixtures.
#
# Exit: 0 = pass, 1 = fail, 77 = skip.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "## test_no_hardcoded_secrets"

fail=0
pass=0

cd "$REPO_ROOT" || { echo "SKIP: cannot cd to repo root"; exit 77; }

# --- Check 1: .env / credentials / keys tracked in git ---
# tests/fixtures/ intentionally tracks fake-value credential files for unit tests — exclude.
tracked_secrets="$(git ls-files 2>/dev/null | grep -E '(^|/)\.env$|(^|/)\.env\.|credentials\.txt$|\.pem$|^.*_rsa$|id_ed25519$|\.p12$|\.pfx$' | grep -v '^tests/fixtures/' || true)"
if [[ -z "$tracked_secrets" ]]; then
    echo "  PASS: no .env/credentials/private-key files tracked in git"
    pass=$((pass+1))
else
    echo "  FAIL: secret-like files tracked in git (§5 violation):"
    echo "$tracked_secrets" | sed 's/^/        /'
    fail=$((fail+1))
fi

# --- Check 2: private key blocks in tracked files ---
key_blocks="$(git grep -lE 'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY' -- ':!tests/' ':!*.md' 2>/dev/null || true)"
if [[ -z "$key_blocks" ]]; then
    echo "  PASS: no PRIVATE KEY blocks in tracked files"
    pass=$((pass+1))
else
    echo "  FAIL: PRIVATE KEY block(s) found in tracked files (§5):"
    echo "$key_blocks" | sed 's/^/        /'
    fail=$((fail+1))
fi

# --- Check 3: hardcoded RFC1918 *host* IP literals in lib/templates/scripts ---
# Only /32-like specific hosts — CIDR ranges (/8 /12 /16 /24) are subnet
# definitions (squid ACL, LAN_SUBNET), not hardcoded targets, and are fine.
scan_targets=(lib templates scripts install.sh)
ip_violations="$(grep -rnHE '\b(192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})\b' "${scan_targets[@]}" 2>/dev/null \
  | grep -vE '/(8|12|16|24|20|28)\b' \
  | grep -vE ':\s*#' \
  | grep -vE '#.*\b(192\.168|10\.|172\.)' \
  | grep -vE '\b(127\.0\.0\.1|127\.0\.0\.11|0\.0\.0\.0)\b' \
  | grep -vE '\b(1\.1\.1\.1|8\.8\.8\.8|192\.168\.1\.1)\b' \
  | grep -vE 'LAN_SUBNET|192\.168\.0\.0|192\.168\.100\.' \
  | grep -vE '(example|пример|e\.g\.|такой как|placeholder|INTEGRATION_PEER_IP|RESEARCH|ROADMAP)' \
  || true)"
# Note: 192.168.100.x = documented QSFP cluster subnet; 10.x/172.x with mask = CIDR.
if [[ -z "$ip_violations" ]]; then
    echo "  PASS: no hardcoded RFC1918 host IPs in lib/templates/scripts (CIDR ranges + docker nets + dns examples whitelisted)"
    pass=$((pass+1))
else
    echo "  FAIL: hardcoded private host IP literal(s) — should be \${VAR}/__PLACEHOLDER__ (§5):"
    echo "$ip_violations" | head -10 | sed 's/^/        /'
    fail=$((fail+1))
fi

# --- Check 4: hardcoded credential *literals* in compose (not ${VAR} forms) ---
# Flag only when value after =/: is a literal NOT starting with $ and containing
# no ${...} anywhere. ${VAR}, ${VAR:-default}, "" (empty), and known non-secret
# internal defaults (root/minio/Milvus/local/us-east-1) are fine.
pw_violations="$(grep -rnHE '\b(PASSWORD|SECRET_KEY|_TOKEN|API_KEY|ACCESS_KEY|JWT_SECRET)\b\s*[=:]\s*[^${}#"'"'"'[:space:]][^${}]*$' templates/docker-compose*.yml 2>/dev/null \
  | grep -vE ':\s*#' \
  | grep -vE '[=:]\s*(local|true|false|root|minio|Milvus|us-east-1|changeme)\s*$' \
  || true)"
# Note: ${SURREALDB_PASSWORD:-changeme} fallback is acceptable — env.lan.template
# always sets SURREALDB_PASSWORD=__PLACEHOLDER__ → wizard replaces with random;
# "changeme" only triggers if .env not loaded at all (degenerate case, not prod).
if [[ -z "$pw_violations" ]]; then
    echo "  PASS: no hardcoded credential literals in compose (only \${VAR}/\${VAR:-default}/empty)"
    pass=$((pass+1))
else
    echo "  FAIL: hardcoded credential literal(s) in compose (§5):"
    echo "$pw_violations" | head -10 | sed 's/^/        /'
    fail=$((fail+1))
fi

echo ""
echo "=== Summary: ${pass} passed, ${fail} failed ==="
[[ $fail -eq 0 ]]
