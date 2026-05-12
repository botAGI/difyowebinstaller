# Security Policy

AGmind installs a corporate RAG platform (Dify + RAGFlow + vLLM + Open WebUI +
vector stores + monitoring) on a DGX Spark with a single command. The installer
touches the firewall, generates secrets, and brings up ~30 containers — a
security bug here has a large blast radius. We take reports seriously.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security problems.**

Use one of the private channels:

1. **GitHub Security Advisories** (preferred) —
   [Report a vulnerability](https://github.com/botAGI/AGmind/security/advisories/new)
   from the repo's Security tab. This gives a private discussion thread and a
   coordinated-disclosure workflow.

2. **Email** — if GHSA is unavailable, email the maintainers (address in the
   org profile / README). Include:
   - affected version / commit
   - reproduction steps
   - assessed impact (RCE / privilege escalation / data exposure / DoS)
   - a suggested fix, if you have one

We aim to acknowledge within **72 hours** and ship a fix within **14 days** for
critical / high severity. If those windows slip, please ping again.

## Scope

In scope (please report):
- `install.sh`, `lib/*.sh`, `scripts/*.sh` — the installer and runtime scripts
- `templates/docker-compose*.yml`, `templates/*.template` — stack configuration
- `.github/workflows/*.yml` — the CI/CD pipeline
- credentials handling, firewall / SSH / TLS setup, secret generation & rotation
- supply chain — pinned image tags, GitHub Actions pins, downloaded binaries and
  their SHA256 checks

Out of scope:
- vulnerabilities in upstream images (Dify, RAGFlow, vLLM, Postgres, …) — report
  those to their maintainers; we pin versions and react to their advisories
- issues that only occur under deliberately insecure configuration
  (`SKIP_DOCKER_HARDENING=true`, `AGMIND_ALLOW_AMD64=true`, fail2ban disabled,
  …) — that is an explicit opt-out
- DoS via overload (heavy-document RAG indexing, etc.) — that is resource
  management, not a security boundary
- self-XSS, or attacks that require physical / admin access to the host

## Supported Versions

Only the latest release is supported. We do not backport security fixes to
older releases — upgrade to latest. Component versions are pinned in
`templates/versions.env`; security bumps ship through the normal release cycle
(or a hotfix for critical severity).

## Security Practices in This Repo

- Every `image:tag` is pinned to a concrete version (no `:latest`) with a
  verified arm64 manifest — enforced in CI (`tests/compose/test_image_tags_exist.sh`).
- Every GitHub Action is pinned to a full commit SHA — enforced by zizmor in CI.
- Downloaded binaries (SOPS, etc.) are verified against a pinned SHA256 — the
  installer refuses on mismatch.
- CI runs Trivy config scan + zizmor static analysis + OpenSSF Scorecard.
- Architectural and operational decisions (driver holds, arm64-manifest holds,
  plugin-daemon pin, network isolation, …) are recorded as ADRs in
  [`docs/adr/`](docs/adr/); many of those rules are enforced as regression tests
  in [`tests/unit/`](tests/unit/).
- Credentials live in `chmod 600` files, are passed via environment variables /
  secrets, and are never printed to stdout, logs, or UI hints.
- The security model (no exposed admin UI, docker-socket-proxy, airgapped mode)
  is documented in [`docs/security/`](docs/security/) and
  [`docs/architecture/security-zones.md`](docs/architecture/security-zones.md);
  `agmind security audit` runs a read-only runtime self-check (exposed ports,
  privileged containers, `docker.sock` consumers, weak secrets, bad file perms).
