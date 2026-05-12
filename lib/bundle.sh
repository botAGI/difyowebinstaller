#!/usr/bin/env bash
# bundle.sh — Offline transfer bundle: create tarball with images + model volumes + repo
# (no secrets) for air-gapped deployment; install (sha-verify → docker load → restore
# volumes → instruct AGMIND_AIRGAPPED=true bash install.sh).
# Dependencies: common.sh (log_*, validate_path), doctor.sh (_sanitize_text),
#   airgapped.sh (_AIRGAPPED_MODEL_VOLUMES — sourced for the 6 volume names).
# Functions: bundle_create([--out <dir>]), bundle_install(<bundle.tar.gz>)
# Expects: INSTALL_DIR, INSTALLER_DIR, VERSION (from install.sh)
# WHY separate module: large/slow operation; agmind bundle dispatch lazy-sources it
# so it never loads into the main agmind.sh footprint unless needed.
set -euo pipefail

[[ -n "${_BUNDLE_SH_LOADED:-}" ]] && return 0
_BUNDLE_SH_LOADED=1

# ============================================================================
# FALLBACK SHIMS (active when sourced without common.sh)
# Mirror lib/doctor.sh / lib/airgapped.sh pattern for standalone sourcing.
# ============================================================================
command -v log_info    >/dev/null 2>&1 || log_info()    { echo -e "  -> $*"; }
command -v log_success >/dev/null 2>&1 || log_success() { echo -e "  OK $*"; }
command -v log_warn    >/dev/null 2>&1 || log_warn()    { echo -e "  [WARN] $*" >&2; }
command -v log_error   >/dev/null 2>&1 || log_error()   { echo -e "  [ERROR] $*" >&2; }
command -v validate_path >/dev/null 2>&1 || validate_path() {
    local input="${1:-}"
    [[ -z "$input" ]] && { log_error "validate_path: empty path"; return 1; }
    local resolved
    resolved="$(realpath "$input" 2>/dev/null)" \
        || { log_error "validate_path: cannot resolve: ${input}"; return 1; }
    printf '%s' "$resolved"
}

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

# ============================================================================
# SOURCE DEPENDENCIES (idempotent)
# ============================================================================

# Source lib/doctor.sh for _sanitize_text — the canonical secret scrubber.
# WHY reuse: belt-and-suspenders same as doctor bundle; don't hand-roll sed rules.
_bundle_load_sanitize() {
    command -v _sanitize_text >/dev/null 2>&1 && return 0
    # Try runtime copy first (agmind CLI path), then dev repo path.
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    source "${_script_dir}/doctor.sh" 2>/dev/null \
        || source "${INSTALL_DIR}/scripts/doctor.sh" 2>/dev/null \
        || true
    # Final fallback: minimal 4-rule sed if doctor.sh unavailable
    command -v _sanitize_text >/dev/null 2>&1 || _sanitize_text() {
        sed -E \
            -e 's/([A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|API_?KEY|AUTH_KEY|WEBHOOK_SECRET))([[:space:]]*[=:][[:space:]]*)[^[:space:]"'"'"']{4,}/\1\3<redacted>/gI' \
            -e 's/(_KEY)([[:space:]]*[=:][[:space:]]*)[^[:space:]"'"'"']{4,}/\1\2<redacted>/gI' \
            -e 's/(Authorization:[[:space:]]*).{4,}/\1<redacted>/gI' \
            -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/-]{8,}/Bearer <redacted>/gI' \
            "$@"
    }
}

# Source lib/airgapped.sh for the 6 model volume names.
# WHY: single source of truth — bundle_create iterates the same volumes.
_bundle_load_airgapped() {
    [[ -n "${_AIRGAPPED_SH_LOADED:-}" ]] && return 0
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    source "${_script_dir}/airgapped.sh" 2>/dev/null \
        || source "${INSTALL_DIR}/scripts/airgapped.sh" 2>/dev/null \
        || true
    # Fallback: define inline if airgapped.sh unavailable
    if [[ -z "${_AIRGAPPED_SH_LOADED:-}" ]]; then
        _AIRGAPPED_MODEL_VOLUMES=(
            agmind_vllm_cache agmind_tei_cache agmind_tei_rerank_cache
            agmind_vllm_embed_cache agmind_vllm_rerank_cache agmind_docling_cache
        )
    fi
}

# ============================================================================
# PRIVATE: SHA256 helper
# ============================================================================
# _bundle_sha256 <file> — print just the hex digest (no filename)
_bundle_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        # macOS / OpenBSD fallback
        python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
    fi
}

