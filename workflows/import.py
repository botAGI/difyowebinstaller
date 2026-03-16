#!/usr/bin/env python3
"""
import.py — Full automated Dify setup: plugins, models, KB, workflow.

Steps:
 1.  wait_for_api()
 2.  init_validate()            — Dify 1.13+ INIT_PASSWORD
 3.  setup_account()            — skip if already finished
 4.  login()                    — validate token received
 5.  install_plugin(ollama)     — from marketplace
 6.  install_plugin(xinference) — from marketplace
 7.  install_plugin(docling)    — from marketplace
 8.  wait_for_plugins()         — poll until installed
 9.  configure_provider(ollama, base_url)
10.  configure_provider(xinference, server_url)
11.  add_model(LLM) + set_default
12.  add_model(embedding) + set_default
13.  add_model(reranker) + set_default
14.  find_or_create dataset
15.  create dataset API key
16.  find_or_create app
17.  patch_workflow(kb_id, api_key, model, provider)
18.  update_draft + publish
19.  create_service_api_key + save + patch .env
"""

import argparse
import base64
import json
import os
import re
import sys
import tempfile
import time
import http.cookiejar
import urllib.request
import urllib.error

# Marketplace manifest URL (global CDN)
MARKETPLACE_MANIFEST_URL = "https://marketplace.dify.ai/api/v1/dist/plugins/manifest.json"


