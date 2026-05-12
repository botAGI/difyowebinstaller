# 0008. nginx proxy_pass Must Use Variable Form with resolver

**Date:** 2026-04-26
**Status:** Accepted

## Context and Problem Statement

nginx upstream blocks and static `proxy_pass http://container-name` directives resolve
the upstream hostname to an IP address at nginx startup time. When a Docker container
is force-recreated (e.g., `docker compose up -d --force-recreate api`), the container
gets a new IP from Docker's embedded DNS. nginx continues routing to the old IP, causing
502 errors for all affected routes until nginx itself is manually restarted.

## Decision Outcome

**Chosen option:** "Use the variable form for every `proxy_pass` in `nginx.conf`; add `resolver 127.0.0.11 valid=10s`; remove all static `upstream {}` blocks"

**Reason:** When `proxy_pass` is written as `proxy_pass $variable` (where the variable
holds the upstream URL), nginx re-resolves the hostname on each request using the
configured resolver. Docker's embedded DNS (`127.0.0.11`) returns the current IP for
the container name, so force-recreate no longer causes stale routing.

Template pattern:
```nginx
resolver 127.0.0.11 valid=10s;
# ...
set $u_api http://api:5001;
proxy_pass $u_api;
```

Important: `resolver` only affects `proxy_pass $variable`. Static `proxy_pass http://name`
and `upstream {}` blocks are not affected by `resolver`.

## Consequences

**Good:**
- Container force-recreate no longer requires a manual `docker restart agmind-nginx`.
- Regression test: `tests/unit/test_nginx_no_static_proxy_pass.sh` enforces that no
  static `proxy_pass http://` (without a `$` variable) is present in nginx templates.

**Bad:**
- Every new location block in `nginx.conf.template` must use the variable form.
  Forgetting results in 502 after the next force-recreate of the proxied container.
- All API-dependent routes (`/console/api`, `/api`, `/v1`, `/files`, `/e/`) must be
  listed explicitly; missing a route breaks the dependent feature after recreate.

## References

- `docs/troubleshooting.md` (nginx routing section)
- `tests/unit/test_nginx_no_static_proxy_pass.sh`
- `templates/nginx.conf.template`
- nginx documentation: [proxy_pass with variable](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass)
