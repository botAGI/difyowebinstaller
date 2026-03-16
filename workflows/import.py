#!/usr/bin/env python3
"""
import.py — Import RAG workflow into Dify
1. Login → get access_token + csrf_token
2. Create Knowledge Base "Documents"
3. Create Dataset API key
4. Create Chatflow app
5. Get draft hash
6. Patch workflow JSON with KB ID, API key, model, company name
7. Push workflow draft
8. Publish workflow
9. Create Service API key
"""

import argparse
import base64
import json
import os
import re
import sys
import time
import http.cookiejar
import urllib.request
import urllib.error


class DifyClient:
    def __init__(self, base_url, console_prefix=""):
        self.base_url = base_url.rstrip("/")
        self.console_prefix = console_prefix.rstrip("/")
        self.access_token = None
        self.csrf_token = None
        # CookieJar handles all cookies automatically (session, access_token, etc.)
        self.cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar)
        )

    def _request(self, method, path, data=None, content_type="application/json"):
        if path.startswith("/console/") and self.console_prefix:
            path = f"{self.console_prefix}{path}"
        url = f"{self.base_url}{path}"
        headers = {}

        if self.csrf_token:
            headers["X-CSRF-Token"] = self.csrf_token

        body = None
        if data is not None:
            if content_type == "application/json":
                headers["Content-Type"] = "application/json"
                body = json.dumps(data).encode("utf-8")
            else:
                body = data

        req = urllib.request.Request(url, data=body, headers=headers, method=method)

        try:
            with self.opener.open(req, timeout=60) as resp:
                # Extract tokens from cookie jar for later use
                for cookie in self.cookie_jar:
                    if cookie.name == "access_token":
                        self.access_token = cookie.value
                    elif cookie.name == "csrf_token":
                        self.csrf_token = cookie.value

                resp_body = resp.read().decode("utf-8")
                if resp_body:
                    return json.loads(resp_body)
                return {}
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8") if e.fp else ""
            print(f"HTTP {e.code} {method} {path}: {error_body}", file=sys.stderr)
            raise

    def init_validate(self, init_password):
        """Step 1: Validate INIT_PASSWORD (Dify 1.13+ self-hosted)"""
        # Check if init already done
        try:
            status = self._request("GET", "/console/api/init")
            if status.get("status") == "finished":
                print("  Init: already completed")
                return
        except urllib.error.HTTPError:
            pass

        try:
            self._request("POST", "/console/api/init", {
                "password": init_password,
            })
            print("  Init: validated")
        except urllib.error.HTTPError as e:
            if e.code == 403:
                print("  Init: already completed")
            else:
                error_body = e.read().decode("utf-8") if e.fp else ""
                print(f"  Init: HTTP {e.code} — {error_body}", file=sys.stderr)

    def setup_account(self, email, password, name="Admin"):
        """Step 2: Create admin account"""
        # Check if setup already done
        try:
            status = self._request("GET", "/console/api/setup")
            if status.get("step") == "finished":
                print("  Setup: already completed")
                return
        except urllib.error.HTTPError:
            pass

        try:
            result = self._request("POST", "/console/api/setup", {
                "email": email,
                "name": name,
                "password": password,  # plain text, not base64
            })
            print("  Setup: account created")
            return result
        except urllib.error.HTTPError as e:
            if e.code == 403:
                print("  Setup: already completed")
            else:
                raise

    def login(self, email, password):
        """Step 3: Login and get access token"""
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
        print(f"  Login: OK (token: {self.access_token[:16]}...)")
        return result

    def create_dataset(self, name="Documents"):
        """Create Knowledge Base"""
        result = self._request("POST", "/console/api/datasets", {
            "name": name,
            "indexing_technique": "high_quality",
            "permission": "all_team_members",
        })
        kb_id = result.get("id", "")
        print(f"  Knowledge Base: {name} (id: {kb_id})")
        return kb_id

    def create_dataset_api_key(self):
        """Create a dataset (Service) API key"""
        result = self._request("POST", "/console/api/datasets/api-keys", {})
        api_key = result.get("api_key", "") or result.get("token", "")
        # Sometimes the key is nested
        if not api_key and isinstance(result, dict):
            api_key = result.get("key", "")
        print(f"  Dataset API Key: {api_key[:20]}...")
        return api_key

    def create_app(self, name, company_name="AGMind"):
        """Create Chatflow app"""
        result = self._request("POST", "/console/api/apps", {
            "name": name,
            "mode": "advanced-chat",
            "icon_type": "emoji",
            "icon": "\U0001f4da",
            "icon_background": "#E4FBCC",
            "description": f"{company_name} RAG Assistant",
        })
        app_id = result.get("id", "")
        print(f"  App: {name} (id: {app_id})")
        return app_id

    def get_workflow_draft(self, app_id):
        """Get current workflow draft (for hash)"""
        result = self._request("GET", f"/console/api/apps/{app_id}/workflows/draft")
        draft_hash = result.get("hash", "")
        print(f"  Draft hash: {draft_hash[:16]}...")
        return result, draft_hash

    def update_workflow_draft(self, app_id, graph, features, draft_hash):
        """Update workflow draft with hash"""
        result = self._request("POST", f"/console/api/apps/{app_id}/workflows/draft", {
            "graph": graph,
            "features": features,
            "hash": draft_hash,
        })
        print(f"  Draft updated: OK")
        return result

    def publish_workflow(self, app_id):
        """Publish workflow"""
        result = self._request("POST", f"/console/api/apps/{app_id}/workflows/publish", {})
        print(f"  Published: OK")
        return result

    def create_service_api_key(self, app_id):
        """Create Service API key for the app"""
        result = self._request("POST", f"/console/api/apps/{app_id}/api-keys", {})
        api_key = result.get("api_key", "") or result.get("token", "")
        if not api_key and isinstance(result, dict):
            api_key = result.get("key", "")
        print(f"  Service API Key: {api_key[:20]}...")
        return api_key