class DifyClient:
    def __init__(self, base_url, console_prefix=""):
        self.base_url = base_url.rstrip("/")
        self.console_prefix = console_prefix.rstrip("/")
        self.access_token = None
        self.csrf_token = None
        self.cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar)
        )

    def _request(self, method, path, data=None, content_type="application/json",
                 timeout=60):
        if path.startswith("/console/") and self.console_prefix:
            path = f"{self.console_prefix}{path}"
        url = f"{self.base_url}{path}"
        headers = {}

        if self.csrf_token:
            headers["X-CSRF-Token"] = self.csrf_token

        if self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"

        headers["Accept"] = "application/json"

        body = None
        if data is not None:
            if content_type == "application/json":
                headers["Content-Type"] = "application/json"
                body = json.dumps(data).encode("utf-8")
            else:
                body = data

        req = urllib.request.Request(url, data=body, headers=headers, method=method)

        try:
            with self.opener.open(req, timeout=timeout) as resp:
                for cookie in self.cookie_jar:
                    if cookie.name == "access_token":
                        self.access_token = cookie.value
                    elif cookie.name == "csrf_token":
                        self.csrf_token = cookie.value

                resp_body = resp.read().decode("utf-8", errors="replace")
                if resp_body:
                    try:
                        return json.loads(resp_body)
                    except json.JSONDecodeError:
                        raise RuntimeError(
                            f"Non-JSON response from {method} {path}: "
                            f"{resp_body[:200]}"
                        )
                return {}
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8", errors="replace") if e.fp else ""
            e._dify_body = error_body  # preserve for callers
            print(f"HTTP {e.code} {method} {path}: {error_body[:500]}", file=sys.stderr)
            raise

    # ==================================================================
    # Init / Setup / Login
    # ==================================================================

    def init_validate(self, init_password):
        """Validate INIT_PASSWORD (Dify 1.13+ self-hosted)."""
        try:
            status = self._request("GET", "/console/api/init")
            if status.get("status") == "finished":
                print("  Init: already completed")
                return
        except urllib.error.HTTPError as e:
            if e.code not in (404, 405):
                raise

        try:
            self._request("POST", "/console/api/init", {
                "password": init_password,
            })
            print("  Init: validated")
        except urllib.error.HTTPError as e:
            if e.code == 403:
                print("  Init: already completed")
            else:
                error_body = getattr(e, '_dify_body', '')
                print(f"  Init: HTTP {e.code} — {error_body[:200]}", file=sys.stderr)

    def setup_account(self, email, password, name="Admin"):
        """Create admin account (first run only)."""
        try:
            status = self._request("GET", "/console/api/setup")
            if status.get("step") == "finished":
                print("  Setup: already completed")
                return
        except urllib.error.HTTPError as e:
            if e.code not in (404, 405):
                raise

        try:
            result = self._request("POST", "/console/api/setup", {
                "email": email,
                "name": name,
                "password": password,
            })
            print("  Setup: account created")
            return result
        except urllib.error.HTTPError as e:
            if e.code == 403:
                print("  Setup: already completed")
            else:
                raise

    def login(self, email, password):
        """Login and get access token. Raises if token is empty."""
        password_b64 = base64.b64encode(password.encode()).decode()
        result = self._request("POST", "/console/api/login", {
            "email": email,
            "password": password_b64,
            "language": "en-US",
            "remember_me": True,
        })
        if not self.access_token:
            self.access_token = result.get("data", {}).get("access_token", "")
            self.csrf_token = result.get("data", {}).get("csrf_token", "")
        if not self.access_token:
            raise RuntimeError(
                "Login failed — access token not received. "
                "Check email/password and Dify logs."
            )
        print("  Login: OK (token: ***masked***)")
        return result

    # ==================================================================
    # Plugin management (marketplace)
    # ==================================================================

    def list_installed_plugins(self):
        """Return set of installed plugin ids ('org/name')."""
        result = self._request(
            "GET",
            "/console/api/workspaces/current/plugin/list"
            "?page=1&page_size=256",
        )
        installed = set()
        for p in result.get("plugins", []):
            decl = p.get("declaration", p.get("plugin_id", {}))
            # plugin_id can be a string "org/name" or nested
            if isinstance(decl, str):
                # strip version if present
                installed.add(decl.split(":")[0])
            else:
                name = p.get("plugin_id", "") or p.get("name", "")
                if "/" in name:
                    installed.add(name.split(":")[0])
        return installed

    def install_plugin_from_marketplace(self, unique_identifier):
        """Install a plugin using its marketplace unique_identifier."""
        try:
            result = self._request(
                "POST",
                "/console/api/workspaces/current/plugin/install/marketplace",
                {"plugin_unique_identifiers": [unique_identifier]},
            )
            task_id = result.get("task_id", "")
            all_tasks = result.get("all_installed", False)
            if all_tasks:
                return None  # already installed
            return task_id
        except urllib.error.HTTPError as e:
            if e.code == 409:
                return None  # already installed
            raise

    def get_plugin_tasks(self):
        """Get all plugin install tasks."""
        return self._request(
            "GET",
            "/console/api/workspaces/current/plugin/tasks"
            "?page=1&page_size=256",
        )

    # ==================================================================
    # Model provider configuration
    # ==================================================================

    def configure_provider(self, provider_path, credentials):
        """Set provider-level credentials (e.g. base_url for Ollama).

        provider_path: e.g. 'langgenius/ollama/ollama'
        """
        try:
            self._request(
                "POST",
                f"/console/api/workspaces/current/model-providers/"
                f"{provider_path}/credentials",
                {"credentials": credentials},
            )
            print(f"  Provider configured: {provider_path}")
        except urllib.error.HTTPError as e:
            if e.code in (409, 400):
                # 409 = already configured, 400 = may already exist
                print(f"  Provider already configured: {provider_path}")
            else:
                raise

    def add_model(self, provider_path, model_name, model_type, credentials):
        """Add a specific model to a provider.

        provider_path: e.g. 'langgenius/ollama/ollama'
        """
        try:
            self._request(
                "POST",
                f"/console/api/workspaces/current/model-providers/"
                f"{provider_path}/models/credentials",
                {
                    "model": model_name,
                    "model_type": model_type,
                    "credentials": credentials,
                },
            )
            print(f"  Model added [{model_type}]: {model_name}")
        except urllib.error.HTTPError as e:
            if e.code in (409, 400):
                print(f"  Model already exists [{model_type}]: {model_name}")
            else:
                raise

    def set_default_models(self, model_settings):
        """Set default models for each type.

        model_settings: list of {"model_type", "provider", "model"}
        """
        self._request(
            "POST",
            "/console/api/workspaces/current/default-model",
            {"model_settings": model_settings},
        )
        for s in model_settings:
            print(f"  Default [{s['model_type']}]: {s['model']}")

    # ==================================================================
    # Datasets (Knowledge Bases)
    # ==================================================================

    def find_dataset(self, name):
        """Find existing dataset by name. Returns id or None."""
        try:
            result = self._request(
                "GET", "/console/api/datasets?page=1&limit=50"
            )
            for ds in result.get("data", []):
                if ds.get("name") == name:
                    print(f"  Knowledge Base found: {name} (id: {ds['id']})")
                    return ds["id"]
        except urllib.error.HTTPError as e:
            if e.code not in (404, 403):
                raise
        return None

    def create_dataset(self, name, embedding_model, embedding_provider):
        """Create Knowledge Base with explicit embedding model."""
        result = self._request("POST", "/console/api/datasets", {
            "name": name,
            "indexing_technique": "high_quality",
            "permission": "all_team_members",
            "embedding_model": embedding_model,
            "embedding_model_provider": embedding_provider,
        })
        kb_id = result.get("id", "")
        print(f"  Knowledge Base created: {name} (id: {kb_id})")
        return kb_id

    def create_dataset_api_key(self):
        """Create a dataset API key. Raises if empty."""
        result = self._request("POST", "/console/api/datasets/api-keys", {})
        api_key = (
            result.get("api_key")
            or result.get("token")
            or result.get("key")
            or ""
        )
        if not api_key:
            raise ValueError(
                f"Dataset API key not found in response: {list(result.keys())}"
            )
        print("  Dataset API Key: ***masked***")
        return api_key

    def get_or_create_dataset_api_key(self):
        """Reuse existing dataset API key if available, otherwise create new."""
        try:
            result = self._request("GET", "/console/api/datasets/api-keys")
            keys = result.get("data", result.get("keys", []))
            if keys:
                existing_key = keys[0].get("token") or keys[0].get("api_key") or keys[0].get("key", "")
                if existing_key:
                    print("  Dataset API Key: ***masked*** (reused)")
                    return existing_key
        except urllib.error.HTTPError:
            pass
        return self.create_dataset_api_key()

    # ==================================================================
    # Apps
    # ==================================================================

    def find_app(self, name):
        """Find existing app by name. Returns id or None."""
        try:
            result = self._request(
                "GET",
                "/console/api/apps?page=1&limit=50&mode=advanced-chat",
            )
            for app in result.get("data", []):
                if app.get("name") == name:
                    print(f"  App found: {name} (id: {app['id']})")
                    return app["id"]
        except urllib.error.HTTPError as e:
            if e.code not in (404, 403):
                raise
        return None

    def create_app(self, name, company_name="AGMind"):
        """Create Chatflow app."""
        result = self._request("POST", "/console/api/apps", {
            "name": name,
            "mode": "advanced-chat",
            "icon_type": "emoji",
            "icon": "\U0001f4da",
            "icon_background": "#E4FBCC",
            "description": f"{company_name} RAG Assistant",
        })
        app_id = result.get("id", "")
        print(f"  App created: {name} (id: {app_id})")
        return app_id

    def get_workflow_draft(self, app_id):
        """Get current workflow draft (for hash)."""
        result = self._request(
            "GET", f"/console/api/apps/{app_id}/workflows/draft"
        )
        draft_hash = result.get("hash", "")
        print("  Draft hash: OK")
        return result, draft_hash

    def update_workflow_draft(self, app_id, graph, features, draft_hash):
        """Update workflow draft."""
        result = self._request(
            "POST",
            f"/console/api/apps/{app_id}/workflows/draft",
            {"graph": graph, "features": features, "hash": draft_hash},
        )
        print("  Draft updated: OK")
        return result

    def publish_workflow(self, app_id):
        """Publish workflow."""
        result = self._request(
            "POST", f"/console/api/apps/{app_id}/workflows/publish", {}
        )
        print("  Published: OK")
        return result

    def create_service_api_key(self, app_id):
        """Create Service API key. Raises if empty."""
        result = self._request(
            "POST", f"/console/api/apps/{app_id}/api-keys", {}
        )
        api_key = (
            result.get("api_key")
            or result.get("token")
            or result.get("key")
            or ""
        )
        if not api_key:
            raise ValueError(
                f"Service API key not found in response: {list(result.keys())}"
            )
        print("  Service API Key: ***masked***")
        return api_key

    def get_or_create_service_api_key(self, app_id):
        """Reuse existing service API key if available, otherwise create new."""
        try:
            result = self._request("GET", f"/console/api/apps/{app_id}/api-keys")
            keys = result.get("data", result.get("keys", []))
            if keys:
                existing_key = keys[0].get("token") or keys[0].get("api_key") or keys[0].get("key", "")
                if existing_key:
                    print("  Service API Key: ***masked*** (reused)")
                    return existing_key
        except urllib.error.HTTPError:
            pass
        return self.create_service_api_key(app_id)


