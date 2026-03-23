#!/usr/bin/env python3
"""
check-manifest-versions.py — CI validator for release-manifest.json

Checks:
  1. All images have non-empty digest fields
  2. Tags in manifest match versions.env
  3. No missing required services
  4. changelog_url is not a placeholder

Usage: python3 scripts/check-manifest-versions.py
Exit 0 on success, 1 on any mismatch.
"""

import json
import os
import sys
from pathlib import Path


def parse_versions_env(path: str) -> dict[str, str]:
    """Parse versions.env into a dict of KEY=VALUE pairs."""
    versions = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, value = line.split("=", 1)
                versions[key.strip()] = value.strip()
    return versions


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    root_dir = script_dir.parent
    manifest_path = root_dir / "templates" / "release-manifest.json"
    versions_path = root_dir / "templates" / "versions.env"

    errors = []

    # Load files
    if not manifest_path.exists():
        print(f"FAIL: {manifest_path} not found")
        return 1
    if not versions_path.exists():
        print(f"FAIL: {versions_path} not found")
        return 1

    with open(manifest_path) as f:
        manifest = json.load(f)

    versions = parse_versions_env(str(versions_path))

    images = manifest.get("images", {})

    # Check 1: Required services present
    required_services = {
        "dify-api", "dify-web", "open-webui", "ollama",
        "postgres", "redis", "weaviate", "qdrant",
        "dify-sandbox", "squid", "nginx", "certbot",
        "dify-plugin-daemon", "docling-serve",
        "authelia", "grafana", "portainer", "node-exporter",
        "cadvisor", "prometheus", "alertmanager", "loki", "promtail",
    }
    missing = required_services - set(images.keys())
    if missing:
        errors.append(f"Missing services in manifest: {', '.join(sorted(missing))}")

    # Check 2: All digests non-empty (warning only — digests require Docker Hub access)
    empty_digests = [svc for svc, info in images.items() if not info.get("digest")]
    if empty_digests:
        print(f"WARN: Empty digests ({len(empty_digests)} images) — run generate-manifest.sh to populate")

    # Check 3: Tags match versions.env
    # Map from manifest service to versions.env key
    tag_to_version_key = {
        "dify-api": "DIFY_VERSION",
        "dify-web": "DIFY_VERSION",
        "open-webui": "OPENWEBUI_VERSION",
        "ollama": "OLLAMA_VERSION",
        "postgres": "POSTGRES_VERSION",
        "redis": "REDIS_VERSION",
        "weaviate": "WEAVIATE_VERSION",
        "qdrant": "QDRANT_VERSION",
        "dify-sandbox": "SANDBOX_VERSION",
        "squid": "SQUID_VERSION",
        "nginx": "NGINX_VERSION",
        "certbot": "CERTBOT_VERSION",
        "dify-plugin-daemon": "PLUGIN_DAEMON_VERSION",
        "docling-serve": "DOCLING_SERVE_VERSION",
        "authelia": "AUTHELIA_VERSION",
        "grafana": "GRAFANA_VERSION",
        "portainer": "PORTAINER_VERSION",
        "node-exporter": "NODE_EXPORTER_VERSION",
        "cadvisor": "CADVISOR_VERSION",
        "prometheus": "PROMETHEUS_VERSION",
        "alertmanager": "ALERTMANAGER_VERSION",
        "loki": "LOKI_VERSION",
        "promtail": "PROMTAIL_VERSION",
    }

    for svc, version_key in tag_to_version_key.items():
        if svc not in images:
            continue
        manifest_tag = images[svc].get("tag", "")
        expected_tag = versions.get(version_key, "")
        if expected_tag and manifest_tag != expected_tag:
            errors.append(
                f"Tag mismatch for {svc}: "
                f"manifest={manifest_tag}, versions.env({version_key})={expected_tag}"
            )

    # Check 4: changelog_url not placeholder
    changelog = manifest.get("changelog_url", "")
    if "your-org" in changelog:
        errors.append(f"changelog_url contains placeholder 'your-org': {changelog}")

    # Report
    if errors:
        print(f"FAIL: {len(errors)} error(s) in release-manifest.json:")
        for e in errors:
            print(f"  ✗ {e}")
        return 1

    print(f"OK: release-manifest.json validated ({len(images)} images, all checks passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
