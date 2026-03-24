#!/usr/bin/env python3
"""Update release-manifest.json from versions.env.

Usage:
    python3 scripts/update-release-manifest.py <tag> [release_date]

    tag          - Release tag (e.g. v2.6.0)
    release_date - ISO 8601 timestamp or YYYY-MM-DD (optional)

Reads  templates/versions.env and templates/release-manifest.json,
writes updated templates/release-manifest.json with:
  - version set to <tag>
  - release_date set to date portion of <release_date> (or today UTC)
  - each image tag updated from the corresponding _VERSION key
"""

import json
import sys
from datetime import datetime, timezone

# Mapping: versions.env key -> list of manifest image keys
KEY_MAP = {
    "DIFY_VERSION": ["dify-api", "dify-web"],
    "OPENWEBUI_VERSION": ["open-webui"],
    "OLLAMA_VERSION": ["ollama"],
    "POSTGRES_VERSION": ["postgres"],
    "REDIS_VERSION": ["redis"],
    "WEAVIATE_VERSION": ["weaviate"],
    "QDRANT_VERSION": ["qdrant"],
    "SANDBOX_VERSION": ["dify-sandbox"],
    "SQUID_VERSION": ["squid"],
    "NGINX_VERSION": ["nginx"],
    "CERTBOT_VERSION": ["certbot"],
    "PLUGIN_DAEMON_VERSION": ["dify-plugin-daemon"],
    "DOCLING_SERVE_VERSION": ["docling-serve"],
    "AUTHELIA_VERSION": ["authelia"],
    "GRAFANA_VERSION": ["grafana"],
    "PORTAINER_VERSION": ["portainer"],
    "NODE_EXPORTER_VERSION": ["node-exporter"],
    "CADVISOR_VERSION": ["cadvisor"],
    "PROMETHEUS_VERSION": ["prometheus"],
    "ALERTMANAGER_VERSION": ["alertmanager"],
    "LOKI_VERSION": ["loki"],
    "PROMTAIL_VERSION": ["promtail"],
    "VLLM_VERSION": ["vllm"],
    "TEI_VERSION": ["tei"],
    "PIPELINES_VERSION": ["pipelines"],
}


def parse_versions_env(path: str) -> dict:
    versions = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                versions[k.strip()] = v.strip()
    return versions


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: update-release-manifest.py <tag> [release_date]", file=sys.stderr)
        sys.exit(1)

    tag = sys.argv[1]
    raw_date = sys.argv[2] if len(sys.argv) > 2 else ""
    release_date = raw_date[:10] if raw_date else datetime.now(timezone.utc).strftime("%Y-%m-%d")

    versions = parse_versions_env("templates/versions.env")

    with open("templates/release-manifest.json") as f:
        manifest = json.load(f)

    manifest["version"] = tag
    manifest["release_date"] = release_date

    images = manifest.get("images", {})
    updated = 0
    for env_key, img_keys in KEY_MAP.items():
        if env_key in versions:
            for img_key in img_keys:
                if img_key in images:
                    images[img_key]["tag"] = versions[env_key]
                    updated += 1

    manifest["images"] = images

    with open("templates/release-manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    print(
        f"Manifest updated: version={manifest['version']}, "
        f"date={manifest['release_date']}, "
        f"{len(images)} images ({updated} tags updated)"
    )


if __name__ == "__main__":
    main()