# ======================================================================
# Marketplace helpers
# ======================================================================

def fetch_marketplace_manifest(timeout=30):
    """Fetch the global plugin manifest from Dify marketplace."""
    req = urllib.request.Request(MARKETPLACE_MANIFEST_URL)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError) as e:
        print(f"  ⚠ Cannot fetch marketplace manifest: {e}", file=sys.stderr)
        return None


def resolve_plugin_identifiers(plugin_specs, manifest):
    """Resolve 'org/name' specs to full 'org/name:version@hash' identifiers.

    plugin_specs: list of strings like 'langgenius/ollama' or
                  'langgenius/ollama:0.1.2' (with pinned version)
    manifest: parsed manifest JSON from marketplace

    Returns: dict mapping 'org/name' -> 'org/name:version@hash'
    """
    if not manifest or "plugins" not in manifest:
        return {}

    # Build lookup: 'org/name' -> plugin entry
    lookup = {}
    for p in manifest["plugins"]:
        key = f"{p['org']}/{p['name']}"
        lookup[key] = p

    resolved = {}
    for spec in plugin_specs:
        # Parse optional version pin: 'org/name:version'
        if ":" in spec and "@" not in spec:
            base, pinned_ver = spec.rsplit(":", 1)
        else:
            base = spec.split(":")[0].split("@")[0]
            pinned_ver = None

        entry = lookup.get(base)
        if not entry:
            print(f"  ⚠ Plugin not found in marketplace: {base}", file=sys.stderr)
            continue

        identifier = entry.get("latest_package_identifier", "")
        if not identifier:
            print(f"  ⚠ No package identifier for: {base}", file=sys.stderr)
            continue

        # If version is pinned and differs from latest, warn but use latest
        if pinned_ver and pinned_ver != entry.get("latest_version", ""):
            print(
                f"  ⚠ Requested {base}:{pinned_ver}, "
                f"using latest {entry.get('latest_version', '?')}",
                file=sys.stderr,
            )

        resolved[base] = identifier

    return resolved


