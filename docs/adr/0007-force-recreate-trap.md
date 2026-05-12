# 0007. Never force-recreate Dify Worker/API During Active Indexing

**Date:** 2026-04-26
**Status:** Accepted

## Context and Problem Statement

`docker compose up -d --force-recreate worker` (or `api`) replaces the running container
with a new one that has a different hostname. Celery uses the container hostname as part
of its worker identity, and Redis persists state keyed to the old hostname. When a
force-recreate happens during active RAG document indexing, the new worker cannot pick up
tasks that the old worker registered — they silently hang in `waiting` state indefinitely.

## Decision Outcome

**Chosen option:** "Use `docker restart` to update Dify worker/api; reserve force-recreate only for necessity, and always flush stale Redis keys before it"

**Reason:** `docker restart` preserves the container identity (same hostname, same Celery
worker ID) and does not leave stale Redis state. When force-recreate is unavoidable (e.g.,
env changes requiring a new container), the stale keys must be removed first. Redis ACL
in AGmind blocks `FLUSHDB` for the default user — only key-by-key `DEL` via `--scan`
pattern works.

## Consequences

**Good:**
- Documented recovery procedure: `docker restart agmind-worker agmind-api` is safe at any time.
- Stale-key cleanup commands are documented and used by `agmind restore` when restoring
  the Dify database (which also creates stale Redis state after reload).

**Bad:**
- Operators must know this constraint; it is not enforced automatically by Docker or Compose.
- `agmind restore` flows must explicitly avoid force-recreate and include the Redis cleanup step.
- Redis `FLUSHDB` is ACL-blocked — automation must use the pattern-based `DEL` approach.

## References

- `docs/troubleshooting.md` section 4 (Dify worker hung — force-recreate trap)
- `docs/troubleshooting.md` section 8 (Restore failed — stale Redis after restore)
- `lib/restore.sh` — stale-Redis cleanup hint in `restore_apply`
- `scripts/agmind.sh` — `agmind restart` subcommand avoids force-recreate