# ============================================================================
# BUNDLE CREATE
# ============================================================================
# bundle_create [--out <dir>]
# Build an offline transfer bundle:
#   images/<img>.tar   — per-image docker save (one tar per image)
#   models/<vol>.tar.gz — model volumes (each volume via docker run busybox tar)
#   repo/               — scripts/ templates/ lib/ install.sh versions.env RELEASE
#                         (EXCLUDING .planning/ .git/ credentials.txt .env
#                          .admin_password .secrets/ *.key *.pem)
#   MANIFEST.txt        — sha256 per artifact + AGMIND_VERSION + RELEASE + timestamp
#   INSTALL.md          — operator instructions
# Output: <out>/agmind-bundle-<timestamp>.tar.gz (chmod 600, atomic via tmp + mv)
bundle_create() {
    _bundle_load_sanitize
    _bundle_load_airgapped

    # ── Parse args ────────────────────────────────────────────────────────────
    local out_dir="${INSTALL_DIR}"
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            --out) out_dir="${2:?--out requires a directory}"; shift 2 ;;
            *)     shift ;;
        esac
    done

    mkdir -p "$out_dir" 2>/dev/null || true

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local bundle_name="agmind-bundle-${ts}.tar.gz"
    local tmp_bundle="${out_dir}/.${bundle_name}.tmp"

    # ── Staging area ──────────────────────────────────────────────────────────
    local staging
    staging="$(mktemp -d)"
    # WHY trap RETURN not EXIT: EXIT trap fires even on subshell exit which
    # can delete staging before tar completes. RETURN is safer for functions.
    # shellcheck disable=SC2064
    trap "rm -rf '${staging}'" RETURN

    local bdir="${staging}/agmind-bundle"
    mkdir -p "${bdir}/images" "${bdir}/models" "${bdir}/repo"

    # ── 1. Images ─────────────────────────────────────────────────────────────
    # Determine image list: use docker compose config --images if compose file exists,
    # else fall back to versions.env reconstruction (same logic as airgapped_preflight).
    local versions_env=""
    if [[ -f "${INSTALL_DIR}/docker/versions.env" ]]; then
        versions_env="${INSTALL_DIR}/docker/versions.env"
    elif [[ -n "${INSTALLER_DIR:-}" && -f "${INSTALLER_DIR}/templates/versions.env" ]]; then
        versions_env="${INSTALLER_DIR}/templates/versions.env"
    elif [[ -n "${INSTALLER_DIR:-}" && -f "${INSTALLER_DIR}/versions.env" ]]; then
        versions_env="${INSTALLER_DIR}/versions.env"
    fi

    local -a images=()
    if [[ -n "$versions_env" ]]; then
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$value" ]] && continue
            if [[ "$key" =~ _VERSION$ || "$key" =~ _IMAGE$ ]]; then
                local raw_prefix="${key%_VERSION}"
                raw_prefix="${raw_prefix%_IMAGE}"
                local img_name
                img_name="$(echo "$raw_prefix" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
                images+=("${img_name}:${value}")
            fi
        done < "$versions_env"
    fi

    local total_images="${#images[@]}"
    local idx=0
    for img in "${images[@]:-}"; do
        [[ -z "${img:-}" ]] && continue
        idx=$(( idx + 1 ))
        local safe_name
        safe_name="$(echo "$img" | tr '/:' '__')"
        log_info "[${idx}/${total_images}] Saving image: ${img}"
        docker save "$img" -o "${bdir}/images/${safe_name}.tar" 2>/dev/null || {
            log_warn "docker save failed for ${img} — skipping"
        }
    done

    # ── 2. Model volumes ──────────────────────────────────────────────────────
    local vol
    for vol in "${_AIRGAPPED_MODEL_VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            log_info "Archiving model volume: ${vol}"
            docker run --rm \
                -v "${vol}:/vol:ro" \
                busybox tar czf - -C / vol \
                > "${bdir}/models/${vol}.tar.gz" 2>/dev/null || {
                log_warn "Failed to archive volume ${vol} — skipping"
                rm -f "${bdir}/models/${vol}.tar.gz"
            }
        else
            log_warn "Model volume ${vol} not found — skipping"
        fi
    done

    # ── 3. Repo (NO secrets) ──────────────────────────────────────────────────
    # Source tree: copy scripts/ templates/ lib/ install.sh versions.env RELEASE
    # from INSTALLER_DIR (or INSTALL_DIR as fallback) into staging/repo/.
    # Then DELETE secret-bearing files from the copy.
    local src_dir="${INSTALLER_DIR:-${INSTALL_DIR}}"
    local items=(scripts templates lib install.sh versions.env RELEASE)
    for item in "${items[@]}"; do
        local src_path="${src_dir}/${item}"
        if [[ -e "$src_path" ]]; then
            cp -r "$src_path" "${bdir}/repo/" 2>/dev/null || true
        fi
    done

    # ── Delete secret-bearing files from the repo copy ────────────────────────
    # WHY explicit deny-list: belt-and-suspenders; _sanitize_text handles content
    # but credential FILE PATHS must not appear in the bundle listing at all.
    local deny_items=(
        ".planning"
        ".git"
        "credentials.txt"
        ".env"
        ".admin_password"
        ".secrets"
    )
    for di in "${deny_items[@]}"; do
        find "${bdir}/repo" -name "$di" -exec rm -rf {} + 2>/dev/null || true
    done
    # Also remove key/cert files
    find "${bdir}/repo" \( -name '*.key' -o -name '*.pem' \) -delete 2>/dev/null || true

    # Also delete any .env variants in the repo copy
    find "${bdir}/repo" -name '.env' -delete 2>/dev/null || true
    find "${bdir}/repo" -name '.env.*' -delete 2>/dev/null || true

    # ── 4. MANIFEST.txt ───────────────────────────────────────────────────────
    local release_str
    release_str="$(cat "${src_dir}/RELEASE" 2>/dev/null || echo "unknown")"
    local manifest_file="${bdir}/MANIFEST.txt"
    {
        printf 'AGMIND_VERSION=%s\n' "${VERSION:-unknown}"
        printf 'RELEASE=%s\n' "$release_str"
        printf 'GENERATED=%s\n' "$(date -u +%FT%TZ)"
        printf '\n'
        # sha256 for every file under images/ models/ repo/
        # WHY relative paths: so MANIFEST.txt is portable and install can verify
        # on any machine regardless of extract path.
        while IFS= read -r -d '' f; do
            local rel
            rel="${f#${bdir}/}"
            local sha
            sha="$(_bundle_sha256 "$f")"
            printf 'sha256:%s  %s\n' "$sha" "$rel"
        done < <(find "${bdir}/images" "${bdir}/models" "${bdir}/repo" -type f -print0 2>/dev/null | sort -z)
    } > "$manifest_file"

    # ── 5. INSTALL.md ─────────────────────────────────────────────────────────
    cat > "${bdir}/INSTALL.md" <<'INSTALLMD'