def patch_workflow(workflow_data, kb_id, api_key, model_name, company_name):
    """Patch workflow JSON with deployment-specific values"""
    graph = workflow_data.get("graph", workflow_data)
    nodes = graph.get("nodes", [])

    for node in nodes:
        data = node.get("data", {})
        node_type = data.get("type", "")

        # Patch knowledge-retrieval node — dataset_ids
        if node_type == "knowledge-retrieval":
            data["dataset_ids"] = [kb_id]
            print(f"  Patched: {data.get('title', node['id'])} → KB {kb_id}")

        # Patch HTTP request nodes — URLs and API keys
        elif node_type == "http-request":
            url = data.get("url", "")
            if "datasets/" in url:
                # Replace old KB ID in URL
                new_url = re.sub(
                    r'datasets/[a-f0-9-]+',
                    f'datasets/{kb_id}',
                    url
                )
                data["url"] = new_url

                # Replace API key
                auth = data.get("authorization", {})
                config = auth.get("config", {})
                if config.get("api_key"):
                    config["api_key"] = api_key
                    print(f"  Patched: {data.get('title', node['id'])} → API key + KB URL")

        # Patch LLM node — model name and system prompt
        elif node_type == "llm":
            model = data.get("model", {})
            if model:
                model["name"] = model_name
                print(f"  Patched: LLM model → {model_name}")

            # Patch system prompt with company name
            prompts = data.get("prompt_template", [])
            for prompt in prompts:
                if prompt.get("role") == "system":
                    text = prompt.get("text", "")
                    text = text.replace(
                        "Ты — ассистент по документации.",
                        f"Ты — ассистент по документации компании {company_name}."
                    )
                    prompt["text"] = text

    return graph


def patch_features(features, company_name):
    """Patch features (opening statement, etc.) with branding"""
    if features.get("opening_statement"):
        features["opening_statement"] = (
            f"👋 Привет! Я ассистент {company_name} по документам.\n\n"
            "📄 Задайте вопрос — найду ответ в документах\n"
            "📎 Прикрепите файл — загружу в базу знаний\n"
            "📋 /list — список документов\n"
            "🗑️ /delete <ID> — удалить документ"
        )
    return features


