#!/usr/bin/env python3
"""
vault-sync.py - Professional Vault Project Synchronization Engine.
Supports single-file secret management with prefix-based distribution.
"""
import os
import sys
import argparse
import json
import urllib.request
import urllib.error
from pathlib import Path

# Prefix Mapping: Key Prefix -> Vault Subpath
PREFIX_MAP = {
    "UPSTOX_": "api/upstock",
    "ZERODHA_": "api/zerodha",
    "MONGO_": "database/mongo",
    "POSTGRES_": "database/postgres",
    "REDIS_": "database/redis",
    "INFLUXDB_": "database/influxdb",
    "KAFKA_": "kafka"
}

class VaultSyncEngine:
    def __init__(self, addr=None, token=None):
        self.token, self.addr = self._discover_creds(token, addr)
        if not self.token:
            raise ValueError("Vault Token not found. Set VAULT_TOKEN or ensure am-infra is initialized.")
        print(f"🔗 Connected to Vault at {self.addr}")

    def _discover_creds(self, token, addr):
        """Discovers Vault credentials from standard locations."""
        possible_paths = [
            Path("/workspaces/am-repos/am-infra/generated-credentials.txt"),
            Path("/workspaces/am-repos/am-infra/vault-keys.json"),
            Path(__file__).parent.parent.parent / "am-infra" / "generated-credentials.txt",
            Path(__file__).parent.parent.parent / "am-infra" / "vault-keys.json"
        ]
        for p in possible_paths:
            if not p.exists(): continue
            try:
                with open(p, "r") as f:
                    content = f.read()
                    if p.suffix == ".json":
                        data = json.loads(content)
                        return data.get("root_token"), addr or "http://localhost:8200"
                    for line in content.splitlines():
                        if "VAULT_ROOT_TOKEN=" in line:
                            return line.split("=", 1)[1].strip(), addr or "http://localhost:8200"
            except: continue
        return token or os.getenv("VAULT_TOKEN"), addr or os.getenv("VAULT_ADDR") or "http://localhost:8200"

    def load_env(self, filepath):
        kv = {}
        if not os.path.exists(filepath): return kv
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line: continue
                k, v = line.split('=', 1)
                kv[k.strip()] = v.strip().strip('"').strip("'")
        return kv

    def sync_path(self, vault_path, secrets):
        headers = {"X-Vault-Token": self.token, "Content-Type": "application/json"}
        url = f"{self.addr}/v1/kv/data/{vault_path}"
        
        existing = {}
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req) as res:
                existing = json.loads(res.read().decode('utf-8')).get("data", {}).get("data", {})
        except: pass

        if existing == secrets:
            print(f"✅ kv/{vault_path} up to date.")
            return

        existing.update(secrets)
        try:
            data_bytes = json.dumps({"data": existing}).encode('utf-8')
            req_post = urllib.request.Request(url, headers=headers, data=data_bytes, method="POST")
            with urllib.request.urlopen(req_post) as res_post:
                if res_post.status in [200, 204]:
                    print(f"🎉 Successfully synced {len(secrets)} keys to kv/{vault_path}")
        except Exception as e:
            print(f"❌ Failed to sync: {e}")

def main():
    parser = argparse.ArgumentParser(description="Professional Vault Project Sync Engine")
    parser.add_argument("--project", help="Single .env file for the whole project")
    parser.add_argument("--path", help="Specific Vault path override")
    parser.add_argument("--file", help="Specific .env file override")
    parser.add_argument("--env", default="preprod", help="Environment (default: preprod)")
    
    args = parser.parse_args()
    engine = VaultSyncEngine()

    if args.project:
        print(f"🚀 Starting Project Synchronization: {args.project}...")
        secrets = engine.load_env(args.project)
        if not secrets:
            print(f"❌ Error: {args.project} not found or empty.")
            sys.exit(1)

        # Distribute secrets based on prefix
        distributed = {} # path -> {key: val}
        for k, v in secrets.items():
            mapped = False
            for prefix, subpath in PREFIX_MAP.items():
                if k.startswith(prefix):
                    # Clean the key (remove prefix) for Vault
                    clean_key = k[len(prefix):]
                    vault_path = f"{args.env}/{subpath}"
                    if vault_path not in distributed: distributed[vault_path] = {}
                    distributed[vault_path][clean_key] = v
                    mapped = True
                    break
            if not mapped:
                print(f"⚠️ Warning: No prefix mapping for key '{k}'. Use UPSTOX_, ZERODHA_, MONGO_, etc.")

        for path, data in distributed.items():
            engine.sync_path(path, data)

    elif args.path and args.file:
        secrets = engine.load_env(args.file)
        if secrets: engine.sync_path(args.path, secrets)
    else:
        print("💡 Usage: python3 vault-sync.py --project .env.secrets  OR  <path> --file <env-file>")
        sys.exit(1)

if __name__ == "__main__":
    main()
