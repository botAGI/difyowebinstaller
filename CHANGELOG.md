# Changelog

All notable changes to AGmind are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.2] — 2026-05-16

### Hotfix release: 9 critical and high-severity findings.

Driven by `AGmind-Autofix-Architecture-Spec-v1.0.2` §3 (Findings Register).
All fixes ship behind regression tests in `tests/unit/`. Track-B architecture
work (state store, registry.yaml, golden tests, GSD plugin runtime, Go
migration, HEALTH-02B resolver refactor, ENV-PARSE-01, DUPLICATION-01) is
explicitly out of scope and slated for v3.2.0.

### Fixed

- **LIC-DIFY-01** — `ENABLE_DIFY_PREMIUM` default flipped from `true` to
  `false` in four sites (lib/wizard.sh × 3, lib/config.sh × 1). Fresh
  installs no longer auto-apply the third-party Dify premium feature
  patches without explicit user opt-in.
- **GEN-01** — `lib/common.sh::generate_random` rewritten with a
  length-guarantee contract. The old `head -c 256 /dev/urandom | tr -dc |
  head -c $length` pipeline failed length=64 about 59% of the time
  (entropy filter discarded more bytes than the source provided). New
  implementation prefers Python `secrets.choice` and falls back to a
  bash `dd`-into-tempfile loop with 100-attempt retry. Affected secrets:
  SECRET_KEY, AUTHELIA_JWT_SECRET, AUTHELIA_SESSION_SECRET,
  AUTHELIA_STORAGE_KEY, and any other 64-char value. Also flips the
  inline duplicate in lib/openwebui.sh:43 to use the helper.
- **HEALTH-01** — `lib/health.sh` and `scripts/health.sh` (byte-identical
  duplicate) replaced three `grep -qi "up\|healthy"` / `up\|starting`
  status checks with `docker inspect` enum-based logic. The string-match
  pattern matched `"Up 5 minutes (unhealthy)"` as if it were OK, giving
  false-positives for any container with a failing healthcheck.
- **NGINX-HEALTH-01** — `lib/common.sh::ensure_bind_mount_files` and
  `preflight_bind_mount_check` now reference `nginx/health/health.json`
  (the directory-based mount in `templates/docker-compose.yml`) instead
  of the legacy single-file `nginx/health.json` path. Cleanup of the
  legacy artifact in install.sh carries the `# LEGACY_NGINX_HEALTH_CLEANUP_OK`
  allowlist marker for the regression gate.
- **HEALTH-02A** — `lib/health.sh::get_service_list` now reports MinIO
  when any of `ENABLE_MINIO=true`, `ENABLE_RAGFLOW=true`, or
  `VECTOR_STORE=milvus` are set. Previously a stopped MinIO on a RAGFlow
  or Milvus deploy slipped past the post-install health gate.
- **SEC-RAGFLOW-01** — `templates/docker-compose.yml` RAGFlow port mapping
  now defaults `RAGFLOW_BIND_ADDR` to `127.0.0.1`. The admin-signup race
  ("first user wins" until first registration) is no longer open to the
  LAN by default. Wizard prompts opt-in to expose `:9380` directly; nginx
  vhost `agmind-rag.local` continues to proxy local port for normal LAN
  access.
- **SEC-PEER-01** — `lib/peer.sh::phase_deploy_peer` now `chmod 600 +
  chown root:root` the worker `.env` on peer via SSH immediately after
  scp. scp preserved the peer user's umask (typically `0644`), exposing
  VLLM_IMAGE, HF_TOKEN, PORTAINER_AGENT_SECRET, etc. to any
  unprivileged shell on the peer.
