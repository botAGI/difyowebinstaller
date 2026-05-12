# 0002. VPS/VDS Deployment Profile Removed

**Date:** 2026-04-25
**Status:** Accepted

## Context and Problem Statement

AGmind previously included a VPS/VDS deployment path: an autossh tunnel (`lib/tunnel.sh`),
a `templates/env.vps.template`, and supporting configuration for routing public traffic
through a remote VPS to the DGX Spark. DGX Spark hardware is always deployed behind NAT
in single-tenant LAN environments, so public ingress always required an external tunnel.

## Decision Outcome

**Chosen option:** "Remove VPS/VPS deployment profile; LAN-only deployment going forward"

**Reason:** DGX Spark is a single-tenant appliance behind NAT. The VPS tunnel path was
dead weight: it added attack surface (autossh, outbound persistent SSH connection, external
VPS credentials management) while the target deployment model doesn't require public-facing
endpoints. Operators who need public access are expected to implement their own reverse
proxy or tunnel externally.

## Consequences

**Good:**
- Smaller codebase; no autossh/tunnel lifecycle management.
- Reduced attack surface — no persistent outbound SSH tunnel to maintain (see `docs/architecture/security-zones.md`).
- Cleaner `install.sh` wizard (only LAN profile; no VPS/VDS conditional branches).

**Bad:**
- No built-in public-ingress story. Operators who need external access must configure
  their own solution (e.g., Cloudflare Tunnel, WireGuard, nginx reverse proxy on a VPS)
  without AGmind integration.
- Airgapped / air-gap-with-update-server mode is deferred to v3.1 Phase 7.

## References

- `docs/architecture/security-zones.md`
- Git history: `lib/tunnel.sh`, `templates/autossh.service.template`, `templates/env.vps.template` (removed 2026-04-25)