def wait_for_api(base_url, console_prefix="", timeout=300):
    """Wait for Dify API to be ready"""
    check_url = f"{base_url}{console_prefix}/console/api/setup"
    print(f"Ожидание Dify API ({check_url})...")
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(check_url)
            urllib.request.urlopen(req, timeout=5)
            return True
        except Exception:
            time.sleep(5)
    print("ОШИБКА: Dify API не отвечает", file=sys.stderr)
    return False


def save_api_key(install_dir, api_key):
    """Save the Service API key for Open WebUI configuration"""
    key_file = os.path.join(install_dir, ".dify_service_api_key")
    with open(key_file, "w") as f:
        f.write(api_key)
    os.chmod(key_file, 0o600)
    print(f"  API key saved: {key_file}")


def main():
    parser = argparse.ArgumentParser(description="Import RAG workflow into Dify")
    parser.add_argument("--url", default="http://localhost", help="Dify base URL")
    parser.add_argument("--email", required=True, help="Admin email")
    parser.add_argument("--password", required=True, help="Admin password (plaintext)")
    parser.add_argument("--model", default="qwen2.5:14b", help="LLM model name")
    parser.add_argument("--embedding", default="bge-m3", help="Embedding model")
    parser.add_argument("--company", default="AGMind", help="Company name")
    parser.add_argument("--workflow", required=True, help="Path to workflow JSON")
    parser.add_argument("--install-dir", default="/opt/agmind", help="Install directory")
    parser.add_argument("--console-prefix", default="", help="URL prefix for console API (e.g., /admin_token)")
    parser.add_argument("--init-password", default="", help="INIT_PASSWORD from .env (for first-boot validation)")
    args = parser.parse_args()

    # Wait for API
    if not wait_for_api(args.url, args.console_prefix):
        sys.exit(1)

    # Load workflow JSON
    with open(args.workflow, "r") as f:
        workflow_data = json.load(f)

    client = DifyClient(args.url, args.console_prefix)

    print("\n=== Настройка Dify ===\n")

    # Step 1: Init validation (Dify 1.13+ requires INIT_PASSWORD validation first)
    if args.init_password:
        client.init_validate(args.init_password)

    # Step 2: Setup account (first run)
    try:
        client.setup_account(args.email, args.password, f"{args.company} Admin")
    except Exception as e:
        print(f"  Setup skip: {e}")

    # Small delay for account creation
    time.sleep(3)

    # Step 3: Login
    client.login(args.email, args.password)

    # Step 4: Create Knowledge Base
    try:
        kb_id = client.create_dataset("Documents")
    except urllib.error.HTTPError as e:
        if e.code == 400:
            print("\n  ⚠ Модели ещё не настроены в Dify.")
            print("  Настройте модели вручную через Dify UI,")
            print("  затем создайте Knowledge Base.")
            print("\n=== Установка продолжена (workflow не импортирован) ===")
            return 0
        raise

    # Step 5: Create Dataset API key
    dataset_api_key = client.create_dataset_api_key()

    # Step 6: Create Chatflow app
    app_name = f"Ассистент {args.company}"
    app_id = client.create_app(app_name, args.company)

    # Step 7: Get draft hash
    _, draft_hash = client.get_workflow_draft(app_id)

    # Step 8: Patch workflow
    print("\n  Патчинг workflow...")
    graph = patch_workflow(workflow_data, kb_id, dataset_api_key, args.model, args.company)
    features = patch_features(workflow_data.get("features", {}), args.company)

    # Step 9: Push workflow draft
    client.update_workflow_draft(app_id, graph, features, draft_hash)

    # Step 10: Publish
    client.publish_workflow(app_id)

    # Step 11: Create Service API key
    service_api_key = client.create_service_api_key(app_id)

    # Save API key for Open WebUI
    save_api_key(args.install_dir, service_api_key)

    print(f"\n=== Готово ===")
    print(f"  App: {app_name}")
    print(f"  KB: Documents ({kb_id})")
    print(f"  Model: {args.model}")
    print(f"  Service API Key: {service_api_key}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