- **SEC-UFW-01 + SEC-UFW-02** — `lib/security.sh::configure_ufw`
  rewritten as append-only with `_ufw_add_or_keep` helper. Reset is now
  explicit opt-in via `AGMIND_UFW_RESET=true`. Admin's existing rules
  (custom SSH ports, fail2ban hooks, k8s nodeport allowlists) survive
  install. LAN allows narrowed from `ufw allow from $SUBNET` (every
  internal port wide-open) to per-port rules for `:80` and `:443` only.
  Grafana `:3001` and Portainer `:9443` gated behind explicit
  `EXPOSE_GRAFANA_LAN` / `EXPOSE_PORTAINER_LAN` env opt-ins. Default
  `LAN_SUBNET` tightened from `/16` to `/24`. New
  `uninstall_agmind_ufw_rules` removes only `agmind-*`-tagged rules in
  reverse-numeric order.
- **RAGFLOW-URL-01** — `lib/status.sh` now reports
  `http://agmind-rag.local` (matches the nginx vhost and the
  avahi-mdns-publish advertisement). The stale `agmind-ragflow.local`
  caused mDNS resolution timeouts and confused users running `agmind
  status` / `agmind status --json`.
- **PROFILES-ALL-01** — `lib/service-map.sh::ALL_COMPOSE_PROFILES` synced
  with the actual `profiles:` keys in `templates/docker-compose.yml`.
  Added `ragflow`, `loadtest`, `vps`. Removed stale `etl`.
  `_compose_down_all` no longer leaves orphaned containers after
  `agmind uninstall` on a RAGFlow/loadtest/vps deploy.

### Also

- `_init_dify_admin` no longer fails on Dify 1.14.1's stricter password
  validator. The previous `init_password | base64 -d` admin password
  occasionally landed without any digit; the validator
  (`^(?=.*[a-zA-Z])(?=.*\d).{8,}$`) returned HTTP 422 on setup. Now uses
  the raw INIT_PASSWORD with a guaranteed-digit append.
- `lib/peer.sh::_render_worker_env` heredoc switched to single-quoted
  `VLLM_EXTRA_ARGS`; double-quoted form broke docker compose `.env`
  parser when the value contained JSON (e.g. `--speculative-config`).
- `templates/docker-compose.worker.yml` declares `entrypoint: ["vllm",
  "serve"]` for the vllm service. NGC's base image entrypoint
  (`/opt/nvidia/nvidia_entrypoint.sh`) does a bare `exec "$@"` so
  passing `--model …` as the command failed with `exec: --: invalid
  option`.
- Phase 8 (Deploy Peer) timeout bumped from 1800s to 3600s (effective
  ceiling 10800s with retry). Qwen3.6-35B-A3B-FP8 first-time HF download
  + load + CUDAGraph capture for 36 batch sizes can exceed the previous
  budget on slower peer WAN links.

### Artifacts

Each finding ships a regression test under `tests/unit/`:

- `test_dify_premium_default_off.sh` (LIC-DIFY-01)
- `test_generate_random_length.sh` (GEN-01)
- `test_health_check_container.sh` (HEALTH-01)
- `test_bind_mount_nginx_health.sh` (NGINX-HEALTH-01)
- `test_get_service_list.sh` (HEALTH-02A)
- `test_ragflow_bind_localhost.sh` (SEC-RAGFLOW-01)
- `test_peer_env_lockdown.sh` (SEC-PEER-01)
- `test_configure_ufw.sh` (SEC-UFW-01 + SEC-UFW-02)
- `test_ragflow_url_alias.sh` (RAGFLOW-URL-01)
- `test_all_profiles_synced.sh` (PROFILES-ALL-01)

PR-1 and PR-2 (LIC-DIFY-01, GEN-01) also include apply/verify scripts
under `scripts/gsd/{apply,verify}/` as proof-of-concept for the GSD
plugin contract (§7 of the spec); these scaffolds will be consumed by
the runtime in v3.2.0. PR-3..PR-9 use direct edits with regression tests
only.

## [3.1.1] — 2026-05-12

Prior release. See `git log v3.1.1..v3.1.2` for the full set of changes
that preceded this CHANGELOG.

[3.1.2]: https://github.com/botAGI/AGmind/compare/v3.1.1...v3.1.2