def install_plugins(client, plugin_specs, timeout=180):
    """Install plugins from marketplace with polling.

    Returns True if all plugins are ready.
    """
    # Check what's already installed
    installed = client.list_installed_plugins()
    needed_specs = [s for s in plugin_specs if s.split(":")[0] not in installed]

    if not needed_specs:
        print("  All plugins already installed")
        return True

    # Fetch manifest
    print("  Fetching marketplace manifest...")
    manifest = fetch_marketplace_manifest()
    if not manifest:
        print(
            "  ⚠ Marketplace unreachable — plugins must be installed manually",
            file=sys.stderr,
        )
        return False

    # Resolve identifiers
    identifiers = resolve_plugin_identifiers(needed_specs, manifest)
    if not identifiers:
        print("  ⚠ No plugins resolved from manifest", file=sys.stderr)
        return False

    # Install each plugin
    task_ids = []
    for base_name, identifier in identifiers.items():
        short_id = identifier.split("@")[0]  # mask hash
        print(f"  Installing: {short_id}...")
        task_id = client.install_plugin_from_marketplace(identifier)
        if task_id:
            task_ids.append(task_id)
        else:
            print(f"  Already installed: {base_name}")

    if not task_ids:
        return True

    # Poll until all tasks complete
    print("  Waiting for plugin installation...")
    start = time.time()
    while time.time() - start < timeout:
        time.sleep(5)
        try:
            tasks_resp = client.get_plugin_tasks()
            tasks = tasks_resp.get("tasks", [])
            if not tasks and time.time() - start > 15:
                # No pending tasks after initial wait = all done
                break

            pending = 0
            for t in tasks:
                status = t.get("status", "")
                plugin_id = t.get("plugin_unique_identifier", "?")
                short = plugin_id.split("@")[0] if plugin_id else "?"
                if status in ("success", "installed"):
                    continue
                elif status in ("failed", "error"):
                    print(
                        f"  ✗ Plugin failed: {short} — "
                        f"{t.get('message', 'unknown error')}",
                        file=sys.stderr,
                    )
                else:
                    pending += 1

            if pending == 0:
                break
        except Exception as e:
            print(f"  Poll error: {e}", file=sys.stderr)
    else:
        print(f"  ⚠ Plugin install poll timed out after {timeout}s — check manually", file=sys.stderr)

    # Final check
    installed = client.list_installed_plugins()
    all_ok = True
    for spec in plugin_specs:
        base = spec.split(":")[0]
        if base in installed:
            print(f"  ✓ {base}")
        else:
            print(f"  ✗ {base} — not installed", file=sys.stderr)
            all_ok = False

    return all_ok


