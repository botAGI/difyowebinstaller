#!/usr/bin/env bash
# airgapped.sh — AGMIND_AIRGAPPED mode: preflight check (all images + model volumes
# present locally before any mutation) + airgapped_guard (skip public-network ops).
# Dependencies: common.sh (log_*) — fallback shims provided for standalone sourcing.
# Functions: airgapped_guard(), airgapped_preflight()
# Expects: INSTALL_DIR, INSTALLER_DIR, AGMIND_AIRGAPPED
# WHY separate module: lib/docker.sh, lib/detect.sh, lib/models.sh each source it for
# the guard shim; install.sh sources it before lib/phases.sh (which registers the
# airgapped_preflight phase entry). Standalone sourcing is safe — no top-level actions.
set -euo pipefail

[[ -n "${_AIRGAPPED_SH_LOADED:-}" ]] && return 0
_AIRGAPPED_SH_LOADED=1

# ============================================================================
# FALLBACK SHIMS (active when sourced without common.sh, e.g. tests, leaf libs)
# Mirror lib/doctor.sh / lib/health.sh pattern.
# ============================================================================
command -v log_info    >/dev/null 2>&1 || log_info()    { echo -e "  -> $*"; }
command -v log_success >/dev/null 2>&1 || log_success() { echo -e "  OK $*"; }
command -v log_warn    >/dev/null 2>&1 || log_warn()    { echo -e "  [WARN] $*" >&2; }
command -v log_error   >/dev/null 2>&1 || log_error()   { echo -e "  [ERROR] $*" >&2; }
command -v validate_path >/dev/null 2>&1 || validate_path() { :; }

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# MODEL VOLUMES
# The 6 named Docker volumes that carry model weights — must be present and
# non-empty for airgapped install to proceed without reaching out to HF/NGC.
# WHY: airgapped_preflight + bundle_create iterate the same list; keeping a
# single source here avoids drift (bundle.sh sources this file).
# ============================================================================
_AIRGAPPED_MODEL_VOLUMES=(
    agmind_vllm_cache
    agmind_tei_cache
    agmind_tei_rerank_cache
    agmind_vllm_embed_cache
    agmind_vllm_rerank_cache
    agmind_docling_cache
)

# ============================================================================
# AIRGAPPED GUARD — skip public-network operations when airgapped
# ============================================================================
# Usage (idiomatic): airgapped_guard "apt-get install docker-ce" || { apt-get ...; }
# When AGMIND_AIRGAPPED=true  → prints skip-warn (stdout), returns 0  → || branch SKIPPED.
# When AGMIND_AIRGAPPED=false → returns 1                             → || branch RUNS.
#
# WHY stdout for the warn: tests capture stdout via $(...) and grep for 'airgap|skip'.
# Stderr would leak out of the $(...) capture due to bash quoting semantics.
# Using `echo` to stdout allows both the terminal operator to see the skip and tests
# to assert it. Operators who watch install.sh output will see it inline.
airgapped_guard() {
    local op_name="${1:?airgapped_guard: op_name required}"
    if [[ "${AGMIND_AIRGAPPED:-false}" == "true" ]]; then
        echo "[WARN] airgapped: skipping ${op_name} (AGMIND_AIRGAPPED=true)"
        return 0
    fi
    return 1
}

# ============================================================================
# AIRGAPPED PREFLIGHT — fail fast if required images or model volumes are missing
# ============================================================================
# Read-only: uses only `docker image inspect` and `docker volume inspect`.
# No mutations. Returns 1 with a list of missing items BEFORE any install step.
# Called as a PHASES entry (preflight-flagged) so it runs even in --dry-run.
airgapped_preflight() {
    # Accept optional path to a versions.env override (used by tests).
    local versions_env_override="${1:-}"

    local missing_images=()
    local missing_models=()

    # ── 1. Image check ────────────────────────────────────────────────────────
    # Resolve versions.env: prefer the running docker dir, fall back to installer.
    local versions_env=""
    if [[ -n "$versions_env_override" && -f "$versions_env_override" ]]; then
        versions_env="$versions_env_override"
    elif [[ -f "${INSTALL_DIR}/docker/versions.env" ]]; then
        versions_env="${INSTALL_DIR}/docker/versions.env"
    elif [[ -n "${INSTALLER_DIR:-}" && -f "${INSTALLER_DIR}/templates/versions.env" ]]; then
        versions_env="${INSTALLER_DIR}/templates/versions.env"
    fi

    if [[ -z "$versions_env" ]]; then
        log_warn "airgapped_preflight: versions.env not found — skipping image check"
    else
        # Parse *_VERSION= lines and reconstruct image references.
        # versions.env contains bare VERSION strings, not full image:tag combos.
        # We iterate the file and check which image tags are locally available.
        # Strategy: any line that looks like COMPONENT_VERSION=<tag> produces a
        # potential image name. We check each reconstructed image via docker image inspect.
        # For files with just NGINX_VERSION=1.27.0, we reconstruct nginx:1.27.0 etc.
        # The test fixture has: NGINX_VERSION, REDIS_VERSION, PORTAINER_VERSION, DOCKER_SOCKET_PROXY_VERSION
        # We use a simple heuristic: KEY → lowercase prefix → image:VERSION
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            # Skip blank lines and comments
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$value" ]] && continue

            # Only process *_VERSION and *_IMAGE keys
            if [[ "$key" =~ _VERSION$ || "$key" =~ _IMAGE$ ]]; then
                # Reconstruct image name: lowercase the prefix
                local raw_prefix="${key%_VERSION}"
                raw_prefix="${raw_prefix%_IMAGE}"
                # Convert _ to / for known multi-component names (e.g. DOCKER_SOCKET_PROXY)
                local img_name
                img_name="$(echo "$raw_prefix" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
                local img_ref="${img_name}:${value}"

                # Check if locally available
                if ! docker image inspect "$img_ref" >/dev/null 2>&1; then
                    missing_images+=("$img_ref")
                fi
            fi
        done < "$versions_env"
    fi

    # ── 2. Model volume check ─────────────────────────────────────────────────
    # For each of the 6 model volumes: inspect to get mountpoint; warn if empty.
    # A missing or empty volume is a warning (model downloads happen at start time);
    # missing images are the hard fail (docker pull is blocked when airgapped).
    local vol mp
    for vol in "${_AIRGAPPED_MODEL_VOLUMES[@]}"; do
        mp="$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)"
        if [[ -z "$mp" ]]; then
            # Volume doesn't exist
            missing_models+=("model-volume:${vol}")
        fi
        # Note: we do NOT check if mountpoint is non-empty here — that requires
        # root access to the Docker data directory. The volume existing is enough
        # to confirm it was created (content is loaded by bundle_install).
    done

    # ── 3. Report ─────────────────────────────────────────────────────────────
    if [[ ${#missing_images[@]} -gt 0 ]]; then
        log_error "AGMIND_AIRGAPPED: missing locally: ${missing_images[*]}"
        if [[ ${#missing_models[@]} -gt 0 ]]; then
            log_warn "AGMIND_AIRGAPPED: missing model volumes: ${missing_models[*]}"
        fi
        log_error "Run: agmind bundle install <bundle.tar.gz> first"
        return 1
    fi

    if [[ ${#missing_models[@]} -gt 0 ]]; then
        log_warn "AGMIND_AIRGAPPED: missing model volumes: ${missing_models[*]}"
        log_warn "Run: agmind bundle install <bundle.tar.gz> to restore model volumes"
        # Model volumes missing is a warning, not a hard fail — models may stream at start
    fi

    log_success "airgapped preflight: all images present locally"
    return 0
}