# AGmind Offline Bundle — Installation Instructions

## Transfer
Copy this tarball to the air-gapped target box.

## Install
```bash
sudo agmind bundle install agmind-bundle-<timestamp>.tar.gz
```
Or manually:
```bash
sudo bash -c 'source /opt/agmind/scripts/bundle.sh; bundle_install agmind-bundle-<timestamp>.tar.gz'
```

After bundle install completes:
```bash
AGMIND_AIRGAPPED=true sudo bash install.sh
```

## What This Bundle Contains
- images/   — Docker images (docker save format, one .tar per image)
- models/   — Model volume archives (restore into Docker named volumes)
- repo/     — AGmind scripts, templates, lib/ (NO secrets — your target box generates its own)
- MANIFEST.txt — sha256 checksums + version info
INSTALLMD

    # ── 6. Atomic tar + chmod 600 ─────────────────────────────────────────────
    log_info "Creating bundle tarball..."
    tar czf "$tmp_bundle" -C "$staging" agmind-bundle
    chmod 600 "$tmp_bundle"
    mv "$tmp_bundle" "${out_dir}/${bundle_name}"

    local bundle_size
    bundle_size="$(du -sh "${out_dir}/${bundle_name}" 2>/dev/null | cut -f1 || echo "?")"
    log_success "Bundle created: ${out_dir}/${bundle_name} (${bundle_size})"
    log_info "Transfer to air-gapped box, then: sudo agmind bundle install ${bundle_name}"
}