# ======================================================================
# Workflow patching
# ======================================================================

def patch_workflow(workflow_data, kb_id, api_key, model_name, company_name,
                   model_provider="langgenius/ollama/ollama"):
    """Patch workflow JSON with deployment-specific values."""
    graph = workflow_data.get("graph", workflow_data)
    nodes = graph.get("nodes", [])

    for node in nodes:
        data = node.get("data", {})
        node_type = data.get("type", "")

        # Patch knowledge-retrieval node
        if node_type == "knowledge-retrieval":
            data["dataset_ids"] = [kb_id]
            print(f"  Patched: {data.get('title', node['id'])} → KB {kb_id}")

        # Patch HTTP request nodes — URLs and API keys
        elif node_type == "http-request":
            url = data.get("url", "")
            if "datasets/" in url:
                new_url = re.sub(
                    r'datasets/[a-f0-9-]+',
                    f'datasets/{kb_id}',
                    url,
                )
                data["url"] = new_url

                auth = data.get("authorization", {})
                config = auth.get("config", {})
                if config.get("api_key"):
                    config["api_key"] = api_key
                    print(
                        f"  Patched: {data.get('title', node['id'])} "
                        f"→ API key + KB URL"
                    )

        # Patch LLM node — model name, provider, system prompt
        elif node_type == "llm":
            model = data.get("model", {})
            if model:
                model["name"] = model_name
                model["provider"] = model_provider
                print(f"  Patched: LLM → {model_name} ({model_provider})")

            prompts = data.get("prompt_template", [])
            for prompt in prompts:
                if prompt.get("role") == "system":
                    text = prompt.get("text", "")
                    text = text.replace(
                        "\u0422\u044b \u2014 \u0430\u0441\u0441\u0438\u0441"
                        "\u0442\u0435\u043d\u0442 \u043f\u043e "
                        "\u0434\u043e\u043a\u0443\u043c\u0435\u043d"
                        "\u0442\u0430\u0446\u0438\u0438.",
                        f"\u0422\u044b \u2014 \u0430\u0441\u0441\u0438\u0441"
                        f"\u0442\u0435\u043d\u0442 \u043f\u043e "
                        f"\u0434\u043e\u043a\u0443\u043c\u0435\u043d"
                        f"\u0442\u0430\u0446\u0438\u0438 "
                        f"\u043a\u043e\u043c\u043f\u0430\u043d\u0438\u0438"
                        f" {company_name}."
                    )
                    prompt["text"] = text

    return graph


def patch_features(features, company_name):
    """Patch features (opening statement, etc.) with branding."""
    if features.get("opening_statement"):
        features["opening_statement"] = (
            f"\U0001f44b \u041f\u0440\u0438\u0432\u0435\u0442! "
            f"\u042f \u0430\u0441\u0441\u0438\u0441\u0442\u0435\u043d\u0442 "
            f"{company_name} \u043f\u043e "
            f"\u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u0430\u043c.\n\n"
            "\U0001f4c4 \u0417\u0430\u0434\u0430\u0439\u0442\u0435 "
            "\u0432\u043e\u043f\u0440\u043e\u0441 \u2014 "
            "\u043d\u0430\u0439\u0434\u0443 \u043e\u0442\u0432\u0435\u0442 "
            "\u0432 \u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u0430\u0445\n"
            "\U0001f4ce \u041f\u0440\u0438\u043a\u0440\u0435\u043f\u0438\u0442\u0435"
            " \u0444\u0430\u0439\u043b \u2014 "
            "\u0437\u0430\u0433\u0440\u0443\u0436\u0443 \u0432 "
            "\u0431\u0430\u0437\u0443 \u0437\u043d\u0430\u043d\u0438\u0439\n"
            "\U0001f4cb /list \u2014 "
            "\u0441\u043f\u0438\u0441\u043e\u043a "
            "\u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u043e\u0432\n"
            "\U0001f5d1\ufe0f /delete <ID> \u2014 "
            "\u0443\u0434\u0430\u043b\u0438\u0442\u044c "
            "\u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442"
        )
    return features


