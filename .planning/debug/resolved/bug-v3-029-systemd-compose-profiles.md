---
status: diagnosed
trigger: "BUG-V3-029: agmind-stack.service runs docker compose up -d without COMPOSE_PROFILES"
created: 2026-03-21T00:00:00Z
updated: 2026-03-21T00:00:00Z
---

## Current Focus

hypothesis: CONFIRMED — systemd service has no EnvironmentFile directive and no Environment= line for COMPOSE_PROFILES; the variable is built at install time in memory only and never persisted to disk.
test: COMPLETED — verified that (1) env templates contain no COMPOSE_PROFILES line, (2) _generate_env_file() writes no COMPOSE_PROFILES to .env, (3) build_compose_profiles() only sets it in the current process environment, (4) the service template has no EnvironmentFile or Environment= stanza.
expecting: N/A — root cause confirmed
next_action: DONE — return diagnosis

## Symptoms

expected: After reboot, agmind-stack.service restarts all containers including profile-based ones (monitoring, etl, ollama, vllm, tei, etc.)
actual: After reboot, only core containers start. Profile-based containers (docling, xinference, prometheus, grafana, alertmanager, cadvisor, ollama, vllm, etc.) do not start.
errors: No error — docker compose up -d simply starts nothing for services behind `profiles:` because COMPOSE_PROFILES is empty.
reproduction: Reboot the server. Check `docker ps` — only core containers running.
started: Since systemd service was introduced (any installation where agmind-stack.service is used).

## Eliminated

- hypothesis: COMPOSE_PROFILES is written to .env and docker compose auto-reads it
  evidence: Grepped all four env templates (env.lan.template, env.vpn.template, env.vps.template, env.offline.template) — zero matches for COMPOSE_PROFILES. The .env file never contains this variable.
  timestamp: 2026-03-21T00:00:00Z

- hypothesis: The systemd service sets COMPOSE_PROFILES via Environment= or EnvironmentFile=
  evidence: Read templates/agmind-stack.service.template in full — contains no Environment= or EnvironmentFile= stanza. The only command is: ExecStart=/usr/bin/docker compose up -d
  timestamp: 2026-03-21T00:00:00Z

## Evidence

- timestamp: 2026-03-21T00:00:00Z
  checked: templates/agmind-stack.service.template (full file)
  found: ExecStart=/usr/bin/docker compose up -d — no COMPOSE_PROFILES in environment, no EnvironmentFile= directive
  implication: At boot, systemd runs `docker compose up -d` with a completely empty environment for COMPOSE_PROFILES, so Docker Compose treats all profiled services as inactive.

- timestamp: 2026-03-21T00:00:00Z
  checked: lib/compose.sh — build_compose_profiles() and compose_up()
  found: build_compose_profiles() builds a comma-separated string into COMPOSE_PROFILE_STRING (shell variable, exported only in current process). compose_up() inlines it as `COMPOSE_PROFILES="$profiles" docker compose up -d`. This value is NEVER written to disk.
  implication: COMPOSE_PROFILES only exists in the installer's bash process. Once install.sh exits, it is gone. On reboot, systemd has no way to reconstruct it.

- timestamp: 2026-03-21T00:00:00Z
  checked: Grepped all templates/*.template files for COMPOSE_PROFILES
  found: Zero matches. The value is not persisted to .env or any config file.
  implication: docker compose, when launched by systemd with WorkingDirectory=/opt/agmind/docker, reads .env but finds no COMPOSE_PROFILES there. All profiled services are silently skipped.

- timestamp: 2026-03-21T00:00:00Z
  checked: install.sh — _install_systemd_service()
  found: Only substitutes __INSTALL_DIR__ placeholder. Does not inject COMPOSE_PROFILES. No EnvironmentFile= is added.
  implication: The service file is installed with no knowledge of which profiles were chosen during installation.

- timestamp: 2026-03-21T00:00:00Z
  checked: scripts/agmind.sh and lib/compose.sh compose_down() — for comparison
  found: Both hardcode COMPOSE_PROFILES=vps,monitoring,qdrant,weaviate,etl,authelia,ollama,vllm,tei inline on the command line for stop operations. The up path does NOT do this equivalently.
  implication: Developers already knew profiles must be explicit for stop — but forgot to wire the same for the systemd start path.

## Resolution

root_cause: |
  COMPOSE_PROFILES is built dynamically in memory by build_compose_profiles() during installation
  but is NEVER written to /opt/agmind/docker/.env or any file on disk. The systemd service
  template (agmind-stack.service.template) has no Environment= or EnvironmentFile= stanza,
  so when systemd executes `docker compose up -d` after reboot, COMPOSE_PROFILES is empty.
  Docker Compose therefore skips all services that have a `profiles:` key, starting only
  the core (unprofileed) containers.

fix: |
  Two-part fix required:

  1. In lib/config.sh — _generate_env_file() or a new step after it: after build_compose_profiles()
     is called (or inline in generate_config()), append the computed COMPOSE_PROFILES value to
     /opt/agmind/docker/.env:
       echo "COMPOSE_PROFILES=${COMPOSE_PROFILE_STRING}" >> "${INSTALL_DIR}/docker/.env"
     This persists the profile string so docker compose can pick it up automatically from .env
     on every subsequent run (install, update, reboot).

  2. In templates/agmind-stack.service.template — add EnvironmentFile directive so systemd
     loads .env before executing docker compose:
       EnvironmentFile=-__INSTALL_DIR__/docker/.env
     (The leading dash means "ignore if file missing", which is safe.)
     With this, COMPOSE_PROFILES from .env is available in the systemd unit's environment.

  Either fix alone is sufficient in theory — option 1 (writing to .env) is the cleaner solution
  because docker compose natively reads .env from its working directory, making COMPOSE_PROFILES
  available everywhere (manual runs, agmind CLI, crons, systemd). Option 2 alone is brittle
  because it loads all .env vars into the systemd unit environment, which can cause issues with
  special characters or variable expansion. The recommended fix is BOTH: persist to .env (option 1)
  AND add EnvironmentFile (option 2) as defense-in-depth.

  Additionally, build_compose_profiles() must be called BEFORE _generate_env_file() completes,
  or a dedicated step must append COMPOSE_PROFILES to .env at the end of generate_config().
  Currently build_compose_profiles() is only called from compose_up() — it must also be called
  during config generation so the value is available to write to .env at install time.

verification: N/A — diagnose-only mode
files_changed: []