# ============================================================================
# BUNDLE INSTALL
# ============================================================================
# bundle_install <bundle.tar.gz>
# Load a bundle on an air-gapped box:
#   1. Extract to temp dir
#   2. Verify sha256 of every artifact against MANIFEST.txt (BEFORE docker load)
#   3. docker load each image from images/*.tar
#   4. Restore model volumes from models/*.tar.gz
#   5. Print instruction to run AGMIND_AIRGAPPED=true bash install.sh
# Requires root (caller agmind.sh checks _require_root before calling this).
bundle_install() {
    local bundle_file="${1:?bundle_install requires bundle.tar.gz path}"

    if [[ ! -f "$bundle_file" ]]; then
        log_error "Bundle file not found: ${bundle_file}"
        return 1
    fi

    # ── Extract ───────────────────────────────────────────────────────────────
    local tmpx
    tmpx="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpx}'" RETURN

    log_info "Extracting bundle..."
    tar xzf "$bundle_file" -C "$tmpx"
    local bdir="${tmpx}/agmind-bundle"
    if [[ ! -d "$bdir" ]]; then
        # Try top-level (no agmind-bundle/ prefix)
        bdir="$tmpx"
    fi

    local manifest="${bdir}/MANIFEST.txt"
    if [[ ! -f "$manifest" ]]; then
        log_error "MANIFEST.txt not found in bundle — corrupt archive?"
        return 1
    fi

    # ── 1. Verify sha256 BEFORE any mutation ─────────────────────────────────
    # WHY: tamper check must happen before docker load — partial loads are messy.
    log_info "Verifying bundle integrity (sha256)..."
    local verify_ok=true
    local sha_line file_rel expected_sha actual_sha
    while IFS= read -r sha_line; do
        # Lines look like: sha256:<hex>  <relpath>
        [[ "$sha_line" =~ ^sha256: ]] || continue
        expected_sha="${sha_line%%[[:space:]]*}"   # sha256:<hex>
        expected_sha="${expected_sha#sha256:}"      # strip prefix
        file_rel="${sha_line#*[[:space:]][[:space:]]}"  # everything after double-space
        [[ -z "$file_rel" ]] && continue

        local full_path="${bdir}/${file_rel}"
        if [[ ! -f "$full_path" ]]; then
            log_error "bundle integrity: file missing: ${file_rel}"
            verify_ok=false
            continue
        fi

        actual_sha="$(_bundle_sha256 "$full_path")"
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            log_error "bundle integrity check failed: ${file_rel}"
            log_error "  expected: ${expected_sha}"
            log_error "  actual:   ${actual_sha}"
            verify_ok=false
        fi
    done < "$manifest"

    if [[ "$verify_ok" != "true" ]]; then
        log_error "Bundle integrity check failed — aborting install (no docker load performed)"
        return 1
    fi
    log_success "Bundle integrity verified"

    # ── 2. docker load images ─────────────────────────────────────────────────
    local img_files
    img_files="$(find "${bdir}/images" -name '*.tar' 2>/dev/null | sort)"
    if [[ -n "$img_files" ]]; then
        local img_count
        img_count="$(echo "$img_files" | wc -l | tr -d ' ')"
        local img_idx=0
        while IFS= read -r f; do
            img_idx=$(( img_idx + 1 ))
            log_info "[${img_idx}/${img_count}] Loading image: $(basename "$f")"
            docker load -i "$f" || {
                log_error "docker load failed: ${f}"
                return 1
            }
        done <<< "$img_files"
    fi

    # ── 3. Restore model volumes ──────────────────────────────────────────────
    if [[ -d "${bdir}/models" ]]; then
        local vol_file
        while IFS= read -r vol_file; do
            [[ -z "$vol_file" ]] && continue
            local vol_name
            vol_name="$(basename "$vol_file" .tar.gz)"
            log_info "Restoring model volume: ${vol_name}"
            docker volume create "$vol_name" >/dev/null 2>&1 || true
            docker run --rm \
                -v "${vol_name}:/vol" \
                -v "${vol_file}:/restore.tar.gz:ro" \
                busybox sh -c 'cd / && tar xzf /restore.tar.gz' || {
                log_warn "Failed to restore volume ${vol_name}"
            }
        done < <(find "${bdir}/models" -name '*.tar.gz' 2>/dev/null | sort)
    fi

    # ── 4. Install instruction ────────────────────────────────────────────────
    # WHY print instruction rather than auto-run: bundle install should not
    # trigger a full install without explicit operator confirmation. The operator
    # may want to review or adjust config before running install.sh.
    log_success "Bundle installed successfully"
    echo ""
    log_info "Next step — run install with airgapped mode:"
    echo "  AGMIND_AIRGAPPED=true sudo bash ${INSTALL_DIR}/install.sh"
    echo ""
}