# ======================================================================
# Utilities
# ======================================================================

def wait_for_api(base_url, console_prefix="", timeout=300):
    """Wait for Dify API to be ready."""
    check_url = f"{base_url}{console_prefix}/console/api/setup"
    print(f"\u041e\u0436\u0438\u0434\u0430\u043d\u0438\u0435 Dify API "
          f"({check_url})...")
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(check_url)
            urllib.request.urlopen(req, timeout=5)
            return True
        except Exception:
            time.sleep(5)
    print("\u041e\u0428\u0418\u0411\u041a\u0410: Dify API "
          "\u043d\u0435 \u043e\u0442\u0432\u0435\u0447\u0430\u0435\u0442",
          file=sys.stderr)
    return False


def save_api_key(install_dir, api_key):
    """Save Service API key to file AND patch .env."""
    key_file = os.path.join(install_dir, ".dify_service_api_key")
    with open(key_file, "w") as f:
        f.write(api_key)
    os.chmod(key_file, 0o600)
    print(f"  API key saved: {key_file}")

    env_file = os.path.join(install_dir, "docker/.env")
    if os.path.exists(env_file):
        with open(env_file, "r") as f:
            content = f.read()
        if "DIFY_API_KEY=" in content:
            content = re.sub(
                r"^DIFY_API_KEY=.*$",
                f"DIFY_API_KEY={api_key}",
                content,
                flags=re.MULTILINE,
            )
        else:
            content += f"\nDIFY_API_KEY={api_key}\n"
        tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(env_file))
        try:
            with os.fdopen(tmp_fd, 'w') as tmp_f:
                tmp_f.write(content)
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, env_file)
        except:
            os.unlink(tmp_path)
            raise
        print("  .env updated: DIFY_API_KEY")


