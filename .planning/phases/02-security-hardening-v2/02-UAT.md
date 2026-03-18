---
status: complete
phase: 02-security-hardening-v2
source: 02-01-SUMMARY.md, 02-02-SUMMARY.md, 02-03-SUMMARY.md, 02-04-SUMMARY.md
started: 2026-03-18T12:15:00Z
updated: 2026-03-18T12:20:00Z
---

## Current Test

[testing complete]

## Tests

### 1. nginx login rate limiting
expected: nginx.conf.template содержит limit_req_zone для login (1r/10s) и api (10r/s). Отдельный location /console/api/login с burst=3.
result: pass

### 2. fail2ban SSH only
expected: lib/security.sh не содержит agmind-nginx. Содержит sshd jail.
result: pass

### 3. Admin UI привязан к 127.0.0.1
expected: env.lan/vpn/offline.template содержат GRAFANA_BIND_ADDR=127.0.0.1 и PORTAINER_BIND_ADDR=127.0.0.1 по умолчанию.
result: pass

### 4. Credentials не в stdout
expected: install.sh показывает URLS & STATUS (не CREDENTIALS). Путь к credentials.txt указан отдельно.
result: pass

### 5. Squid SSRF deny ACLs
expected: install.sh содержит acl metadata dst 169.254.169.254 и http_access deny metadata (+ link_local, rfc1918).
result: pass

### 6. Authelia bypass для API
expected: authelia configuration.yml.template содержит policy: bypass для API-роутов ПЕРЕД policy: two_factor для /console.
result: pass

### 7. restore.sh RESTORE_TMP
expected: restore.sh использует RESTORE_TMP вместо mktemp. mktemp не найден в скрипте.
result: pass

### 8. BATS тесты backup/restore
expected: tests/test_backup.bats существует.
result: pass

## Summary

total: 8
passed: 8
issues: 0
pending: 0
skipped: 0

## Gaps

[none]