# ======================================================================
# Main
# ======================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Import RAG workflow into Dify (full automation)"
    )
    parser.add_argument("--url", default="http://localhost",
                        help="Dify base URL")
    parser.add_argument("--email", required=True, help="Admin email")
    parser.add_argument("--password", required=True,
                        help="Admin password (plaintext)")
    parser.add_argument("--model", default="qwen2.5:14b",
                        help="LLM model name")
    parser.add_argument("--embedding", default="bge-m3",
                        help="Embedding model")
    parser.add_argument("--company", default="AGMind",
                        help="Company name")
    parser.add_argument("--workflow", required=True,
                        help="Path to workflow JSON")
    parser.add_argument("--install-dir", default="/opt/agmind",
                        help="Install directory")
    parser.add_argument("--console-prefix", default="",
                        help="URL prefix for console API")
    parser.add_argument("--init-password", default="",
                        help="INIT_PASSWORD from .env")
    parser.add_argument("--ollama-url", default="http://ollama:11434",
                        help="Ollama URL inside Docker network")
    parser.add_argument("--rerank-model", default="bce-reranker-base_v1",
                        help="Xinference rerank model (empty to skip)")
    parser.add_argument("--xinference-url", default="http://xinference:9997",
                        help="Xinference URL inside Docker network")
    parser.add_argument("--model-provider",
                        default="langgenius/ollama/ollama",
                        help="Dify model provider path for LLM")
    parser.add_argument("--embedding-provider",
                        default="langgenius/ollama/ollama",
                        help="Dify embedding model provider path")
    parser.add_argument("--rerank-provider",
                        default="langgenius/xinference/xinference",
                        help="Dify rerank model provider path")
    parser.add_argument(
        "--plugins",
        default="langgenius/ollama,langgenius/xinference,s20ss/docling",
        help="Comma-separated plugin specs to install from marketplace",
    )
    args = parser.parse_args()

    # Wait for API
    if not wait_for_api(args.url, args.console_prefix):
        sys.exit(1)

    # Load workflow JSON
    with open(args.workflow, "r") as f:
        workflow_data = json.load(f)

    client = DifyClient(args.url, args.console_prefix)

    print("\n=== \u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430"
          " Dify ===\n")

    # --- Step 1-2: Init + Setup ---
    if args.init_password:
        client.init_validate(args.init_password)

    try:
        client.setup_account(
            args.email, args.password, f"{args.company} Admin"
        )
    except Exception as e:
        print(f"  Setup skip: {e}")

    time.sleep(3)

    # --- Step 3: Login ---
    client.login(args.email, args.password)

    # --- Step 4-7: Install plugins from marketplace ---
    print("\n--- \u041f\u043b\u0430\u0433\u0438\u043d\u044b ---")
    plugin_specs = [
        s.strip() for s in args.plugins.split(",") if s.strip()
    ]
    if plugin_specs:
        install_plugins(client, plugin_specs)
    else:
        print("  No plugins to install")

    # --- Step 8-9: Configure providers ---
    print("\n--- \u041f\u0440\u043e\u0432\u0430\u0439\u0434\u0435\u0440\u044b"
          " ---")
    # Ollama provider
    client.configure_provider(
        args.model_provider,
        {"base_url": args.ollama_url},
    )
    # Xinference provider (if rerank model specified)
    if args.rerank_model:
        client.configure_provider(
            args.rerank_provider,
            {
                "server_url": args.xinference_url,
            },
        )

    # --- Step 10-12: Add models + set defaults ---
    print("\n--- \u041c\u043e\u0434\u0435\u043b\u0438 ---")
    # LLM
    client.add_model(
        args.model_provider,
        args.model,
        "llm",
        {
            "base_url": args.ollama_url,
            "mode": "chat",
            "context_size": "8192",
            "max_tokens": "8192",
            "vision_support": "false",
            "function_call_support": "false",
        },
    )
    # Embedding
    client.add_model(
        args.embedding_provider,
        args.embedding,
        "text-embedding",
        {
            "base_url": args.ollama_url,
        },
    )

    # Reranker (Xinference)
    if args.rerank_model:
        client.add_model(
            args.rerank_provider,
            args.rerank_model,
            "rerank",
            {
                "server_url": args.xinference_url,
                "model_uid": args.rerank_model,
            },
        )

    # Set defaults
    default_settings = [
        {
            "model_type": "llm",
            "provider": args.model_provider,
            "model": args.model,
        },
        {
            "model_type": "text-embedding",
            "provider": args.embedding_provider,
            "model": args.embedding,
        },
    ]
    if args.rerank_model:
        default_settings.append({
            "model_type": "rerank",
            "provider": args.rerank_provider,
            "model": args.rerank_model,
        })
    client.set_default_models(default_settings)

    # --- Step 13: Find or create Knowledge Base ---
    print("\n--- Knowledge Base ---")
    kb_id = client.find_dataset("Documents")
    if not kb_id:
        kb_id = client.create_dataset(
            "Documents", args.embedding, args.embedding_provider
        )

    # --- Step 14: Dataset API key ---
    dataset_api_key = client.get_or_create_dataset_api_key()

    # --- Step 15-16: Find or create App ---
    print("\n--- Workflow ---")
    app_name = (
        f"\u0410\u0441\u0441\u0438\u0441\u0442\u0435\u043d\u0442"
        f" {args.company}"
    )
    app_id = client.find_app(app_name)
    if not app_id:
        app_id = client.create_app(app_name, args.company)

    # --- Step 17: Patch + upload + publish ---
    _, draft_hash = client.get_workflow_draft(app_id)

    print("\n  \u041f\u0430\u0442\u0447\u0438\u043d\u0433 workflow...")
    graph = patch_workflow(
        workflow_data, kb_id, dataset_api_key,
        args.model, args.company, args.model_provider,
    )
    features = patch_features(
        workflow_data.get("features", {}), args.company
    )

    client.update_workflow_draft(app_id, graph, features, draft_hash)
    client.publish_workflow(app_id)

    # --- Step 18-19: Service API key + save ---
    service_api_key = client.get_or_create_service_api_key(app_id)
    save_api_key(args.install_dir, service_api_key)

    print(f"\n=== \u0413\u043e\u0442\u043e\u0432\u043e ===")
    print(f"  App: {app_name}")
    print(f"  KB: Documents ({kb_id})")
    print(f"  LLM: {args.model} ({args.model_provider})")
    print(f"  Embedding: {args.embedding} ({args.embedding_provider})")
    if args.rerank_model:
        print(f"  Reranker: {args.rerank_model} ({args.rerank_provider})")
    print(
        f"  Service API Key: saved to "
        f"{args.install_dir}/.dify_service_api_key"
    )
    print("  .env: DIFY_API_KEY patched")

    return 0


if __name__ == "__main__":
    sys.exit(main())
